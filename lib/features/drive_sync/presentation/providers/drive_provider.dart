import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/drive_repository_impl.dart';
import '../../domain/repositories/drive_repository.dart';

/// Live Drive auth state. UI watches this to know whether to show
/// "Connect Drive" or the user's connected account.
final driveAuthProvider =
    AsyncNotifierProvider<DriveAuthNotifier, DriveUser?>(DriveAuthNotifier.new);

class DriveAuthNotifier extends AsyncNotifier<DriveUser?> {
  @override
  Future<DriveUser?> build() async {
    return ref.read(driveRepositoryProvider).currentUser();
  }

  Future<void> signIn() async {
    state = const AsyncValue.loading();
    final res = await ref.read(driveRepositoryProvider).signIn();
    state = res.fold(
      (u) => AsyncValue.data(u),
      (f) => AsyncValue.error(f, StackTrace.current),
    );
  }

  Future<void> signOut() async {
    await ref.read(driveRepositoryProvider).signOut();
    state = const AsyncValue.data(null);
  }
}
