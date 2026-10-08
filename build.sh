#!/bin/zsh
# Builds Bass EQ.
#
#   ./build.sh             BassEQ.app next to this script, signed with the stable local identity
#                          (run scripts/setup-signing.sh once; falls back to ad-hoc if it's missing).
#   ./build.sh --unsigned  dist/BassEQ.app + dist/BassEQ.zip with no certificate: a universal
#                          (Apple silicon + Intel) build with only the ad-hoc signature macOS
#                          requires to launch anything. Use this to share the app.
set -euo pipefail
cd "$(dirname "$0")"

UNSIGNED=false
[[ "${1:-}" == "--unsigned" ]] && UNSIGNED=true

NAME="BassEQ Local Signing"
KC="$HOME/Library/Keychains/basseq-signing.keychain-db"
PASSFILE="$HOME/.config/basseq/keychain-password"

if $UNSIGNED; then
  mkdir -p dist
  APP=dist/BassEQ.app
  ARCHS=(arm64 x86_64)
else
  APP=BassEQ.app
  ARCHS=("$(uname -m)")
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SLICES=()
for arch in $ARCHS; do
  out="$APP/Contents/MacOS/BassEQ-$arch"
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos14.4" \
    Sources/BassEQ.swift -o "$out"
  SLICES+=("$out")
done
lipo -create $SLICES -output "$APP/Contents/MacOS/BassEQ"
rm -f $SLICES

if $UNSIGNED; then
  # Apple silicon refuses to run code with no signature at all, so this is the minimum:
  # an ad-hoc signature, no certificate, no identity.
  codesign --force --sign - "$APP"
  rm -f dist/BassEQ.zip
  ditto -c -k --keepParent "$APP" dist/BassEQ.zip
  echo "Built $(pwd)/$APP (no certificate, $(lipo -archs "$APP/Contents/MacOS/BassEQ"))"
  echo "Zipped $(pwd)/dist/BassEQ.zip"
elif [[ -f "$KC" && -f "$PASSFILE" ]]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
  # Self-signed certs aren't "trusted", so codesign only finds them by SHA-1 hash, not by name.
  HASH=$(security find-identity -p codesigning "$KC" | grep -F "\"$NAME\"" | awk '{print $2; exit}')
  codesign --force --keychain "$KC" --sign "$HASH" "$APP"
  echo "Built $(pwd)/$APP"
else
  echo "warning: no stable signing identity, using ad-hoc (macOS will re-ask for audio permission)" >&2
  codesign --force --sign - "$APP"
  echo "Built $(pwd)/$APP"
fi
