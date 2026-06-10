import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../analytics/analytics_service.dart';
import '../utils/logger.dart';
import 'app_routes.dart';

/// Maps incoming deep links to in-app routes.
///
/// Supported URIs:
///   `interactpro://open?path=/abs/path/to.pdf`     → Viewer
///   `interactpro://scan`                            → Scanner
///   `interactpro://translate?text=…&to=ur`          → Translation sheet
///   `interactpro://settings`                        → Settings
///   `https://interactpak.com/open?path=…`           → Viewer (Universal Link)
///
/// Other apps integrate by launching one of these URIs via
/// `url_launcher` / `Intent.ACTION_VIEW` / `UIApplication.shared.open`.
class DeepLinkHandler {
  DeepLinkHandler(this._ref);
  final Ref _ref;

  /// Returns true if the link was recognized and routed.
  Future<bool> handle(Uri uri, GoRouter router) async {
    appLogger.i('Deep link: $uri');
    final analytics = _ref.read(analyticsServiceProvider);

    // Universal links land on https://interactpak.com/<path>
    final isUniversal = uri.scheme == 'https' && uri.host == 'interactpak.com';
    final action = isUniversal
        ? uri.pathSegments.firstOrNull ?? ''
        : uri.host; // for interactpro://scan, host == 'scan'

    switch (action) {
      case 'open':
        final path = uri.queryParameters['path'];
        if (path == null || path.isEmpty) return false;
        await analytics.track(
          AnalyticsEvents.featureUsed,
          properties: {'feature': 'deep_link_open'},
        );
        router.pushNamed(AppRoutes.viewer, extra: path);
        return true;

      case 'scan':
        await analytics.track(
          AnalyticsEvents.featureUsed,
          properties: {'feature': 'deep_link_scan'},
        );
        router.pushNamed(AppRoutes.scanner);
        return true;

      case 'translate':
        // Translation is shown as a modal sheet from the Viewer; if there
        // isn't an active document, route to home with the text stashed —
        // wire that hand-off if/when you build a translate-only screen.
        await analytics.track(
          AnalyticsEvents.featureUsed,
          properties: {'feature': 'deep_link_translate'},
        );
        router.pushNamed(AppRoutes.home);
        return true;

      case 'settings':
        router.pushNamed(AppRoutes.settings);
        return true;

      default:
        appLogger.w('Unrecognized deep link action: $action');
        return false;
    }
  }
}

final deepLinkHandlerProvider = Provider<DeepLinkHandler>((Ref ref) {
  return DeepLinkHandler(ref);
});
