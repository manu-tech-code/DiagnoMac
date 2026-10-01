#!/bin/zsh
# Builds a Release copy, packages it as a .dmg with an Applications link, signs
# the .dmg for Sparkle and writes the appcast that installed copies read.
#   scripts/release.sh            build build/DiagnoMac-<version>.dmg and build/appcast.xml
#   scripts/release.sh --upload   also attach both to the draft GitHub release v<version>
#                                 and publish it (run from release/<version>, after the
#                                 Release workflow)
# Sparkle's update key lives in the login Keychain (account com.amalitech.DiagnoMac);
# its public half is SUPublicEDKey in project.yml.
# The app is signed with your Apple Development certificate: it runs on your
# own Macs. Sharing it with other people needs a Developer ID certificate and
# notarization (Apple Developer Program).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
DERIVED="$ROOT/build/DerivedData"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)
UPLOAD=false
[[ "${1:-}" == "--upload" ]] && UPLOAD=true

if $UPLOAD; then
  git fetch --quiet --tags origin
  TAG_COMMIT=$(git rev-parse -q --verify "v$VERSION^{commit}") \
    || { echo "no tag v$VERSION yet: merge develop into main first"; exit 1; }
  [[ "$(git rev-parse HEAD)" == "$TAG_COMMIT" ]] \
    || { echo "HEAD isn't v$VERSION: git switch release/$VERSION && git pull"; exit 1; }
  [[ -z "$(git status --porcelain)" ]] || { echo "uncommitted changes: commit or stash them first"; exit 1; }
fi

xcodegen generate --quiet
(cd Packages/DiagnoKit && swift test 2>&1 | grep -E "Test run|✘")
xcodebuild -project DiagnoMac.xcodeproj -scheme DiagnoMac -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' build -quiet 2>&1 \
  | grep -vE "appintentsmetadataprocessor" || true

APP="$DERIVED/Build/Products/Release/DiagnoMac.app"
[[ -d "$APP" ]] || { echo "release build failed"; exit 1; }
codesign --verify --deep --strict "$APP"
echo "signed: $(codesign -dvv "$APP" 2>&1 | awk -F= '/Authority/ {print $2; exit}')"

STAGE="$ROOT/build/dmg"
DMG="$ROOT/build/DiagnoMac-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/DiagnoMac.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DiagnoMac $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"

# Sparkle: the signed appcast that installed copies read from the latest release.
scripts/appcast.sh "$DMG"
APPCAST="$ROOT/build/appcast.xml"

if $UPLOAD; then
  [[ "$(gh release view "v$VERSION" --json isDraft --jq .isDraft)" == "true" ]] \
    || { echo "v$VERSION is already published: assets can only be added to a draft"; exit 1; }
  gh release upload "v$VERSION" "$DMG" "$APPCAST" --clobber
  gh release edit "v$VERSION" --draft=false --latest >/dev/null
  echo "published $(gh release view "v$VERSION" --json url --jq .url)"
fi
