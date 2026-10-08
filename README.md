# Bass EQ

Menu-bar bass equalizer for the **SA-D40M2** Bluetooth speaker (macOS 14.4+, no audio driver needed).

## Build and run

```sh
./build.sh          # builds and ad-hoc signs BassEQ.app
open BassEQ.app     # speaker icon appears in the menu bar
./BassEQ.app/Contents/MacOS/BassEQ --selftest   # verifies filter math
```

On first launch macOS asks for **System Audio Recording** permission. Allow it, otherwise the EQ receives silence.
(System Settings > Privacy & Security > Screen & System Audio Recording.)

## Controls

- **Bass** -12 to +12 dB
- **Frequency** 40 to 250 Hz
- **Shape**: Shelf (lifts everything below the frequency) or Punch (peak around it, Q 1)
- **Low cut** 40 Hz high-pass so a small driver isn't asked to reproduce sub-bass it can't play
- Presets: Flat, Warm, Boost, Thump, Less boom
- Soft limiter above -1.4 dBFS so boosts don't hard-clip

## How it works

A global Core Audio process tap captures and mutes system audio (excluding this app), a private
aggregate device pairs it with the speaker, and an IOProc applies the biquad filters and plays the result
on the speaker. The EQ engages only while SA-D40M2 is the default output, and re-attaches automatically
when the speaker reconnects. Quit the app and audio returns to normal.

To target a different device: `defaults write com.manojachari.basseq targetName "Device Name"`.
