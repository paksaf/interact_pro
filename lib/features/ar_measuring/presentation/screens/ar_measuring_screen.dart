import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/app_routes.dart';

/// **Stub.** The full AR measurement screen needs `ar_flutter_plugin`,
/// which is currently disabled in `pubspec.yaml` because it conflicts
/// with every modern Android + iOS dep we use (permission_handler 11,
/// AndroidX, AGP 8 namespace, ARCore 1.32 vs ML Kit's GoogleToolboxForMac
/// 4.x, etc.). Until a maintained alternative ships, the AR measuring
/// route still exists — but it surfaces this informational screen
/// rather than crashing on a missing package.
///
/// The full implementation lives in git history at
/// `lib/features/ar_measuring/presentation/screens/ar_measuring_screen.dart`
/// before commit-that-disabled-AR; restore from there once the plugin
/// situation improves.
class ArMeasuringScreen extends StatelessWidget {
  const ArMeasuringScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AR measure')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.threed_rotation, size: 96, color: cs.outline),
                const SizedBox(height: 24),
                Text(
                  'AR measurement is on the roadmap',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Point-and-tap distance measurement using ARKit / ARCore '
                  'is paused while we wait for a maintained Flutter binding. '
                  'Until then, the photo-based measuring tool gives the '
                  'same numbers using a reference object.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () =>
                      context.pushReplacementNamed(AppRoutes.measuring),
                  icon: const Icon(Icons.straighten),
                  label: const Text('Use photo-based measure'),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
