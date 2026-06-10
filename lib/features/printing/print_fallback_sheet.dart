import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'print_helper.dart';

/// Bottom sheet shown when the user taps Print but the OS print sheet
/// either reports no printer found or the user cancels. Without this
/// they'd have been left with a "Print cancelled" snackbar and no
/// obvious next step — bug reported during device testing on May 7.
///
/// Surfaces the alternatives the user actually wants in that moment,
/// in priority order:
///
///   1. **Try printing again** — most "no printer found" results are
///      the iOS Local Network permission prompt being dismissed, or
///      the printer needing a moment to wake. Retry costs nothing.
///   2. **Save to Drive** — if the user is signed in to Google Drive,
///      back up the PDF there immediately. Provided as a callback so
///      the sheet stays decoupled from the Drive feature module.
///   3. **Share** — opens the OS share sheet, which on iOS surfaces
///      AirDrop / Mail / Files / Save to Files / Print again with a
///      different printer / etc.
///   4. **Save a copy** — drops the PDF into the user's Downloads /
///      iOS Files-app-visible directory. Last-resort "I just want this
///      file off the app and onto my device" path.
///
/// The sheet is also useful as the FIRST choice if the user knows
/// printing isn't going to work today — not just the fallback.
Future<void> showPrintFallbackSheet({
  required BuildContext context,
  required File pdfFile,
  required Future<void> Function() onSaveToDrive,
  String? failureReason,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) => _PrintFallbackSheet(
      pdfFile: pdfFile,
      onSaveToDrive: onSaveToDrive,
      failureReason: failureReason,
    ),
  );
}

class _PrintFallbackSheet extends StatelessWidget {
  const _PrintFallbackSheet({
    required this.pdfFile,
    required this.onSaveToDrive,
    required this.failureReason,
  });

  final File pdfFile;
  final Future<void> Function() onSaveToDrive;
  final String? failureReason;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Row(
              children: [
                Icon(Icons.print_disabled, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    failureReason ?? 'No printer? Try one of these',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (Platform.isIOS) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: cs.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'On iOS, AirPrint needs the "Local Network" permission. '
                        'If you denied it, open Settings → Interact Pro → Local '
                        'Network and turn it on.',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (Platform.isAndroid) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: cs.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Android needs a "Print Service" plugin to see your '
                            'printer — even if your printer\'s own app works. '
                            'Install one of these:',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant,),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _PluginButton(
                          label: 'Mopria (most printers)',
                          // Universal IPP plugin — handles Brother, HP,
                          // Canon, Epson, Lexmark, Xerox, Ricoh, etc.
                          packageName: 'org.mopria.printplugin',
                        ),
                        _PluginButton(
                          label: 'Brother Print Service',
                          packageName: 'com.brother.mfc.brprint',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.print),
              title: const Text('Try printing again'),
              subtitle: const Text(
                'Sometimes the printer needs a moment to wake up.',
              ),
              onTap: () async {
                Navigator.of(context).pop();
                await PrintHelper.printPdf(pdfFile: pdfFile);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Save to Google Drive'),
              subtitle: const Text(
                'Backs up this PDF to your Drive.',
              ),
              onTap: () async {
                Navigator.of(context).pop();
                await onSaveToDrive();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(Platform.isIOS
                  ? 'Share / Save to Files / AirDrop'
                  : 'Share / Save to device',),
              subtitle: Text(Platform.isIOS
                  ? 'Pick AirDrop, Mail, Files, or any installed app.'
                  : 'Pick a target — including Drive, Files, Bluetooth.',),
              onTap: () async {
                Navigator.of(context).pop();
                await PrintHelper.sharePdf(pdfFile: pdfFile);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Save a copy to device'),
              subtitle: Text(
                Platform.isIOS
                    ? 'Visible in the Files app under On My iPhone / On My iPad.'
                    : 'Saved to your Downloads folder.',
              ),
              onTap: () async {
                final saved = await _saveCopyToDevice(pdfFile);
                if (!context.mounted) return;
                Navigator.of(context).pop();
                final messenger = ScaffoldMessenger.of(context);
                messenger.showSnackBar(SnackBar(
                  content: Text(saved == null
                      ? 'Could not save copy.'
                      : 'Saved to $saved',),
                ),);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Tappable Play Store launch for a Print Service plugin. Falls back
/// to the web URL if the Play Store app isn't reachable (e.g. on
/// Huawei without GMS).
class _PluginButton extends StatelessWidget {
  const _PluginButton({required this.label, required this.packageName});
  final String label;
  final String packageName;

  Future<void> _open() async {
    final marketUri = Uri.parse('market://details?id=$packageName');
    if (await canLaunchUrl(marketUri)) {
      await launchUrl(marketUri, mode: LaunchMode.externalApplication);
      return;
    }
    final webUri =
        Uri.parse('https://play.google.com/store/apps/details?id=$packageName');
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: _open,
      icon: const Icon(Icons.shop_outlined, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Drops the file at a documented, user-visible location on each
/// platform. Returns the destination path (or null on failure).
Future<String?> _saveCopyToDevice(File pdfFile) async {
  try {
    final basename = p.basename(pdfFile.path);
    if (Platform.isIOS) {
      // On iOS the app's Documents directory is mirrored into the
      // Files app under "On My iPhone / Interact Pro" when the
      // UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace
      // Info.plist keys are set (we'll add those in a follow-up if
      // they aren't already). Even without them, the directory is
      // inspectable via Files app → Browse → On My iPhone.
      final docs = await getApplicationDocumentsDirectory();
      final dest = File(p.join(docs.path, basename));
      await pdfFile.copy(dest.path);
      return 'Files → On My iPhone → Interact Pro';
    } else {
      // Android: prefer the user's actual Downloads folder. Falls
      // back to the app's external dir if Downloads isn't writable
      // (some Samsung skins).
      Directory? target;
      try {
        target = Directory('/storage/emulated/0/Download');
        if (!target.existsSync()) target = null;
      } catch (_) {
        target = null;
      }
      target ??= await getExternalStorageDirectory();
      if (target == null) return null;
      final dest = File(p.join(target.path, basename));
      await pdfFile.copy(dest.path);
      return dest.path;
    }
  } catch (_) {
    return null;
  }
}
