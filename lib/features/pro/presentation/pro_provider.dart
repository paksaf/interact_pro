import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/pro_repository.dart';
import '../domain/pro_entitlement.dart';

/// Live subscription state. Watch this from any feature to gate access:
///
/// ```dart
/// final isPro = ref.watch(proSubscriptionProvider).valueOrNull?.isPro ?? false;
/// ```
final proSubscriptionProvider =
    StreamProvider<ProSubscription>((Ref ref) async* {
  final repo = ref.watch(proRepositoryProvider);
  yield await repo.currentSubscription();
  yield* repo.watchSubscription();
});

/// Convenience: true iff a given entitlement is unlocked right now.
final hasEntitlementProvider =
    Provider.family.autoDispose<bool, ProEntitlement>((Ref ref, e) {
  final sub = ref.watch(proSubscriptionProvider).valueOrNull
      ?? ProSubscription.free;
  return sub.has(e);
});
