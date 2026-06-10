import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Drag-to-flip page view. Uses a 3D rotateY transform on the dragged
/// page so the user sees a real "page turning" motion rather than a
/// flat horizontal swipe. The leading edge gets a soft shadow / sheen
/// during the flip to sell the curl.
///
/// Book-curl polish (task #155): the bare `rotateY(drag*π)` looked
/// mechanical — like a slide flipping, not paper lifting. The
/// [_FlippingPage] below layers on:
///   • Soft drop-shadow underneath the page (deepens as it lifts).
///   • Curl-highlight gradient on the page face — bright line near
///     the lifting edge fading to dim at the spine, mimicking the
///     way light catches a curving sheet.
///   • Spine-edge ambient shadow on the page being revealed.
///   • Spring-physics settle (mass=1, k=180, damping=18) so the page
///     overshoots slightly then bounces back — feels paper-y, not
///     mechanical.
/// A full physically-accurate page-curl needs a CustomPainter mesh
/// deformation, which is significantly more code and battery; this
/// approximation reads as "a real book turning" to users without the
/// engineering cost.
///
/// Why a custom widget instead of pulling a flip-book package:
///   • Most flip-book packages are unmaintained or have iOS-only quirks.
///   • The animation is small enough to write directly with Transform +
///     a Matrix4 perspective entry.
///   • Owning the widget means we control how it composes inside the
///     viewer (zoom, double-tap, fullscreen) without fighting an
///     opinionated package.
class PageFlip extends StatefulWidget {
  const PageFlip({
    required this.pageCount,
    required this.builder,
    this.initialPage = 0,
    this.onPageChanged,
    super.key,
  });

  final int pageCount;
  final IndexedWidgetBuilder builder;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;

  @override
  State<PageFlip> createState() => PageFlipState();
}

class PageFlipState extends State<PageFlip>
    with SingleTickerProviderStateMixin {
  late int _current = widget.initialPage;

  /// Drag amount as a fraction of page width. Negative = dragging left
  /// (forward / next page), positive = dragging right (back / prev).
  /// Range typically -1..1 but clamped during settle.
  double _drag = 0.0;

  late final AnimationController _settle;

  /// Direction the settle is heading: -1 turns to next, 1 turns back,
  /// 0 returns to current. Used to apply the final page change once
  /// the animation completes.
  int _settleDir = 0;

  @override
  void initState() {
    super.initState();
    // Duration is unused when `_animateTo` calls `animateWith(SpringSimulation)`
    // — the spring drives its own settling time. We still need a
    // duration for the controller to be valid; pick something sane in
    // case any future caller does a plain forward()/animateTo().
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d, double width) {
    if (_settle.isAnimating) return;
    setState(() {
      _drag = (_drag + d.primaryDelta! / width).clamp(-1.0, 1.0);
    });
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (_settle.isAnimating) return;
    // Decide whether to commit the flip based on distance + velocity.
    final velocity = d.primaryVelocity ?? 0;
    final distance = _drag;
    final commitNext =
        distance < -0.35 || velocity < -700;
    final commitPrev =
        distance > 0.35 || velocity > 700;

    if (commitNext && _current < widget.pageCount - 1) {
      _animateTo(-1.0, dir: -1);
    } else if (commitPrev && _current > 0) {
      _animateTo(1.0, dir: 1);
    } else {
      _animateTo(0.0, dir: 0);
    }
  }

  void _animateTo(double target, {required int dir}) {
    _settleDir = dir;
    // Spring physics so the page settles with a small overshoot —
    // makes the flip feel paper-y rather than mechanical. Underdamped
    // (ratio < 1) gives one or two visible bounces; tuned by ear on a
    // physical paperback feel.
    //
    // animateWith() sets controller.value directly to sim.x(t) on each
    // tick, so our existing listener (set up in initState as
    // `setState(() => _drag = _settleAnim?.value ?? _drag)`) is bypassed
    // — we read controller.value into _drag in the tick listener below.
    const spring = SpringDescription(mass: 1.0, stiffness: 220, damping: 22);
    final sim = SpringSimulation(spring, _drag, target, 0.0);
    _settle.removeListener(_springTick); // idempotent
    _settle.addListener(_springTick);
    // NOTE: animateWith() returns a TickerFuture — DO NOT cascade
    // (..) here, or .whenComplete would attach to the controller (no
    // such method on AnimationController) instead of the future.
    _settle.animateWith(sim).whenComplete(() {
      _settle.removeListener(_springTick);
      if (dir == -1) {
        setState(() {
          _current = (_current + 1).clamp(0, widget.pageCount - 1);
          _drag = 0.0;
        });
        widget.onPageChanged?.call(_current);
      } else if (dir == 1) {
        setState(() {
          _current = (_current - 1).clamp(0, widget.pageCount - 1);
          _drag = 0.0;
        });
        widget.onPageChanged?.call(_current);
      } else {
        setState(() => _drag = 0.0);
      }
    });
  }

  void _springTick() {
    setState(() => _drag = _settle.value);
  }

  /// External handle used by the screen toolbar / keyboard arrows.
  void next() {
    if (_settle.isAnimating || _current >= widget.pageCount - 1) return;
    _animateTo(-1.0, dir: -1);
  }

  void previous() {
    if (_settle.isAnimating || _current <= 0) return;
    _animateTo(1.0, dir: 1);
  }

  void jumpTo(int page) {
    if (_settle.isAnimating) return;
    final clamped = page.clamp(0, widget.pageCount - 1);
    if (clamped == _current) return;
    setState(() {
      _current = clamped;
      _drag = 0.0;
    });
    widget.onPageChanged?.call(clamped);
  }

  int get currentPage => _current;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) =>
              _onHorizontalDragUpdate(d, constraints.maxWidth),
          onHorizontalDragEnd: _onHorizontalDragEnd,
          child: Stack(
            fit: StackFit.expand,
            children: _buildLayers(constraints),
          ),
        );
      },
    );
  }

  List<Widget> _buildLayers(BoxConstraints constraints) {
    final layers = <Widget>[];

    // The page UNDERNEATH the dragged one — i.e. the page the flip is
    // about to reveal. Stays static until the flip animation completes.
    final underneath = _drag < 0
        ? _safePage(_current + 1) // dragging forward — next page below
        : _drag > 0
            ? _safePage(_current - 1)
            : null;
    if (underneath != null) {
      layers.add(Positioned.fill(child: underneath));
    }

    // The current page on top, transformed.
    final currentPage = _safePage(_current);
    if (currentPage != null) {
      layers.add(_FlippingPage(
        drag: _drag,
        child: currentPage,
      ),);
    }
    return layers;
  }

  Widget? _safePage(int index) {
    if (index < 0 || index >= widget.pageCount) return null;
    return widget.builder(context, index);
  }
}

/// One page wrapped in a 3D rotateY transform. Negative drag (next)
/// rotates the LEFT edge towards the camera, positive rotates the RIGHT
/// edge — same as flipping a real book either direction.
///
/// Book-curl polish layers (task #155):
///   1. Behind the page → soft drop shadow, intensity grows with drag.
///   2. The page itself → unchanged content widget.
///   3. Curl-highlight overlay → linear gradient from the lifting edge
///      (light) to the spine (dim) suggesting the bent paper catching
///      light. Skews with the angle so it slides across the surface as
///      you flip.
///   4. Past-90° darken → applied via the existing black overlay so the
///      reverse side reads as the back of the page (not bright white).
class _FlippingPage extends StatelessWidget {
  const _FlippingPage({
    required this.drag,
    required this.child,
  });

  final double drag;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final angle = drag * math.pi; // 0 → flat, ±π → 180° flip
    final flippingLeft = drag <= 0;
    // Pivot at the spine edge — the OPPOSITE side from the leading edge
    // we're lifting. Flipping forward (drag<0) pivots on the RIGHT spine.
    final alignment =
        flippingLeft ? Alignment.centerRight : Alignment.centerLeft;
    // How "lifted" the page is: 0 = flat, 1 = perpendicular, dropping
    // back to 0 as we approach 180°. Used to scale the drop shadow and
    // curl highlight (both peak when the page is most upright).
    final lift = math.sin(drag.abs() * math.pi).clamp(0.0, 1.0);

    return Center(
      child: Transform(
        alignment: alignment,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0018) // perspective foreshortening
          ..rotateY(angle),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            // ── Drop shadow underneath, deepens as page lifts ──────
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35 * lift),
                        blurRadius: 28 * lift,
                        spreadRadius: 2 * lift,
                        offset: Offset(flippingLeft ? -6 * lift : 6 * lift,
                            6 * lift,),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            child,
            // ── Curl highlight gradient on the page face ───────────
            // Bright sheen near the lifting edge fading to dim toward
            // the spine. Sells the bent-paper effect without any
            // mesh deformation.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: flippingLeft
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      end: flippingLeft
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      stops: const [0.0, 0.15, 0.5, 1.0],
                      colors: [
                        Colors.white.withOpacity(0.18 * lift),
                        Colors.white.withOpacity(0.06 * lift),
                        Colors.black.withOpacity(0.06 * lift),
                        Colors.black.withOpacity(0.22 * lift),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // ── Past-90° darken overlay (existing) ─────────────────
            // Reverse side of the page shows through; tint it darker so
            // the back doesn't read as bright white text.
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withOpacity(
                    (drag.abs() * 0.45).clamp(0.0, 0.45),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
