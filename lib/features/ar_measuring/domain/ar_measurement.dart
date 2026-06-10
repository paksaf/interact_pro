import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;

/// One real-world point picked by the user, expressed in the AR session's
/// coordinate frame. The 3D position survives across recognitions because
/// the session anchors track features in the environment — the position
/// stays "stuck" to the spot the user tapped even as they move the phone.
class ArPoint {
  const ArPoint({
    required this.id,
    required this.position,
  });

  /// Anchor id assigned by the underlying AR session. Used to update or
  /// remove the visible marker when the user clears the screen.
  final String id;

  /// World-space position in metres. Shared coordinate frame across all
  /// points in the same session.
  final vm.Vector3 position;
}

/// One measurement = a pair of points and the distance between them.
class ArSegment {
  const ArSegment({
    required this.id,
    required this.a,
    required this.b,
    required this.label,
  });

  final String id;
  final ArPoint a;
  final ArPoint b;

  /// Human-readable label like "1.42 m" or "4'8\"". Computed at create
  /// time using the user's selected unit, baked in so the history list
  /// doesn't have to recalculate when the unit picker changes — the
  /// user can re-add a measurement if they want it expressed differently.
  final String label;

  double get distanceMetres =>
      math.sqrt(math.pow(b.position.x - a.position.x, 2) +
          math.pow(b.position.y - a.position.y, 2) +
          math.pow(b.position.z - a.position.z, 2),);
}

enum ArUnit {
  millimetre,
  centimetre,
  metre,
  inch,
  foot;

  /// Format [metres] into a localised, abbreviated string in this unit.
  /// Round to a precision sensible for the unit so the user sees
  /// "12.3 cm" rather than "12.345678 cm".
  String format(double metres) {
    switch (this) {
      case ArUnit.millimetre:
        return '${(metres * 1000).toStringAsFixed(0)} mm';
      case ArUnit.centimetre:
        return '${(metres * 100).toStringAsFixed(1)} cm';
      case ArUnit.metre:
        return '${metres.toStringAsFixed(2)} m';
      case ArUnit.inch:
        return '${(metres * 39.3701).toStringAsFixed(1)} in';
      case ArUnit.foot:
        // For feet, fold the residual into inches — "4'8\"" reads
        // better than "4.67 ft" for casual room measurement.
        final ft = metres * 3.28084;
        final wholeFt = ft.floor();
        final inches = ((ft - wholeFt) * 12).round();
        if (inches == 12) return '${wholeFt + 1}\'0"';
        return '$wholeFt\'$inches"';
    }
  }

  String get label {
    switch (this) {
      case ArUnit.millimetre:
        return 'mm';
      case ArUnit.centimetre:
        return 'cm';
      case ArUnit.metre:
        return 'm';
      case ArUnit.inch:
        return 'in';
      case ArUnit.foot:
        return 'ft';
    }
  }
}
