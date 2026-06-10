enum HotspotKind { note, link, image, audio }

/// An interactive region on a PDF page. On long-press (or tap, depending
/// on settings), the [payload] is revealed.
class Hotspot {
  const Hotspot({
    required this.id,
    required this.documentUuid,
    required this.pageNumber,
    required this.kind,
    required this.bounds,
    required this.payload,
    required this.createdAt,
  });

  final String id;
  final String documentUuid;
  final int pageNumber;
  final HotspotKind kind;
  final List<double> bounds; // [left, top, right, bottom] in PDF user units
  final HotspotPayload payload;
  final DateTime createdAt;
}

sealed class HotspotPayload {
  const HotspotPayload();
}

class NotePayload extends HotspotPayload {
  const NotePayload(this.text);
  final String text;
}

class LinkPayload extends HotspotPayload {
  const LinkPayload(this.url);
  final String url;
}

class ImagePayload extends HotspotPayload {
  const ImagePayload(this.imagePath);
  final String imagePath;
}

class AudioPayload extends HotspotPayload {
  const AudioPayload(this.audioPath);
  final String audioPath;
}
