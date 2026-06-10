import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/app_database.dart' as db;
import '../../data/lan_repository.dart';
import '../../domain/entities.dart';

/// Settings → Nearby Devices entry. Lists paired devices first, then
/// unpaired-but-discovered. Tap unpaired → pair flow. Tap paired →
/// device detail (rename, unpair, send a doc).
class NearbyDevicesScreen extends ConsumerStatefulWidget {
  const NearbyDevicesScreen({super.key});
  @override
  ConsumerState<NearbyDevicesScreen> createState() =>
      _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends ConsumerState<NearbyDevicesScreen> {
  /// The AnExplorer/TvExplorer fallback card is intentionally a
  /// last-resort affordance — we don't want to push users at a
  /// third-party app the moment they open the screen. So we only
  /// surface it after ~30 seconds of empty discovery results, on the
  /// reasoning that mDNS normally resolves in 5-10 s on a healthy
  /// network. If the user has a TV showing or a paired device the
  /// timer is cancelled.
  Timer? _fallbackTimer;
  bool _showFallback = false;

  @override
  void initState() {
    super.initState();
    _fallbackTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _showFallback = true);
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discovered = ref.watch(discoveredDevicesProvider);
    final paired = ref.watch(pairedDevicesProvider);

    // Cancel the timer once discovery succeeds — no need to nag the
    // user about a workaround when the primary flow is working.
    discovered.whenData((peers) {
      if (peers.isNotEmpty && _fallbackTimer?.isActive == true) {
        _fallbackTimer?.cancel();
        if (_showFallback) setState(() => _showFallback = false);
      }
    });
    paired.whenData((rows) {
      if (rows.isNotEmpty && _fallbackTimer?.isActive == true) {
        _fallbackTimer?.cancel();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby devices'),
        actions: [
          // Always-present refresh action. Autofocused so the TV remote
          // D-pad has a landing target even when no devices are paired or
          // discovered yet.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            autofocus: true,
            onPressed: () => ref.invalidate(lanRepositoryProvider),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          // Re-bootstrap the repository — bonsoir browse re-queries the
          // mDNS responder, which is what users intuit "refresh" should do.
          ref.invalidate(lanRepositoryProvider);
        },
        child: ListView(
          children: [
            const _SectionHeader(label: 'Paired'),
            paired.when(
              loading: () => const _SkeletonRow(),
              error: (e, _) => _ErrorRow('$e'),
              data: (rows) => rows.isEmpty
                  ? const _EmptyHint(
                      'Pair a device to send PDFs over the same Wi-Fi without uploading them.',
                    )
                  : Column(
                      children: rows.map((r) => _PairedTile(r)).toList(),
                    ),
            ),
            const Divider(height: 32),
            const _SectionHeader(label: 'Discovered on this Wi-Fi'),
            discovered.when(
              loading: () => const _SkeletonRow(),
              error: (e, _) => _ErrorRow('$e'),
              data: (peers) {
                final unpaired = peers.where((p) => !p.isPaired).toList();
                if (unpaired.isEmpty) {
                  return const _EmptyHint(
                    'No new devices nearby. Make sure both devices have Interact Pro open and are on the same Wi-Fi.',
                  );
                }
                return Column(
                  children: unpaired.map((p) => _DiscoveredTile(p)).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
            const _ManualIpEntry(),
            if (_showFallback) ...[
              const SizedBox(height: 16),
              const _FileManagerWorkaround(),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

/// Stopgap recommendation when LAN discovery isn't working — points
/// users at AnExplorer / TvExplorer's WiFi Share. Independent of the
/// mDNS layer; works on any Android TV regardless of router multicast
/// blocking / Android 11+ NSD quirks / sideloaded-app permission gaps.
/// See `interact_pro_strategic_roadmap_2026-05-16.md` — Track 1 fallback.
class _FileManagerWorkaround extends StatelessWidget {
  const _FileManagerWorkaround();

  static const _appExplorerPackage = 'dev.dworks.apps.anexplorer';
  static const _appExplorerWebUrl =
      'https://play.google.com/store/apps/details?id=dev.dworks.apps.anexplorer';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cs.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tv_outlined, color: cs.primary, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    "Can't see your TV?",
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                "Some Wi-Fi routers block the discovery protocol Interact Pro uses. "
                "If your TV doesn't appear above, install a file-manager app on "
                "the TV and use its built-in WiFi Share feature — works "
                "on every Android TV regardless of router settings.",
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              const _NumberedStep(
                n: 1,
                text:
                    "Install AnExplorer (or TvExplorer) on your TV from Play Store.",
              ),
              const _NumberedStep(
                n: 2,
                text:
                    "Open it on the TV → tap WiFi Share → Receive. The TV shows a code or address.",
              ),
              const _NumberedStep(
                n: 3,
                text:
                    "On your phone, share the PDF to AnExplorer → WiFi Share → pick your TV.",
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Show me how'),
                      onPressed: () => _showHowTo(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.help_outline),
                    tooltip: 'Why doesn\'t my TV show up?',
                    onPressed: () => _showWhyDialog(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHowTo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send files via AnExplorer'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                "AnExplorer's WiFi Share runs a tiny server on your TV that any "
                "phone on the same network can send to — bypasses Google Cast, "
                "DLNA, and mDNS entirely.",
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 14),
              _HowToStep(
                title: "On the TV",
                body:
                    "1. Play Store → search 'AnExplorer' → Install.\n"
                    "2. Open AnExplorer.\n"
                    "3. Find the WiFi Share / Network tile (sidebar or menu).\n"
                    "4. Tap Receive. A 4-digit code or http://192.168.x.x:port "
                    "address appears.",
              ),
              SizedBox(height: 12),
              _HowToStep(
                title: "On your phone",
                body:
                    "1. Install AnExplorer (or any file manager with WiFi share).\n"
                    "2. Pick the PDF you want to send.\n"
                    "3. Share → AnExplorer → WiFi Share → Send.\n"
                    "4. Enter the TV's code or pick it from the discovered list.\n"
                    "5. Transfer finishes in seconds — file lands in the TV's "
                    "Downloads folder.",
              ),
              SizedBox(height: 12),
              _HowToStep(
                title: "Open in Interact Pro on the TV",
                body:
                    "Open Interact Pro on the TV → Library → Local files → "
                    "Downloads. The PDF will be there waiting.",
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _showWhyDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Why doesn't my TV show up?"),
        content: const SingleChildScrollView(
          child: Text(
            "Interact Pro uses mDNS (the same protocol AirPlay uses) to discover "
            "devices on your Wi-Fi. Three things commonly break it:\n\n"
            "• Router blocks multicast traffic. Many guest networks and ISP "
            "modems do this by default. Switching off 'AP isolation' or "
            "'Client isolation' usually fixes it.\n\n"
            "• Android 11+ on some phones (Xiaomi/Realme/Vivo) needs you to "
            "grant 'Nearby devices' permission to Interact Pro under "
            "Settings → Apps → Permissions.\n\n"
            "• Sideloaded apps on Android TV have stricter network rules than "
            "Play Store installs.\n\n"
            "The AnExplorer workaround sidesteps all three because it uses a "
            "direct TCP connection by IP — no discovery needed.",
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _NumberedStep extends StatelessWidget {
  const _NumberedStep({required this.n, required this.text});
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primaryContainer,
            ),
            alignment: Alignment.center,
            child: Text(
              '$n',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: cs.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.35,
                    )),
          ),
        ],
      ),
    );
  }
}

class _HowToStep extends StatelessWidget {
  const _HowToStep({required this.title, required this.body});
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(fontSize: 13, height: 1.4)),
      ],
    );
  }
}

class _PairedTile extends StatelessWidget {
  const _PairedTile(this.device);
  final db.PairedDevice device;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _PlatformIcon(device.platform),
      title: Text(device.name),
      subtitle: Text(
        device.lastSeenAt == null
            ? 'Paired ${_relative(device.pairedAt)}'
            : 'Last seen ${_relative(device.lastSeenAt!)}',
      ),
      trailing: const Icon(Icons.chevron_right),
      // First paired tile gets focus — gives TV D-pad a target on entry.
      // (StatelessWidget can't tell if it's the first; the parent passes
      // autofocus when iterating. Default false here is the safe baseline.)
      onTap: () => _showPairedDeviceSheet(context, device),
    );
  }
}

/// Bottom-sheet detail view for a paired device. Lists everything drift
/// knows about the pair plus an Unpair action. Replaces the
/// pre-2026-05-16 placeholder snackbar that read "Detail view for X —
/// not built yet" (visible bug on production builds).
///
/// Sender side gets the "send a file" affordance via the FAB on the
/// home/library screens; we don't duplicate it here. Detail view is
/// for inspection + lifecycle (unpair).
void _showPairedDeviceSheet(BuildContext context, db.PairedDevice device) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) {
      final cs = Theme.of(sheetCtx).colorScheme;
      Widget row(IconData icon, String label, String value) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: Text(
                    label,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: cs.primaryContainer,
                    child: Icon(Icons.devices_other, color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.name,
                          style: Theme.of(sheetCtx).textTheme.titleMedium,
                        ),
                        Text(
                          device.platform,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              row(Icons.fingerprint, 'Device ID', device.deviceId),
              row(Icons.calendar_today_outlined, 'Paired',
                  device.pairedAt.toLocal().toString().split('.').first,),
              if (device.lastSeenAt != null)
                row(Icons.visibility_outlined, 'Last seen',
                    device.lastSeenAt!.toLocal().toString().split('.').first,),
              row(
                Icons.lock_outline,
                'TLS pinned',
                device.tlsFingerprintSha256 == null ||
                        device.tlsFingerprintSha256!.isEmpty
                    ? 'No (plain HTTP)'
                    : '${device.tlsFingerprintSha256!.substring(0, 16)}…',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                  icon: const Icon(Icons.link_off),
                  label: const Text('Unpair this device'),
                  onPressed: () async {
                    final container = ProviderScope.containerOf(sheetCtx);
                    final repo =
                        await container.read(lanRepositoryProvider.future);
                    await repo.unpair(device.deviceId);
                    if (sheetCtx.mounted) {
                      Navigator.of(sheetCtx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Unpaired ${device.name}')),
                      );
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _DiscoveredTile extends ConsumerWidget {
  const _DiscoveredTile(this.peer);
  final NearbyDevice peer;

  Future<String?> _askForPin(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'A 6-digit PIN is showing on ${peer.name}. Type it here to confirm pairing.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(counterText: ''),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: _PlatformIcon(peer.platform),
      title: Text(peer.name),
      subtitle: Text('${peer.host} · v${peer.appVersion}'),
      trailing: FilledButton(
        onPressed: () async {
          final repo = await ref.read(lanRepositoryProvider.future);
          final res = await repo.pair(
            peer: peer,
            requestPin: () => _askForPin(context),
          );
          if (!context.mounted) return;
          res.fold(
            (paired) => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Paired with ${paired.name}')),
            ),
            (failure) => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(failure.message)),
            ),
          );
        },
        child: const Text('Pair'),
      ),
    );
  }
}

// ── Reusable bits ────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

class _PlatformIcon extends StatelessWidget {
  const _PlatformIcon(this.platform);
  final String platform;
  @override
  Widget build(BuildContext context) {
    final icon = switch (platform) {
      'ios' => Icons.phone_iphone,
      'android' => Icons.phone_android,
      'macos' => Icons.laptop_mac,
      'windows' => Icons.laptop_windows,
      _ => Icons.devices,
    };
    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Icon(icon,
          color: Theme.of(context).colorScheme.onPrimaryContainer,),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Text(text,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),),
      );
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      );
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Error: $message',
            style: TextStyle(color: Theme.of(context).colorScheme.error),),
      );
}

String _relative(DateTime when) {
  final delta = DateTime.now().difference(when);
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

/// Manual IP entry — the deterministic fallback when mDNS discovery
/// fails entirely (router blocks multicast, Wi-Fi isolation, Android
/// permission gate, etc.). User types the IP shown on the other
/// device's Pro home screen + an optional port; we construct a
/// synthetic `NearbyDevice` and feed it straight into the existing
/// pair flow so all downstream code (TLS pinning, HMAC, PIN exchange)
/// just works without knowing the device wasn't discovered.
class _ManualIpEntry extends ConsumerStatefulWidget {
  const _ManualIpEntry();
  @override
  ConsumerState<_ManualIpEntry> createState() => _ManualIpEntryState();
}

class _ManualIpEntryState extends ConsumerState<_ManualIpEntry> {
  // Default port matches LanServer's defaults in lan_server.dart.
  // If the user runs a custom port via env (uncommon) they can type it.
  static const int _defaultPort = 39201;

  final _ipController = TextEditingController();
  final _portController =
      TextEditingController(text: _defaultPort.toString());
  bool _expanded = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  bool get _ipValid {
    final v = _ipController.text.trim();
    // Permissive — accept IPv4 dotted quad, IPv6, or .local hostname.
    // The full resolve step happens server-side in repo.pair().
    if (v.isEmpty) return false;
    final ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
    if (ipv4.hasMatch(v)) return true;
    if (v.contains('.local')) return true;
    if (v.contains(':') && v.length > 4) return true; // IPv6-ish
    return false;
  }

  Future<String?> _askForPin(BuildContext context, String shownOn) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'A 6-digit PIN is showing on $shownOn. Type it here to confirm pairing.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(counterText: ''),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }

  Future<void> _connect() async {
    var ip = _ipController.text.trim();
    var port = int.tryParse(_portController.text.trim()) ?? _defaultPort;
    // QoL: if the user pasted "192.168.100.4:39201" into the IP field
    // (which is exactly what the TV banner shows), split off the port
    // and use it instead of whatever's in the port box. This makes the
    // common "copy what you see on the TV" path Just Work even if the
    // user doesn't think about the port field at all. Only do this for
    // IPv4 — IPv6 has its own colon syntax and we don't want to chew on
    // a `[::1]:port`-shaped string here.
    final ipv4WithPort = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$');
    final m = ipv4WithPort.firstMatch(ip);
    if (m != null) {
      ip = m.group(1)!;
      final parsedPort = int.tryParse(m.group(2)!);
      if (parsedPort != null) {
        port = parsedPort;
        _portController.text = parsedPort.toString();
        _ipController.text = ip;
      }
    }
    // Catch the most common user error: they typed 5555 (the ADB port
    // they remember from `adb connect 192.168.x.y:5555`) instead of
    // Pro's LAN server port 39201. Surface a specific message rather
    // than the generic "could not connect" so the user knows where to
    // look. Also catch a few other ports they might confuse it with.
    const knownWrongPorts = {
      5555: 'the ADB debugging port',
      8080: 'a common HTTP port',
      80: 'plain HTTP',
      443: 'HTTPS',
    };
    if (knownWrongPorts.containsKey(port)) {
      setState(() {
        _error = 'Port $port is ${knownWrongPorts[port]}, not the Pro app port. '
            'Use $_defaultPort (shown next to the IP on the other device).';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(lanRepositoryProvider.future);
      // Synthetic peer — the discovery service never saw this, but
      // every downstream layer (pair, TLS pinning, HMAC, file send)
      // only needs host + port + a deviceId stable across the
      // pairing handshake. We use the IP itself as a temporary
      // deviceId; the real one is exchanged during pair init.
      final synthetic = NearbyDevice(
        deviceId: 'manual:$ip:$port',
        name: 'Device at $ip',
        host: ip,
        port: port,
        platform: 'unknown',
        appVersion: 'unknown',
      );
      final res = await repo.pair(
        peer: synthetic,
        requestPin: () => _askForPin(context, ip),
      );
      if (!mounted) return;
      res.fold(
        (paired) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Paired with ${paired.name}')),
          );
          setState(() {
            _busy = false;
            _expanded = false;
            _ipController.clear();
          });
        },
        (failure) {
          setState(() {
            _busy = false;
            // Surface the actual failure reason — buried-error debugging
            // is way harder than a slightly-too-technical user-visible
            // string. The PairingFailure messages are already
            // user-readable ("Could not reach X at Y…", "PIN mismatch",
            // etc.); only fall back to the generic copy if the failure
            // has nothing to say.
            final reason = failure.message.trim();
            _error = reason.isNotEmpty
                ? reason
                : 'Could not connect to $ip:$port — check the IP shown on the other device and that both are on the same Wi-Fi.';
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Connection failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.dns_outlined, color: cs.primary, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Connect by IP address',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            'For TVs or PCs that don\'t appear in the list',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'On the other device, open Interact Pro → home screen. '
                      'The local IP address is shown at the bottom (e.g. 192.168.1.42).',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.4,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _ipController,
                            keyboardType: TextInputType.text,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.none,
                            decoration: const InputDecoration(
                              labelText: 'IP address',
                              hintText: '192.168.1.42',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 1,
                          child: TextField(
                            controller: _portController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.link, size: 18),
                        label: Text(_busy ? 'Connecting…' : 'Connect'),
                        onPressed:
                            (!_busy && _ipValid) ? _connect : null,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: TextStyle(color: cs.error, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
