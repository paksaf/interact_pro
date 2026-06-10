import 'package:flutter/material.dart';

import 'app_permissions.dart';

/// Shared "Permission needed" dialog. When the user dismissed a prompt
/// permanently we can't re-prompt them — only deep-link to settings.
///
/// Use:
/// ```dart
/// final ok = await ensurePermission(
///   context: context,
///   request: AppPermissions.requestCamera,
///   featureLabel: 'Camera',
///   reason: 'Scanning needs the camera to capture pages.',
/// );
/// if (!ok) return;
/// ```
Future<bool> ensurePermission({
  required BuildContext context,
  required Future<dynamic> Function() request,
  required String featureLabel,
  required String reason,
}) async {
  final dynamic result = await request();
  // `result.fold(...)` is called on a `dynamic` so its declared type
  // parameter is erased at the call site — Dart infers `dynamic` regardless
  // of the `<Future<bool>>` annotation. The explicit `as Future<bool>` makes
  // the analyser trust us; at runtime the Result<T> always returns a
  // `Future<bool>` here, matching the two branches below.
  final Future<bool> outcome = result.fold<Future<bool>>(
    (_) async => true,
    (dynamic failure) async {
      if (!context.mounted) return false;
      final bool permanent =
          (failure.message as String).toLowerCase().contains('permanently denied');
      final bool? shouldOpen = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$featureLabel permission needed'),
          content: Text(
            permanent
                ? '$reason\n\nIt looks like you previously denied this '
                    "permission. Tap 'Open Settings' to enable it."
                : reason,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(permanent ? 'Open Settings' : 'Try again'),
            ),
          ],
        ),
      );
      if (shouldOpen != true) return false;
      if (permanent) {
        await AppPermissions.openSettings();
        // We can't know what the user did in Settings — caller can re-attempt
        // the action and re-trigger this flow.
        return false;
      }
      // User chose to retry — caller should re-invoke.
      return false;
    },
  ) as Future<bool>;
  return await outcome;
}
