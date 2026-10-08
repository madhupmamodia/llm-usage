#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LLMUsage"
APP_DIR="$APP_NAME.app"
INSTALL_DIR="/Applications"

# Parse flags
DO_INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install|-i) DO_INSTALL=true ;;
    --uninstall|-u)
      echo "Removing $INSTALL_DIR/$APP_NAME.app..."
      rm -rf "$INSTALL_DIR/$APP_NAME.app"
      echo "Done."
      exit 0
      ;;
    --help|-h)
      echo "Usage: $0 [--install] [--uninstall]"
      echo "  (no flag)   Build LLMUsage.app in this directory"
      echo "  --install   Build + move to /Applications + launch"
      echo "  --uninstall Remove from /Applications"
      exit 0
      ;;
  esac
done

# Prereq checks — give a clear error if something is missing.
if ! command -v swift >/dev/null 2>&1; then
  echo "❌ Swift not found. Install Command Line Tools:"
  echo "   xcode-select --install"
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "❌ codesign not found. Install Command Line Tools:"
  echo "   xcode-select --install"
  exit 1
fi

# Only check Xcode license if xcodebuild actually exists (full Xcode install).
# CommandLineTools-only setups don't have xcodebuild and don't need license acceptance.
if command -v xcodebuild >/dev/null 2>&1; then
  if ! xcodebuild -license check >/dev/null 2>&1; then
    echo "❌ Xcode license not accepted. Run:"
    echo "   sudo xcodebuild -license accept"
    exit 1
  fi
fi

echo "Building release..."
swift build -c release

echo "Wrapping in $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/llm-usage" "$APP_DIR/Contents/MacOS/llm-usage"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/llm-usage"

# Ad-hoc sign + strip xattrs so local builds don't hit Gatekeeper.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
xattr -cr "$APP_DIR"

echo "Built $APP_DIR"

if $DO_INSTALL; then
  echo "Installing to $INSTALL_DIR..."
  # Stop running instance if any.
  pkill -f "$APP_DIR/Contents/MacOS/llm-usage" 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALL_DIR/$APP_DIR"
  mv "$APP_DIR" "$INSTALL_DIR/$APP_DIR"
  open "$INSTALL_DIR/$APP_DIR"
  echo "Installed. Look for the icon in your menu bar."
else
  echo
  echo "Run:     open $APP_DIR"
  echo "Install: $0 --install"
fi