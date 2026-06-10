/// Result of one vision-LLM call. Generic over task — for
/// transcription, [text] is the recognised text; for description,
/// [text] is the caption; for Q&A, [text] is the answer.
class VisionResult {
  const VisionResult({
    required this.text,
    required this.elapsedMs,
    this.detectedLanguage,
    this.tokensUsed,
    this.modelName,
  });

  final String text;
  final int elapsedMs;

  /// BCP-47 tag the model thought it saw. Null when the API doesn't
  /// surface it (DeepSeek's chat-completions doesn't currently expose
  /// language detection metadata).
  final String? detectedLanguage;

  /// Total tokens billed. Surfaced in the UI as a faint cost hint when
  /// available so users on metered API keys can keep an eye on usage.
  final int? tokensUsed;

  /// Which model the response came from. Useful in logs to disambiguate
  /// quality drops after a server-side model rev.
  final String? modelName;

  bool get isEmpty => text.trim().isEmpty;
}
