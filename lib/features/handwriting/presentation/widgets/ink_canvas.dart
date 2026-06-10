import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/ink_stroke.dart';

/// Touchscreen / Apple Pencil drawing surface that captures strokes for
/// digital-ink recognition.
///
/// Uses [Listener] for pointer events so we get `pressure`, `tilt`, and
/// `kind` (touch vs stylus). The wrapping [GestureDetector] is there
/// purely to claim the gesture arena — without it, a vertical drag
/// inside the canvas could be hijacked by an ancestor scrollable.
///
/// Owns its own gesture state (in-progress stroke + completed strokes)
/// and exposes them via [InkCanvasController] so the screen can call
/// `currentCapture()` when the user taps "Recognise".
///
/// The canvas is INTENTIONALLY dumb about coordinate normalisation: ML
/// Kit's recogniser is scale-invariant, so the only thing that matters
/// is that the points share a coordinate system. We use raw widget-local
/// pixels and let ML Kit handle the rest.
class InkCanvas extends StatefulWidget {
  const InkCanvas({
    required this.controller,
    this.height = 280,
    this.strokeWidth = 3.5,
    super.key,
  });

  final InkCanvasController controller;
  final double height;

  /// Base stroke width — multiplied by pressure (0.5×–1.5× range) to
  /// give variable-width ink on stylus input. Touch input renders at
  /// 1.0× of this since the OS reports 0 for touch pressure.
  final double strokeWidth;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  Stopwatch? _sessionClock;
  InkStroke? _activeStroke;

  /// One-shot timestamp baseline for the entire capture session. Reset
  /// every time the user clears the canvas, so timestamps inside a
  /// single recognition request are always monotonically increasing
  /// and start near zero (which ML Kit prefers).
  int get _now {
    final clock = _sessionClock;
    if (clock == null) return 0;
    return clock.elapsedMilliseconds;
  }

  void _ensureSessionStarted() {
    _sessionClock ??= Stopwatch()..start();
  }

  /// Apple Pencil / Wacom etc. report `pressure` in the device's native
  /// range. iOS forces it to 0..1; Android usually does too, but some
  /// vendors report 0..2. Clamp defensively. Touch input reports 0, in
  /// which case we substitute 1.0 so the line still draws at full width.
  double _normalisedPressure(PointerEvent event) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return 1.0;
    }
    final raw = event.pressure;
    if (raw <= 0) return 1.0;
    final max = event.pressureMax > 0 ? event.pressureMax : 1.0;
    return (raw / max).clamp(0.05, 1.0);
  }

  void _onPointerDown(PointerDownEvent e) {
    _ensureSessionStarted();
    final stroke = InkStroke(points: [
      InkPoint(
        x: e.localPosition.dx,
        y: e.localPosition.dy,
        timestampMs: _now,
        pressure: _normalisedPressure(e),
      ),
    ],);
    setState(() => _activeStroke = stroke);
  }

  void _onPointerMove(PointerMoveEvent e) {
    final s = _activeStroke;
    if (s == null) return;
    setState(() {
      _activeStroke = InkStroke(points: [
        ...s.points,
        InkPoint(
          x: e.localPosition.dx,
          y: e.localPosition.dy,
          timestampMs: _now,
          pressure: _normalisedPressure(e),
        ),
      ],);
    });
  }

  void _onPointerUp(PointerUpEvent _) {
    final s = _activeStroke;
    if (s == null || s.isEmpty) {
      setState(() => _activeStroke = null);
      return;
    }
    widget.controller._commit(s);
    setState(() => _activeStroke = null);
  }

  void _onPointerCancel(PointerCancelEvent _) {
    // Drop the in-progress stroke without committing — usually fires
    // when the OS preempts the gesture (e.g. notification swipe).
    setState(() => _activeStroke = null);
  }

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
  }

  @override
  void dispose() {
    widget.controller._detach(this);
    super.dispose();
  }

  void _resetClock() {
    _sessionClock = Stopwatch()..start();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        // GestureDetector claims the gesture arena with a no-op pan
        // handler so ancestor scrollables don't steal the drag. The
        // actual drawing happens via the inner Listener (which gives
        // us pressure / tilt / kind that GestureDetector hides).
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {},
          onPanUpdate: (_) {},
          onPanEnd: (_) {},
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (_, __) => CustomPaint(
                painter: _InkPainter(
                  strokes: widget.controller._strokes,
                  inProgress: _activeStroke,
                  baseWidth: widget.strokeWidth,
                  strokeColor: cs.onSurface,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter({
    required this.strokes,
    required this.inProgress,
    required this.baseWidth,
    required this.strokeColor,
  });

  final List<InkStroke> strokes;
  final InkStroke? inProgress;
  final double baseWidth;
  final Color strokeColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _drawStroke(canvas, s);
    }
    final cur = inProgress;
    if (cur != null) _drawStroke(canvas, cur);
  }

  /// We draw each segment between two consecutive points individually so
  /// the per-segment width can interpolate the two endpoint pressures.
  /// This is more expensive than a single `Path` but gives the
  /// "tapering ink" look users expect from a stylus app.
  void _drawStroke(Canvas canvas, InkStroke stroke) {
    final pts = stroke.points;
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      // Single tap — dot scaled by pressure so light taps look light.
      final p = pts.first;
      final r = baseWidth * 0.5 * _widthScale(p.pressure);
      canvas.drawCircle(
        Offset(p.x, p.y),
        r,
        Paint()..color = strokeColor,
      );
      return;
    }
    final paint = Paint()
      ..color = strokeColor
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final b = pts[i];
      // Average the two endpoint pressures for the segment width — gives
      // smoother width transitions than picking one or the other.
      final avgPressure = (a.pressure + b.pressure) * 0.5;
      paint.strokeWidth = baseWidth * _widthScale(avgPressure);
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), paint);
    }
  }

  /// Map normalised pressure (0..1) to a width multiplier (0.5..1.5).
  /// A linear map this wide is what feels right with `baseWidth = 3.5`;
  /// going below 0.5× makes hairline strokes nearly invisible on bright
  /// backgrounds, and above 1.5× makes a moderate press look like
  /// shouting.
  double _widthScale(double pressure) => 0.5 + pressure;

  @override
  bool shouldRepaint(covariant _InkPainter old) {
    return !identical(old.strokes, strokes) ||
        !identical(old.inProgress, inProgress) ||
        old.baseWidth != baseWidth ||
        old.strokeColor != strokeColor;
  }
}

/// External handle on the canvas. Lives outside the widget so the parent
/// screen can clear / undo / read the strokes without juggling
/// GlobalKeys.
class InkCanvasController extends ChangeNotifier {
  final List<InkStroke> _strokes = [];
  _InkCanvasState? _attached;

  void _attach(_InkCanvasState s) => _attached = s;
  void _detach(_InkCanvasState s) {
    if (identical(_attached, s)) _attached = null;
  }

  void _commit(InkStroke stroke) {
    _strokes.add(stroke);
    notifyListeners();
  }

  /// Snapshot of everything the user has drawn so far. Hand this to the
  /// recogniser when "Recognise" is tapped.
  InkCapture currentCapture() => InkCapture(strokes: List.unmodifiable(_strokes));

  bool get isEmpty => _strokes.isEmpty;
  int get strokeCount => _strokes.length;

  void clear() {
    if (_strokes.isEmpty) return;
    _strokes.clear();
    _attached?._resetClock();
    notifyListeners();
  }

  void undo() {
    if (_strokes.isEmpty) return;
    _strokes.removeLast();
    notifyListeners();
  }

  /// Visible for debugging so widget tests can inspect captured input.
  @visibleForTesting
  List<InkStroke> get strokes => List.unmodifiable(_strokes);
}
