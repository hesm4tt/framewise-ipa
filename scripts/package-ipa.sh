#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
OUTPUT_IPA="${1:-$BUILD_DIR/Framewise.ipa}"

# Prefer an installed full Xcode when the system currently points at only CLT.
if [[ -z "${DEVELOPER_DIR:-}" ]] && xcode-select -p 2>/dev/null | grep -q '/CommandLineTools$'; then
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi

xcodebuild \
	-quiet \
	-project "$ROOT/Framewise.xcodeproj" \
	-scheme Framewise \
	-configuration Release \
	-sdk iphoneos \
	-destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/Framewise.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded but the app bundle was not found at: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_IPA")"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/framewise-ipa.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_DIR/Payload"
ditto "$APP_PATH" "$STAGE_DIR/Payload/Framewise.app"
ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/Payload" "$OUTPUT_IPA"
echo "Created $OUTPUT_IPA"
