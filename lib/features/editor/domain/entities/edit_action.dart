import 'dart:ui';

/// Command pattern: every editor mutation is an `EditAction`. The undo/redo
/// stack stores these so we can replay or invert them. PRD EDIT-07 calls
/// for at least 50 steps — see `AppConstants.undoRedoStackSize`.
sealed class EditAction {
  const EditAction({required this.pageIndex, required this.timestamp});
  final int pageIndex;
  final DateTime timestamp;
}

class InsertText extends EditAction {
  const InsertText({
    required super.pageIndex,
    required super.timestamp,
    required this.text,
    required this.position,
    required this.fontSize,
    required this.color,
    required this.fontFamily,
  });
  final String text;
  final Offset position;
  final double fontSize;
  final Color color;
  final String fontFamily;
}

class EditExistingText extends EditAction {
  const EditExistingText({
    required super.pageIndex,
    required super.timestamp,
    required this.blockId,
    required this.previousText,
    required this.newText,
  });
  final String blockId;
  final String previousText;
  final String newText;
}

class MoveImage extends EditAction {
  const MoveImage({
    required super.pageIndex,
    required super.timestamp,
    required this.imageId,
    required this.from,
    required this.to,
  });
  final String imageId;
  final Rect from;
  final Rect to;
}

class InsertImage extends EditAction {
  const InsertImage({
    required super.pageIndex,
    required super.timestamp,
    required this.sourcePath,
    required this.position,
  });
  final String sourcePath;
  final Rect position;
}

class DeletePage extends EditAction {
  const DeletePage({required super.pageIndex, required super.timestamp});
}

class RotatePage extends EditAction {
  const RotatePage({
    required super.pageIndex,
    required super.timestamp,
    required this.degrees,
    this.previousRotation,
  });

  /// Delta in degrees to apply (90 / 180 / 270 / -90 / -180 / -270).
  final int degrees;

  /// Page rotation *before* this action, in degrees (0 / 90 / 180 / 270).
  /// Captured by the UI when the user taps Rotate so undo can restore the
  /// exact pre-state without trusting Syncfusion's `page.rotation` getter,
  /// which has been observed to return stale values across save/reopen.
  /// Null only on actions emitted by code that pre-dates this field.
  final int? previousRotation;
}
