# Page-flip SFX

`page_flip.wav` — short paper-flip sound effect, generated 2026-05-20
via the scipy noise+decaying-tone recipe below. ~44 KB, 0.5 s,
16-bit mono 44.1 kHz PCM.

The BookViewer plays this on every page turn (#252) at 0.45 volume in
lowLatency mode. If the file is absent the `_playFlipSfx()` catch in
`book_viewer_screen.dart` silently swallows — navigation never depends
on audio.

## Regenerating

```python
import numpy as np
from scipy.io.wavfile import write

sample_rate = 44100
duration = 0.5
t = np.linspace(0, duration, int(sample_rate * duration), False)
noise = np.random.uniform(-0.1, 0.1, len(t))
tone = 0.3 * np.sin(2 * np.pi * 800 * t) * np.exp(-t * 10)
flip = noise + tone
flip = np.int16(flip / np.max(np.abs(flip)) * 32767)
write('page_flip.wav', sample_rate, flip)
```

## Why WAV instead of MP3

audioplayers handles both. WAV decodes faster on cold-start (no codec
init), and for a ~150 ms effect played 5+ times a minute the size
penalty is negligible. The scipy script also outputs WAV natively, so
no ffmpeg / pydub re-encode step is needed.

## Replacing with a higher-quality clip

Drop a `page_flip.wav` in this directory and the BookViewer picks it
up on next build. CC0 sources: freesound.org · pixabay.com sound
effects · zapsplat.
