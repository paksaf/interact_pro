/// One sampled point along a handwriting stroke.
///
/// Coordinate space is the local widget pixel space of the canvas at
/// capture time — ML Kit's recogniser is scale-invariant, so we don't
/// have to normalise to image-pixel or device-independent units.
class InkPoint {
  const InkPoint({
    required this.x,
    required this.y,
    required this.timestampMs,
    this.pressure = 1.0,
  });

  /// X in widget-local pixels.
  final double x;

  /// Y in widget-local pixels.
  final double y;

  /// Milliseconds since the first point of the *first* stroke in the
  /// capture session. ML Kit uses the relative timestamps to disambiguate
  /// strokes — they don't have to be wall-clock; just monotonically
  /// increasing within a single recognition request.
  final int timestampMs;

  /// 0.0–1.0 normalised pressure from the input device. Apple Pencil and
  /// most stylus drivers report a real value; finger touch reports 0 (we
  /// default to 1.0 in that case so non-stylus input still draws).
  ///
  /// IMPORTANT: ML Kit's recogniser only consumes x/y/t — pressure is
  /// rendering-only and never flows into the [Stroke] sent to ML Kit.
  /// Treat this field as a UI hint, not a recognition signal.
  final double pressure;
}

/// One continuous stroke — a sequence of [InkPoint]s captured between
/// pointer-down and pointer-up.
class InkStroke {
  const InkStroke({required this.points});
  final List<InkPoint> points;

  bool get isEmpty => points.isEmpty;
  bool get isNotEmpty => points.isNotEmpty;
}

/// Whole capture session — multiple strokes recognised together. The
/// recogniser performs much better when the entire word / line is
/// passed at once (vs per-stroke), because it uses inter-stroke
/// geometry to disambiguate letters.
class InkCapture {
  const InkCapture({required this.strokes});
  final List<InkStroke> strokes;

  bool get isEmpty => strokes.every((s) => s.isEmpty);
  int get strokeCount => strokes.length;
  int get pointCount => strokes.fold(0, (a, s) => a + s.points.length);
}
