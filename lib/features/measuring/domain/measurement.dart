import 'dart:math' as math;
import 'dart:ui';

/// User-displayable units for the measuring tool. mm is the canonical
/// internal unit — all conversions go through it.
enum MeasurementUnit {
  millimeter('mm', 1.0),
  centimeter('cm', 10.0),
  inch('in', 25.4),
  meter('m', 1000.0);

  const MeasurementUnit(this.symbol, this.mmPerUnit);

  final String symbol;
  final double mmPerUnit;

  /// Format [mm] millimetres as a human-readable string in this unit.
  /// Picks decimal places based on magnitude:
  ///   • mm: integer if ≥ 100, 1 decimal otherwise
  ///   • cm: 1 decimal
  ///   • inch: 2 decimals
  ///   • m: 3 decimals
  String format(double mm) {
    final value = mm / mmPerUnit;
    final decimals = switch (this) {
      MeasurementUnit.millimeter => value >= 100 ? 0 : 1,
      MeasurementUnit.centimeter => 1,
      MeasurementUnit.inch => 2,
      MeasurementUnit.meter => 3,
    };
    return '${value.toStringAsFixed(decimals)} $symbol';
  }
}

/// A real-world reference whose physical length is known. Used to
/// calibrate the photo's scale (mm per widget-pixel) by tapping its
/// two endpoints in the image.
///
/// All defaults below are well-known global standards — credit cards
/// follow ISO/IEC 7810 ID-1, A4 follows ISO 216, etc. See [presets].
class ReferenceObject {
  const ReferenceObject({
    required this.label,
    required this.lengthMm,
    this.note,
  });

  /// Short user-facing name shown in the picker chip.
  final String label;

  /// Real-world length of the reference's longest dimension, in mm.
  final double lengthMm;

  /// Optional clarification shown as a subtitle (e.g. "long edge",
  /// "short edge"). Lets the picker stay short.
  final String? note;

  /// Built-in references the picker offers out of the box. Order
  /// matters — first item is the default selection.
  static const List<ReferenceObject> presets = [
    ReferenceObject(
      label: 'Credit card',
      lengthMm: 85.6,
      note: 'long edge · ISO/IEC 7810',
    ),
    ReferenceObject(
      label: 'A4 paper',
      lengthMm: 210.0,
      note: 'short edge · ISO 216',
    ),
    ReferenceObject(
      label: 'A4 paper',
      lengthMm: 297.0,
      note: 'long edge · ISO 216',
    ),
    ReferenceObject(
      label: 'US dollar bill',
      lengthMm: 155.956,
      note: 'long edge',
    ),
    ReferenceObject(
      label: 'Business card',
      lengthMm: 89.0,
      note: 'long edge · UK/PK standard',
    ),
    ReferenceObject(
      label: 'Pakistani 1 rupee coin',
      lengthMm: 19.5,
      note: 'diameter',
    ),
    ReferenceObject(
      label: 'Pakistani 5 rupee coin',
      lengthMm: 24.0,
      note: 'diameter',
    ),
    ReferenceObject(
      label: 'iPhone 15',
      lengthMm: 147.6,
      note: 'long edge · device height',
    ),
  ];
}

/// One completed measurement on the photo: two tapped endpoints in
/// widget-local coordinates. The screen converts the pixel distance
/// to mm using the calibration from the reference object.
class Measurement {
  const Measurement({required this.a, required this.b});

  final Offset a;
  final Offset b;

  double get pixelDistance => (a - b).distance;

  /// Midpoint — used for placing the measurement label.
  Offset get midpoint => Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

  /// Real-world distance in millimetres, given a calibration of
  /// [mmPerPixel]. Returns 0 if the calibration is non-positive.
  double mmFromCalibration(double mmPerPixel) {
    if (mmPerPixel <= 0) return 0;
    return pixelDistance * mmPerPixel;
  }
}

/// Compute mm-per-widget-pixel from a reference's known length plus
/// its two tapped endpoints. Returns 0 (uncalibrated) if either
/// endpoint is null or the points are too close together to give a
/// meaningful scale.
double mmPerPixelFromReference({
  required Offset? a,
  required Offset? b,
  required double knownLengthMm,
}) {
  if (a == null || b == null) return 0;
  final pixelDistance = (a - b).distance;
  if (pixelDistance < 4) return 0; // too close — would explode the scale
  if (knownLengthMm <= 0) return 0;
  return knownLengthMm / pixelDistance;
}

/// 2-arg max for use in painter sizing math (Dart stdlib `math.max` is
/// a templated 2-arg already, but this keeps the call sites clean
/// without importing math everywhere).
double maxd(double a, double b) => math.max(a, b);
