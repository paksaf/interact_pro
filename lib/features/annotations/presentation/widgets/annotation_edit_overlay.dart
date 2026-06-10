// SPDX-License-Identifier: AGPL-3.0
//
// AnnotationEditOverlay — sits on top of a rendered PDF page and:
//   1. PAINTS live in-progress strokes / shapes as the user drags.
//   2. CONVERTS the gesture into a ShapeAnnotation or InkAnnotation
//      and dispatches `onAnnotationAdded(annotation)` on pointer-up.
//   3. STAYS PASSIVE when AnnotationEditState.tool is `none` — pointer
//      events pass through to the underlying InteractiveViewer so the
//      reading experience is unchanged.
//
// Coordinate model:
//   • Strokes are recorded in normalised page-space (0..1 in both
//     axes) so they survive zoom + spread-mode changes.
//   • Bounds is the axis-aligned bbox of the gesture.
//
// This overlay does NOT persist annotations itself — the caller is
// expected to call AnnotationRepository.addAnnotation() inside the
// onAnnotationAdded callback. That keeps this widget free of
// PDF-document context (it doesn't know which file is open).

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/annotation.dart';
import '../annotation_edit_controller.dart';

class AnnotationEditOverlay extends ConsumerStatefulWidget {
  const AnnotationEditOverlay({
    required this.pageIndex,
    required this.pageSize,
    required this.existing,
    required this.onAnnotationAdded,
    super.key,
  });

  /// Which page in the document this overlay sits on. Recorded on the
  /// created Annotation so the caller can route it to the right PDF
  /// page when baking.
  final int pageIndex;

  /// Render size of the page image (in logical pixels). Used to map
  /// global pointer offsets to normalised 0..1 page-space.
  final Size pageSize;

  /// Already-persisted annotations on this page, painted underneath
  /// the live-drawing overlay so the user sees the cumulative result.
  final List<Annotation> existing;

  /// Fired when the user completes a stroke (pointer-up). Caller is
  /// expected to persist via AnnotationRepository.addAnnotation().
  final ValueChanged<Annotation> onAnnotationAdded;

  @override
  ConsumerState<AnnotationEditOverlay> createState() =>
      _AnnotationEditOverlayState();
}

class _AnnotationEditOverlayState extends ConsumerState<AnnotationEditOverlay> {
  /// Normalised points (0..1) of the in-progress stroke. Cleared on
  /// pointer-up after the annotation is dispatched.
  final List<Offset> _live = [];

  static const _uuid = Uuid();

  Offset _normalise(Offset local) {
    final w = widget.pageSize.width <= 0 ? 1.0 : widget.pageSize.width;
    final h = widget.pageSize.height <= 0 ? 1.0 : widget.pageSize.height;
    return Offset(
      (local.dx / w).clamp(0.0, 1.0),
      (local.dy / h).clamp(0.0, 1.0),
    );
  }

  Rect _bboxOf(List<Offset> pts) {
    if (pts.isEmpty) return Rect.zero;
    var minX = pts.first.dx, maxX = pts.first.dx;
    var minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Convert the in-progress stroke into a domain Annotation, using
  /// the active tool. Returns null when the gesture is too small to
  /// be meaningful (one-tap with no drag — avoid creating zero-area
  /// shapes the user would have to delete).
  Annotation? _toAnnotation(AnnotationEditState s) {
    if (_live.length < 2) return null;
    final bboxNorm = _bboxOf(_live);
    if (bboxNorm.width < 0.005 && bboxNorm.height < 0.005) return null;
    // ShapeAnnotation.bounds is in page-space coordinates (i.e. the
    // PDF page's userUnit grid the Syncfusion bake uses) — but we
    // hand it the normalised rect scaled into the actual page size
    // dimensions our painter sees. The repository scales again from
    // there. Both translations are passthrough multiplies; nothing
    // is lost as long as we're consistent.
    final bbox = Rect.fromLTRB(
      bboxNorm.left * widget.pageSize.width,
      bboxNorm.top * widget.pageSize.height,
      bboxNorm.right * widget.pageSize.width,
      bboxNorm.bottom * widget.pageSize.height,
    );
    final now = DateTime.now();
    final id = _uuid.v4();
    final stroke = s.stroke.width;

    switch (s.tool) {
      case AnnotationTool.highlighter:
        return InkAnnotation(
          id: id,
          pageIndex: widget.pageIndex,
          bounds: bbox,
          createdAt: now,
          points: List.unmodifiable(_live),
          color: s.color,
          strokeWidth: stroke,
          isHighlighter: true,
        );
      case AnnotationTool.pen:
        return InkAnnotation(
          id: id,
          pageIndex: widget.pageIndex,
          bounds: bbox,
          createdAt: now,
          points: List.unmodifiable(_live),
          color: s.color,
          strokeWidth: stroke,
        );
      case AnnotationTool.circle:
        return ShapeAnnotation(
          id: id,
          pageIndex: widget.pageIndex,
          bounds: bbox,
          createdAt: now,
          kind: ShapeKind.circle,
          strokeColor: s.color,
          strokeWidth: stroke,
        );
      case AnnotationTool.rectangle:
        return ShapeAnnotation(
          id: id,
          pageIndex: widget.pageIndex,
          bounds: bbox,
          createdAt: now,
          kind: ShapeKind.rectangle,
          strokeColor: s.color,
          strokeWidth: stroke,
        );
      case AnnotationTool.arrow:
        return ShapeAnnotation(
          id: id,
          pageIndex: widget.pageIndex,
          bounds: bbox,
          createdAt: now,
          kind: ShapeKind.arrow,
          strokeColor: s.color,
          strokeWidth: stroke,
        );
      case AnnotationTool.text:
      case AnnotationTool.eraser:
      case AnnotationTool.none:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(annotationEditControllerProvider);
    final active = s.isEditing &&
        s.tool != AnnotationTool.eraser &&
        s.tool != AnnotationTool.text;
    return Listener(
      // IgnorePointer when not active so the parent InteractiveViewer
      // keeps receiving pinch/pan events for reading.
      behavior:
          active ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
      onPointerDown: active
          ? (e) {
              setState(() {
                _live
                  ..clear()
                  ..add(_normalise(e.localPosition));
              });
            }
          : null,
      onPointerMove: active
          ? (e) {
              setState(() => _live.add(_normalise(e.localPosition)));
            }
          : null,
      onPointerUp: active
          ? (_) {
              final anno = _toAnnotation(s);
              if (anno != null) widget.onAnnotationAdded(anno);
              setState(_live.clear);
            }
          : null,
      onPointerCancel: active ? (_) => setState(_live.clear) : null,
      child: CustomPaint(
        size: widget.pageSize,
        painter: _AnnotationPainter(
          existing: widget.existing,
          live: _live,
          pageSize: widget.pageSize,
          tool: s.tool,
          color: s.color,
          strokeWidth: s.stroke.width,
        ),
        child: SizedBox.fromSize(size: widget.pageSize),
      ),
    );
  }
}

/// Paints both committed annotations (from widget.existing) and the
/// in-progress live stroke. Single painter for both avoids two stacked
/// CustomPaints fighting for the same rect.
class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter({
    required this.existing,
    required this.live,
    required this.pageSize,
    required this.tool,
    required this.color,
    required this.strokeWidth,
  });

  final List<Annotation> existing;
  final List<Offset> live;
  final Size pageSize;
  final AnnotationTool tool;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // ── Committed annotations first ───────────────────────────────
    for (final a in existing) {
      switch (a) {
        case HighlightAnnotation():
          final paint = Paint()..color = a.color.withValues(alpha: 0.35);
          canvas.drawRect(a.bounds, paint);
        case RedactAnnotation():
          canvas.drawRect(a.bounds, Paint()..color = a.fillColor);
        case NoteAnnotation():
          // Just a marker icon hint — the actual popup is rendered by
          // a different widget. Yellow square at the top-left of bounds.
          canvas.drawRect(
            Rect.fromLTWH(a.bounds.left, a.bounds.top, 14, 14),
            Paint()..color = const Color(0xFFFCD34D),
          );
        case ShapeAnnotation():
          _paintShape(canvas, a);
        case InkAnnotation():
          _paintInk(canvas, a);
      }
    }

    // ── In-progress live stroke ───────────────────────────────────
    if (live.isEmpty) return;
    final pts = live
        .map((p) => Offset(p.dx * size.width, p.dy * size.height))
        .toList();
    final livePaint = Paint()
      ..color = tool == AnnotationTool.highlighter
          ? color.withValues(alpha: 0.35)
          : color
      ..strokeWidth = tool == AnnotationTool.highlighter
          ? strokeWidth * 4
          : strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (tool) {
      case AnnotationTool.highlighter:
      case AnnotationTool.pen:
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        canvas.drawPath(path, livePaint);
      case AnnotationTool.circle:
        final r = _bbox(pts);
        canvas.drawOval(r, livePaint);
      case AnnotationTool.rectangle:
        canvas.drawRect(_bbox(pts), livePaint);
      case AnnotationTool.arrow:
        if (pts.length >= 2) {
          final r = _bbox(pts);
          canvas.drawLine(r.topLeft, r.bottomRight, livePaint);
          _paintArrowHead(
            canvas,
            r.topLeft,
            r.bottomRight,
            livePaint,
          );
        }
      case AnnotationTool.eraser:
      case AnnotationTool.text:
      case AnnotationTool.none:
        // No live preview for these tools.
        break;
    }
  }

  void _paintShape(Canvas canvas, ShapeAnnotation a) {
    final paint = Paint()
      ..color = a.strokeColor
      ..strokeWidth = a.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fill = a.fillColor;
    final fillPaint = fill == null
        ? null
        : (Paint()
          ..color = fill
          ..style = PaintingStyle.fill);
    switch (a.kind) {
      case ShapeKind.circle:
      case ShapeKind.ellipse:
        if (fillPaint != null) canvas.drawOval(a.bounds, fillPaint);
        canvas.drawOval(a.bounds, paint);
      case ShapeKind.rectangle:
        if (fillPaint != null) canvas.drawRect(a.bounds, fillPaint);
        canvas.drawRect(a.bounds, paint);
      case ShapeKind.arrow:
        canvas.drawLine(a.bounds.topLeft, a.bounds.bottomRight, paint);
        _paintArrowHead(
          canvas,
          a.bounds.topLeft,
          a.bounds.bottomRight,
          paint,
        );
    }
  }

  void _paintInk(Canvas canvas, InkAnnotation a) {
    if (a.points.length < 2) return;
    final r = a.bounds;
    final paint = Paint()
      ..color = a.isHighlighter
          ? a.color.withValues(alpha: 0.35)
          : a.color
      ..strokeWidth = a.isHighlighter ? a.strokeWidth * 4 : a.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    final first = a.points.first;
    path.moveTo(
      r.left + first.dx * r.width,
      r.top + first.dy * r.height,
    );
    for (var i = 1; i < a.points.length; i++) {
      final p = a.points[i];
      path.lineTo(
        r.left + p.dx * r.width,
        r.top + p.dy * r.height,
      );
    }
    canvas.drawPath(path, paint);
  }

  void _paintArrowHead(Canvas canvas, Offset from, Offset to, Paint p) {
    final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
    final headLen = (p.strokeWidth + 2) * 3.5;
    final a1 = angle + math.pi - 0.5;
    final a2 = angle + math.pi + 0.5;
    final h1 = Offset(
      to.dx + math.cos(a1) * headLen,
      to.dy + math.sin(a1) * headLen,
    );
    final h2 = Offset(
      to.dx + math.cos(a2) * headLen,
      to.dy + math.sin(a2) * headLen,
    );
    final tri = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(h1.dx, h1.dy)
      ..lineTo(h2.dx, h2.dy)
      ..close();
    final fillPaint = Paint()
      ..color = p.color
      ..style = PaintingStyle.fill;
    canvas.drawPath(tri, fillPaint);
  }

  Rect _bbox(List<Offset> pts) {
    var minX = pts.first.dx, maxX = pts.first.dx;
    var minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) =>
      old.live != live ||
      old.existing != existing ||
      old.tool != tool ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
