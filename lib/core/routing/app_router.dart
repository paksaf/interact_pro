import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../device/device_info.dart';
import '../layout/responsive.dart';
import '../../features/drive_sync/presentation/providers/drive_provider.dart';
import '../../features/drive_sync/presentation/screens/drive_browser_screen.dart';
import '../../features/editor/presentation/screens/editor_screen.dart';
import '../../l10n/app_localizations.dart';

import '../../features/converter/presentation/screens/unit_converter_screen.dart';
import '../../features/handwriting/presentation/screens/handwriting_screen.dart';
import '../../features/admin/presentation/screens/admin_screen.dart';
import '../../features/ar_measuring/presentation/screens/ar_measuring_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/otp_screen.dart';
import '../../features/book_viewer/presentation/screens/book_viewer_screen.dart';
import '../../features/casting/presentation/screens/cast_receiver_screen.dart';
import '../../features/lan/domain/entities.dart' show IncomingCast;
import '../../features/handwriting_doc/presentation/screens/handwriting_doc_screen.dart';
import '../../features/library/presentation/screens/library_screen.dart';
import '../../features/support_chat/presentation/screens/support_chat_screen.dart';
import '../../features/home/presentation/screens/home_screen.dart';
import '../../features/image_identifier/presentation/screens/image_identifier_screen.dart';
import '../../features/sticky_notes/presentation/screens/notes_screen.dart';
import '../../features/help/presentation/screens/help_screen.dart';
import '../../features/help/presentation/screens/onboarding_screen.dart';
import '../../features/image_viewer/presentation/screens/image_viewer_screen.dart';
import '../../features/measuring/presentation/screens/measuring_tool_screen.dart';
import '../../features/ocr/presentation/screens/batch_image_ocr_screen.dart';
import '../../features/ocr/presentation/screens/ocr_screen.dart';
import '../../features/pro/presentation/screens/paywall_screen.dart';
import '../../features/lan/presentation/screens/nearby_devices_screen.dart';
import '../../features/lan/presentation/screens/web_share_screen.dart';
import '../../features/tags/presentation/tag_manager_screen.dart';
import '../../features/bookmarks/presentation/reference_diary_screen.dart';
import '../../features/signatures/presentation/verification_screen.dart';
import '../../features/scanner/presentation/screens/scanner_screen.dart';
import '../../features/signed_documents/presentation/screens/find_signed_screen.dart';
import '../../features/settings/presentation/screens/settings_screen.dart';
import '../../features/tts/presentation/screens/tts_settings_screen.dart';
import '../../features/signature/presentation/screens/signature_pad_screen.dart';
import '../../features/viewer/presentation/screens/viewer_screen.dart';
import 'app_routes.dart';

final appRouterProvider = Provider<GoRouter>((Ref ref) {
  return GoRouter(
    initialLocation: AppRoutes.pathHome,
    debugLogDiagnostics: false,
    // External-scheme guard: when Android invokes the app via "Open with"
    // from WhatsApp, Files, Gmail, etc. it delivers a content:// or file://
    // URI on the platform deep-link channel. go_router 14+ auto-routes that
    // URI as a location string, finds no matching GoRoute, and renders its
    // default "Page Not Found" screen. Until we wire actual file-import
    // (read content:// via ContentResolver → copy to local PDF dir → push
    // viewer with that path), redirect any non-app scheme to home so the
    // user lands on a working screen instead of an error.
    redirect: (context, state) {
      final loc = state.uri.toString();
      if (loc.startsWith('content://') ||
          loc.startsWith('file://') ||
          loc.startsWith('android-app://')) {
        // TODO(file-import): hand `state.uri` to a ContentResolver bridge
        // that copies to /docs and routes to /viewer with the new path.
        return AppRoutes.pathHome;
      }
      return null;
    },
    routes: [
      ShellRoute(
        builder: (context, state, child) => _RootShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.pathHome,
            name: AppRoutes.home,
            builder: (_, __) => const HomeScreen(),
          ),
          GoRoute(
            path: AppRoutes.pathOcr,
            name: AppRoutes.ocr,
            builder: (_, GoRouterState state) {
              // The viewer's "Run OCR on this PDF" overflow passes the
              // current PDF path via `extra`. The bottom-nav OCR tab
              // doesn't pass anything → null falls through to the
              // file-picker entry point.
              final initialPath = state.extra as String?;
              return OcrScreen(initialPdfPath: initialPath);
            },
          ),
          GoRoute(
            path: AppRoutes.pathScanner,
            name: AppRoutes.scanner,
            builder: (_, __) => const ScannerScreen(),
          ),
          GoRoute(
            path: AppRoutes.pathDrive,
            name: AppRoutes.driveBrowser,
            builder: (_, __) => const DriveBrowserScreen(),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.pathViewer,
        name: AppRoutes.viewer,
        builder: (_, GoRouterState state) {
          final path = state.extra! as String;
          return ViewerScreen(filePath: path);
        },
      ),
      GoRoute(
        path: AppRoutes.pathImageViewer,
        name: AppRoutes.imageViewer,
        builder: (_, GoRouterState state) {
          final path = state.extra! as String;
          return ImageViewerScreen(filePath: path);
        },
      ),
      GoRoute(
        path: AppRoutes.pathEditor,
        name: AppRoutes.editor,
        builder: (_, GoRouterState state) {
          final path = state.extra! as String;
          return EditorScreen(filePath: path);
        },
      ),
      GoRoute(
        path: AppRoutes.pathSignaturePad,
        name: AppRoutes.signaturePad,
        builder: (_, __) => const SignaturePadScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathPaywall,
        name: AppRoutes.paywall,
        builder: (_, __) => const PaywallScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathSettings,
        name: AppRoutes.settings,
        builder: (_, __) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathTtsSettings,
        name: AppRoutes.ttsSettings,
        builder: (_, __) => const TtsSettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathNearbyDevices,
        name: AppRoutes.nearbyDevices,
        builder: (_, __) => const NearbyDevicesScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathWebShare,
        name: AppRoutes.webShare,
        builder: (_, __) => const WebShareScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathTagManager,
        name: AppRoutes.tagManager,
        builder: (_, __) => const TagManagerScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathReferenceDiary,
        name: AppRoutes.referenceDiary,
        builder: (_, __) => const ReferenceDiaryScreen(),
      ),
      // Verification screen — accessed by passing a 3-tuple
      // (documentId, pdfPath, documentTitle) as extra so the screen
      // can re-hash the current PDF on disk and run verify.
      GoRoute(
        path: AppRoutes.pathVerifySignatures,
        name: AppRoutes.verifySignatures,
        builder: (context, state) {
          final args = state.extra as Map<String, String>;
          return VerificationScreen(
            documentId: args['documentId']!,
            pdfPath: args['pdfPath']!,
            documentTitle: args['documentTitle']!,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.pathFindSigned,
        name: AppRoutes.findSigned,
        builder: (_, __) => const FindSignedScreen(),
      ),
      // Pro-to-Pro cast receiver screen — pushed by IncomingCastBootstrap
      // when /cast/start lands on this device's LAN server. The initial
      // IncomingCast event is the route's `extra` so the screen can read
      // sender host/port + doc title without round-tripping through the
      // provider on first build.
      GoRoute(
        path: AppRoutes.pathCastReceiver,
        name: AppRoutes.castReceiver,
        builder: (_, GoRouterState state) {
          return CastReceiverScreen(initial: state.extra! as IncomingCast);
        },
      ),
      GoRoute(
        path: AppRoutes.pathImageIdentifier,
        name: AppRoutes.imageIdentifier,
        builder: (_, __) => const ImageIdentifierScreen(),
      ),
      // Sticky notes (task #260) — multi-kind capture with location
      // reference back to the active book/page. Source in
      // lib/features/sticky_notes/.
      GoRoute(
        path: AppRoutes.pathStickyNotes,
        name: AppRoutes.stickyNotes,
        builder: (_, __) => const NotesScreen(),
      ),
      // Help (task #270) — feature catalog accessible any time from the
      // AppBar "?" icon. Source in lib/features/help/.
      GoRoute(
        path: AppRoutes.pathHelp,
        name: AppRoutes.help,
        builder: (_, __) => const HelpScreen(),
      ),
      // First-run onboarding (task #270) — auto-pushed by app.dart when
      // shouldShowOnboardingProvider returns true. Five swipeable slides.
      GoRoute(
        path: AppRoutes.pathOnboarding,
        name: AppRoutes.onboarding,
        builder: (_, __) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathConverter,
        name: AppRoutes.converter,
        builder: (_, __) => const UnitConverterScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathBatchOcr,
        name: AppRoutes.batchOcr,
        builder: (_, __) => const BatchImageOcrScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathMeasuring,
        name: AppRoutes.measuring,
        builder: (_, __) => const MeasuringToolScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathHandwriting,
        name: AppRoutes.handwriting,
        builder: (_, __) => const HandwritingScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathHandwritingDoc,
        name: AppRoutes.handwritingDoc,
        builder: (_, __) => const HandwritingDocScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathArMeasuring,
        name: AppRoutes.arMeasuring,
        builder: (_, __) => const ArMeasuringScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathLibrary,
        name: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathBookViewer,
        name: AppRoutes.bookViewer,
        builder: (_, GoRouterState state) {
          final path = state.extra! as String;
          return BookViewerScreen(pdfPath: path);
        },
      ),
      GoRoute(
        path: AppRoutes.pathLogin,
        name: AppRoutes.login,
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathOtp,
        name: AppRoutes.otp,
        builder: (_, GoRouterState state) {
          // The login screen passes a private _OtpExtra here; OtpExtra
          // unifies that with the public form so this route doesn't
          // depend on the login file's private types.
          return OtpScreen(contact: OtpExtra.from(state.extra));
        },
      ),
      GoRoute(
        path: AppRoutes.pathAdmin,
        name: AppRoutes.admin,
        builder: (_, __) => const AdminScreen(),
      ),
      GoRoute(
        path: AppRoutes.pathSupportChat,
        name: AppRoutes.supportChat,
        builder: (_, __) => const SupportChatScreen(),
      ),
    ],
  );
});

class _RootShell extends ConsumerStatefulWidget {
  const _RootShell({required this.child});
  final Widget child;

  @override
  ConsumerState<_RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<_RootShell> {
  int _index = 0;

  // Two nav layouts share the same indices for the first 4:
  //   0 Home  1 OCR  2 Scan  3 Drive   (+ 4 Settings on tablet/TV)
  //
  // On phones we drop Settings — it stays accessible via the AppBar gear
  // because the bottom nav is already crowded. On tablet/TV we always
  // show Settings as a 5th tab so it's reachable when the AppBar
  // overflows off-screen (the bug TV user hit).
  static const _phonePaths = [
    AppRoutes.pathHome,
    AppRoutes.pathOcr,
    AppRoutes.pathScanner,
    AppRoutes.pathDrive,
  ];
  static const _wideScreenPaths = [
    AppRoutes.pathHome,
    AppRoutes.pathOcr,
    AppRoutes.pathScanner,
    AppRoutes.pathDrive,
    AppRoutes.pathSettings,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isWide = WindowSize.of(context).isTabletOrWider;

    final baseDestinations = [
      NavigationDestination(
        icon: const Icon(Icons.description_outlined),
        selectedIcon: const Icon(Icons.description),
        label: l10n.navRecent,
      ),
      NavigationDestination(
        icon: const Icon(Icons.text_snippet_outlined),
        selectedIcon: const Icon(Icons.text_snippet),
        label: l10n.navOcr,
      ),
      NavigationDestination(
        icon: const Icon(Icons.document_scanner_outlined),
        selectedIcon: const Icon(Icons.document_scanner),
        label: l10n.navScan,
      ),
      NavigationDestination(
        icon: const Icon(Icons.cloud_outlined),
        selectedIcon: const Icon(Icons.cloud),
        label: l10n.navDrive,
      ),
    ];
    final destinations = isWide
        ? [
            ...baseDestinations,
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: l10n.settingsTitle,
            ),
          ]
        : baseDestinations;
    final paths = isWide ? _wideScreenPaths : _phonePaths;

    // TV form factor gets a custom focusable nav row — Material's
    // NavigationBar doesn't render persistent focus on TV remotes
    // (the highlight flickers for ~30ms on focus-enter then disappears,
    // and OK key activation is unreliable). Phone/tablet keep the
    // standard NavigationBar for touch.
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isTvLike = DeviceInfo.isAndroidTv ||
        (shortestSide >= 720 &&
            (Theme.of(context).platform == TargetPlatform.android));

    // ── TV nav strategy (task #159 + #253 fix 2026-05-20) ──────────
    // Material's NavigationRail looked right but its destinations
    // ate D-pad focus on Bravia VH21 — user reported "left side panel
    // still not selectable or working" on 2026-05-20 (#253). The
    // fix: use the SAME _TvNavTile widget that the bottom _TvNavBar
    // uses (proven focusable via FocusableActionDetector + activator
    // shortcuts for OK/Enter/Space/GameButtonA). Render it vertically
    // inside a fixed-width side strip.
    //
    // Phone/tablet keep the bottom NavigationBar (works fine for
    // touch + the Material 3 default for compact-width devices).
    if (isTvLike) {
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              SizedBox(
                width: 88,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border(
                      right: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 0.5,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      for (var i = 0; i < destinations.length; i++)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 4),
                          child: _TvNavTile(
                            destination: destinations[i],
                            selected: i == _index,
                            autofocus: i == _index,
                            onTap: () {
                              setState(() => _index = i);
                              context.go(paths[i]);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index < destinations.length ? _index : 0,
        destinations: destinations,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          context.go(paths[i]);
        },
      ),
    );
  }
}

/// TV-friendly replacement for Material's NavigationBar. Renders the
/// same icons + labels but each destination is wrapped in a
/// FocusableActionDetector so D-pad arrows move focus visibly across
/// tiles (cyan ring + 1.04× scale on focus) and OK / Enter / Space /
/// GameButtonA all fire the tap callback.
///
/// Auto-focuses the currently-selected tile on mount so the TV remote
/// has a starting D-pad target. Up arrow leaves the nav row (returns
/// focus to the page content above).
class _TvNavBar extends StatelessWidget {
  const _TvNavBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onTap,
  });

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < destinations.length; i++)
            Expanded(
              child: _TvNavTile(
                destination: destinations[i],
                selected: i == selectedIndex,
                autofocus: i == selectedIndex,
                onTap: () => onTap(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _TvNavTile extends StatefulWidget {
  const _TvNavTile({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final NavigationDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_TvNavTile> createState() => _TvNavTileState();
}

class _TvNavTileState extends State<_TvNavTile> {
  bool _focused = false;

  static const _activateShortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ringColor =
        _focused ? const Color(0xFF22D3EE) : Colors.transparent;
    final iconColor = widget.selected ? cs.primary : cs.onSurfaceVariant;
    final labelColor = widget.selected ? cs.primary : cs.onSurfaceVariant;
    final icon = widget.selected
        ? (widget.destination.selectedIcon ?? widget.destination.icon)
        : widget.destination.icon;

    // Touch-tap target is a plain GestureDetector — NO InkWell. Inside
    // FocusableActionDetector, InkWell's own focus + key handling
    // competed with our ActivateIntent and ate the OK-key press. With
    // GestureDetector we keep onTap for touch, and the OK key flows
    // cleanly through ActivateIntent → onInvoke → widget.onTap.
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _activateShortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _focused ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: widget.selected
                  ? cs.secondaryContainer.withValues(alpha: 0.6)
                  : Colors.transparent,
              border: Border.all(color: ringColor, width: 2),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: ringColor.withValues(alpha: 0.5),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme(
                  data: IconThemeData(color: iconColor, size: 22),
                  child: icon,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.destination.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: labelColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DrivePlaceholder extends ConsumerWidget {
  const _DrivePlaceholder();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(driveAuthProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive')),
      body: auth.when(
        data: (user) => Center(
          child: Text(user == null ? 'Not signed in' : 'Signed in as ${user.email}'),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => ref.read(driveAuthProvider.notifier).signIn(),
        label: const Text('Connect Drive'),
        icon: const Icon(Icons.login),
      ),
    );
  }
}
