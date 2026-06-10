/// What we're asking the vision model to do with the supplied image.
///
/// The taxonomy is deliberately small — each task maps onto a tightly-
/// scoped system prompt that's been tuned for that one job. Adding a
/// new task means a new entry here AND a matching prompt in
/// `_systemPrompt(...)` inside [DeepSeekVisionClient].
enum VisionTask {
  /// Free-form caption / description of the image. "What is this?"
  describe,

  /// Pull every line of legible text out of the image, preserving line
  /// breaks. Strong on cursive / mixed-script / messy handwriting where
  /// ML Kit's local recogniser struggles.
  transcribeHandwriting,

  /// Like [transcribeHandwriting] but tuned for printed receipts /
  /// signage / business cards / books — emphasises faithful preservation
  /// of layout (columns, totals, fields).
  extractPrintedText,

  /// Open-ended Q&A — the user supplies a question and the model
  /// answers based on the image. "What's the dosage written here?",
  /// "Who's the recipient on this letter?".
  answerQuestion,
}

class VisionRequest {
  const VisionRequest({
    required this.imagePath,
    required this.task,
    this.targetLanguage,
    this.userQuestion,
    this.preserveLineBreaks = true,
  });

  /// Absolute path to a local image file (PNG / JPEG). The client
  /// base64-encodes this into the request payload.
  final String imagePath;

  final VisionTask task;

  /// BCP-47 language hint. For [VisionTask.transcribeHandwriting] this
  /// helps the model pick the right script when the writing is
  /// ambiguous (e.g. Urdu vs Arabic). Null = let the model auto-detect.
  final String? targetLanguage;

  /// Required for [VisionTask.answerQuestion]; ignored for the others.
  final String? userQuestion;

  /// Transcription tasks default to keeping line breaks. Set false to
  /// produce a single paragraph (handy for short receipts that you want
  /// to feed into translation).
  final bool preserveLineBreaks;
}
