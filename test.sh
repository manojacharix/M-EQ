#!/bin/zsh
# Plays test audio through the current output. Usage: ./test.sh [loop|sweep|40|60|90|150|1000]
cd "$(dirname "$0")"
[[ -f test-audio/bass_loop.wav ]] || python3 scripts/make-test-audio.py
case "${1:-loop}" in
  loop)  f=bass_loop ;;
  sweep) f=sweep_30Hz-2kHz ;;
  *)     f="tone_${1}Hz" ;;
esac
[[ -f "test-audio/$f.wav" ]] || { echo "Unknown test: $1 (use loop, sweep, 40, 60, 90, 150 or 1000)"; exit 1; }
echo "Playing $f.wav (Ctrl+C to stop)"; afplay "test-audio/$f.wav"
