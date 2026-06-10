import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Brief animated splash shown after `flutter_native_splash`'s static
/// frame. The native splash holds the same dark-green background +
/// `icon-fg.png` while the engine boots, then this widget takes over
/// with an animation so the transition feels intentional rather than
/// a sudden jump from boot frame to app UI.
///
/// Animation:
///   1. Background stays dark-green (matches native splash → no flash).
///   2. Icon fades + scales up from 0.7 → 1.0 over 700ms.
///   3. Subtle golden ring pulses outward behind the icon.
///   4. App title fades in below the icon.
///   5. After [duration] ms total, calls [onDone] so the host can
///      navigate to the home screen.
///
/// Wrap your real app shell in this — it shows the splash, then renders
/// `child` once done. No timing magic in callers.
class AnimatedSplash extends StatefulWidget {
  const AnimatedSplash({
    this.duration = const Duration(milliseconds: 1400),
    this.onDone,
    super.key,
  });

  final Duration duration;

  /// Called when the animation finishes. Hosts use this to flip a
  /// "splash shown" flag so subsequent rebuilds of the widget tree
  /// don't replay the animation on every navigation.
  final VoidCallback? onDone;

  @override
  State<AnimatedSplash> createState() => _AnimatedSplashState();
}

class _AnimatedSplashState extends State<AnimatedSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _iconScale;
  late final Animation<double> _iconOpacity;
  late final Animation<double> _ringScale;
  late final Animation<double> _ringOpacity;
  late final Animation<double> _titleOpacity;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          // Notify the host first (so it can flip its persistent flag),
          // then mark this widget as done locally.
          widget.onDone?.call();
          setState(() => _done = true);
        }
      });

    // Icon: scale 0.7 → 1.0, opacity 0 → 1, between 0% and 60% of timeline.
    _iconScale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack)),
    );
    _iconOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5, curve: Curves.easeOut)),
    );

    // Ring: scales out from 0.6 → 1.6, fades 0 → 0.5 → 0, between 10% and 80%.
    _ringScale = Tween<double>(begin: 0.6, end: 1.6).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.1, 0.8, curve: Curves.easeOutCubic)),
    );
    _ringOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.5), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.5, end: 0.0), weight: 70),
    ]).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.1, 0.8)),
    );

    // Title: fades in 60% → 100%.
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.6, 1.0, curve: Curves.easeOut)),
    );

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();

    // TV / large-screen sizing: scale every fixed dimension up so a 55"
    // screen doesn't show a postage-stamp icon. Threshold: shortestSide
    // ≥ 720dp matches the same TV detection used elsewhere in the app.
    final isTv = MediaQuery.of(context).size.shortestSide >= 720;
    final iconSize = isTv ? 280.0 : 160.0;
    final ringSize = isTv ? 380.0 : 220.0;
    final ringStroke = isTv ? 6.0 : 4.0;
    final titleFontSize = isTv ? 42.0 : 24.0;
    final taglineFontSize = isTv ? 18.0 : 12.0;
    final titleBottomOffset = isTv ? 200.0 : 120.0;

    return Material(
      color: AppTheme.brandSurfaceDark,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              // Pulsing golden ring behind the icon.
              Transform.scale(
                scale: _ringScale.value,
                child: Opacity(
                  opacity: _ringOpacity.value,
                  child: Container(
                    width: ringSize,
                    height: ringSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AppTheme.brandGold, width: ringStroke,),
                    ),
                  ),
                ),
              ),
              // Icon — scales + fades in.
              Opacity(
                opacity: _iconOpacity.value,
                child: Transform.scale(
                  scale: _iconScale.value,
                  child: SizedBox(
                    width: iconSize,
                    height: iconSize,
                    child: Image.asset(
                      'assets/icon/icon-fg.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              // Title fades in below.
              Positioned(
                bottom: titleBottomOffset,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: _titleOpacity.value,
                  child: Column(
                    children: [
                      Text(
                        'Interact Pro',
                        style: TextStyle(
                          color: AppTheme.brandGold,
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'PDF · Scan · OCR · Translate',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: taglineFontSize,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
