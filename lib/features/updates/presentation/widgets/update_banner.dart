import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/version_check_service.dart';

/// Banner that surfaces above the home content when a newer build is
/// published. Three states (in priority order):
///
///   1. `required = true`  → red, "Update required" + "Update now"
///      button. Cannot be dismissed; the app keeps reminding until the
///      user updates. Used when the server's `minimumSupported` field
///      excludes the running build (e.g. a security-critical fix).
///
///   2. `hasUpdate = true` → green-amber, "New version available" +
///      "Update" + "Later" buttons. Dismissable for the session.
///
///   3. otherwise          → renders nothing.
///
/// "Update now" opens the URL the server sent (typically the APK
/// download URL) in the browser. We don't auto-install — Android
/// shows the "Install from this source" prompt the user expects.
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(updateStatusProvider).asData?.value;
    if (status == null || !status.hasUpdate) return const SizedBox.shrink();
    if (!status.required && _dismissed) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final isRequired = status.required;
    final bg = isRequired ? cs.errorContainer : const Color(0xFFFFF1C7);
    final fg = isRequired ? cs.onErrorContainer : const Color(0xFF6B4500);

    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          Icon(
            isRequired ? Icons.warning_amber_outlined : Icons.system_update,
            color: fg,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isRequired
                      ? 'Update required'
                      : 'New version available — ${status.latest?.latest ?? ''}',
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                if (status.latest?.notes.isNotEmpty == true)
                  Text(
                    status.latest!.notes,
                    style: TextStyle(color: fg, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (!isRequired)
            TextButton(
              onPressed: () => setState(() => _dismissed = true),
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('Later'),
            ),
          FilledButton.icon(
            onPressed: () async {
              final url = status.latest?.url;
              if (url == null) return;
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.download, size: 16),
            label: Text(isRequired ? 'Update now' : 'Update'),
          ),
        ],
      ),
    );
  }
}
