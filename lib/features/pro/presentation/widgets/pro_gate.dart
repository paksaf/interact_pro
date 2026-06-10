import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/app_routes.dart';
import '../../domain/pro_entitlement.dart';
import '../pro_provider.dart';

/// Wraps a child widget. If the user has the required entitlement, renders
/// the child unchanged; otherwise renders an upsell tap-target that opens
/// the paywall.
///
/// Use this around any UI affordance for a Pro feature:
/// ```dart
/// ProGate(
///   entitlement: ProEntitlement.translation,
///   child: TranslateButton(),
/// )
/// ```
class ProGate extends ConsumerWidget {
  const ProGate({
    required this.entitlement,
    required this.child,
    this.upsellLabel,
    super.key,
  });

  final ProEntitlement entitlement;
  final Widget child;
  final String? upsellLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(hasEntitlementProvider(entitlement));
    if (unlocked) return child;
    return _UpsellOverlay(
      label: upsellLabel ?? 'Pro feature',
      child: child,
    );
  }
}

class _UpsellOverlay extends StatelessWidget {
  const _UpsellOverlay({required this.child, required this.label});
  final Widget child;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AbsorbPointer(child: Opacity(opacity: 0.4, child: child)),
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.pushNamed(AppRoutes.paywall),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock, size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(label,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold,),),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
