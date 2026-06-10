import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as ga;
import 'package:http/http.dart' as http;

import '../../../../core/utils/logger.dart';

/// OAuth 2.0 Device Authorization Grant ("Device Flow") for Google APIs.
///
/// Why this exists: as of late 2024 Google deprecated the standard
/// google_sign_in flow on Android TV for Drive specifically. The April
/// 2024 security fix also added extra friction for sideloaded apps
/// (Pro on Bravia is sideloaded). The Device Flow is the official path
/// Google now supports for "TVs and Limited Input devices":
///
///   1. POST /device/code → server returns a short user_code (e.g.
///      "WDJB-MJHT") + a verification_url (e.g. https://google.com/device)
///   2. App shows the code + URL on the TV. User opens the URL on a
///      phone or laptop, types the code, grants access.
///   3. App polls /token every `interval` seconds until the user
///      completes the grant (or the device_code expires).
///   4. On success: refresh_token + access_token are persisted; the
///      googleapis SDK uses them via an AuthClient built from the
///      refresh_token.
///
/// This implementation is hand-rolled against the documented endpoints
/// rather than pulling in `google_sign_in_tizen` because:
///   - The Tizen package is named after Samsung TVs; its inclusion on
///     an Android TV codebase is misleading and brittle.
///   - The flow is just two HTTPS POSTs and a polling loop — small
///     enough to own.
///   - Direct control over polling backoff, slow_down handling, and
///     UI updates.
///
/// Setup required ON THE USER SIDE: create a NEW OAuth 2.0 Client ID
/// in Google Cloud Console (project interact-pro-496115) of type
/// "TVs and Limited Input devices" — NOT the Android type used by the
/// phone path. Save the resulting client_id into
/// `AppConstants.driveTvClientId` AND the client_secret into
/// `AppConstants.driveTvClientSecret`.
///
/// FIX 2026-06-10: unlike most installed-app flows, Google's Limited
/// Input device clients ARE issued a client_secret, and the /token
/// endpoint REQUIRES it for BOTH the device-code poll and the
/// refresh-token grant. Omitting it returns
/// `invalid_request: client_secret is missing` — the exact "client
/// secret missing" failure reported on the TV. (Per Google's docs the
/// secret in a Limited-Input client is not treated as confidential.)
///
/// References:
///   https://developers.google.com/identity/protocols/oauth2/limited-input-device
///   https://datatracker.ietf.org/doc/html/rfc8628
class GoogleDeviceFlowAuth {
  GoogleDeviceFlowAuth({
    required this.clientId,
    required this.clientSecret,
    required this.scopes,
    http.Client? httpClient,
    FlutterSecureStorage? secureStorage,
  })  : _http = httpClient ?? http.Client(),
        _storage = secureStorage ?? const FlutterSecureStorage();

  /// Google "TVs and Limited Input devices" OAuth client id. Different
  /// from the Android client id used by phone google_sign_in.
  final String clientId;

  /// Client secret paired with [clientId]. Required by Google's token
  /// endpoint for Limited-Input device clients (see class doc).
  final String clientSecret;

  /// Scopes to request — same shape as google_sign_in. For Drive use
  /// `['https://www.googleapis.com/auth/drive.file']`.
  final List<String> scopes;

  final http.Client _http;
  final FlutterSecureStorage _storage;

  static const _deviceEndpoint =
      'https://oauth2.googleapis.com/device/code';
  static const _tokenEndpoint =
      'https://oauth2.googleapis.com/token';

  // SecureStorage keys — separate from the phone google_sign_in's
  // internal storage so the two paths don't fight.
  static const _kRefreshToken = 'drive_tv_refresh_token';
  static const _kAccessToken = 'drive_tv_access_token';
  static const _kAccessExpiry = 'drive_tv_access_expiry';

  /// Begin the flow. Returns the user-facing details so the TV UI can
  /// display them while [pollForToken] runs in the background.
  Future<DeviceCodeResponse> requestDeviceCode() async {
    final res = await _http.post(
      Uri.parse(_deviceEndpoint),
      body: {
        'client_id': clientId,
        'scope': scopes.join(' '),
      },
    );
    if (res.statusCode != 200) {
      throw DeviceFlowException(
        'device_code_request_failed',
        'Could not request device code (${res.statusCode}). '
            'Verify the TV OAuth client_id is correct.',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return DeviceCodeResponse(
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String,
      verificationUrl:
          (json['verification_url'] ?? json['verification_uri']) as String,
      expiresIn: (json['expires_in'] as num).toInt(),
      interval: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }

  /// Poll the token endpoint until the user completes the grant on
  /// their phone. Returns the access + refresh token pair on success.
  /// Throws [DeviceFlowException] with a clear code on failure
  /// (expired, denied, user not yet ready — caller decides whether
  /// to surface or keep waiting).
  Future<TokenPair> pollForToken(DeviceCodeResponse codeResponse) async {
    var interval = Duration(seconds: codeResponse.interval);
    final deadline = DateTime.now().add(
      Duration(seconds: codeResponse.expiresIn),
    );

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(interval);
      final res = await _http.post(
        Uri.parse(_tokenEndpoint),
        body: {
          'client_id': clientId,
          // REQUIRED for Limited-Input device clients — Google rejects
          // the poll with "client_secret is missing" without it.
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
          'device_code': codeResponse.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      final json = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200) {
        // Success.
        final pair = TokenPair(
          accessToken: json['access_token'] as String,
          refreshToken: json['refresh_token'] as String?,
          tokenType: json['token_type'] as String? ?? 'Bearer',
          expiresIn: (json['expires_in'] as num).toInt(),
          scope: (json['scope'] as String?)?.split(' ') ?? scopes,
        );
        await _persist(pair);
        appLogger.i('Drive Device Flow: token received');
        return pair;
      }

      final errorCode = json['error'] as String?;
      switch (errorCode) {
        case 'authorization_pending':
          // User hasn't completed grant yet — keep polling.
          break;
        case 'slow_down':
          // Google asks us to back off the polling interval by 5 s.
          interval += const Duration(seconds: 5);
          appLogger.i('Drive Device Flow: slow_down → polling every '
              '${interval.inSeconds}s');
          break;
        case 'access_denied':
          throw DeviceFlowException(
            'access_denied',
            'You declined to grant access. Try again.',
          );
        case 'expired_token':
          throw DeviceFlowException(
            'expired_token',
            'The sign-in code expired. Tap "Sign in" again to get a new one.',
          );
        default:
          throw DeviceFlowException(
            errorCode ?? 'token_poll_failed',
            (json['error_description'] as String?) ??
                'Could not complete sign-in (${res.statusCode}).',
            statusCode: res.statusCode,
            body: res.body,
          );
      }
    }
    throw DeviceFlowException(
      'expired_token',
      'Sign-in code expired before you completed grant. Try again.',
    );
  }

  /// Returns a valid access token for API calls — refreshing
  /// transparently if the cached one has expired. Null when the user
  /// hasn't completed Device Flow yet (UI should prompt sign-in).
  Future<String?> currentAccessToken() async {
    final access = await _storage.read(key: _kAccessToken);
    final expiryIso = await _storage.read(key: _kAccessExpiry);
    final refresh = await _storage.read(key: _kRefreshToken);
    if (access != null && expiryIso != null) {
      final expiry = DateTime.tryParse(expiryIso);
      if (expiry != null &&
          DateTime.now().isBefore(expiry.subtract(const Duration(minutes: 1)))) {
        return access;
      }
    }
    if (refresh == null) return null;
    try {
      return await _refreshAccessToken(refresh);
    } catch (e) {
      appLogger.w('Drive Device Flow: refresh failed → user must sign in again: $e');
      return null;
    }
  }

  /// Adapter that returns an `AuthClient` the googleapis SDK can use
  /// directly. Refreshes under the hood every API call so the
  /// existing googleapis-based code in `google_drive_datasource.dart`
  /// works without changes once switched onto this path.
  Future<ga.AuthClient?> authenticatedClient() async {
    final access = await currentAccessToken();
    if (access == null) return null;
    final expiryIso = await _storage.read(key: _kAccessExpiry);
    final expiry = expiryIso != null
        ? DateTime.tryParse(expiryIso)?.toUtc()
        : DateTime.now().toUtc().add(const Duration(minutes: 50));
    final credentials = ga.AccessCredentials(
      ga.AccessToken('Bearer', access, expiry ??
          DateTime.now().toUtc().add(const Duration(minutes: 50))),
      await _storage.read(key: _kRefreshToken),
      scopes,
    );
    return ga.authenticatedClient(_http, credentials);
  }

  Future<String?> _refreshAccessToken(String refreshToken) async {
    final res = await _http.post(
      Uri.parse(_tokenEndpoint),
      body: {
        'client_id': clientId,
        // Same requirement as the device-code poll (see class doc).
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      },
    );
    if (res.statusCode != 200) {
      throw DeviceFlowException(
        'refresh_failed',
        'Could not refresh access token (${res.statusCode}).',
        statusCode: res.statusCode,
        body: res.body,
      );
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final access = json['access_token'] as String;
    final expiresIn = (json['expires_in'] as num).toInt();
    await _storage.write(key: _kAccessToken, value: access);
    await _storage.write(
      key: _kAccessExpiry,
      value: DateTime.now()
          .add(Duration(seconds: expiresIn))
          .toUtc()
          .toIso8601String(),
    );
    return access;
  }

  Future<void> _persist(TokenPair pair) async {
    await _storage.write(key: _kAccessToken, value: pair.accessToken);
    if (pair.refreshToken != null) {
      await _storage.write(key: _kRefreshToken, value: pair.refreshToken);
    }
    await _storage.write(
      key: _kAccessExpiry,
      value: DateTime.now()
          .add(Duration(seconds: pair.expiresIn))
          .toUtc()
          .toIso8601String(),
    );
  }

  /// Revoke the refresh token + clear local storage. Used by sign-out.
  Future<void> signOut() async {
    final refresh = await _storage.read(key: _kRefreshToken);
    if (refresh != null) {
      try {
        await _http.post(
          Uri.parse('https://oauth2.googleapis.com/revoke'),
          body: {'token': refresh},
        );
      } catch (e) {
        appLogger.w('Drive Device Flow: revoke failed (non-fatal): $e');
      }
    }
    await _storage.delete(key: _kAccessToken);
    await _storage.delete(key: _kRefreshToken);
    await _storage.delete(key: _kAccessExpiry);
  }

  /// True when a refresh token is persisted — the user has completed
  /// Device Flow at least once and we can refresh silently.
  Future<bool> hasRefreshToken() async {
    final t = await _storage.read(key: _kRefreshToken);
    return t != null && t.isNotEmpty;
  }
}

class DeviceCodeResponse {
  const DeviceCodeResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresIn,
    required this.interval,
  });
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresIn;
  final int interval;
}

class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    required this.scope,
  });
  final String accessToken;
  final String? refreshToken;
  final String tokenType;
  final int expiresIn;
  final List<String> scope;
}

class DeviceFlowException implements Exception {
  DeviceFlowException(
    this.code,
    this.message, {
    this.statusCode,
    this.body,
  });
  final String code;
  final String message;
  final int? statusCode;
  final String? body;
  @override
  String toString() => '$code: $message';
}
