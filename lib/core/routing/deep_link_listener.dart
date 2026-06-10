import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../utils/logger.dart';
import 'deep_link_handler.dart';

/// Bridges the platform deep-link channel into our [DeepLinkHandler].
///
/// Two URI sources are subscribed:
///   • **Initial link** — non-null when the app was *cold-launched* by a
///     `interactpro://` or universal-link tap.
///   • **URI stream** — fires when a deep link arrives while the app is
///     already running (warm launch).
///
/// The listener is mounted via [DeepLinkBootstrap] near the root of the
/// widget tree so it has access to a live [GoRouter] instance for routing.
class DeepLinkListener {
  DeepLinkListener(this._handler) : _appLinks = AppLinks();

  final DeepLinkHandler _handler;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;

  Future<void> attach(GoRouter router) async {
    // Cold-launch link.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        appLogger.i('Initial deep link: $initial');
        // Defer one frame so the router is ready to receive pushNamed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_handler.handle(initial, router));
        });
      }
    } catch (e) {
      appLogger.w('getInitialLink failed: $e');
    }

    // Warm-launch links.
    _sub = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handler.handle(uri, router)),
      onError: (Object e) => appLogger.w('uriLinkStream error: $e'),
    );
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
  }
}

final deepLinkListenerProvider = Provider<DeepLinkListener>((ref) {
  final listener = DeepLinkListener(ref.watch(deepLinkHandlerProvider));
  ref.onDispose(listener.detach);
  return listener;
});

/// Inert widget that activates the [DeepLinkListener] for the lifetime of
/// the subtree. Mount it once, immediately under [MaterialApp.router].
class DeepLinkBootstrap extends ConsumerStatefulWidget {
  const DeepLinkBootstrap({required this.router, required this.child, super.key});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<DeepLinkBootstrap> createState() => _DeepLinkBootstrapState();
}

class _DeepLinkBootstrapState extends ConsumerState<DeepLinkBootstrap> {
  @override
  void initState() {
    super.initState();
    // attach() is async — fire and forget; errors are logged inside.
    unawaited(
      ref.read(deepLinkListenerProvider).attach(widget.router),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
