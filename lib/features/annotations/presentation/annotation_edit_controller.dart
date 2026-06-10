// SPDX-License-Identifier: AGPL-3.0
//
// AnnotationEditController — per-document edit state for the floating
// tool palette + page painter (#261, 2026-05-20). Holds the currently
// selected tool, color, and stroke width.
//
// Scope is deliberately limited to in-memory session state — no
// SharedPreferences. Users mostly want consistent settings within a
// reading session, and a remembered "last used red highlighter"
// across sessions surprises more than helps. Defaults bias toward
// the most-used tool (highlighter / yellow / medium) so a single tap
// gets the user productive.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the user can do in annotation edit mode.
enum AnnotationTool {
  none, // edit mode off — palette closed
  highlighter,
  pen,
  eraser,
  circle,
  rectangle,
  arrow,
  text,
}

/// Stroke-width preset bucket. Three named sizes is enough for the
/// audience (annotators, not graphic designers); a continuous slider
/// would let users pick widths that look identical on the rendered
/// page but cost much more screen real-estate.
enum StrokePreset { thin, medium, thick }

extension StrokePresetSize on StrokePreset {
  /// Pixel width passed to the painter and the Syncfusion pen.
  double get width => switch (this) {
        StrokePreset.thin => 1.5,
        StrokePreset.medium => 3.0,
        StrokePreset.thick => 5.5,
      };
}

@immutable
class AnnotationEditState {
  const AnnotationEditState({
    this.tool = AnnotationTool.none,
    this.color = const Color(0xFFFCD34D), // amber-300
    this.stroke = StrokePreset.medium,
  });

  final AnnotationTool tool;
  final Color color;
  final StrokePreset stroke;

  bool get isEditing => tool != AnnotationTool.none;

  AnnotationEditState copyWith({
    AnnotationTool? tool,
    Color? color,
    StrokePreset? stroke,
  }) =>
      AnnotationEditState(
        tool: tool ?? this.tool,
        color: color ?? this.color,
        stroke: stroke ?? this.stroke,
      );
}

class AnnotationEditController extends StateNotifier<AnnotationEditState> {
  AnnotationEditController() : super(const AnnotationEditState());

  /// Enter edit mode with the given tool. Calling with the SAME tool
  /// twice toggles the palette closed — matches the intuition of
  /// "I'm done annotating, give me back my page".
  void selectTool(AnnotationTool tool) {
    if (state.tool == tool) {
      state = state.copyWith(tool: AnnotationTool.none);
    } else {
      state = state.copyWith(tool: tool);
    }
  }

  void setColor(Color color) => state = state.copyWith(color: color);
  void setStroke(StrokePreset s) => state = state.copyWith(stroke: s);
  void exit() => state = state.copyWith(tool: AnnotationTool.none);
}

final annotationEditControllerProvider =
    StateNotifierProvider<AnnotationEditController, AnnotationEditState>(
  (ref) => AnnotationEditController(),
);

/// Canonical color swatches surfaced in the palette. Four colors
/// covers the main use cases (highlight, annotate, redact, note);
/// adding more dilutes the muscle-memory benefit.
const annotationSwatches = <Color>[
  Color(0xFFFCD34D), // amber — default highlighter
  Color(0xFFFB7185), // rose — corrections / mistakes
  Color(0xFF60A5FA), // blue — info / quotes
  Color(0xFF34D399), // emerald — agreements / approvals
];
