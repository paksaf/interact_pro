import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../../domain/ar_measurement.dart';

/// Reactive state for the AR measurement screen.
///
/// We keep the AR-plugin objects (session/object/anchor managers, native
/// nodes) inside the screen widget — they're tied to the platform view's
/// lifecycle and should not survive a screen pop. The controller carries
/// only the user-visible model: current points, completed segments,
/// chosen unit, and a status banner string.
class ArMeasuringState {
  const ArMeasuringState({
    this.tracking = false,
    this.unit = ArUnit.centimetre,
    this.pendingPoint,
    this.segments = const [],
    this.statusMessage = 'Move the phone slowly to detect surfaces…',
    this.errorMessage,
  });

  /// True once the AR session reports it has detected at least one plane
  /// and is ready to accept taps.
  final bool tracking;

  final ArUnit unit;

  /// First point of an in-progress measurement. Null when nothing has
  /// been tapped or the previous segment is complete.
  final ArPoint? pendingPoint;

  /// Completed measurements in tap order.
  final List<ArSegment> segments;

  /// One-line status / instruction shown above the camera view.
  final String statusMessage;

  final String? errorMessage;

  ArMeasuringState copyWith({
    bool? tracking,
    ArUnit? unit,
    ArPoint? pendingPoint,
    List<ArSegment>? segments,
    String? statusMessage,
    String? errorMessage,
    bool clearPending = false,
    bool clearError = false,
  }) {
    return ArMeasuringState(
      tracking: tracking ?? this.tracking,
      unit: unit ?? this.unit,
      pendingPoint: clearPending ? null : (pendingPoint ?? this.pendingPoint),
      segments: segments ?? this.segments,
      statusMessage: statusMessage ?? this.statusMessage,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

final arMeasuringControllerProvider = StateNotifierProvider.autoDispose<
    ArMeasuringController, ArMeasuringState>((ref) {
  return ArMeasuringController();
});

class ArMeasuringController extends StateNotifier<ArMeasuringState> {
  ArMeasuringController() : super(const ArMeasuringState());

  static const _uuid = Uuid();

  void markTracking() {
    state = state.copyWith(
      tracking: true,
      statusMessage: state.pendingPoint == null
          ? 'Tap anywhere on a detected surface to set the start point.'
          : 'Tap the second point to complete the measurement.',
    );
  }

  void reportError(String message) {
    state = state.copyWith(errorMessage: message);
  }

  void setUnit(ArUnit unit) {
    reformatSegments(unit);
  }

  /// Called by the screen each time the AR session resolves a tap into
  /// a 3D world point. Returns the new point's id so the screen can map
  /// it to the native marker node it just placed.
  String onPointPicked(vm.Vector3 position) {
    final id = _uuid.v4();
    final picked = ArPoint(id: id, position: position);

    final pending = state.pendingPoint;
    if (pending == null) {
      state = state.copyWith(
        pendingPoint: picked,
        statusMessage: 'Tap the second point to measure.',
        clearError: true,
      );
      return id;
    }

    final segment = ArSegment(
      id: _uuid.v4(),
      a: pending,
      b: picked,
      label: state.unit.format(_distance(pending, picked)),
    );
    state = state.copyWith(
      segments: [...state.segments, segment],
      clearPending: true,
      statusMessage:
          'Measured ${segment.label}. Tap to start a new measurement.',
      clearError: true,
    );
    return id;
  }

  void reformatSegments(ArUnit unit) {
    final reformatted = state.segments
        .map((s) => ArSegment(
              id: s.id,
              a: s.a,
              b: s.b,
              label: unit.format(s.distanceMetres),
            ),)
        .toList();
    state = state.copyWith(unit: unit, segments: reformatted);
  }

  void clearAll() {
    state = state.copyWith(
      clearPending: true,
      segments: const [],
      statusMessage: state.tracking
          ? 'Tap anywhere on a detected surface to set the start point.'
          : 'Move the phone slowly to detect surfaces…',
      clearError: true,
    );
  }

  void cancelPending() {
    if (state.pendingPoint == null) return;
    state = state.copyWith(
      clearPending: true,
      statusMessage: 'Tap to set the start point.',
    );
  }

  static double _distance(ArPoint a, ArPoint b) {
    final dx = b.position.x - a.position.x;
    final dy = b.position.y - a.position.y;
    final dz = b.position.z - a.position.z;
    return (dx * dx + dy * dy + dz * dz).abs() <= 0
        ? 0
        : _sqrt(dx * dx + dy * dy + dz * dz);
  }

  static double _sqrt(double v) {
    if (v <= 0) return 0;
    var x = v;
    for (var i = 0; i < 16; i++) {
      final next = 0.5 * (x + v / x);
      if ((next - x).abs() < 1e-9) return next;
      x = next;
    }
    return x;
  }
}
