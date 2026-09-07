#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export MACOSX_DEPLOYMENT_TARGET=13.0

rm -rf dist
mkdir -p dist/Luma.app/Contents/MacOS

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

cp "$BIN_DIR/Luma" dist/Luma.app/Contents/MacOS/Luma
cp packaging/Info.plist dist/Luma.app/Contents/Info.plist

chmod +x dist/Luma.app/Contents/MacOS/Luma

# CI releases are intentionally ad-hoc signed. This makes the app bundle
# self-consistent without requiring a Developer ID certificate in GitHub Secrets.
codesign --force --sign - --timestamp=none dist/Luma.app

plutil -lint dist/Luma.app/Contents/Info.plist
codesign --verify --deep --strict dist/Luma.app
file dist/Luma.app/Contents/MacOS/Luma

ditto -c -k --sequesterRsrc --keepParent dist/Luma.app dist/Luma-macOS-arm64.zip

echo "Built: $ROOT/dist/Luma.app"
echo "Archive: $ROOT/dist/Luma-macOS-arm64.zip"
