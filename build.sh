#!/bin/zsh
# Builds BassEQ.app (ad-hoc signed) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP=BassEQ.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.4" \
  Sources/BassEQ.swift -o "$APP/Contents/MacOS/BassEQ"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
