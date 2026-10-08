# Bass EQ

Menu-bar equalizer for Bluetooth speakers (macOS 14.4+, no audio driver needed). Feature set modelled on
Sony Headphones Connect and Nothing X.

## Build and run

```sh
./build.sh          # builds and ad-hoc signs BassEQ.app
open BassEQ.app     # slider icon appears in the menu bar
./BassEQ.app/Contents/MacOS/BassEQ --selftest   # verifies filter math against sine tones
./BassEQ.app/Contents/MacOS/BassEQ --devices    # lists outputs, marks the Bluetooth ones
./test.sh loop|sweep|40|60|90|150|1000          # plays bass test audio
```

macOS asks for **System Audio Recording** permission on first launch. Allow it, otherwise the EQ receives silence.

Signing: run `./scripts/setup-signing.sh` once on a new Mac. It creates a self-signed "BassEQ Local Signing"
identity in its own keychain (`~/Library/Keychains/basseq-signing.keychain-db`, password in
`~/.config/basseq/`), so every build has the same signature and macOS keeps the permission. Without it,
`build.sh` falls back to ad-hoc signing and macOS re-asks after each rebuild.
Status is logged to `~/Library/Logs/BassEQ.log`.

## Features

- **Follows your speaker**: engages whenever the current output is a Bluetooth device (optionally any
  output) and remembers separate settings per device.
- **Simple mode** (Nothing style): Lows (150 Hz shelf), Mids (1 kHz), Highs (5 kHz shelf), +/-12 dB.
- **Advanced mode** (Sony style): 10-band graphic EQ, 31 Hz to 16 kHz, +/-12 dB.
- **Bass Boost** (like Clear Bass / Bass Enhance): independent of the curve, -10 to +10 dB, with
  frequency (40 to 250 Hz), Shelf/Punch shape and a 40 Hz low cut that protects small drivers.
- **Presets**: Balanced, More Bass, Bass Boost, More Treble, Treble Boost, Bright, Excited, Mellow,
  Relaxed, Vocal, Speech, Loudness, plus your own saved custom presets (right-click to delete).
- Live response curve, signal meter, output trim and a soft limiter so boosts don't hard-clip.

## How it works

A global Core Audio process tap captures and mutes system audio (excluding this app), a private
aggregate device pairs it with the speaker, and an IOProc runs a fixed chain of 15 biquad filters and
plays the result on the speaker. Quit the app and audio returns to normal.
