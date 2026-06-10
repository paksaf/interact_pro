import 'dart:ui' show Color, Offset, Rect;

/// PRD SEL-02 / SEL-03: page-level annotations (highlights, redactions,
/// notes, shapes, freehand ink). Signatures and stamps live as separate
/// entities for clarity.
///
/// Extended 2026-05-20 (#256) with ShapeAnnotation + InkAnnotation so
/// the editor can offer circle/rectangle/arrow + freehand pen tools.
/// Repository impl + page painter + tool palette need to learn the new
/// subtypes before they show up in the UI — schema lands here first so
/// downstream code can be added in follow-up commits.
sealed class Annotation {
  const Annotation({
    required this.id,
    required this.pageIndex,
    required this.bounds,
    required this.createdAt,
    this.author,
  });
  final String id;
  final int pageIndex;
  final Rect bounds;
  final DateTime createdAt;
  final String? author;
}

enum HighlightStyle { highlight, underline, strikeout }

class HighlightAnnotation extends Annotation {
  const HighlightAnnotation({
    required super.id,
    required super.pageIndex,
    required super.bounds,
    required super.createdAt,
    super.author,
    required this.color,
    required this.text,
    this.style = HighlightStyle.highlight,
  });
  final Color color;
  final String text;
  final HighlightStyle style;
}

class RedactAnnotation extends Annotation {
  const RedactAnnotation({
    required super.id,
    required super.pageIndex,
    required super.bounds,
    required super.createdAt,
    super.author,
    this.fillColor = const Color(0xFF000000),
  });
  final Color fillColor;
}

class NoteAnnotation extends Annotation {
  const NoteAnnotation({
    required super.id,
    required super.pageIndex,
    required super.bounds,
    required super.createdAt,
    super.author,
    required this.note,
  });
  final String note;
}

/// Shape primitive — circle/ellipse, rectangle, arrow. Drawn as an
/// outline (or filled outline) inside the bounding rect. Stroke is the
/// outline color/width; `fill` is null for open shapes.
enum ShapeKind { circle, ellipse, rectangle, arrow }

class ShapeAnnotation extends Annotation {
  const ShapeAnnotation({
    required super.id,
    required super.pageIndex,
    required super.bounds,
    required super.createdAt,
    super.author,
    required this.kind,
    required this.strokeColor,
    this.strokeWidth = 2.0,
    this.fillColor,
  });
  final ShapeKind kind;
  final Color strokeColor;
  final double strokeWidth;
  final Color? fillColor;
}

/// Freehand pen / highlighter. Stored as a polyline of normalized
/// page-space offsets (0..1 in both axes) so the same annotation
/// renders correctly at any zoom level. `points` must have ≥ 2 entries
/// — single-tap "dot" strokes are represented by two identical points.
class InkAnnotation extends Annotation {
  const InkAnnotation({
    required super.id,
    required super.pageIndex,
    required super.bounds,
    required super.createdAt,
    super.author,
    required this.points,
    required this.color,
    this.strokeWidth = 2.5,
    this.isHighlighter = false,
  });

  /// Normalised polyline points (each Offset.dx and .dy are in [0,1]).
  /// `bounds` is the axis-aligned bbox of the polyline for hit-testing.
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  /// When true, the renderer draws this stroke at low opacity with a
  /// flat-cap brush — the visual difference between a "marker" pen and
  /// a "highlighter" pen.
  final bool isHighlighter;
}
