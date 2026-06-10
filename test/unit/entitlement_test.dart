import 'package:flutter_test/flutter_test.dart';
import 'package:interact_pro/features/pro/domain/pro_entitlement.dart';

void main() {
  group('ProSubscription', () {
    test('free tier has only the [free] marker', () {
      const sub = ProSubscription.free;
      expect(sub.isPro, isFalse);
      expect(sub.has(ProEntitlement.free), isTrue);
      expect(sub.has(ProEntitlement.translation), isFalse);
      expect(sub.has(ProEntitlement.voiceReadAloud), isFalse);
      expect(sub.has(ProEntitlement.hotspots), isFalse);
    });

    test('pro tier unlocks every feature in proAll', () {
      const sub = ProSubscription(
        isPro: true,
        entitlements: proAll,
        productId: 'pro_yearly',
      );
      for (final e in proAll) {
        expect(sub.has(e), isTrue, reason: '$e should be unlocked');
      }
    });

    test('proAll contains every gated feature listed in the enum', () {
      // Anyone adding a new ProEntitlement should remember to put it in
      // proAll. This test catches that mistake.
      for (final e in ProEntitlement.values) {
        expect(proAll.contains(e), isTrue,
            reason: 'Add $e to proAll in pro_entitlement.dart',);
      }
    });
  });
}
