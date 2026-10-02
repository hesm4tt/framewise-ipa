#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="hesm4tt/framewise-ipa"
FEED="$ROOT/distribution/framewise.json"
DIST_README="$ROOT/distribution/README.md"
IPA="$ROOT/build/Framewise.ipa"
APP="$ROOT/build/DerivedData/Build/Products/Release-iphoneos/Framewise.app"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required to publish the SideStore feed." >&2
  exit 1
fi
gh auth status >/dev/null

"$ROOT/scripts/package-ipa.sh" "$IPA"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
TAG="v$VERSION"
SIZE="$(stat -f %z "$IPA")"

python3 - "$FEED" "$VERSION" "$SIZE" <<'PY'
import json
import sys
from datetime import date
from pathlib import Path

path = Path(sys.argv[1])
version, size = sys.argv[2], int(sys.argv[3])
feed = json.loads(path.read_text())
app = feed["apps"][0]
feed["sourceURL"] = "https://github.com/hesm4tt/framewise-ipa/releases/latest/download/framewise.json"
app["bundleIdentifier"] = "com.framewise.camera"
app["localizedDescription"] = "On-device subject tracking, movement cues, optical zoom stops matched to the iPhone camera system, and optional RAW capture."
app["permissions"] = [p for p in app.get("permissions", []) if p.get("type") != "photos"]
versions = app.setdefault("versions", [])
versions[:] = [entry for entry in versions if entry.get("version") != version]
versions.insert(0, {
    "version": version,
    "date": date.today().isoformat(),
    "downloadURL": f"https://github.com/hesm4tt/framewise-ipa/releases/download/v{version}/Framewise.ipa",
    "size": size,
    "minOSVersion": "15.0",
    "localizedDescription": "On-device subject tracking, movement cues, smooth suggested zoom, device-matched optical stops, and optional RAW capture."
})
path.write_text(json.dumps(feed, indent=2, ensure_ascii=False) + "\n")
PY

if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  gh release upload "$TAG" "$IPA" "$FEED" --repo "$REPOSITORY" --clobber
else
  gh release create "$TAG" "$IPA" "$FEED" \
    --repo "$REPOSITORY" \
    --title "Framewise $VERSION" \
    --notes "Adapts optical and optical-quality zoom stops to the iPhone's rear cameras and sensor resolution. Adds optional ProRAW/Bayer RAW + processed capture at the largest available photo dimensions, and preserves the original processed image. On-device AI with no per-use service cost. Build $BUILD."
fi

publish_repository_file() {
  local local_path="$1"
  local remote_path="$2"
  local commit_message="$3"
  local file_sha
  file_sha="$(gh api "repos/$REPOSITORY/contents/$remote_path" --jq .sha)"
  python3 - "$local_path" "$file_sha" "$commit_message" <<'PY' | gh api --method PUT "repos/$REPOSITORY/contents/$remote_path" --input - --jq '.commit | {sha, html_url}'
import base64
import json
import sys
from pathlib import Path

content = base64.b64encode(Path(sys.argv[1]).read_bytes()).decode("ascii")
print(json.dumps({
    "message": sys.argv[3],
    "content": content,
    "sha": sys.argv[2],
    "branch": "main"
}))
PY
}

publish_repository_file "$FEED" "framewise.json" "Publish Framewise SideStore feed update"
publish_repository_file "$DIST_README" "README.md" "Update Framewise install instructions"

PUBLISHED_FEED="$ROOT/build/framewise-published-feed.json"
curl --location --fail --silent --show-error \
  --header 'Cache-Control: no-cache' \
  --header 'Pragma: no-cache' \
  "https://raw.githubusercontent.com/$REPOSITORY/main/framewise.json" \
  --output "$PUBLISHED_FEED"
python3 - "$PUBLISHED_FEED" "$VERSION" "$SIZE" <<'PY'
import json
import sys
from pathlib import Path

feed = json.loads(Path(sys.argv[1]).read_text())
app = feed["apps"][0]
latest = app["versions"][0]
if latest["version"] != sys.argv[2] or latest["size"] != int(sys.argv[3]):
    raise SystemExit("Published SideStore feed does not match the latest IPA.")
if app["bundleIdentifier"] != "com.framewise.camera" or feed["identifier"] != "com.framewise.source":
    raise SystemExit("Published SideStore identifiers do not match the app.")
print(f"Verified live SideStore feed · {latest['version']} · {latest['size']} bytes · {app['bundleIdentifier']}")
PY

echo "Published $TAG ($SIZE bytes)."
echo "IPA: https://github.com/$REPOSITORY/releases/download/$TAG/Framewise.ipa"
echo "SideStore source: https://github.com/$REPOSITORY/releases/latest/download/framewise.json"
