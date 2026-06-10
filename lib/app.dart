import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/device/device_info.dart';
import 'core/i18n/locale_provider.dart';
import 'core/routing/app_router.dart';
import 'core/routing/deep_link_listener.dart';
import 'core/sharing/incoming_file_listener.dart';
import 'features/casting/presentation/widgets/incoming_cast_bootstrap.dart';
import 'features/lan/presentation/widgets/incoming_pin_bootstrap.dart';
import 'core/shortcuts/app_shortcuts.dart';
import 'core/splash/animated_splash.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/logger.dart';
import 'features/lan/data/lan_repository.dart';
import 'features/voice/data/voice_command_controller.dart';
import 'features/voice/presentation/voice_command_button.dart'
    show VoiceListenSheet;
import 'features/help/presentation/screens/onboarding_screen.dart';
import 'core/routing/app_routes.dart';
import 'l10n/app_localizations.dart';

class InteractProApp extends ConsumerStatefulWidget {
  const InteractProApp({super.key});

  @override
  ConsumerState<InteractProApp> createState() => _InteractProAppState();
}

class _InteractProAppState extends ConsumerState<InteractProApp> {
  /// Animated splash plays once per app launch. Once finished we never
  /// rebuild the splash widget — the user just sees the home screen on
  /// every subsequent navigation.
  bool _splashDone = false;

  /// Reference to the global keyboard handler we register in initState
  /// so we can remove it cleanly in dispose. HardwareKeyboard accepts
  /// any KeyEventCallback — we keep the closure identity so add/remove
  /// match.
  late final KeyEventCallback _voiceKeyHandler;

  @override
  void initState() {
    super.initState();

    // TV remote SEARCH key → trigger Pro's voice command flow.
    //
    // Background: Android TV reserves KEYCODE_ASSIST (the dedicated
    // mic button on the remote) for Google Assistant — apps can't
    // intercept it without privileged signing. KEYCODE_SEARCH on the
    // other hand IS reachable, and on Sony Bravia VH21 the
    // magnifying-glass remote button maps to it. On non-TV platforms
    // the handler is registered but the inner guard short-circuits,
    // so this is a no-op cost for phones.
    _voiceKeyHandler = (KeyEvent event) {
      if (event is! KeyDownEvent) return false;
      if (!DeviceInfo.isAndroidTv) return false;
      // Only fire on TV — search key on a phone with hardware
      // keyboard would be confusing.
      //
      // Two candidates:
      //   • LogicalKeyboardKey.find — Sony Bravia VH21 typically
      //     maps the magnifier remote button to this. Universal
      //     "find/search" constant available across Flutter
      //     versions (LogicalKeyboardKey.search was renamed/removed
      //     in some Flutter releases — don't rely on it).
      //   • LogicalKeyboardKey.launchAssistant — some Android TV
      //     firmwares emit this for the same button instead. Trying
      //     both costs nothing.
      //
      // If a third firmware variant surfaces (KEYCODE_TV_VOICE_INPUT
      // or similar), add it here. We'll learn the right keyId from
      // logcat the first time it doesn't fire.
      final lk = event.logicalKey;
      final isVoice = lk == LogicalKeyboardKey.find ||
          lk == LogicalKeyboardKey.launchAssistant;
      if (!isVoice) return false;

      // Pull the root navigator's context to anchor the bottom sheet.
      // If the app is still on the splash (no router context yet) the
      // call no-ops via the null-check.
      final router = ref.read(appRouterProvider);
      final ctx = router.routerDelegate.navigatorKey.currentContext;
      if (ctx == null) return false;

      // Fire-and-forget — the controller guards against re-entry, so
      // repeated rapid keypresses won't stack sheets.
      final controller = ref.read(voiceCommandControllerProvider);
      // ignore: discarded_futures
      controller.listen(
        context: ctx,
        sheetBuilder: (sheetCtx) => VoiceListenSheet(
          speech: controller.speech,
        ),
      );
      return true; // consume the event — no other handler runs
    };
    HardwareKeyboard.instance.addHandler(_voiceKeyHandler);
    // Eager-start the LAN repository at app boot. The repo is otherwise
    // lazy-initialized — it only fires the Bonsoir mDNS broadcast when
    // a screen reads lanRepositoryProvider (Nearby Devices,
    // SendToDeviceSheet, IncomingFileBootstrap). On TVs that's bad: the
    // TV is meant to be a passive receiver and the user should never
    // have to navigate ANYWHERE for the device to be discoverable.
    //
    // Using addPostFrameCallback so the read happens after the first
    // frame paints (avoids blocking the splash + lets ProviderScope
    // finish hydrating). listenManual returns a subscription that
    // survives for the lifetime of the State — we don't dispose it
    // because the LAN repo should run the entire app lifetime.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Touch the FutureProvider to trigger its async init. listenManual
      // would also work but a one-shot ref.read of the future is enough
      // here — once started, the repo stays alive via its own provider
      // ref-count (held alive by IncomingFileBootstrap's listenManual
      // on incomingSharesProvider).
      ref
          .read(lanRepositoryProvider.future)
          .then((_) =>
              appLogger.i('LAN repo eager-start kicked at app boot'))
          .catchError((Object e, StackTrace st) {
        appLogger.e('LAN repo eager-start failed', error: e, stackTrace: st);
      });
    });
  }

  @override
  void dispose() {
    // Remove the global key handler. In practice this only runs when
    // the app is being torn down (InteractProApp is the root) — but
    // keeping the symmetry avoids leaks during hot-restart in dev.
    HardwareKeyboard.instance.removeHandler(_voiceKeyHandler);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GoRouter router = ref.watch(appRouterProvider);
    final Locale? locale = ref.watch(localeProvider);

    // TV gets the high-contrast focus halo variant of the same brand
    // theme — D-pad navigation needs visible focus from 10ft. See
    // AppTheme._buildTv for the overrides. Set once at boot via
    // DeviceInfo.probe() so this is a one-line conditional.
    final useTvTheme = DeviceInfo.isAndroidTv;

    return MaterialApp.router(
      title: 'Interact Pro',
      debugShowCheckedModeBanner: false,
      theme: useTvTheme ? AppTheme.lightTv() : AppTheme.light(),
      darkTheme: useTvTheme ? AppTheme.darkTv() : AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      // The builder runs on every navigation. We always mount the deep-
      // link + incoming-file bootstraps. The animated splash overlay is
      // mounted only until it finishes — _splashDone gating prevents it
      // from replaying on subsequent rebuilds.
      builder: (context, child) {
        return AppShortcuts(
          child: Stack(
            children: [
              DeepLinkBootstrap(
                router: router,
                child: IncomingFileBootstrap(
                  router: router,
                  // IncomingCastBootstrap listens on /cast/start events
                  // from the LAN server and pushes a CastReceiverScreen
                  // when another Pro instance casts TO this device. Mounted
                  // INSIDE IncomingFileBootstrap so both listeners share
                  // the same router instance and survive the same parent
                  // lifecycle; no special ordering required since the
                  // file + cast event streams are independent.
                  child: IncomingCastBootstrap(
                    router: router,
                    // IncomingPinBootstrap listens on /pair/init events
                    // from the LAN server and pops a PIN dialog when
                    // another Pro instance starts a pair handshake
                    // against this device. Same nesting reasoning as
                    // IncomingCastBootstrap — independent streams, all
                    // listeners share the router lifecycle.
                    child: IncomingPinBootstrap(
                      child: _OnboardingGate(
                        router: router,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
              if (!_splashDone)
                Positioned.fill(
                  child: AnimatedSplash(
                    onDone: () {
                      if (mounted) setState(() => _splashDone = true);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Watches `shouldShowOnboardingProvider` and pushes the onboarding
/// route once on first launch (or major-version bump). Sits inside the
/// router's `builder`, after the splash, so the slides appear over a
/// fully-mounted Navigator + Scaffold.
///
/// We push the route imperatively rather than redirecting from
/// GoRouter's `redirect:` because the onboarding is a one-shot
/// experience — making it a redirect target would force every cold-
/// start to evaluate `SharedPreferences` synchronously, slowing TTFP.
class _OnboardingGate extends ConsumerStatefulWidget {
  const _OnboardingGate({required this.router, required this.child});
  final GoRouter router;
  final Widget child;
  @override
  ConsumerState<_OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<_OnboardingGate> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_checked || !mounted) return;
      final shouldShow = await ref.read(shouldShowOnboardingProvider.future);
      if (!mounted || !shouldShow) return;
      _checked = true;
      widget.router.pushNamed(AppRoutes.onboarding);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
