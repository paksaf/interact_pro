import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth_api_client.dart';
import '../../domain/auth_user.dart';

/// Streamed user-or-null. Drives `redirect` in app_router so signed-out
/// users land on the login screen and admins see the admin nav item.
final authUserProvider = StreamProvider<AuthUser?>((ref) async* {
  final repo = ref.watch(authRepositoryProvider);
  // Seed from cache first so cold-start doesn't flash the login screen.
  final cached = await repo.restoreSession();
  yield cached;
  yield* repo.watchUser();
});

/// Convenience for read-only consumers that don't need the stream — flat
/// boolean for "is the user signed in right now".
final isSignedInProvider = Provider<bool>((ref) {
  return ref.watch(authUserProvider).asData?.value != null;
});

/// Has-trial-or-pro check. Used by paywalls to decide whether a feature
/// should run or surface an upgrade prompt.
final hasFullAccessProvider = Provider<bool>((ref) {
  final user = ref.watch(authUserProvider).asData?.value;
  return user?.hasFullAccess ?? false;
});

/// Days left in the user's trial. Negative when the trial has elapsed.
/// Null when the user has no trial (already on Pro, or trial-less).
final trialDaysLeftProvider = Provider<int?>((ref) {
  final user = ref.watch(authUserProvider).asData?.value;
  if (user == null || user.trialEndsAt == null) return null;
  final delta = user.trialEndsAt!.difference(DateTime.now());
  return delta.inDays;
});
