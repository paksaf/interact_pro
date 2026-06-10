import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../../core/device/device_capabilities.dart';
import '../../../../core/device/device_info.dart';
import '../../../../core/layout/responsive.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../auth/presentation/widgets/trial_banner.dart';
import '../../../casting/data/local_ip.dart';
import '../../../updates/presentation/widgets/update_banner.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../../pro/presentation/pro_provider.dart';
import '../../../library/presentation/widgets/book_card.dart';
import '../../../library/presentation/widgets/shelf_row.dart';
import '../../../tags/presentation/tag_picker_sheet.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/presentation/providers/viewer_provider.dart';
import '../../../voice/presentation/voice_command_button.dart';
import '../widgets/recent_documents.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../lan/data/lan_repository.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(allDocumentsProvider);
    final isPro = ref.watch(proSubscriptionProvider).valueOrNull?.isPro ?? false;
    final user = ref.watch(authUserProvider).asData?.value;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Interact Pro'),
            const SizedBox(width: 8),
            if (isPro)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('PRO',
                    style: TextStyle(color: Colors.white, fontSize: 10,
                        fontWeight: FontWeight.bold,),),
              ),
          ],
        ),
        actions: [
          // Phone-narrow screens fit ~6 icons in the AppBar before
          // they get clipped. Keep the highest-value, most-frequent
          // actions visible; tuck creative tools into a "⋮" overflow.
          // The Icons.search button that lived here pre-2026-05-12
          // was deleted — it had an empty onPressed and never did
          // anything. If/when a real search experience ships, it
          // goes in the overflow first, then promotes if it earns
          // its slot.
          if (!isPro)
            TextButton.icon(
              onPressed: () => context.pushNamed(AppRoutes.paywall),
              icon: const Icon(Icons.workspace_premium),
              label: const Text('Upgrade'),
            ),
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: 'Library / shelf view',
            onPressed: () => context.pushNamed(AppRoutes.library),
          ),
          // Sticky notes — multi-kind capture (text/voice/image/handwriting)
          // with location reference back to the active book/page. Source
          // in lib/features/sticky_notes/.
          IconButton(
            icon: const Icon(Icons.sticky_note_2_outlined),
            tooltip: 'Sticky notes',
            onPressed: () => context.pushNamed(AppRoutes.stickyNotes),
          ),
          // Help / training — always-accessible feature catalog with
          // step-by-step guides + TV remote + touch hints. Source in
          // lib/features/help/. The first-run onboarding flow uses the
          // same content; users who skipped onboarding land here.
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Help & feature guide',
            onPressed: () => context.pushNamed(AppRoutes.help),
          ),
          // Voice command — mic-based shortcut so TV remote users can
          // just say "open scanner", "library", "settings", etc.
          // instead of D-pad-navigating through icons. Stays visible
          // because on TV it's the primary input modality.
          const VoiceCommandButton(),
          IconButton(
            icon: Icon(user == null
                ? Icons.account_circle_outlined
                : Icons.account_circle,),
            tooltip: user == null ? 'Sign in' : 'Account',
            onPressed: () => context.pushNamed(
              user == null ? AppRoutes.login : AppRoutes.settings,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.pushNamed(AppRoutes.settings),
          ),
          // Overflow menu — creative tools + admin live here. The
          // PopupMenuButton uses the standard 3-dot icon and respects
          // theme so the focus halo stays consistent with the rest of
          // the AppBar.
          PopupMenuButton<String>(
            tooltip: 'More tools',
            onSelected: (route) => context.pushNamed(route),
            itemBuilder: (ctx) => <PopupMenuEntry<String>>[
              const PopupMenuItem(
                value: AppRoutes.imageIdentifier,
                child: ListTile(
                  leading: Icon(Icons.image_search),
                  title: Text('Identify image'),
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: AppRoutes.handwriting,
                child: ListTile(
                  leading: Icon(Icons.draw_outlined),
                  title: Text('Write by hand'),
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: AppRoutes.handwritingDoc,
                child: ListTile(
                  leading: Icon(Icons.spellcheck_outlined),
                  title: Text('Transcribe handwriting'),
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: AppRoutes.arMeasuring,
                child: ListTile(
                  leading: Icon(Icons.straighten_outlined),
                  title: Text('AR measure'),
                  dense: true,
                ),
              ),
              const PopupMenuItem(
                value: AppRoutes.converter,
                child: ListTile(
                  leading: Icon(Icons.calculate_outlined),
                  title: Text('Unit converter'),
                  dense: true,
                ),
              ),
              if (user?.isAdmin == true)
                const PopupMenuItem(
                  value: AppRoutes.admin,
                  child: ListTile(
                    leading: Icon(Icons.admin_panel_settings_outlined),
                    title: Text('Admin'),
                    dense: true,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // App-update banner — pings /api/version on launch and shows
          // a "new version available" / "update required" pill above
          // everything else when the running build is stale.
          const UpdateBanner(),
          // Trial / paywall awareness banner above the document list.
          // Hidden entirely for Pro users and signed-out users.
          const TrialBanner(),
          // Diagnostic strip — reports the size class the home screen
          // is currently rendering so we can confirm TV form-factor
          // detection on real hardware. Tappable: long-press to dismiss
          // for the rest of the session. Hidden once a known-good
          // window class has been observed twice (i.e. when we know
          // the detection is stable).
          const _LayoutDebugStrip(),
          Expanded(
            child: WindowSize.of(context).isTabletOrWider
                ? _TabletHomeBody(docs: docs)
                : _PhoneHomeBody(docs: docs),
          ),
          // Bottom IP banner — only renders on TV. Gives the user the
          // address to type into another device's "Connect by IP" form
          // when mDNS discovery isn't working. Sized big so it's
          // readable from a sofa across the room.
          const _TvIpBanner(),
        ],
      ),
      // Two-FAB cluster: small chat bubble on the left, primary
      // "Import PDF" on the right. Chat bubble only renders when the
      // user is signed in (anonymous users have nowhere to receive a
      // reply, so we don't tease the feature).
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (user != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FloatingActionButton.small(
                heroTag: 'support_chat',
                tooltip: 'Support chat — AI first, admin reply within 24h',
                onPressed: () => context.pushNamed(AppRoutes.supportChat),
                child: const Icon(Icons.support_agent),
              ),
            ),
          FloatingActionButton.extended(
            heroTag: 'import_pdf',
            onPressed: () async {
              // FilePicker throws on TVs without a system file manager
              // (Android TV / Fire TV ship with neither — they assume
              // app installs come via Play Store, not file picking). On
              // those devices the SYSTEM shows its own "no app" toast
              // BEFORE the exception bubbles to Flutter, so the
              // try/catch fallback alone wasn't enough — users still
              // saw the system error. Pre-detect TV-shaped screens and
              // skip file_picker entirely, going straight to the
              // Drive / Scan sheet. shortestSide ≥ 720 covers every
              // 1080p+ TV but never a phone or tablet in portrait.
              // OS-reported TV signal trumps dimension math — Sony
              // Bravia VH21 can give shortestSide ~300 in compact-
              // window mode, but UiModeManager still correctly reports
              // TELEVISION. See lib/core/device/device_info.dart.
              final shortestSide =
                  MediaQuery.of(context).size.shortestSide;
              final isTvLike = DeviceInfo.isAndroidTv ||
                  (shortestSide >= 720 &&
                      (Platform.isAndroid || Platform.isLinux));
              if (isTvLike) {
                _showImportFallbackSheet(context);
                return;
              }
              try {
                final res = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['pdf'],
                );
                final pickedPath = res?.files.first.path;
                if (pickedPath == null) return;

                // Copy the picked file into our app's PDF folder so it
                // survives the user moving / deleting the original. Then
                // open() upserts it into the drift index — recents
                // updates automatically.
                final paths = await ref.read(appPathsProvider.future);
                final targetPath = paths.pdfPathFor(p.basename(pickedPath));
                if (pickedPath != targetPath) {
                  await File(pickedPath).copy(targetPath);
                }

                final repo = await ref.read(pdfRepositoryProvider.future);
                await repo.open(targetPath);

                // Refresh the recents list.
                ref.invalidate(allDocumentsProvider);
              } catch (e) {
                if (!context.mounted) return;
                _showImportFallbackSheet(context);
              }
            },
            icon: const Icon(Icons.add),
            label: const Text('Import PDF'),
          ),
        ],
      ),
    );
  }
}

/// Phone layout — what the home screen always was: a vertical list of
/// recent docs.
class _PhoneHomeBody extends StatelessWidget {
  const _PhoneHomeBody({required this.docs});
  final AsyncValue<List<PdfDocument>> docs;

  @override
  Widget build(BuildContext context) {
    return docs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) => list.isEmpty
          ? const _EmptyState()
          : RecentDocuments(
              documents: list,
              onTap: (doc) => context.pushNamed(
                AppRoutes.viewer,
                extra: doc.path,
              ),
            ),
    );
  }
}

/// Tablet / desktop / TV layout — left rail of shortcut tiles, right pane.
/// On TV-sized screens (shortest side ≥ 720dp) the right pane renders a
/// bookshelf — physical-looking shelves with book spines — instead of the
/// list-of-rows layout that's appropriate for tablets in portrait. The
/// bookshelf reads better from across a room.
class _TabletHomeBody extends StatelessWidget {
  const _TabletHomeBody({required this.docs});
  final AsyncValue<List<PdfDocument>> docs;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // TV-shaped screens get the bookshelf body; tablets in portrait get
    // the existing list. Threshold: shortestSide ≥ 720 — covers every
    // 1080p/4K TV and rules out tablets in portrait.
    // Trust OS UiModeManager first; fall back to dimensions. See
    // lib/core/device/device_info.dart for the why.
    final isTvLike = DeviceInfo.isAndroidTv ||
        MediaQuery.of(context).size.shortestSide >= 720;
    // 2026-05-17: removed the left _ShortcutRail. It duplicated the
    // AppBar overflow ("⋮") menu — same six entries (Library / Write
    // by hand / Transcribe / Identify / AR measure / Converter) shown
    // twice on screen. The AppBar overflow stays as the canonical
    // launcher; the rail was eating ~280 px of horizontal real-estate
    // for no unique affordance. Body now takes full width.
    //
    // If we later want a TV-specific quick-launch rail back, it
    // should live as a collapsible floating button (per user request:
    // "make it floating small buttons on left side, before name on
    // top"), not as a fixed-width column that competes with content.
    final bodyChild = docs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (list) {
        if (list.isEmpty) return const _EmptyState();
        if (isTvLike) {
          return _BookshelfBody(documents: list);
        }
        return RecentDocuments(
          documents: list,
          onTap: (doc) => Navigator.of(context)
              .pushNamed('/viewer', arguments: doc),
        );
      },
    );
    // Use a local ref so cs stays in scope for any future tweaks.
    // (We dropped the divider + rail entirely.)
    // ignore: unused_local_variable
    final _ = cs;
    return bodyChild;
  }
}

/// Inline bookshelf used as the TV home body. Mirrors
/// `lib/features/library/presentation/screens/library_screen.dart` shelf
/// layout but without its own AppBar (the home AppBar wraps it).
class _BookshelfBody extends StatelessWidget {
  const _BookshelfBody({required this.documents});
  final List<PdfDocument> documents;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7EFDC), Color(0xFFE8DABA)],
        ),
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // Larger books on TV — sized for couch viewing distance.
          const bookHeight = 260.0;
          const bookFootprint = bookHeight * 0.72 + 28;
          final perShelf =
              (constraints.maxWidth / bookFootprint).floor().clamp(3, 10);
          final shelves = <List<PdfDocument>>[];
          for (var i = 0; i < documents.length; i += perShelf) {
            shelves.add(documents.sublist(
              i,
              (i + perShelf).clamp(0, documents.length),
            ),);
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
            itemCount: shelves.length,
            itemBuilder: (_, i) {
              final row = shelves[i];
              return ShelfRow(
                books: row
                    .asMap()
                    .entries
                    .map<Widget>((entry) {
                      final idx = entry.key;
                      final doc = entry.value;
                      // On TV: ALWAYS open in BookViewer (full-screen
                      // page-flip) regardless of page count. The 10-ft
                      // reading experience is the whole reason a user
                      // is on TV; the editor view's pinch/scroll model
                      // is wrong for D-pad input. Long-press still
                      // surfaces the menu to override to editor view
                      // when the user wants annotation tools.
                      return BookCard(
                        pdfPath: doc.path,
                        height: bookHeight,
                        // First book on first shelf gets the autofocus —
                        // gives the TV remote a starting D-pad target.
                        autofocus: i == 0 && idx == 0,
                        onTap: () => context.pushNamed(
                          AppRoutes.bookViewer,
                          extra: doc.path,
                        ),
                        onLongPress: () => _showBookModeMenu(
                          context,
                          pdfPath: doc.path,
                          documentId: doc.id,
                          documentTitle: doc.title,
                        ),
                      );
                    })
                    .toList(),
              );
            },
          );
        },
      ),
    );
  }

  void _showBookModeMenu(
    BuildContext context, {
    required String pdfPath,
    required String documentId,
    required String documentTitle,
  }) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('Open with page-flip'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.pushNamed(AppRoutes.bookViewer, extra: pdfPath);
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Open in editor view'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.pushNamed(AppRoutes.viewer, extra: pdfPath);
              },
            ),
            const Divider(height: 1),
            // Task #2 — apply/unapply tags on this PDF. Opens the
            // TagPickerSheet with the doc's current tags pre-selected.
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Tags…'),
              subtitle: const Text('Apply colored labels to this PDF'),
              onTap: () async {
                Navigator.of(sheetCtx).pop();
                await showTagPickerSheet(
                  context,
                  documentId: documentId,
                  documentTitle: documentTitle,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutRail extends ConsumerWidget {
  const _ShortcutRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = <_RailTile>[
      const _RailTile(
        icon: Icons.menu_book_outlined,
        label: 'Library',
        route: AppRoutes.library,
      ),
      const _RailTile(
        icon: Icons.draw_outlined,
        label: 'Write by hand',
        route: AppRoutes.handwriting,
      ),
      const _RailTile(
        icon: Icons.spellcheck_outlined,
        label: 'Transcribe handwriting',
        route: AppRoutes.handwritingDoc,
      ),
      const _RailTile(
        icon: Icons.image_search,
        label: 'Identify image',
        route: AppRoutes.imageIdentifier,
      ),
      const _RailTile(
        icon: Icons.straighten_outlined,
        label: 'AR measure',
        route: AppRoutes.arMeasuring,
      ),
      const _RailTile(
        icon: Icons.calculate_outlined,
        label: 'Unit converter',
        route: AppRoutes.converter,
      ),
      // OCR + Scan deliberately omitted — both already live in the
      // bottom NavigationBar (Recent / OCR / Scan / Drive, configured
      // in core/routing/app_router.dart). Putting them in the rail
      // too just added noise. Anything UNIQUE to the rail (creative
      // tools that don't have a dedicated tab) stays.
    ];
    final user = ref.watch(authUserProvider).asData?.value;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Shortcuts',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        // Autofocus the FIRST tile so the TV remote's D-pad has a
        // landing target on app launch. Each tile is wrapped in a
        // _FocusableRailTile that paints a cyan ring + scales up on
        // focus AND binds D-pad OK / Enter / Numpad-Enter / Space /
        // GameButtonA → ActivateIntent → onTap, so any TV remote can
        // both SEE the focused tile and ACTIVATE it. Without these
        // wrappers the ListTile's default focus halo flickers for
        // ~30 ms (Material default) and disappears, leaving the user
        // with no idea what's selected.
        ...tiles.asMap().entries.map((entry) {
              final i = entry.key;
              final t = entry.value;
              return _FocusableRailTile(
                icon: t.icon,
                label: t.label,
                autofocus: i == 0,
                onTap: () => context.pushNamed(t.route),
              );
            }),
        if (user?.isAdmin == true) ...[
          const Divider(),
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Admin'),
            onTap: () => context.pushNamed(AppRoutes.admin),
            dense: true,
          ),
        ],
      ],
    );
  }
}

class _RailTile {
  const _RailTile({
    required this.icon,
    required this.label,
    required this.route,
  });
  final IconData icon;
  final String label;
  final String route;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.description_outlined, size: 96, color: cs.outline),
            const SizedBox(height: 16),
            Text('No documents yet',
                style: Theme.of(context).textTheme.titleLarge,),
            const SizedBox(height: 8),
            Text('Add one of these ways:',
                style: TextStyle(color: cs.onSurfaceVariant),),
            const SizedBox(height: 16),
            // Three ways to get a PDF in. Crucially, on TVs the
            // FilePicker often fails ("no app to handle this") because
            // there's no system file manager — Drive and Scan are the
            // only viable paths there.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                Builder(builder: (ctx) {
                  return FilledButton.tonalIcon(
                    onPressed: () => GoRouter.of(ctx).pushNamed(AppRoutes.driveBrowser),
                    icon: const Icon(Icons.cloud_outlined),
                    label: const Text('From Google Drive'),
                  );
                },),
                // Hide on Android TV — no camera, the scanner activity
                // crashes on launch. Power users can flip "Show advanced
                // controls" in Settings → Display to override.
                CapabilityGate.camera(
                  child: Builder(builder: (ctx) {
                    return FilledButton.tonalIcon(
                      onPressed: () => GoRouter.of(ctx).pushNamed(AppRoutes.scanner),
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: const Text('Scan with camera'),
                    );
                  },),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Or tap the green "Import PDF" button to pick a file. '
              '(May not work on TVs without a file manager — use Drive instead.)',
              style: TextStyle(color: cs.outline, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// One-row diagnostic strip at the top of the home screen reporting
/// what MediaQuery sees right now: size, density, classified window
/// class, and whether we believe this is a TV. Helpful for diagnosing
/// "why is my TV still rendering portrait?" without an adb logcat.
/// Long-press to hide for the session.
class _LayoutDebugStrip extends StatefulWidget {
  const _LayoutDebugStrip();
  @override
  State<_LayoutDebugStrip> createState() => _LayoutDebugStripState();
}

class _LayoutDebugStripState extends State<_LayoutDebugStrip> {
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    // Release builds NEVER show the debug HUD — there's no long-press
    // affordance on TV remotes so once it shows on a TV the user has no
    // way to dismiss it. Devs still see it in `flutter run` / debug
    // APKs. (Fix 2026-05-21 after user-reported Bravia screenshot.)
    if (!kDebugMode) return const SizedBox.shrink();
    if (_hidden) return const SizedBox.shrink();
    final mq = MediaQuery.of(context);
    final s = mq.size;
    final cls = WindowSize.of(context);
    // Two TV signals: OS UiModeManager (authoritative) vs the
    // dimension heuristic. Show both so we can tell at a glance which
    // path resolved the layout — useful when debugging form-factor
    // detection on a new TV model.
    final osTv = DeviceInfo.isAndroidTv;
    final dimTv = s.shortestSide >= 720;
    return GestureDetector(
      onLongPress: () => setState(() => _hidden = true),
      child: Container(
        width: double.infinity,
        color: Colors.black.withValues(alpha: 0.6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          '${s.width.toStringAsFixed(0)}×${s.height.toStringAsFixed(0)} '
          '· short=${s.shortestSide.toStringAsFixed(0)} '
          '· dpr=${mq.devicePixelRatio.toStringAsFixed(2)} '
          '· class=${cls.name} '
          '· tv(os)=$osTv tv(dim)=$dimTv '
          '· (long-press to hide)',
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'monospace',
            fontSize: 10,
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet shown when file picking is unavailable (TV) or fails
/// (no file manager installed). Offers Drive + Scan as alternatives,
/// both of which work without the system file picker.
///
/// Extracted so the FAB handler can call it from BOTH paths:
///   - pre-emptive (TV detected → skip file_picker entirely), and
///   - reactive (file_picker threw → catch handler).
void _showImportFallbackSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    // isScrollControlled lets the sheet grow past the default 50%
    // viewport height — critical on TV where the body has 540 logical
    // pixels and a fixed-height sheet truncates the "Other paths" help
    // box. Combined with the SingleChildScrollView below, the sheet
    // now sizes to its content up to ~85% of the screen, then
    // scrolls. (Was task #159 — user reported the help text was
    // hidden behind the bottom nav.)
    isScrollControlled: true,
    builder: (sheetCtx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
        ),
      child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    color: Theme.of(sheetCtx).colorScheme.primary,),
                const SizedBox(width: 8),
                Text("Choose how to import",
                    style: Theme.of(sheetCtx).textTheme.titleMedium,),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'TVs and many new devices have no file picker app. '
              'Use one of these to load a PDF:',
              style: TextStyle(
                color: Theme.of(sheetCtx).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              autofocus: true,
              onPressed: () {
                Navigator.of(sheetCtx).pop();
                GoRouter.of(sheetCtx).pushNamed(AppRoutes.driveBrowser);
              },
              icon: const Icon(Icons.cloud_outlined),
              label: const Text('Browse Google Drive'),
            ),
            const SizedBox(height: 8),
            // Same gate as the empty-state above — hidden on TV.
            CapabilityGate.camera(
              child: FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  GoRouter.of(sheetCtx).pushNamed(AppRoutes.scanner);
                },
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Scan with camera'),
              ),
            ),
            const SizedBox(height: 8),
            // Receive-from-phone path — open the Nearby Devices
            // screen where this TV broadcasts its mDNS presence
            // and waits for a Pro-on-phone instance to push a PDF
            // via `/receive`. Works when Drive OAuth is broken
            // (e.g. unregistered SHA-1) since it doesn't touch
            // Google Sign-In at all.
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.of(sheetCtx).pop();
                GoRouter.of(sheetCtx).pushNamed(AppRoutes.nearbyDevices);
              },
              icon: const Icon(Icons.devices),
              label: const Text('Receive from phone (LAN)'),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(sheetCtx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Other paths that work without any UI:',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                      color: Theme.of(sheetCtx).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '• From your Mac/PC over Wi-Fi:\n'
                    '    adb -s <TV-IP>:5555 push file.pdf /sdcard/Download/\n'
                    '  Then open the Files app on the TV to install it.\n'
                    '• Plug a USB drive into the TV — Files app picks\n'
                    '  it up automatically.\n'
                    '• On a phone running Pro: open any PDF → Send → pick\n'
                    '  this TV from the Nearby Devices list.',
                    style: TextStyle(
                      color: Theme.of(sheetCtx).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      height: 1.4,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
      ),
    ),
  );
}

/// Sofa-readable IP banner anchored to the bottom of the TV home screen.
/// Only renders when the device is detected as Android TV. Tells the
/// user "this device is reachable at 192.168.x.y" so they can type that
/// into another device's "Connect by IP" form when mDNS discovery
/// isn't surfacing this TV in the Nearby Devices list — the
/// deterministic fallback path in the Track 1 LAN-reliability rework.
class _TvIpBanner extends StatefulWidget {
  const _TvIpBanner();
  @override
  State<_TvIpBanner> createState() => _TvIpBannerState();
}

class _TvIpBannerState extends State<_TvIpBanner> {
  String? _ip;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadIp();
    // Re-resolve every 30 s — covers the case where the user switches
    // Wi-Fi networks while the TV stays on.
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadIp(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadIp() async {
    try {
      final addr = await LocalIpResolver.resolve();
      if (mounted) setState(() => _ip = addr);
    } catch (_) {
      if (mounted) setState(() => _ip = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hide on phones / tablets — they'll never see this strip. TV-shape
    // is the same heuristic the body uses elsewhere in this file.
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final isTvLike = DeviceInfo.isAndroidTv ||
        (shortestSide >= 720 &&
            (Platform.isAndroid || Platform.isLinux));
    if (!isTvLike) return const SizedBox.shrink();
    if (_ip == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    // Compact bottom-CENTER pill — was bottom-right initially, but that
    // collided with the FAB cluster ("Import PDF" + chat bubble). Now
    // anchored to bottom-center so it stays readable across TV sizes
    // and never overlaps the FAB. Long-press reveals the connect-by-IP
    // hint as a SnackBar so we don't waste pixels on copy that's only
    // relevant when discovery already failed.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
        child: GestureDetector(
          onLongPress: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'On your phone: Settings → Nearby Devices → '
                  'Connect by IP → type the number shown.',
                ),
                duration: Duration(seconds: 6),
              ),
            );
          },
          // #254 — enriched status row: TV IP + paired count + AI health
          // + Pro status. Compact pills, glanceable from across a room.
          // Uses a Consumer so the paired count + Pro state stay live
          // without us having to re-poll inside _TvIpBanner's state.
          child: Consumer(
            builder: (context, ref, _) {
              final pairedAsync = ref.watch(pairedDevicesProvider);
              final pairedCount = pairedAsync.maybeWhen(
                data: (list) => list.length,
                orElse: () => 0,
              );
              final isPro =
                  ref.watch(proSubscriptionProvider).valueOrNull?.isPro ??
                      false;
              final aiOk = AppConstants.aiBackendConfigured;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(999),
                  border:
                      Border.all(color: cs.outlineVariant, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // ── TV reachability pill ────────────────────────
                    Icon(Icons.tv_outlined, color: cs.primary, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'TV: ',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '$_ip:39201',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                    // ── Paired devices pill ────────────────────────
                    if (pairedCount > 0) ...[
                      _StatusDivider(cs: cs),
                      Icon(
                        Icons.devices_other,
                        color: cs.primary,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$pairedCount paired',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    // ── AI backend health dot ──────────────────────
                    _StatusDivider(cs: cs),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: aiOk
                            ? const Color(0xFF22C55E) // green
                            : cs.outlineVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      aiOk ? 'AI on' : 'AI off',
                      style: TextStyle(
                        fontSize: 11,
                        color: aiOk
                            ? cs.onSurface
                            : cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    // ── Pro / trial state ──────────────────────────
                    if (isPro) ...[
                      _StatusDivider(cs: cs),
                      Icon(
                        Icons.workspace_premium,
                        color: const Color(0xFFEAB308),
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Pro',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// TV-friendly wrapper around the shortcut-rail ListTile. Paints a cyan
/// ring + 1.04× scale when focused and binds D-pad OK / Enter /
/// Numpad-Enter / Space / GameButtonA → ActivateIntent → onTap so any
/// TV remote's central button activates the tile.
///
/// Mirrors `_FocusableActionButton` in trial_banner.dart — same visual
/// vocabulary across the app so users get one consistent focus model.
class _FocusableRailTile extends StatefulWidget {
  const _FocusableRailTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_FocusableRailTile> createState() => _FocusableRailTileState();
}

class _FocusableRailTileState extends State<_FocusableRailTile> {
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
    final ringColor =
        _focused ? const Color(0xFF22D3EE) : Colors.transparent;
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
      child: AnimatedScale(
        scale: _focused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ringColor, width: 2),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: ringColor.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: ListTile(
            leading: Icon(widget.icon),
            title: Text(widget.label),
            onTap: widget.onTap,
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small vertical separator between status pills inside the TV bottom
/// bar (#254). Kept as a top-level widget rather than inlining the
/// SizedBox + Container so the spacing constants live in one place
/// and the bottom bar's Row stays readable.
class _StatusDivider extends StatelessWidget {
  const _StatusDivider({required this.cs});
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 1,
        height: 12,
        color: cs.outlineVariant.withValues(alpha: 0.55),
      ),
    );
  }
}
