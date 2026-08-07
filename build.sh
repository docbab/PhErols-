#!/bin/bash
# Builds UsageBar.app (status-bar-only agent app). No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP=UsageBar.app
MODE="${1:-}"
# The app compares its own version against the latest GitHub release, so a dist build must
# carry a real one. Dev builds get 0.0 and therefore always report an update available.
VERSION="${2:-0.0}"
if [ "$MODE" = "dist" ] && [ "$VERSION" = "0.0" ]; then
  echo "usage: ./build.sh dist <version>   e.g. ./build.sh dist 1.1" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIdentifier</key><string>local.usagebar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Universal binary so the zip runs on both Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14" \
    -o "/tmp/UsageBar-$arch" UsageBar.swift
done
lipo -create /tmp/UsageBar-arm64 /tmp/UsageBar-x86_64 -output "$APP/Contents/MacOS/UsageBar"
rm -f /tmp/UsageBar-arm64 /tmp/UsageBar-x86_64

codesign --force --deep --sign - "$APP"

"$APP/Contents/MacOS/UsageBar" --selftest
echo "built $PWD/$APP v$VERSION ($(lipo -archs "$APP/Contents/MacOS/UsageBar"))"

if [ "$MODE" = "dist" ]; then
  rm -f UsageBar.zip
  # ditto, not zip: it preserves the bundle's code signature and metadata.
  ditto -c -k --keepParent "$APP" UsageBar.zip
  echo "packaged $PWD/UsageBar.zip ($(du -h UsageBar.zip | cut -f1))"

  # The install/troubleshooting half of the notes is identical every release; only the
  # changelog differs. Regenerate rather than copy-paste so the version never goes stale.
  # Strip the leading HTML comment (instructions for the maintainer, not for the release page).
  sed -e '/^<!--$/,/^-->$/d' -e "s/{{VERSION}}/$VERSION/g" RELEASE_NOTES_TEMPLATE.md > release-notes.md
  echo "notes:    $PWD/release-notes.md — fill in '## 바뀐 것', then:"
  echo "publish:  gh release create v$VERSION UsageBar.zip -R docbab/PhErols- -t v$VERSION --latest --notes-file release-notes.md"
fi
