// SPDX-License-Identifier: AGPL-3.0
//
// First-run onboarding — 5 swipeable slides that introduce the major
// feature areas pulled from help_content. Shown once on first install
// and re-shown on major-version bumps (the "seen" key is version-pinned
// so a v2.1.0 → v2.2.0 user sees the new tour automatically).
//
// Dismissable with "Skip" or by reaching the last slide and tapping "Get
// started". The Help screen remains accessible from the AppBar at any
// time, so users who skip can always come back to learn at their own pace.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/routing/app_routes.dart';
import '../../data/help_content.dart';

/// Pinned to the major.minor of the app — bump when the onboarding
/// content materially changes so existing users get re-introduced.
const String _onboardingVersion = '2.0';
const String _seenKey = 'onboarding.seen.v$_onboardingVersion';

/// Watch from app.dart's root widget. AsyncValue.data(true) = show the
/// onboarding route; data(false) = first-run already happened; loading
/// = SharedPreferences hasn't returned yet, render normally.
final shouldShowOnboardingProvider = FutureProvider<bool>((ref) async {
  final p = await SharedPreferences.getInstance();
  return !p.getBool(_seenKey).orElseFalse();
});

extension on bool? {
  bool orElseFalse() => this ?? false;
}

/// Marks the onboarding done so the user isn't shown it again until the
/// version pin changes. Called from OnboardingScreen on completion or
/// Skip; also exposed for the Settings screen's "Replay onboarding"
/// action (which we don't ship yet but the API supports it).
Future<void> markOnboardingSeen() async {
  final p = await SharedPreferences.getInstance();
  await p.setBool(_seenKey, true);
}

/// Forces the next launch to show onboarding again — useful for users
/// who want to refresh on new features, and for QA.
Future<void> resetOnboardingSeen() async {
  final p = await SharedPreferences.getInstance();
  await p.remove(_seenKey);
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageCtrl = PageController();
  int _page = 0;

  /// Slides = one teaser from each top section in helpSections.
  /// Pick the first item per section so the tour stays at 5 slides.
  late final List<_Slide> _slides = helpSections
      .map((s) => _Slide(
            section: s,
            item: s.items.isNotEmpty ? s.items.first : null,
          ),)
      .where((s) => s.item != null)
      .toList();

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await markOnboardingSeen();
    if (!mounted) return;
    // Pop the onboarding if we were pushed; otherwise go home.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.goNamed(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (ctx, i) => _SlideView(slide: _slides[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_slides.length, (i) {
                      final active = i == _page;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: active ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      if (_page > 0)
                        TextButton(
                          onPressed: () => _pageCtrl.previousPage(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOut,
                          ),
                          child: const Text('Back'),
                        )
                      else
                        const SizedBox(width: 64),
                      const Spacer(),
                      FilledButton(
                        onPressed: _page < _slides.length - 1
                            ? () => _pageCtrl.nextPage(
                                  duration: const Duration(milliseconds: 240),
                                  curve: Curves.easeOut,
                                )
                            : _finish,
                        child: Text(
                          _page < _slides.length - 1 ? 'Next' : 'Get started',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slide {
  const _Slide({required this.section, required this.item});
  final HelpSection section;
  final HelpItem? item;
}

class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide});
  final _Slide slide;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final it = slide.item!;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              slide.section.icon,
              size: 52,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            slide.section.title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            it.title,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            it.summary,
            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          ...it.steps.asMap().entries.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${e.key + 1}',
                        style: TextStyle(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w800, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(e.value, style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),),
          if (it.remoteHint != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.tv_outlined, size: 18, color: theme.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'On your remote:  ${it.remoteHint}',
                      style: TextStyle(color: theme.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
