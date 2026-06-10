import 'dart:ui' show Color, Rect;

/// PRD STAMP-01..05.
enum StampKind {
  /// STAMP-01: predefined like APPROVED, REJECTED, DRAFT, CONFIDENTIAL.
  predefined,
  /// STAMP-02: user-typed text stamp.
  customText,
  /// STAMP-03: dynamic — placeholders resolved at place time.
  dynamic_,
  /// STAMP-04: imported PNG / JPG.
  image,
}

/// PRD STAMP-03: dynamic placeholders we substitute at apply time.
enum DynamicStampField {
  date,
  time,
  dateTime,
  user,
  pageNumber,
  documentName,
}

class Stamp {
  const Stamp({
    required this.id,
    required this.kind,
    required this.text,
    required this.dynamicFields,
    required this.color,
    required this.opacity,
    this.imagePath,
    this.fontFamily = 'Roboto',
  });

  /// Convenience constructor for predefined stamps.
  const Stamp.predefined({
    required this.id,
    required this.text,
    this.color = const Color(0xFFCC0000),
    this.opacity = 1.0,
    this.fontFamily = 'Roboto',
  })  : kind = StampKind.predefined,
        dynamicFields = const <DynamicStampField>[],
        imagePath = null;

  final String id;
  final StampKind kind;
  final String text;
  final List<DynamicStampField> dynamicFields;
  final Color color;

  /// PRD STAMP-05: between 0.2 and 1.0.
  final double opacity;
  final String? imagePath;
  final String fontFamily;
}

/// PRD STAMP-01: catalogue of predefined stamps.
class PredefinedStamps {
  PredefinedStamps._();

  static final List<Stamp> all = <Stamp>[
    const Stamp.predefined(id: 'approved', text: 'APPROVED', color: Color(0xFF1B5E20)),
    const Stamp.predefined(id: 'rejected', text: 'REJECTED', color: Color(0xFFB71C1C)),
    const Stamp.predefined(id: 'draft', text: 'DRAFT', color: Color(0xFF424242)),
    const Stamp.predefined(id: 'confidential', text: 'CONFIDENTIAL', color: Color(0xFFB71C1C)),
    const Stamp.predefined(id: 'pending', text: 'PENDING', color: Color(0xFFE65100)),
    const Stamp.predefined(id: 'signed', text: 'SIGNED', color: Color(0xFF1B5E20)),
    const Stamp.predefined(id: 'paid', text: 'PAID', color: Color(0xFF1B5E20)),
    const Stamp.predefined(id: 'urgent', text: 'URGENT', color: Color(0xFFB71C1C)),
  ];
}

class PlacedStamp {
  const PlacedStamp({
    required this.id,
    required this.stamp,
    required this.pageIndex,
    required this.bounds,
    required this.placedAt,
  });
  final String id;
  final Stamp stamp;
  final int pageIndex;
  final Rect bounds;
  final DateTime placedAt;
}
