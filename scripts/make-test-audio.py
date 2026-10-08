#!/usr/bin/env python3
"""Generates the test WAVs used by test.sh (standard library only)."""
import math, struct, sys, wave
from pathlib import Path

FS = 44100
out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "test-audio")
out.mkdir(parents=True, exist_ok=True)

def write(name, gen, secs):
    frames = bytearray()
    for i in range(int(FS * secs)):
        v = int(max(-1, min(1, gen(i / FS))) * 32767 * 0.5)
        frames += struct.pack("<hh", v, v)
    with wave.open(str(out / f"{name}.wav"), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(FS); w.writeframes(bytes(frames))

def fade(t, total):
    return min(1, t * 20, (total - t) * 20)

for f in (40, 60, 90, 150, 1000):
    write(f"tone_{f}Hz", lambda t, f=f: math.sin(2 * math.pi * f * t) * fade(t, 4), 4)

def sweep(t, f0=30, f1=2000, T=10):
    k = math.log(f1 / f0) / T
    return math.sin(2 * math.pi * f0 * (math.exp(k * t) - 1) / k) * fade(t, T)
write("sweep_30Hz-2kHz", sweep, 10)

def loop(t):
    beat = t % 0.5
    kick = math.sin(2 * math.pi * (50 + 120 * math.exp(-beat * 30)) * beat) * math.exp(-beat * 8)
    note = [55, 55, 73.4, 65.4][int(t / 2) % 4]
    bass = 0.5 * math.sin(2 * math.pi * note * t) * (0.6 + 0.4 * math.exp(-(t % 0.25) * 6))
    hat = 0.05 * math.sin(2 * math.pi * 7000 * t) * math.exp(-((t + 0.25) % 0.5) * 60)
    return 0.8 * kick + bass + hat
write("bass_loop", loop, 8)
print(f"Wrote test audio to {out}")
