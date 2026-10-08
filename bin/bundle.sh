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

# Only check Xcode license if running a real Xcode install.
# CLT-only setups have an xcodebuild shim that errors with "requires Xcode" — skip them.
if xcode-select -p 2>/dev/null | grep -qv "CommandLineTools"; then
  if command -v xcodebuild >/dev/null 2>&1; then
    if ! xcodebuild -license check >/dev/null 2>&1; then
      echo "❌ Xcode license not accepted. Run:"
      echo "   sudo xcodebuild -license accept"
      exit 1
    fi
  fi
fi

echo "Building release..."

# Workaround for Swift 6.3.3 CLT bug: libPackageDescription.dylib exports
# SwiftLanguageMode symbol but the 5.9 manifest interface still uses the
# deprecated SwiftVersion typealias, causing a linker mismatch.
# Tried first; if your toolchain doesn't have the bug, plain build wins.
# (Reported by @Renju Jose, Oct 2026.)
MANIFEST_ALIAS_FLAGS=(
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc -alias
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc '_$s18PackageDescription0A0C4name19defaultLocalization9platforms9pkgConfig9providers8products12dependencies7targets21swiftLanguageVersions01cN8Standard03cxxnP0ACSS_AA0N3TagVSgSayAA17SupportedPlatformVGSgSSSgSayAA06SystemA8ProviderOGSgSayAA7ProductCGSayAC10DependencyCGSayAA6TargetCGSayAA05SwiftN4ModeOGSgAA09CLanguageP0OSgAA011CXXLanguageP0OSgtcfC'
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc '_$s18PackageDescription0A0C4name19defaultLocalization9platforms9pkgConfig9providers8products12dependencies7targets21swiftLanguageVersions01cN8Standard03cxxnP0ACSS_AA0N3TagVSgSayAA17SupportedPlatformVGSgSSSgSayAA06SystemA8ProviderOGSgSayAA7ProductCGSayAC10DependencyCGSayAA6TargetCGSayAA12SwiftVersionOGSgAA09CLanguageP0OSgAA011CXXLanguageP0OSgtcfC'
)

if swift build -c release; then
  echo "Built with plain swift build."
elif swift build -c release "${MANIFEST_ALIAS_FLAGS[@]}"; then
  echo "Built with manifest alias workaround (Swift 6.3.3 CLT bug)."
else
  # Last resort: compile sources directly with swiftc, bypassing SPM.
  echo "SwiftPM build failed; falling back to direct swiftc..."
  mkdir -p .build/release
  swiftc -O -target arm64-apple-macosx14.0 -parse-as-library \
    Sources/llm-usage/*.swift -o .build/release/llm-usage
fi

echo "Wrapping in $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/llm-usage" "$APP_DIR/Contents/MacOS/llm-usage"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "bin/sync-models" ]]; then
  cp "bin/sync-models" "$APP_DIR/Contents/Resources/sync-models"
  chmod +x "$APP_DIR/Contents/Resources/sync-models"
fi
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