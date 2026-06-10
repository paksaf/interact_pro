/// Result of running [ImageIdentifierService.identify] on a single image.
///
/// Carries everything the UI needs to render at once: the labels the
/// model is most confident about, the OCR'd text (if any), and the
/// source path for re-display.
class ImageIdentifyResult {
  const ImageIdentifyResult({
    required this.imagePath,
    required this.labels,
    required this.extractedText,
    required this.processingMs,
    this.aiDescription,
    this.aiElapsedMs,
  });

  final String imagePath;

  /// Free-form description from the vision LLM, when the user asked for
  /// a "deep analysis". Null when the user only ran the on-device pass
  /// — keeps the response card backwards compatible.
  final String? aiDescription;

  /// Wall-clock time the vision LLM call took. Surfaced as a faint
  /// label so the user can see where the latency went.
  final int? aiElapsedMs;

  /// All labels returned by the on-device labeler, sorted by confidence
  /// (descending). The UI applies its own per-screen confidence filter
  /// over this list — we deliberately keep raw labels here so a user
  /// dragging the slider down can see noisier-but-real labels without
  /// re-running the model.
  ///
  /// Capped at 25 so the UI doesn't have to paginate.
  final List<IdentifierLabel> labels;

  /// Concatenated text from ML Kit's text recognizer. Empty if the
  /// image has no readable text.
  final String extractedText;

  /// Wall-clock time spent in the labeler + recognizer combined. Used
  /// for the "ran in 230 ms" badge on the result card.
  final int processingMs;

  /// Group [labels] by category, preserving sort order within each
  /// group. Empty categories are omitted. Used by the result card to
  /// render labels grouped by domain (People, Food, Vehicles, ...).
  Map<LabelCategory, List<IdentifierLabel>> labelsByCategory({
    double minConfidence = 0.0,
  }) {
    final out = <LabelCategory, List<IdentifierLabel>>{};
    for (final l in labels) {
      if (l.confidence < minConfidence) continue;
      out.putIfAbsent(l.category, () => []).add(l);
    }
    return out;
  }
}

class IdentifierLabel {
  const IdentifierLabel({
    required this.text,
    required this.confidence,
    required this.category,
  });

  final String text;

  /// 0.0 – 1.0 from ML Kit's `confidence` field.
  final double confidence;

  /// Domain group inferred from the label text (see [categorizeLabel]).
  final LabelCategory category;

  /// Confidence as a 0–100 integer percentage, rounded.
  int get percent => (confidence * 100).round();
}

/// High-level domain groups used to sort image labels into intuitive
/// buckets in the UI. Categorisation is heuristic — ML Kit's image
/// labeler returns ~400 labels from its built-in entity list, and we
/// map them to these groups via simple substring matches in
/// [categorizeLabel]. Order of cases in the enum is the display order.
enum LabelCategory {
  people('People'),
  food('Food'),
  vehicles('Vehicles'),
  animals('Animals'),
  plants('Plants & nature'),
  buildings('Buildings & architecture'),
  indoor('Indoor & furniture'),
  outdoor('Outdoor & landscape'),
  other('Other');

  const LabelCategory(this.displayName);

  final String displayName;
}

/// Map a raw ML Kit label string (e.g. "Plant", "Skyscraper", "Dog")
/// to one of [LabelCategory]. Match order matters: more specific
/// categories must come first because labels can match multiple groups
/// (e.g. "Fruit" matches both Food and Plants — we keep it in Food).
LabelCategory categorizeLabel(String label) {
  final s = label.toLowerCase();

  bool any(List<String> needles) {
    for (final n in needles) {
      if (s.contains(n)) return true;
    }
    return false;
  }

  // People — face features, clothing, body parts. Check before Food
  // because "lip" / "tooth" otherwise collides with snack-related labels.
  if (any([
    'person', 'people', 'face', 'smile', 'hair', 'beard', 'eye', 'lip',
    'tooth', 'head', 'glasses', 'eyewear', 'forehead', 'cheek', 'mouth',
    'nose', 'ear', 'skin', 'hand', 'finger', 'arm', 'leg', 'shoulder',
    'clothing', 'shirt', 'jacket', 'jeans', 'dress', 'shoe', 'boot',
    'hat', 'helmet', 'jewelry', 'necklace', 'ring', 'watch',
  ])) {
    return LabelCategory.people;
  }

  // Food & drink. Check before Plants so fruits/vegetables read as Food.
  if (any([
    'food', 'dish', 'cuisine', 'meal', 'bread', 'cake', 'cookie', 'pizza',
    'pasta', 'rice', 'noodle', 'soup', 'salad', 'meat', 'beef', 'chicken',
    'pork', 'fish', 'seafood', 'fruit', 'vegetable', 'tomato', 'apple',
    'banana', 'orange', 'lemon', 'cheese', 'butter', 'egg', 'milk',
    'coffee', 'tea', 'juice', 'wine', 'beer', 'cocktail', 'beverage',
    'drink', 'cup', 'mug', 'glass', 'bottle', 'plate', 'bowl', 'fork',
    'knife', 'spoon', 'kitchen utensil',
  ])) {
    return LabelCategory.food;
  }

  // Vehicles
  if (any([
    'vehicle', 'car', 'truck', 'bus', 'motorcycle', 'bicycle', 'bike',
    'scooter', 'plane', 'aircraft', 'helicopter', 'boat', 'ship', 'yacht',
    'train', 'tram', 'tire', 'wheel', 'tyre',
  ])) {
    return LabelCategory.vehicles;
  }

  // Animals
  if (any([
    'animal', 'mammal', 'dog', 'cat', 'bird', 'fish', 'reptile', 'insect',
    'butterfly', 'bee', 'spider', 'horse', 'cow', 'sheep', 'goat', 'pig',
    'rabbit', 'mouse', 'rat', 'lion', 'tiger', 'elephant', 'bear',
    'wildlife', 'pet', 'paw', 'feather', 'fur',
  ])) {
    return LabelCategory.animals;
  }

  // Plants & nature
  if (any([
    'plant', 'tree', 'flower', 'leaf', 'leaves', 'grass', 'garden',
    'forest', 'jungle', 'bush', 'shrub', 'cactus', 'palm', 'fern',
    'moss', 'vine', 'rose', 'tulip', 'sunflower', 'petal', 'branch',
    'trunk', 'root',
  ])) {
    return LabelCategory.plants;
  }

  // Buildings & architecture
  if (any([
    'building', 'house', 'home', 'skyscraper', 'tower', 'church', 'temple',
    'mosque', 'cathedral', 'castle', 'palace', 'mansion', 'cottage',
    'bridge', 'monument', 'architecture', 'facade', 'roof', 'door',
    'window', 'balcony', 'fence', 'gate', 'staircase', 'stairs',
  ])) {
    return LabelCategory.buildings;
  }

  // Indoor & furniture
  if (any([
    'room', 'bedroom', 'kitchen', 'bathroom', 'living', 'office', 'studio',
    'furniture', 'table', 'desk', 'chair', 'sofa', 'couch', 'bed',
    'cushion', 'pillow', 'blanket', 'lamp', 'light', 'shelf', 'bookcase',
    'cabinet', 'drawer', 'wardrobe', 'mirror', 'curtain', 'rug', 'carpet',
    'wall', 'ceiling', 'floor', 'tile',
  ])) {
    return LabelCategory.indoor;
  }

  // Outdoor & landscape
  if (any([
    'sky', 'cloud', 'sun', 'moon', 'star', 'horizon', 'sunset', 'sunrise',
    'mountain', 'hill', 'valley', 'cliff', 'rock', 'sand', 'desert',
    'beach', 'shore', 'sea', 'ocean', 'lake', 'river', 'stream', 'pond',
    'water', 'wave', 'snow', 'ice', 'glacier', 'rain', 'fog', 'mist',
    'road', 'street', 'highway', 'pathway', 'trail', 'park', 'meadow',
    'field', 'farm', 'crop',
  ])) {
    return LabelCategory.outdoor;
  }

  return LabelCategory.other;
}
