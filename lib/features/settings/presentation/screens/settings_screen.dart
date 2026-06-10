import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/analytics/analytics_service.dart';
import '../../../../core/config/api_config.dart';
import '../../../../core/i18n/locale_provider.dart';
import '../../../../core/layout/responsive.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../core/settings/ui_preferences.dart';
import '../../../book_viewer/data/flip_sound_controller.dart';
import '../../../pro/data/pro_repository.dart';
import '../../../pro/domain/pro_entitlement.dart';
import '../../../pro/presentation/pro_provider.dart';
import '../../../sync/data/auto_sync_service.dart';

/// Settings + Support entry point. Surfaces:
///   • Pro / trial status
///   • Help & feedback links to interactpak.com
///   • Privacy / Terms / Restore purchases
///   • Analytics opt-out
///   • App version
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _optedOut = false;
  bool _trialUsed = false;

  /// Spike F — auto-sync toggle state. Mirrors
  /// `AutoSyncService.isEnabled()`. Default false.
  bool _autoSync = false;

  @override
  void initState() {
    super.initState();
    _refreshLocal();
  }

  Future<void> _refreshLocal() async {
    final analytics = ref.read(analyticsServiceProvider);
    final pro = ref.read(proRepositoryProvider);
    final sync = ref.read(autoSyncServiceProvider);
    final optedOut = await analytics.isOptedOut();
    final trialUsed = await pro.hasTrialBeenUsed();
    final autoSync = await sync.isEnabled();
    if (!mounted) return;
    setState(() {
      _optedOut = optedOut;
      _trialUsed = trialUsed;
      _autoSync = autoSync;
    });
  }

  Future<void> _open(String url, {required String source}) async {
    await ref.read(analyticsServiceProvider).track(
      AnalyticsEvents.supportLinkClicked,
      properties: {'source': source},
    );
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sub = ref.watch(proSubscriptionProvider).valueOrNull
        ?? ProSubscription.free;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: LandscapeFormBody(
        child: ListView(
        children: [
          _ProStatusTile(sub: sub, trialUsed: _trialUsed, onChanged: _refreshLocal),
          const Divider(),

          const _SectionHeader(label: 'Help & Feedback'),
          ListTile(
            leading: const Icon(Icons.support_agent),
            title: const Text('Support'),
            subtitle: Text(ApiConfig.supportUrl),
            trailing: const Icon(Icons.open_in_new, size: 18),
            // First focusable item on this screen — TV remote D-pad lands
            // here on entry instead of nowhere.
            autofocus: true,
            onTap: () => _open(ApiConfig.supportUrl, source: 'support'),
          ),
          ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('Send feedback'),
            subtitle: const Text('Help us improve Interact Pro'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(ApiConfig.feedbackUrl, source: 'feedback'),
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('Visit interactpak.com'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(ApiConfig.websiteBaseUrl, source: 'website'),
          ),
          const Divider(),

          const _SectionHeader(label: 'Reading'),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Read aloud'),
            subtitle: const Text(
              'Pick a voice for the TTS speaker icon in the book viewer.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(AppRoutes.ttsSettings),
          ),
          // #273 — flip-sound picker. Inline (not a sub-page) since
          // there are only 5 options and showing them in a single
          // RadioListTile column is glanceable + D-pad friendly.
          const _PageFlipSoundPicker(),
          const Divider(),

          const _SectionHeader(label: 'Cross-device'),
          ListTile(
            leading: const Icon(Icons.devices_other),
            title: const Text('Nearby devices'),
            subtitle: const Text(
              'Send PDFs directly to your other devices on the same Wi-Fi.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(AppRoutes.nearbyDevices),
          ),
          const Divider(),

          const _SectionHeader(label: 'Library'),
          ListTile(
            leading: const Icon(Icons.label_outline),
            title: const Text('Tags'),
            subtitle: const Text(
              'Create colored labels to organize your PDFs.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(AppRoutes.tagManager),
          ),
          ListTile(
            leading: const Icon(Icons.bookmarks_outlined),
            title: const Text('Reference diary'),
            subtitle: const Text(
              'All bookmarks across your library in one place.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(AppRoutes.referenceDiary),
          ),
          // Icon-labels toggle (task #4b). Default ON for TV-sized
          // displays (D-pad users can't easily reveal tooltips), OFF
          // on phones where tooltip-on-long-press is fine and the
          // toolbar has limited horizontal space. Per-user, persisted
          // in SharedPreferences via UiPreferencesNotifier.
          Consumer(builder: (context, ref, _) {
            final showLabels =
                ref.watch(uiPreferencesProvider).showIconLabels;
            return SwitchListTile(
              secondary: const Icon(Icons.text_fields),
              title: const Text('Show icon labels'),
              subtitle: const Text(
                'Render a short text label under each toolbar icon. '
                'Recommended on TVs and larger tablets.',
              ),
              value: showLabels,
              onChanged: (v) => ref
                  .read(uiPreferencesProvider.notifier)
                  .setShowIconLabels(v),
            );
          },),
          // Per task #156: by default we hide icons that don't work on
          // the current device class (mic/camera on TV, share on TV).
          // Power users who want to see everything flip this on and
          // accept the "tap and fail" consequence.
          Consumer(builder: (context, ref, _) {
            final showAll =
                ref.watch(uiPreferencesProvider).showAdvancedIcons;
            return SwitchListTile(
              secondary: const Icon(Icons.tune),
              title: const Text('Show advanced controls'),
              subtitle: const Text(
                'By default, icons that don\'t work on this device are '
                'hidden — mic & camera on TV, share on TV, etc. Turn '
                'this on to see every icon (some may not work).',
              ),
              value: showAll,
              onChanged: (v) => ref
                  .read(uiPreferencesProvider.notifier)
                  .setShowAdvancedIcons(v),
            );
          },),
          const Divider(),

          const _SectionHeader(label: 'Signed documents'),
          ListTile(
            leading: const Icon(Icons.draw_outlined),
            title: const Text('Find signed PDF'),
            subtitle: const Text('Search by name or code.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(AppRoutes.findSigned),
          ),
          const Divider(),

          const _SectionHeader(label: 'Language'),
          // Locale picker — three options: English, Urdu, or follow OS.
          // Watching the provider here means the radio buttons reflect
          // the current locale even after the screen is reopened.
          //
          // Flutter 3.32 deprecated per-tile groupValue/onChanged in favor
          // of a shared `RadioGroup<T>` ancestor that owns the value. The
          // wrapper takes a single `onChanged`; each `RadioListTile` only
          // declares its `value`.
          Consumer(
            builder: (context, ref, _) {
              final current = ref.watch(localeProvider);
              final notifier = ref.read(localeProvider.notifier);
              return RadioGroup<String>(
                groupValue: current?.languageCode ?? '__system__',
                onChanged: (val) {
                  if (val == 'en') {
                    notifier.setLocale(const Locale('en'));
                  } else if (val == 'ur') {
                    notifier.setLocale(const Locale('ur'));
                  } else {
                    notifier.setLocale(null);
                  }
                },
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      secondary: Icon(Icons.language),
                      title: Text('English'),
                      subtitle: Text('English UI labels'),
                      value: 'en',
                    ),
                    RadioListTile<String>(
                      secondary: Icon(Icons.translate),
                      title: Text('اردو · Urdu'),
                      subtitle: Text('اردو UI labels (right-to-left)'),
                      value: 'ur',
                    ),
                    RadioListTile<String>(
                      secondary: Icon(Icons.smartphone),
                      title: Text('Follow system language'),
                      subtitle: Text(
                        "Use your phone's language. Falls back to English "
                        "if your language isn't supported.",
                      ),
                      value: '__system__',
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(),

          const _SectionHeader(label: 'Privacy'),
          SwitchListTile(
            secondary: const Icon(Icons.analytics_outlined),
            title: const Text('Share anonymous usage data'),
            subtitle: const Text(
              'Helps us prioritize fixes and features. No content is shared.',
            ),
            value: !_optedOut,
            onChanged: (on) async {
              await ref.read(analyticsServiceProvider).setOptOut(!on);
              setState(() => _optedOut = !on);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Auto-save to cloud when complete'),
            subtitle: const Text(
              'Uploads to your private VPS storage 3s after any save '
              '(annotation, signature, redaction). Default off.',
            ),
            value: _autoSync,
            onChanged: (on) async {
              await ref.read(autoSyncServiceProvider).setEnabled(on);
              setState(() => _autoSync = on);
            },
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(ApiConfig.privacyPolicyUrl, source: 'privacy'),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Terms of Service'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(ApiConfig.termsUrl, source: 'terms'),
          ),
          const Divider(),

          const _SectionHeader(label: 'Subscription'),
          ListTile(
            leading: const Icon(Icons.workspace_premium),
            title: const Text('Manage Pro'),
            onTap: () => context.pushNamed(AppRoutes.paywall),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restore purchases'),
            onTap: () async {
              // Capture ScaffoldMessenger BEFORE the await so we never
              // reach across an async gap to `context`. The lint
              // `use_build_context_synchronously` flags exactly this
              // pattern, and the fix is to grab any context-derived
              // value upfront. mounted-check still guards setState-y
              // work if we add any later.
              final messenger = ScaffoldMessenger.of(context);
              await ref.read(proRepositoryProvider).restore();
              if (!mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('Restore initiated…')),
              );
            },
          ),
          const Divider(),

          const _SectionHeader(label: 'About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Interact Pro'),
            subtitle: Text('Version 2.0.0 · Made in Pakistan'),
          ),
        ],
      ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
}

class _ProStatusTile extends ConsumerWidget {
  const _ProStatusTile({
    required this.sub,
    required this.trialUsed,
    required this.onChanged,
  });

  final ProSubscription sub;
  final bool trialUsed;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    if (sub.isPaid) {
      return Card(
        margin: const EdgeInsets.all(16),
        color: cs.primaryContainer,
        child: ListTile(
          leading: Icon(Icons.workspace_premium, color: cs.onPrimaryContainer),
          title: Text('Pro — ${sub.productId ?? 'active'}',
              style: TextStyle(color: cs.onPrimaryContainer),),
          subtitle: Text(
            sub.expiresAt == null
                ? 'Lifetime · all features unlocked'
                : 'Renews ${sub.expiresAt!.toLocal().toString().split(' ').first}',
            style: TextStyle(color: cs.onPrimaryContainer),
          ),
        ),
      );
    }

    if (sub.isTrial) {
      return Card(
        margin: const EdgeInsets.all(16),
        color: cs.tertiaryContainer,
        child: ListTile(
          leading: Icon(Icons.timer_outlined, color: cs.onTertiaryContainer),
          title: Text('Free trial active',
              style: TextStyle(color: cs.onTertiaryContainer),),
          subtitle: Text(
            '${sub.trialDaysRemaining} day${sub.trialDaysRemaining == 1 ? '' : 's'} '
            'remaining · Tap to upgrade and keep access',
            style: TextStyle(color: cs.onTertiaryContainer),
          ),
          onTap: () => Navigator.of(context).pushNamed('/paywall'),
        ),
      );
    }

    // Free user — offer trial if not used, paywall otherwise.
    return Card(
      margin: const EdgeInsets.all(16),
      child: ListTile(
        leading: const Icon(Icons.workspace_premium_outlined),
        title: Text(trialUsed ? 'Upgrade to Pro' : 'Try Pro free for 7 days'),
        subtitle: const Text(
          'Unlimited OCR · AI translation · Read aloud · Hotspots',
        ),
        trailing: FilledButton(
          onPressed: () async {
            if (!trialUsed) {
              final repo = ref.read(proRepositoryProvider);
              await repo.startTrial();
              await ref.read(analyticsServiceProvider).track(
                AnalyticsEvents.trialStarted,
              );
              onChanged();
            } else {
              await ref.read(analyticsServiceProvider).track(
                AnalyticsEvents.paywallViewed,
                properties: {'source': 'settings'},
              );
              if (context.mounted) {
                // Fire-and-forget — we don't want to block on the user
                // returning from the paywall route. Wrapping in
                // `unawaited(...)` makes the intent explicit and silences
                // the `unawaited_futures` lint.
                unawaited(Navigator.of(context).pushNamed('/paywall'));
              }
            }
          },
          child: Text(trialUsed ? 'Upgrade' : 'Start trial'),
        ),
      ),
    );
  }
}

/// Inline picker for the page-flip sound (#273). 5 options as
/// RadioListTiles — each focusable for D-pad on TV.
///
/// Why inline rather than a sub-page: only 5 entries, and TV users
/// benefit from the choice being visible in the Settings flow rather
/// than buried one tap deeper. The tap-target is the whole row.
class _PageFlipSoundPicker extends ConsumerWidget {
  const _PageFlipSoundPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flipSoundControllerProvider);
    final ctrl = ref.read(flipSoundControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.volume_up_outlined, size: 18),
              SizedBox(width: 12),
              Text(
                'Page-flip sound',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(48, 0, 16, 8),
          child: Text(
            'Pick the sound played on each page turn in the book viewer.',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B6B6B)),
          ),
        ),
        for (final s in PageFlipSound.values)
          RadioListTile<PageFlipSound>(
            value: s,
            groupValue: state.sound,
            onChanged: (v) {
              if (v == null) return;
              ctrl.setSound(v);
              // Preview the chosen sound immediately so the user
              // hears it without having to leave Settings + open a
              // book + flip a page. Best-effort; failures swallow.
              if (v.isEnabled) {
                final player = AudioPlayer()
                  ..setReleaseMode(ReleaseMode.release);
                player.play(AssetSource(v.asset), volume: state.volume)
                    .catchError((_) {});
              }
            },
            title: Text(s.label),
            subtitle: Text(s.description),
            dense: true,
          ),
      ],
    );
  }
}

