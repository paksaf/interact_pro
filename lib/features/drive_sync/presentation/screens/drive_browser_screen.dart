
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/device/device_info.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/logger.dart';
import 'drive_device_flow_screen.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/presentation/providers/viewer_provider.dart';
import '../../data/repositories/drive_repository_impl.dart'
    show driveRepositoryProvider;
import '../../domain/repositories/drive_repository.dart';
import '../providers/drive_provider.dart';

/// Browse + import PDFs from the user's Google Drive.
///
/// Replaces the previous "Connect Drive" stub. When signed in, lists every
/// PDF in the configured Interact Pro folder (defaults to `Interact Pro/`)
/// with name + date + size, and lets the user tap any row to download +
/// open it locally. The downloaded copy is registered in Drift so it
/// shows up in the home Recents list immediately.
///
/// On TVs this is the primary way to get a PDF into the app — the system
/// FilePicker doesn't work without a file manager, and this screen has a
/// guaranteed D-pad-focusable list of file rows.
class DriveBrowserScreen extends ConsumerStatefulWidget {
  const DriveBrowserScreen({super.key});

  @override
  ConsumerState<DriveBrowserScreen> createState() => _DriveBrowserScreenState();
}

class _DriveBrowserScreenState extends ConsumerState<DriveBrowserScreen> {
  /// Files fetched from Drive. Refreshed on entry + on pull-to-refresh.
  AsyncValue<List<DriveFile>> _files = const AsyncValue.loading();

  /// Currently downloading file id → "downloading…" label so we don't fire
  /// two parallel downloads of the same file when a user double-taps.
  String? _downloadingId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() => _files = const AsyncValue.loading());
    try {
      final repo = ref.read(driveRepositoryProvider);
      final user = await repo.currentUser();
      if (user == null) {
        setState(() => _files = const AsyncValue.data([]));
        return;
      }
      final res = await repo.listFolder();
      res.fold(
        (list) => setState(() => _files = AsyncValue.data(list)),
        (failure) => setState(() => _files =
            AsyncValue.error(failure.message, StackTrace.current),),
      );
    } catch (e, st) {
      setState(() => _files = AsyncValue.error(e, st));
    }
  }

  Future<void> _signIn() async {
    // Android TV: use OAuth Device Flow instead of google_sign_in.
    // Google deprecated google_sign_in for Drive on Android TV in
    // late 2024; sideloaded apps additionally lost automatic-token
    // reuse in April 2024. Device Flow is the supported path:
    // TV shows a short code, user enters it on phone, TV polls
    // for the resulting token. See google_device_flow.dart.
    if (DeviceInfo.isAndroidTv) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => const DriveDeviceFlowScreen(),
        ),
      );
      if (ok == true && mounted) {
        // Re-fetch Drive listing now that we have a token.
        _refresh();
      }
      return;
    }
    // Phone path — unchanged.
    final repo = ref.read(driveRepositoryProvider);
    final res = await repo.signIn();
    if (!mounted) return;
    res.fold(
      (_) => _refresh(),
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      ),
    );
  }

  Future<void> _openFile(DriveFile file) async {
    if (_downloadingId == file.id) return;
    setState(() => _downloadingId = file.id);
    try {
      final paths = await ref.read(appPathsProvider.future);
      final localPath = paths.pdfPathFor(file.name);
      final repo = ref.read(driveRepositoryProvider);
      final dl = await repo.download(file.id, localPath);
      if (!mounted) return;
      await dl.fold<Future<void>>(
        (savedPath) async {
          // Index it in Drift so it shows in Recents.
          try {
            final pdfRepo = await ref.read(pdfRepositoryProvider.future);
            await pdfRepo.open(savedPath);
            ref.invalidate(allDocumentsProvider);
          } catch (e) {
            appLogger.w('Drive: drift register failed: $e');
          }
          if (!mounted) return;
          // Open in the viewer right away — that's typically what the user
          // tapped a Drive file to do.
          context.pushNamed(AppRoutes.viewer, extra: savedPath);
        },
        (failure) async {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(failure.message)),
          );
        },
      );
    } finally {
      if (mounted) setState(() => _downloadingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(driveAuthProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Drive'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            // Autofocus the refresh button — gives the TV remote D-pad a
            // landing target on entry, even when the file list is empty.
            autofocus: true,
            onPressed: _refresh,
          ),
        ],
      ),
      body: auth.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Error: $e', textAlign: TextAlign.center),
          ),
        ),
        data: (user) {
          if (user == null) return _signedOutBody(cs);
          return Column(
            children: [
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.account_circle)),
                title: Text(user.email),
                subtitle: const Text('Connected to Google Drive'),
                trailing: TextButton(
                  onPressed: () =>
                      ref.read(driveAuthProvider.notifier).signOut(),
                  child: const Text('Sign out'),
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _filesBody()),
            ],
          );
        },
      ),
    );
  }

  Widget _signedOutBody(ColorScheme cs) {
    final shortest = MediaQuery.of(context).size.shortestSide;
    final isTvLike = shortest >= 720;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_outlined, size: 96, color: cs.outline),
            const SizedBox(height: 16),
            Text('Connect Google Drive',
                style: Theme.of(context).textTheme.titleLarge,),
            const SizedBox(height: 8),
            Text(
              'Sign in to browse and import PDFs from your Drive. '
              'Especially useful on TVs and other devices that have no file picker.',
              style: TextStyle(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              autofocus: true,
              onPressed: _signIn,
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Google'),
            ),
            if (isTvLike) ...[
              const SizedBox(height: 32),
              Container(
                constraints: const BoxConstraints(maxWidth: 560),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.tv_outlined, size: 18, color: cs.primary),
                        const SizedBox(width: 8),
                        Text('On TVs',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(color: cs.primary),),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'If "Sign in" does nothing, your TV does not have a '
                      'Google account configured at the system level.',
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 13,),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Fix: open TV Settings → Accounts → Add Google account, '
                      'sign in with the account that holds your PDFs, then '
                      'come back here and tap Sign in again. Interact Pro '
                      'will then auto-detect that account silently.',
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 13,),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Fire TV without Play Services: use "Send to Device" '
                      'from a phone running Interact Pro instead — it works '
                      'over your local Wi-Fi without any Google sign-in.',
                      style:
                          TextStyle(color: cs.outline, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filesBody() {
    return _files.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('Could not load your Drive: $e',
                  textAlign: TextAlign.center,),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No PDFs found in your Interact Pro Drive folder yet. '
                'Upload PDFs to Drive (in the Interact Pro folder) — '
                'they\'ll appear here.',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.outline),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (ctx, i) {
            final f = list[i];
            final isDownloading = _downloadingId == f.id;
            return ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
              title: Text(f.name),
              subtitle: Text(
                '${DateFormat.yMd().add_jm().format(f.modifiedTime)} · '
                '${_humanSize(f.sizeBytes)}',
              ),
              trailing: isDownloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),)
                  : const Icon(Icons.download_outlined),
              autofocus: i == 0,
              onTap: isDownloading ? null : () => _openFile(f),
            );
          },
        );
      },
    );
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
