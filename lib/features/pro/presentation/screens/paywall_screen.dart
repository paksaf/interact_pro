import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/layout/responsive.dart';
import '../../data/pro_repository.dart';
import '../../domain/iap_products.dart';

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  late Future<List<ProductDetails>> _productsFuture;

  @override
  void initState() {
    super.initState();
    _productsFuture = ref.read(proRepositoryProvider).loadProducts();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: () => ref.read(proRepositoryProvider).restore(),
            // Autofocus on TV / remote — gives the D-pad a top-of-screen
            // landing target. Users typically arrive here meaning to either
            // restore or pick a tier; either way Restore is the safe first
            // focusable element (it's a no-op for new users so accidental
            // taps are harmless).
            autofocus: true,
            child: const Text('Restore'),
          ),
        ],
      ),
      body: SafeArea(
        child: LandscapeFormBody(
          maxWidth: 640,
          child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(Icons.workspace_premium, size: 72, color: cs.primary),
              const SizedBox(height: 16),
              Text('Interact Pro',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,),),
              const SizedBox(height: 8),
              Text('Unlock the full document workstation',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),),
              const SizedBox(height: 24),
              const _Feature(icon: Icons.translate, title: 'AI Translation', subtitle: 'Translate any PDF to Urdu, English and 30+ languages with DeepSeek.'),
              const _Feature(icon: Icons.record_voice_over, title: 'Read Aloud', subtitle: 'Listen to PDFs with natural-sounding text-to-speech.'),
              const _Feature(icon: Icons.mic, title: 'Voice Dictation', subtitle: 'Dictate annotations and notes hands-free.'),
              const _Feature(icon: Icons.touch_app, title: 'Interactive Hotspots', subtitle: 'Embed hidden notes, links, and media on long-press.'),
              const _Feature(icon: Icons.text_format, title: 'Polished Urdu / Arabic', subtitle: 'Properly shaped RTL text rendering.'),
              const _Feature(icon: Icons.bolt, title: 'Unlimited OCR & Sync', subtitle: 'No monthly page or storage caps.'),
              const _Feature(icon: Icons.workspace_premium_outlined, title: 'No watermarks', subtitle: 'Clean exports, every time.'),
              const SizedBox(height: 24),
              FutureBuilder<List<ProductDetails>>(
                future: _productsFuture,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),);
                  }
                  final products = snap.data ?? const <ProductDetails>[];
                  if (products.isEmpty) {
                    // Store unavailable for any reason (sideload, region not
                    // supported by IAP, Play / App Store hiccup, dev build).
                    // Don't dead-end — offer a "Request access" path that
                    // emails admin@interactpak.com so we can manually grant
                    // testing / promo access.
                    return _StoreUnavailableCard(onRequest: _emailRequestAccess);
                  }
                  return Column(children: products.map(_priceTile).toList());
                },
              ),
              const SizedBox(height: 24),
              Text(
                'Subscriptions auto-renew. Cancel anytime in your device settings. '
                'See Terms and Privacy for details.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
        ),
      ),
    );
  }

  /// Open the user's mail client pre-filled with a Pro-access request.
  /// Falls back to copying the address + opening the in-app support chat
  /// if no mail client is installed (common on freshly-flashed Android TVs).
  Future<void> _emailRequestAccess() async {
    const to = 'admin@interactpak.com';
    final subject = Uri.encodeComponent('Interact Pro — request access');
    final body = Uri.encodeComponent(
      'Hello,\n\n'
      'I would like to request Interact Pro access. The in-app store '
      'shows as unavailable on my device.\n\n'
      'Device: (please describe — phone / tablet / TV / sideload?)\n'
      'Country: \n'
      'How I plan to use the app: \n\n'
      'Thanks.',
    );
    final mailto = Uri.parse('mailto:$to?subject=$subject&body=$body');

    // launchUrl returns false if no mail client is registered. Don't
    // throw — show a snackbar with the address so the user can copy it.
    if (!await canLaunchUrl(mailto) || !await launchUrl(mailto)) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'No mail app found. Email admin@interactpak.com manually — '
            'we typically reply within one business day.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  Widget _priceTile(ProductDetails p) {
    final isYearly = p.id == IapProducts.yearly;
    final isLifetime = p.id == IapProducts.lifetime;
    final suffix = isLifetime ? '' : isYearly ? '/yr' : '/mo';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        title: Text(p.title.isEmpty ? p.id : p.title,
            style: const TextStyle(fontWeight: FontWeight.bold),),
        subtitle: Text(p.description),
        trailing: FilledButton(
          onPressed: () async {
            final ok = await ref.read(proRepositoryProvider).purchase(p.id);
            if (!mounted) return;
            if (ok) context.pop();
          },
          child: Text('${p.price}$suffix'),
        ),
      ),
    );
  }
}

class _StoreUnavailableCard extends StatelessWidget {
  const _StoreUnavailableCard({required this.onRequest});
  final Future<void> Function() onRequest;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.storefront_outlined, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Store not available',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "We couldn't reach the in-app store on this device. This often "
              'happens on sideloaded builds, regions where Play Billing is '
              'restricted, or during a temporary outage.',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.mark_email_read_outlined),
              label: const Text('Email us to request access'),
            ),
            const SizedBox(height: 4),
            Text(
              'We typically grant testing or promo access within one business day. '
              'You can also try again later — the store may be momentarily down.',
              style: TextStyle(color: cs.outline, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
