/// One candidate transcription returned by the recogniser. ML Kit ranks
/// these by score (higher = more confident); the UI shows the top one
/// prominently and offers the next 2-3 as tap-to-replace alternatives.
class HandwritingCandidate {
  const HandwritingCandidate({
    required this.text,
    required this.score,
  });

  final String text;

  /// Raw recogniser score. Treat as a relative confidence — higher is
  /// better, but the absolute scale isn't a probability and varies by
  /// language. Don't show this to the user as a percentage.
  final double score;
}

/// Full result for one [InkCapture] → text recognition request.
class HandwritingResult {
  const HandwritingResult({
    required this.candidates,
    required this.languageCode,
    required this.elapsedMs,
  });

  /// In ranked order — first is the best match. Empty if nothing
  /// recognisable was found (recogniser returned no candidates).
  final List<HandwritingCandidate> candidates;

  /// BCP-47 tag used by the recogniser (e.g. `en-US`, `ar`, `ur`).
  final String languageCode;

  /// Wall-clock time the recogniser took, useful for telemetry / UX
  /// progress hints ("usually takes ~200ms on this device").
  final int elapsedMs;

  bool get isEmpty => candidates.isEmpty;
  HandwritingCandidate? get best => candidates.isEmpty ? null : candidates.first;
  String get bestText => best?.text ?? '';
}
