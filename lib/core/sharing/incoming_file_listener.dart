import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../notifications/local_notifications.dart';
import '../routing/app_routes.dart';
import '../storage/app_paths.dart';
import '../utils/logger.dart';
import '../../features/lan/data/lan_repository.dart' show incomingSharesProvider;
import '../../features/lan/domain/entities.dart' show IncomingShare, ShareKind;
import '../../features/sharing/presentation/send_to_device_sheet.dart';
import '../../features/viewer/data/repositories/pdf_repository_impl.dart';
import '../../features/viewer/presentation/providers/viewer_provider.dart';

/// Handles files shared INTO the app from other apps (WhatsApp, Files,
/// Gmail, etc).
///
/// When a user taps a PDF in WhatsApp and picks "Open with → Interact Pro",
/// Android delivers a `content://com.whatsapp.provider.media/...` URI to
/// the launch intent. The OS surface for this is the
/// `ACTION_VIEW` / `ACTION_SEND` intent, which `receive_sharing_intent`
/// normalises into a stream of `SharedMediaFile` records carrying
/// resolvable file paths.
///
/// On every shared file we:
///   1. Copy the bytes into our app's `pdfDir` so the file persists
///      after the source app's content provider closes the URI.
///   2. Call `PdfRepository.open()` so it lands in drift's recents.
///   3. Push `/viewer` with the local path.
///
/// Mounts as a Riverpod-backed widget near the router root so it has
/// the live `GoRouter` to dispatch routes against.
class IncomingFileListener {
  IncomingFileListener(this._ref);
  final Ref _ref;

  StreamSubscription<List<SharedMediaFile>>? _sub;
  final ReceiveSharingIntent _api = ReceiveSharingIntent.instance;

  Future<void> attach(GoRouter router) async {
    // Cold-launch: the app was opened by tapping a file (not already running).
    try {
      final initial = await _api.getInitialMedia();
      if (initial.isNotEmpty) {
        appLogger.i('IncomingFile: cold-launch with ${initial.length} files');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_handleAll(initial, router));
        });
        // Important: tell the plugin we've consumed the initial intent so
        // it isn't redelivered on next cold launch.
        _api.reset();
      }
    } catch (e, st) {
      appLogger.w('IncomingFile: getInitialMedia failed', error: e, stackTrace: st);
    }

    // Warm-launch: app was already running when the share came in.
    _sub = _api.getMediaStream().listen(
      (files) {
        if (files.isEmpty) return;
        appLogger.i('IncomingFile: warm-launch with ${files.length} files');
        unawaited(_handleAll(files, router));
      },
      onError: (Object e, StackTrace st) =>
          appLogger.w('IncomingFile: stream error', error: e, stackTrace: st),
    );
  }

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Holder used by the bootstrap widget to pop the "Send to TV" action
  /// sheet for the user, without coupling this listener to BuildContext.
  ///
  /// Set once by [IncomingFileBootstrap.initState]; cleared on detach.
  BuildContext? _navigatorContext;
  // ignore: use_setters_to_change_properties
  void setContext(BuildContext ctx) => _navigatorContext = ctx;

  /// Handle every file in a single share batch. We process them sequentially
  /// so the viewer's `pushNamed` calls don't stack on top of each other —
  /// the user only sees the LAST file in the batch in the viewer (typical
  /// WhatsApp share is a single file anyway).
  Future<void> _handleAll(List<SharedMediaFile> files, GoRouter router) async {
    final imported = <_Imported>[];
    for (final f in files) {
      final res = await _importOne(f);
      if (res != null) imported.add(res);
    }
    if (imported.isEmpty) return;

    // Single file: open the matching viewer immediately (the original
    // behaviour for PDFs, now extended to images).
    final last = imported.last;
    if (imported.length == 1) {
      switch (last.kind) {
        case ShareKind.pdf:
          router.pushNamed(AppRoutes.viewer, extra: last.path);
        case ShareKind.image:
          router.pushNamed(AppRoutes.imageViewer, extra: last.path);
        case ShareKind.document:
          // Office / iWork — hand off to the system "Open with" picker.
          // The user picks WPS / Microsoft Office / Pages / Numbers /
          // Keynote etc. on their device. We still own the file so the
          // SendToDeviceSheet that mounts below works for nearby-send
          // / re-share without going back through the picker.
          unawaited(_openWithExternalApp(last.path));
        case ShareKind.video:
        case ShareKind.text:
        case ShareKind.other:
          // Nothing yet — the file is on disk; the SendToDeviceSheet below
          // gives the user the "do something" affordance.
          break;
      }
    }

    // Offer "Send to TV" via the SendToDeviceSheet for whatever just landed.
    // Only opens if a navigator context is mounted (the bootstrap widget
    // sets it on initState; nothing happens during cold-start before the
    // first frame, which is correct — we'd have nowhere to draw the sheet).
    final ctx = _navigatorContext;
    if (ctx != null && ctx.mounted) {
      // Defer one frame so this runs after the viewer push above (if any).
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!ctx.mounted) return;
        await SendToDeviceSheet.show(
          ctx,
          file: File(last.path),
          kind: last.kind,
          suggestedName: p.basename(last.path),
        );
      });
    }
  }

  /// Copy the shared file's bytes into a kind-appropriate folder, register
  /// in drift if it's a PDF, return path + kind. Returns null if the source
  /// path is gone.
  Future<_Imported?> _importOne(SharedMediaFile shared) async {
    try {
      final src = File(shared.path);
      if (!src.existsSync()) {
        appLogger.w('IncomingFile: source path missing: ${shared.path}');
        return null;
      }

      // Resolve kind from extension. We don't have the original mimeType
      // here (receive_sharing_intent normalises everything to a path) so
      // extension is the best signal.
      final extLower = p.extension(shared.path).toLowerCase();
      final kind = switch (extLower) {
        '.pdf' => ShareKind.pdf,
        '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' || '.heic' =>
          ShareKind.image,
        '.mp4' || '.mov' || '.m4v' || '.webm' => ShareKind.video,
        '.txt' || '.md' || '.csv' => ShareKind.text,
        // Office / iWork — preview via system "Open with" handoff
        // (open_filex), but still own the file so re-send /
        // save-to-Drive work. AndroidManifest intent filters + iOS
        // Info.plist Document Types need matching entries.
        '.doc' || '.docx' || '.rtf' || '.odt' ||
        '.xls' || '.xlsx' || '.ods' || '.csv' ||
        '.ppt' || '.pptx' || '.odp' ||
        '.pages' || '.numbers' || '.key' || '.keynote' =>
          ShareKind.document,
        _ => ShareKind.other,
      };

      final paths = await _ref.read(appPathsProvider.future);
      final originalBase = p.basenameWithoutExtension(shared.path);
      final cleanBase = originalBase.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
      final ext = extLower.isNotEmpty ? extLower : kind.defaultExtension;
      final filename = cleanBase.length >= 4
          ? '$cleanBase$ext'
          : 'Shared_${DateTime.now().millisecondsSinceEpoch}$ext';

      // PDFs go in the pdf library so they appear in Recents. Other types
      // go in the dedicated `incoming/` folder until per-kind viewers ship.
      final destPath = kind == ShareKind.pdf
          ? paths.pdfPathFor(filename)
          : paths.incomingPathFor(filename);

      await Directory(p.dirname(destPath)).create(recursive: true);
      await src.copy(destPath);
      appLogger.i('IncomingFile: imported $kind to $destPath');

      if (kind == ShareKind.pdf) {
        try {
          final repo = await _ref.read(pdfRepositoryProvider.future);
          await repo.open(destPath);
          _ref.invalidate(allDocumentsProvider);
        } catch (e, st) {
          appLogger.w('IncomingFile: drift register failed',
              error: e, stackTrace: st,);
        }
      }

      return _Imported(path: destPath, kind: kind);
    } catch (e, st) {
      appLogger.e('IncomingFile: import failed', error: e, stackTrace: st);
      return null;
    }
  }

}

/// Hand a file off to the system "Open with" picker via `open_filex`.
/// Used for `ShareKind.document` so the user picks WPS / Microsoft
/// Office / Pages / Numbers / Keynote on their device. We don't
/// surface specific app names — the OS picker shows whatever the
/// user has installed for that mime type.
///
/// Top-level (not instance) so BOTH `_IncomingFileListenerState` (cold-
/// start import) and `_IncomingFileBootstrapState` (LAN receive) can
/// call the same handoff. Pre-2026-05-13 this was a method on
/// IncomingFileListener only, which broke the build at the LAN call
/// site because `_IncomingFileBootstrapState` had no access to it.
///
/// Logs the OpenResult so failed handoffs ("no app installed", file
/// permission denied, etc.) are visible in logcat. A future iteration
/// can surface this as a snackbar with a Play Store deep link to a
/// free Office app, but the OS dialog already shows "No app can open
/// this type" when nothing is installed.
Future<void> _openWithExternalApp(String path) async {
  try {
    final result = await OpenFilex.open(path);
    appLogger.i(
      'IncomingFile: open_filex result for $path → '
      '${result.type} (${result.message})',
    );
  } catch (e, st) {
    appLogger.w('IncomingFile: open_filex threw',
        error: e, stackTrace: st,);
  }
}

class _Imported {
  const _Imported({required this.path, required this.kind});
  final String path;
  final ShareKind kind;
}

final incomingFileListenerProvider = Provider<IncomingFileListener>((ref) {
  final listener = IncomingFileListener(ref);
  ref.onDispose(listener.detach);
  return listener;
});

/// Mount once near the router root to start listening for shares.
class IncomingFileBootstrap extends ConsumerStatefulWidget {
  const IncomingFileBootstrap({
    required this.router,
    required this.child,
    super.key,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<IncomingFileBootstrap> createState() =>
      _IncomingFileBootstrapState();
}

class _IncomingFileBootstrapState extends ConsumerState<IncomingFileBootstrap> {
  ProviderSubscription<AsyncValue<IncomingShare>>? _lanIncomingSub;

  @override
  void initState() {
    super.initState();
    final listener = ref.read(incomingFileListenerProvider);
    listener.setContext(context);
    unawaited(listener.attach(widget.router));

    // Set up local notifications so backgrounded receives don't get
    // silently dropped on the floor. The onTap callback routes the user
    // back into the app on the right viewer screen when they tap a
    // notification from the system tray.
    unawaited(LocalNotifications.instance.init(
      onTap: (routeName, path) {
        if (mounted) {
          widget.router.pushNamed(routeName, extra: path);
        }
      },
    ),);

    // Receive-side: when a paired peer pushes a file to us via the LAN
    // server, route to the right viewer so the TV / tablet auto-opens it.
    // Phones subscribe too — symmetrical so phones can be cast targets,
    // not just senders.
    _lanIncomingSub = ref.listenManual<AsyncValue<IncomingShare>>(
      incomingSharesProvider,
      (prev, next) {
        next.whenData((share) async {
          appLogger.i(
            'IncomingShare: ${share.kind.name} from ${share.fromName} → ${share.path}',
          );

          // Phase 3: signature-chain sidecars arrive as kind=other with
          // a `.sigchain.json` filename. The LanServer already parked
          // them next to their PDF, so the sidecar import API finds
          // the chain transparently. Surface a "X signed — continue
          // signing" snackbar that deep-links to the PDF viewer rather
          // than treating the .json as an opaque file.
          if (share.kind == ShareKind.other &&
              share.path.endsWith('.sigchain.json')) {
            _handleSigchainArrival(share);
            return;
          }

          // Register received PDFs in drift so they appear in Library /
          // Recents. The LanServer's /receive handler saves the bytes
          // but doesn't touch the PDF repository — without this call
          // the file sits on disk but Library shows "No documents yet"
          // and the user has no way back to the file after closing the
          // auto-opened viewer.
          if (share.kind == ShareKind.pdf) {
            try {
              final repo = await ref.read(pdfRepositoryProvider.future);
              await repo.open(share.path);
              ref.invalidate(allDocumentsProvider);
            } catch (e, st) {
              appLogger.w(
                'IncomingShare: drift register failed for ${share.path}',
                error: e,
                stackTrace: st,
              );
            }
          }

          final routeName = _routeNameForKind(share.kind);
          final tracker = ref.read(appForegroundTrackerProvider);

          if (tracker.isForeground) {
            // App is visible — show snackbar + auto-open viewer (the
            // immediate, in-app experience).
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Received from ${share.fromName}')),
              );
            }
            if (routeName != null) {
              widget.router.pushNamed(routeName, extra: share.path);
            } else if (share.kind == ShareKind.document) {
              // Office / iWork doc arrived over LAN — hand off to the
              // user's installed Office app via the system "Open with"
              // picker. Same flow as cold-start import.
              unawaited(_openWithExternalApp(share.path));
            }
          } else {
            // App is backgrounded (TV is on a different input, user
            // switched to home screen, etc). Post a system notification
            // so they see something arrived; tapping it brings them
            // back to the right viewer.
            unawaited(LocalNotifications.instance.showIncomingShare(
              peerName: share.fromName,
              filePath: share.path,
              fileBasename: p.basename(share.path),
              // For kinds without an in-app viewer, route to home — at
              // least the user gets back into the app and can find the
              // file in the incoming/ folder via Settings.
              routeName: routeName ?? AppRoutes.home,
            ),);
          }
        });
      },
    );
  }

  /// Phase 3: handle a `.sigchain.json` arrival. The companion PDF
  /// already landed (the sender ships PDF first, sidecar second), so
  /// derive the PDF path by stripping the `.sigchain.json` suffix and
  /// deep-link the viewer there. The viewer's existing sidecar import
  /// path (called on document open) will pick up the new sigchain
  /// rows automatically — no separate import call needed here.
  void _handleSigchainArrival(IncomingShare share) {
    // `<basename>.pdf.sigchain.json` → `<basename>.pdf`
    final pdfPath =
        share.path.substring(0, share.path.length - '.sigchain.json'.length);
    if (!File(pdfPath).existsSync()) {
      appLogger.w(
        'Sigchain arrived but matching PDF not found at $pdfPath — '
        'sidecar will sit unused until the PDF re-arrives.',
      );
      return;
    }

    final tracker = ref.read(appForegroundTrackerProvider);
    if (tracker.isForeground) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${share.fromName} signed a document — continue signing?',
            ),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () =>
                  widget.router.pushNamed(AppRoutes.viewer, extra: pdfPath),
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } else {
      unawaited(LocalNotifications.instance.showIncomingShare(
        peerName: share.fromName,
        filePath: pdfPath,
        fileBasename: p.basename(pdfPath),
        routeName: AppRoutes.viewer,
      ),);
    }
  }

  /// Returns the GoRouter name for the right viewer per [kind], or null
  /// when there isn't a matching viewer yet. PDFs and images are wired
  /// today; video / text are TODO.
  String? _routeNameForKind(ShareKind kind) => switch (kind) {
        ShareKind.pdf => AppRoutes.viewer,
        ShareKind.image => AppRoutes.imageViewer,
        // Office / iWork → external app via open_filex; no in-app
        // route. The arrival flow handles this branch separately.
        ShareKind.document => null,
        ShareKind.video => null,
        ShareKind.text => null,
        ShareKind.other => null,
      };

  @override
  void dispose() {
    _lanIncomingSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
