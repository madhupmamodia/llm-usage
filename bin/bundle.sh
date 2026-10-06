#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LLMUsage"
APP_DIR="$APP_NAME.app"

echo "Building release..."
swift build -c release

echo "Wrapping in $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/llm-usage" "$APP_DIR/Contents/MacOS/llm-usage"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/llm-usage"

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
xattr -cr "$APP_DIR"

echo "Built $APP_DIR"
echo
echo "Run:     open $APP_DIR"
echo "Install: mv $APP_DIR /Applications/"