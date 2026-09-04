# Sound Effect Provenance

**All audio in this folder is synthesised, not sourced.** No third-party or
licensed audio ships in this app.

| File | Event |
|---|---|
| `answer_correct.wav` | Correct trivia answer |
| `answer_wrong.wav` | Wrong trivia answer |
| `round_start.wav` | Round begins |
| `winner_reveal.wav` | Winner celebration on Results |
| `player_joined.wav` | A peer joins the lobby |
| `tap_registered.wav` | Reflex tap registered |
| `selection.wav` | Generic selection feedback |

## Why we can say that with confidence

Each file is a bare canonical 44-byte WAV header (PCM, mono, 44.1 kHz,
16-bit) followed immediately by the `data` chunk — no `LIST`/`INFO` chunk, no
encoder or software tag, no authoring metadata of any kind. Sample data begins
at exact digital silence and ramps on a smooth mathematical envelope. Recorded
or downloaded audio effectively always carries either metadata chunks or a
non-zero noise floor at the first sample; these have neither.

## Why this file exists

These were generated during the Phase 3 haptics/sound pass under an explicit
instruction: if genuinely royalty-free audio could not be obtained, synthesise
tones rather than commit anything of unclear licensing. The agent that
generated them was terminated by a spend limit before it could report its
sourcing, so provenance was re-established by inspecting the files themselves
and recorded here.

**Before App Store submission**, you must be able to account for the licence of
every shipped asset. These are safe. If you later replace them with designed
sound effects, update this file with the source and licence terms of whatever
takes their place.

## If you want better sound

These are functional placeholder tones, not sound design. A party game benefits
a lot from characterful audio. When replacing them, keep the same filenames and
they'll drop straight in — `SoundPlayer` looks them up by name.
