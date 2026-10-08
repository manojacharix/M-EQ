#!/bin/zsh
# Builds BassEQ.app next to this script, signed with the stable local identity
# (run scripts/setup-signing.sh once; falls back to ad-hoc signing if it's missing).
set -euo pipefail
cd "$(dirname "$0")"
APP=BassEQ.app
NAME="BassEQ Local Signing"
KC="$HOME/Library/Keychains/basseq-signing.keychain-db"
PASSFILE="$HOME/.config/basseq/keychain-password"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.4" \
  Sources/BassEQ.swift -o "$APP/Contents/MacOS/BassEQ"
if [[ -f "$KC" && -f "$PASSFILE" ]]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
  # Self-signed certs aren't "trusted", so codesign only finds them by SHA-1 hash, not by name.
  HASH=$(security find-identity -p codesigning "$KC" | grep -F "\"$NAME\"" | awk '{print $2; exit}')
  codesign --force --keychain "$KC" --sign "$HASH" "$APP"
else
  echo "warning: no stable signing identity, using ad-hoc (macOS will re-ask for audio permission)" >&2
  codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"
