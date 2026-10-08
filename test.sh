#!/bin/zsh
# Plays a bass test file through the speaker. Usage: ./test.sh [loop|sweep|40|60|90|150|1000]
D="$(dirname "$0")/test-audio"
case "${1:-loop}" in
  loop)  f=bass_loop ;;
  sweep) f=sweep_30Hz-2kHz ;;
  *)     f="tone_${1}Hz" ;;
esac
echo "Playing $f.wav (Ctrl+C to stop)"; afplay "$D/$f.wav"
