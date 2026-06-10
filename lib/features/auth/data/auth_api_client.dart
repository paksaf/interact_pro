import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/error/failures.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_user.dart';

/// Backend contract. Document this on the server side too — these are
/// the four endpoints `pro.interactpak.com/api/auth` must implement:
///
/// `POST /api/auth/otp/request`       body: `{ email | phone }`
///   → `200 { sentTo: 'email'|'sms', expiresInSec: 600 }`
///   → `429` rate-limited (returns retry-after header)
///   → `400` bad email / phone format
///
/// `POST /api/auth/otp/verify`        body: `{ email | phone, otp }`
///   → `200 { token, user: { id, email, phone, displayName, role,
///                            trialEndsAt, proActive } }`
///       — token is a JWT, valid 30d, signed HS256
///       — first verify for an unknown contact creates the user with a
///         7-day trial (server side)
///   → `401` wrong / expired OTP
///
/// `GET  /api/auth/me`                hdr: `Authorization: Bearer <token>`
///   → `200 { user }` (same shape as /verify)
///   → `401` token invalid / expired → client triggers signOut()
///
/// `POST /api/auth/sign-out`          hdr: `Authorization: Bearer <token>`
///   → `204` (the JWT is also blacklisted server-side)
///
/// Build defines (see core/config/api_config.dart):
///   AUTH_BASE_URL — defaults to https://pro.interactpak.com
///   AUTH_TOKEN_HEADER — default 'Authorization'
class AuthApiClient {
  AuthApiClient(this._secure, {http.Client? httpClient, String? baseUrl})
      : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? _resolvedBaseUrl;

  static const _kJwtKey = 'auth_jwt';
  static const _kUserKey = 'auth_user';

  static String get _resolvedBaseUrl {
    const fromDefine = String.fromEnvironment('AUTH_BASE_URL');
    if (fromDefine.isNotEmpty) return fromDefine;
    return 'https://pro.interactpak.com';
  }

  final SecureStore _secure;
  final http.Client _http;
  final String _baseUrl;

  Future<String?> _readJwt() => _secure.read(_kJwtKey);

  Future<void> _writeJwt(String jwt) => _secure.write(_kJwtKey, jwt);

  Future<void> _clearJwt() => _secure.delete(_kJwtKey);

  Future<AuthUser?> _readCachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUserKey);
    if (raw == null) return null;
    try {
      return AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      appLogger.w('cached user parse failed: $e');
      return null;
    }
  }

  Future<void> _cacheUser(AuthUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserKey, jsonEncode(user.toJson()));
  }

  Future<void> _clearUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserKey);
  }

  Future<Result<void>> requestOtp({String? email, String? phone}) async {
    if ((email == null || email.isEmpty) &&
        (phone == null || phone.isEmpty)) {
      return const Result.err(AuthFailure('Provide an email or phone number.'));
    }
    try {
      final resp = await _http
          .post(
            Uri.parse('$_baseUrl/api/auth/otp/request'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              if (email != null && email.isNotEmpty) 'email': email,
              if (phone != null && phone.isNotEmpty) 'phone': phone,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 429) {
        return const Result.err(NetworkFailure(
            'Too many requests. Try again in a minute.',),);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
            'Could not send code (${resp.statusCode}).',),);
      }
      return const Result.ok(null);
    } catch (e, st) {
      appLogger.e('requestOtp failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Network error sending OTP', cause: e));
    }
  }

  Future<Result<AuthUser>> verifyOtp({
    String? email,
    String? phone,
    required String otp,
  }) async {
    try {
      final resp = await _http
          .post(
            Uri.parse('$_baseUrl/api/auth/otp/verify'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              if (email != null && email.isNotEmpty) 'email': email,
              if (phone != null && phone.isNotEmpty) 'phone': phone,
              'otp': otp,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 401) {
        return const Result.err(AuthFailure('Wrong code. Try again.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
            'Verification failed (${resp.statusCode}).',),);
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final token = json['token'] as String?;
      final userJson = json['user'] as Map<String, dynamic>?;
      if (token == null || userJson == null) {
        return const Result.err(AuthFailure('Server returned an unexpected shape.'));
      }
      final user = AuthUser.fromJson(userJson);
      await _writeJwt(token);
      await _cacheUser(user);
      return Result.ok(user);
    } catch (e, st) {
      appLogger.e('verifyOtp failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Network error verifying code', cause: e));
    }
  }

  Future<Result<AuthUser>> me() async {
    final jwt = await _readJwt();
    if (jwt == null) {
      return const Result.err(AuthFailure('No session. Sign in.'));
    }
    try {
      final resp = await _http.get(
        Uri.parse('$_baseUrl/api/auth/me'),
        headers: {'Authorization': 'Bearer $jwt'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 401) {
        await signOut();
        return const Result.err(AuthFailure('Session expired. Sign in again.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const Result.err(NetworkFailure('Could not refresh user.'));
      }
      final user = AuthUser.fromJson(
          (jsonDecode(resp.body) as Map<String, dynamic>)['user']
              as Map<String, dynamic>,);
      await _cacheUser(user);
      return Result.ok(user);
    } catch (e, st) {
      appLogger.e('me() failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Network error', cause: e));
    }
  }

  Future<AuthUser?> restoreFromCache() async {
    final jwt = await _readJwt();
    if (jwt == null) return null;
    return _readCachedUser();
  }

  Future<void> signOut() async {
    final jwt = await _readJwt();
    if (jwt != null) {
      try {
        await _http
            .post(
              Uri.parse('$_baseUrl/api/auth/sign-out'),
              headers: {'Authorization': 'Bearer $jwt'},
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        appLogger.w('signOut server call failed (continuing locally): $e');
      }
    }
    await _clearJwt();
    await _clearUser();
  }

  /// Used by [SyncApiClient] and other authenticated callers to grab the
  /// current bearer token.
  Future<String?> bearerToken() => _readJwt();

  String get baseUrl => _baseUrl;

  // ── Trial renewal (admin-mediated) ───────────────────────────────────
  //
  // Until in-app purchase + web Stripe are live, users whose 7-day trial
  // has lapsed can ask the admin to extend. The client surfaces a
  // "Request renewal" button (paywall + trial banner) which calls
  // POST /api/auth/renewal/request — server records the request, emails
  // admin, returns 202 with `{requestId}`. Admin Screen lists pending
  // requests via GET /api/auth/renewal/pending and approves via POST
  // /api/auth/renewal/<id>/approve (extends trialEndsAt by 30d).
  //
  // Server endpoints not implemented yet — the methods below are wired
  // so the moment pro-api ships the routes, the app works without a
  // rebuild. Until then, the calls 404 and the UI surfaces "Admin
  // hasn't enabled renewal requests yet — contact support."

  /// Send a renewal request to the admin. [note] is an optional one-
  /// liner the user can include ("renewing for Q3 audit work" etc.).
  Future<Result<void>> requestRenewal({String? note}) async {
    final jwt = await _readJwt();
    if (jwt == null) {
      return const Result.err(AuthFailure('Sign in to request a renewal.'));
    }
    try {
      final resp = await _http
          .post(
            Uri.parse('$_baseUrl/api/auth/renewal/request'),
            headers: {
              'Authorization': 'Bearer $jwt',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 404) {
        return const Result.err(NetworkFailure(
          'Renewal requests are not yet enabled on the server. '
          'Contact support@interactpak.com to extend your trial.',
        ),);
      }
      if (resp.statusCode == 409) {
        return const Result.err(NetworkFailure(
          'You already have a pending renewal request. '
          'The admin will respond soon.',
        ),);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
          'Could not submit renewal (${resp.statusCode}).',
        ),);
      }
      return const Result.ok(null);
    } catch (e, st) {
      appLogger.e('requestRenewal failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Network error', cause: e));
    }
  }

  /// Admin-only: list pending renewal requests.
  /// Response shape: `{ requests: [{id, userId, displayName, email, phone,
  ///                                 trialEndsAt, requestedAt, note}] }`
  Future<Result<List<RenewalRequest>>> listPendingRenewals() async {
    final jwt = await _readJwt();
    if (jwt == null) {
      return const Result.err(AuthFailure('Sign in.'));
    }
    try {
      final resp = await _http.get(
        Uri.parse('$_baseUrl/api/auth/renewal/pending'),
        headers: {'Authorization': 'Bearer $jwt'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 403) {
        return const Result.err(AuthFailure('Admin role required.'));
      }
      if (resp.statusCode == 404) {
        // Endpoint not yet on server — render an empty list rather than
        // an error, so the admin UI shows "No pending renewals" instead
        // of a scary banner.
        return const Result.ok(<RenewalRequest>[]);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
          'Could not load renewals (${resp.statusCode}).',
        ),);
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (j['requests'] as List?) ?? const [];
      return Result.ok(list
          .map((e) => RenewalRequest.fromJson(e as Map<String, dynamic>))
          .toList(),);
    } catch (e, st) {
      appLogger.e('listPendingRenewals failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Network error', cause: e));
    }
  }

  /// Admin-only: approve a renewal request. Server extends the target
  /// user's trialEndsAt by 30 days and sends them an email + push.
  /// [extendDays] defaults to 30 — admin can override (UI field).
  Future<Result<void>> approveRenewal(String requestId, {int extendDays = 30}) async {
    return _renewalAction(requestId, 'approve', body: {'extendDays': extendDays});
  }

  /// Admin-only: decline a renewal request with an optional reason.
  Future<Result<void>> declineRenewal(String requestId, {String? reason}) async {
    return _renewalAction(requestId, 'decline',
        body: {if (reason != null && reason.isNotEmpty) 'reason': reason},);
  }

  Future<Result<void>> _renewalAction(
    String requestId,
    String action, {
    required Map<String, dynamic> body,
  }) async {
    final jwt = await _readJwt();
    if (jwt == null) {
      return const Result.err(AuthFailure('Sign in.'));
    }
    try {
      final resp = await _http
          .post(
            Uri.parse('$_baseUrl/api/auth/renewal/$requestId/$action'),
            headers: {
              'Authorization': 'Bearer $jwt',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 403) {
        return const Result.err(AuthFailure('Admin role required.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(NetworkFailure(
          'Could not $action renewal (${resp.statusCode}).',
        ),);
      }
      return const Result.ok(null);
    } catch (e, st) {
      appLogger.e('renewal $action failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Network error', cause: e));
    }
  }
}

/// Admin-listing row for /api/auth/renewal/pending.
class RenewalRequest {
  const RenewalRequest({
    required this.id,
    required this.userId,
    required this.displayName,
    this.email,
    this.phone,
    required this.trialEndsAt,
    required this.requestedAt,
    this.note,
  });

  final String id;
  final String userId;
  final String displayName;
  final String? email;
  final String? phone;
  final DateTime? trialEndsAt;
  final DateTime requestedAt;
  final String? note;

  factory RenewalRequest.fromJson(Map<String, dynamic> j) {
    return RenewalRequest(
      id: j['id'] as String,
      userId: j['userId'] as String,
      displayName: (j['displayName'] as String?) ?? 'User',
      email: j['email'] as String?,
      phone: j['phone'] as String?,
      trialEndsAt: j['trialEndsAt'] == null
          ? null
          : DateTime.tryParse(j['trialEndsAt'] as String),
      requestedAt:
          DateTime.tryParse(j['requestedAt'] as String? ?? '') ?? DateTime.now(),
      note: j['note'] as String?,
    );
  }
}

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl(this._client);

  final AuthApiClient _client;
  final StreamController<AuthUser?> _userCtrl =
      StreamController<AuthUser?>.broadcast();

  @override
  Stream<AuthUser?> watchUser() => _userCtrl.stream;

  @override
  Future<AuthUser?> restoreSession() async {
    final user = await _client.restoreFromCache();
    _userCtrl.add(user);
    if (user == null) return null;
    // Best-effort refresh from server. Failure (offline, server down)
    // doesn't kick the user out; we just keep the cached snapshot.
    final fresh = await _client.me();
    return fresh.fold(
      (u) {
        _userCtrl.add(u);
        return u;
      },
      (_) => user,
    );
  }

  @override
  Future<Result<void>> requestOtp({String? email, String? phone}) =>
      _client.requestOtp(email: email, phone: phone);

  @override
  Future<Result<AuthUser>> verifyOtp({
    String? email,
    String? phone,
    required String otp,
  }) async {
    final r = await _client.verifyOtp(email: email, phone: phone, otp: otp);
    r.fold((u) => _userCtrl.add(u), (_) {});
    return r;
  }

  @override
  Future<void> signOut() async {
    await _client.signOut();
    _userCtrl.add(null);
  }

  @override
  Future<Result<AuthUser>> refreshUser() async {
    final r = await _client.me();
    r.fold((u) => _userCtrl.add(u), (_) {});
    return r;
  }

  @override
  Future<Result<void>> requestRenewal({String? note}) =>
      _client.requestRenewal(note: note);

  @override
  Future<Result<List<RenewalRequest>>> listPendingRenewals() =>
      _client.listPendingRenewals();

  @override
  Future<Result<void>> approveRenewal(String requestId, {int extendDays = 30}) =>
      _client.approveRenewal(requestId, extendDays: extendDays);

  @override
  Future<Result<void>> declineRenewal(String requestId, {String? reason}) =>
      _client.declineRenewal(requestId, reason: reason);
}

final authApiClientProvider = Provider<AuthApiClient>((ref) {
  return AuthApiClient(ref.watch(secureStoreProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(ref.watch(authApiClientProvider));
});
