/// Which engine handles the transcription.
///
/// Two tiers, deliberately exposed in the UI rather than auto-picked —
/// the user has direct context on whether their handwriting is "messy
/// cursive" or "neat block letters" and can pick accordingly. The
/// trade-offs:
///
///   • [TranscribeEngine.onDevice] — ML Kit text recognition. Runs
///     locally with the bundled model, no network, no API cost. Strong
///     on PRINTED text and clear block handwriting; weak on cursive
///     and on languages the model wasn't pre-trained for.
///
///   • [TranscribeEngine.cloud] — DeepSeek vision LLM. Reads cursive,
///     mixed-script (English notes interleaved with Urdu, etc.), and
///     handles many languages well. Costs API tokens and needs network.
enum TranscribeEngine {
  onDevice,
  cloud,
}
