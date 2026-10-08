# Bass EQ

A free, open-source menu-bar equalizer for Bluetooth speakers on macOS.

macOS has no built-in equalizer for system audio, and most Bluetooth speakers ship with a fixed sound.
Bass EQ sits in your menu bar and reshapes everything your Mac plays (music, YouTube, Spotify, games,
calls) before it reaches the speaker. It needs no audio driver, no virtual device and no account.

The feature set is inspired by the equalizers in popular headphone companion apps: a simple three-slider
mode, a 10-band graphic mode, a separate bass boost control and one-tap sound profiles.

**[⬇ Download BassEQ.dmg](https://github.com/manojacharix/BassEQ/releases/latest/download/BassEQ.dmg)** · then follow the [install steps](#download-and-install) below. macOS 14.4 or later.

---

## Download and install

### 1. Download
Download **[BassEQ.dmg](https://github.com/manojacharix/BassEQ/releases/latest/download/BassEQ.dmg)** from the
[latest release](https://github.com/manojacharix/BassEQ/releases/latest). It works on Apple silicon and Intel Macs
running **macOS 14.4 or later**.

### 2. Install
1. Double-click **BassEQ.dmg** to open it.
2. Drag **BassEQ** onto the **Applications** folder shortcut in the same window.
3. Eject the disk image (click ⏏ next to "Bass EQ" in Finder's sidebar). You can delete the DMG afterwards.

### 3. Open it the first time
Bass EQ is free and open source, but it isn't notarized by Apple (that needs a paid developer account), so
macOS blocks the first launch with a warning that Apple can't verify the app is free of malware.
Open it once like this, and after that it opens normally:

**macOS 15 Sequoia and later**
1. Open **Applications** and double-click **BassEQ**. When the warning appears, click **Done**.
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to *"BassEQ" was blocked to protect your Mac*, click **Open Anyway**, enter your password, then click **Open Anyway** again.

**macOS 14 Sonoma**
1. Open **Applications**, **right-click** (or Control-click) **BassEQ** and choose **Open**.
2. Click **Open** in the dialog.

**Or, from Terminal (any version):**
```sh
xattr -dr com.apple.quarantine /Applications/BassEQ.app
```

### 4. Allow audio access
macOS then asks: *"Bass EQ would like to record this computer's audio."* Click **Allow**.
The app needs this to equalize your sound. Nothing is recorded, saved or sent anywhere.

If you missed the prompt: **System Settings → Privacy & Security → Screen & System Audio Recording**,
turn on **Bass EQ**, then quit and reopen the app.

### 5. Use it
A slider icon appears in the menu bar. Click it, connect a Bluetooth speaker or headphones, and pick a
preset or move the sliders. To start Bass EQ automatically, add it in
**System Settings → General → Login Items**.

---

## Features

### Follows your speaker automatically
- Turns on by itself whenever a **Bluetooth speaker or headphones** becomes your Mac's sound output.
- **Remembers settings per device.** Your small desk speaker and your big party speaker each keep their own EQ.
- Steps aside for the MacBook speakers, displays and wired outputs (or switch on **"EQ every output"** to cover them too).
- Reconnects on its own when a speaker goes to sleep, runs out of battery or comes back into range.

### Two EQ modes
| Mode | Controls | Best for |
|---|---|---|
| **Simple** | **Lows** (below 150 Hz), **Mids** (around 1 kHz), **Highs** (above 5 kHz), each ±12 dB | Quick, broad changes: "more bass, less harsh" |
| **Advanced** | **10-band graphic EQ**: 31, 63, 125, 250, 500 Hz, 1, 2, 4, 8, 16 kHz, each ±12 dB | Fine-tuning a specific speaker or room |

### Bass Boost, separate from the EQ curve
- **Bass Boost** slider from -10 to +10 dB that stacks on top of whichever EQ mode you use.
- **Bass tuning** lets you pick where the boost sits (40 to 250 Hz) and its shape:
  - **Shelf**: lifts everything below the frequency, for a fuller, warmer sound.
  - **Punch**: boosts a band around the frequency, for kick-drum thump without muddiness.
- **Low cut below 40 Hz** (on by default) stops small speakers from wasting power on deep sub-bass they
  can't reproduce, which is what usually makes them rattle or distort when you boost bass.

### Sound profiles
One-tap presets, each with a 10-band curve and a matching Simple-mode setting:

| Preset | What it does |
|---|---|
| **Balanced** | Flat, the speaker's own sound |
| **More Bass** / **Bass Boost** | Gentle or strong low-end lift |
| **More Treble** / **Treble Boost** | Gentle or strong extra sparkle and detail |
| **Bright** | Clearer, more forward top end |
| **Excited** | V-shape: punchy lows and crisp highs, mids pulled back |
| **Mellow** | Warm and smooth, softened highs |
| **Relaxed** | Laid back, for long listening at low volume |
| **Vocal** | Brings singers and dialogue forward |
| **Speech** | Podcasts, calls and videos: strong voice focus, less rumble |
| **Loudness** | Lifts lows and highs, for listening quietly |

Save your own sound as a **custom preset** (★) with **+ Save**. Right-click a custom preset to delete it.

### Also in the panel
- **Live response curve** showing exactly what your settings do, from 20 Hz to 20 kHz.
- **Signal meter** so you can see audio is flowing through the EQ.
- **Output trim** (-12 to +6 dB) to make room for big boosts.
- **Built-in soft limiter**: heavy boosts get gently compressed instead of crackling.
- **On/off switch** for instant A/B comparison, and **Reset** to go back to flat.

---

## What to expect

**It works on all system audio.** Every app's sound goes through the EQ. You can't EQ one app and leave another alone.

**Your volume keys work as normal.** The EQ shapes the sound; the speaker's volume still follows the Mac's volume.

**Turning it off is instant and safe.** Flip the switch or quit and audio goes straight back to normal.
The audio tap belongs to the app's process, so if the app ever crashes macOS removes it and normal audio
returns.

**Boosting bass makes things louder.** A +8 dB boost really is louder in the low end. If a boosted speaker
starts to distort at high volume, lower **Output trim** by a few dB or turn **Low cut** on. The limiter
prevents digital clipping, but it can't stop a small speaker's driver from reaching its physical limit.

**A small speaker stays a small speaker.** EQ can rebalance what the speaker plays well, but it can't
make a 40 mm driver produce deep sub-bass. Moderate boosts (+3 to +6 dB) on Shelf or Punch at 70 to
120 Hz usually sound best on compact speakers.

**Using the mic switches Bluetooth to call quality.** When an app uses a Bluetooth speaker's microphone,
macOS switches it to a low-quality call mode (often 16 kHz). The EQ keeps working and adapts to the new
rate, but audio will sound thin until the call ends. That's Bluetooth, not the app.

**There is a small extra delay.** Audio passes through one extra buffered processing step, on top of
Bluetooth's own delay. It hasn't been measured yet; if lip sync in video ever feels off, flip the switch
off to compare.

**It's light.** On an Apple silicon MacBook Air it used about 4% CPU and 25 MB of memory while playing
audio. The EQ runs 15 filters per channel in native code with no allocations on the audio thread.

---

## Requirements

- **macOS 14.4 (Sonoma) or later.** Bass EQ uses Core Audio process taps, added in 14.4. It has been
  developed and tested on macOS 26 on Apple silicon.
- To build from source: **Xcode Command Line Tools** (`xcode-select --install`). Not needed for the DMG.

## Build from source

```sh
git clone https://github.com/manojacharix/BassEQ.git
cd BassEQ
./scripts/setup-signing.sh   # one time, see "Signing" below
./build.sh
open BassEQ.app
```

A slider icon appears in the menu bar. Click it to open the equalizer. Builds you make yourself
don't get the Gatekeeper warning (only downloaded copies do).

To keep it, move `BassEQ.app` into `/Applications`. To start it at login, add it in
**System Settings → General → Login Items**.

On first launch, allow audio access as described in [step 4](#4-allow-audio-access) above.

### Signing

`scripts/setup-signing.sh` creates a self-signed code-signing certificate ("BassEQ Local Signing") in
its own keychain, and `build.sh` signs every build with it. Because the signature stays the same,
macOS remembers your permission when you rebuild or update the app.

You can skip this step. `build.sh` then falls back to ad-hoc signing, and macOS will ask for permission
again after every rebuild.

### Build the DMG yourself

```sh
./build.sh --unsigned
```

This makes `dist/BassEQ.app` and `dist/BassEQ.dmg`: a universal build (Apple silicon and Intel) that
uses no certificate at all. It carries only an *ad-hoc* signature, because Apple silicon Macs refuse to
launch code with no signature whatsoever. It doesn't touch your normal `BassEQ.app`.

People who download it install it with the [Download and install](#download-and-install) steps above.

## Privacy

- Audio is processed in memory, in real time, and goes straight to your speaker. **Nothing is recorded,
  saved or sent anywhere.** The app makes no network connections.
- macOS calls this permission "recording" because the app has to read system audio to equalize it.
- The only things stored are your EQ settings (in the app's preferences) and a short status log at
  `~/Library/Logs/BassEQ.log`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Icon shows a crossed-out speaker | No Bluetooth output is selected, or the switch is off. The status line in the panel says which. |
| Signal meter stays empty while music plays | Allow Bass EQ under Privacy & Security → Screen & System Audio Recording, then relaunch. |
| No sound at all | Quit Bass EQ from its panel; audio returns to normal immediately. Then check `~/Library/Logs/BassEQ.log`. |
| Distortion when boosting | Lower **Output trim**, turn on **Low cut**, or use a smaller boost. |
| "Apple can't verify BassEQ is free of malware" | Expected for a downloaded copy; see [step 3](#3-open-it-the-first-time). |
| Panel freezes right after a rebuild | macOS is waiting on a permission prompt (only happens without stable signing). Answer it, and run `./scripts/setup-signing.sh`. |

Command-line helpers:
```sh
./BassEQ.app/Contents/MacOS/BassEQ --devices    # list outputs and which ones the EQ applies to
./BassEQ.app/Contents/MacOS/BassEQ --selftest   # check the filter math against test tones
./test.sh loop | sweep | 40 | 60 | 90 | 150 | 1000   # play test audio to hear the EQ
```

## How it works

1. A **Core Audio process tap** captures the mixed output of every app (except Bass EQ itself) and
   mutes the original, so you don't hear it twice.
2. A **private aggregate device** pairs that tap with your speaker. It's invisible to other apps and
   doesn't change your sound settings.
3. A real-time callback runs the audio through a fixed chain of 15 biquad filters (10 graphic bands,
   3 tone controls, bass boost, low cut), applies trim and a soft limiter, and writes the result to the speaker.

The filters use the standard RBJ *Audio EQ Cookbook* designs. `--selftest` plays sine waves through
the actual audio code and checks the measured gain against the expected curve.

The whole app is one Swift file: [`Sources/BassEQ.swift`](Sources/BassEQ.swift).

## Uninstall

```sh
rm -rf /Applications/BassEQ.app                       # or wherever you put it
defaults delete com.manojachari.basseq                # settings and presets
rm -f ~/Library/Logs/BassEQ.log
tccutil reset AudioCapture com.manojachari.basseq     # forget the permission (or remove it in
                                                      # Privacy & Security → Screen & System Audio Recording)
# If you ran setup-signing.sh:
security delete-keychain ~/Library/Keychains/basseq-signing.keychain-db
rm -rf ~/.config/basseq
```

## License

MIT, see [LICENSE](LICENSE).

Bass EQ is an independent project and isn't affiliated with any speaker or headphone maker.
