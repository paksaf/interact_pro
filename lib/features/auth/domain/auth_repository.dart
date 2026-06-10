import '../../../core/utils/result.dart';
import '../data/auth_api_client.dart' show RenewalRequest;
import 'auth_user.dart';

/// Auth surface used by the UI. Backed by [AuthRepositoryImpl] which
/// talks to `pro.interactpak.com/api/auth` (the dedicated auth endpoint
/// on the project's Hetzner VPS).
///
/// Both email and phone flows are 2-step: request OTP → verify OTP.
/// Sign-up is implicit — first successful OTP for an unknown contact
/// creates the user with a 7-day trial.
abstract class AuthRepository {
  Stream<AuthUser?> watchUser();

  /// Restore a previously saved session from secure storage. Returns the
  /// user when a valid session is found, `null` otherwise.
  Future<AuthUser?> restoreSession();

  /// Send an OTP code to [email]. The server picks the delivery channel
  /// (email vs SMS) based on which one is non-null.
  Future<Result<void>> requestOtp({String? email, String? phone});

  /// Verify [otp] for the previously-requested [email] or [phone].
  /// Stores the JWT + user, broadcasts the new value via [watchUser].
  Future<Result<AuthUser>> verifyOtp({
    String? email,
    String? phone,
    required String otp,
  });

  /// Drop the cached JWT + user. The next API call will reject with a
  /// 401 and the UI bounces back to the login screen.
  Future<void> signOut();

  /// Refresh the user from the server — picks up role / Pro / trial
  /// changes that happen out-of-band (admin grants, IAP completes on
  /// another device, etc.).
  Future<Result<AuthUser>> refreshUser();

  /// User-side: ask the admin to extend the trial. Surfaces as a button
  /// on the trial banner + paywall after the 7-day trial has lapsed.
  /// Server side: creates a pending request row + emails admin.
  Future<Result<void>> requestRenewal({String? note});

  /// Admin-only: list pending renewal requests for review.
  Future<Result<List<RenewalRequest>>> listPendingRenewals();

  /// Admin-only: approve a renewal — extends the user's trial by
  /// [extendDays] (default 30) and pushes them a notification.
  Future<Result<void>> approveRenewal(String requestId, {int extendDays});

  /// Admin-only: decline a renewal with an optional reason.
  Future<Result<void>> declineRenewal(String requestId, {String? reason});
}
