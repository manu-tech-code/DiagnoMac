#!/bin/bash
# Installs, or updates, DiagnoMac from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/manu-tech-code/DiagnoMac/HEAD/scripts/install.sh | bash
#
# It reads the release feed the app's updater uses, downloads the .dmg with
# curl, checks that the app inside is signed by the project's certificate,
# copies it to Applications and opens it. Files fetched with curl aren't marked
# as downloaded from the internet, so macOS doesn't block the first launch the
# way it does for a browser download. From then on the app updates itself.
#
# Options, as environment variables:
#   DM_INSTALL_DIR=<folder>   install there (default /Applications, or
#                             ~/Applications if /Applications isn't writable)
#   DM_NO_OPEN=1              don't open the app afterwards
set -euo pipefail

REPO="manu-tech-code/DiagnoMac"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
APP_NAME="DiagnoMac.app"
BUNDLE_ID="com.amalitech.DiagnoMac"
TEAM_ID="KNK4UH42NN"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# macOS 15 or later, on Apple silicon (checked even under Rosetta).
[ "$(uname -s)" = "Darwin" ] || fail "DiagnoMac is a Mac app."
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] || fail "DiagnoMac needs an Apple silicon Mac (M1 or later)."
MACOS=$(sw_vers -productVersion)
[ "${MACOS%%.*}" -ge 15 ] || fail "DiagnoMac needs macOS 15 or later; this Mac has macOS $MACOS."

DEST="${DM_INSTALL_DIR:-/Applications}"
if [ -z "${DM_INSTALL_DIR:-}" ] && [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; fi
mkdir -p "$DEST" 2>/dev/null || true
[ -w "$DEST" ] || fail "Can't write to $DEST."
TARGET="$DEST/$APP_NAME"

WORK=$(mktemp -d -t diagnomac)
MOUNT="$WORK/volume"
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say "Finding the latest release"
APPCAST=$(curl -fsSL "$FEED") || fail "Couldn't reach GitHub."
VERSION=$(printf '%s\n' "$APPCAST" | sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)<.*|\1|p' | head -n 1)
DMG_URL=$(printf '%s\n' "$APPCAST" | sed -n 's|.*<enclosure url="\([^"]*\)".*|\1|p' | head -n 1)
[ -n "$VERSION" ] && [ -n "$DMG_URL" ] || fail "The release feed doesn't list a download."
case "$DMG_URL" in
  "https://github.com/$REPO/releases/download/"*) ;;
  *) fail "Unexpected download address: $DMG_URL" ;;
esac

say "Downloading DiagnoMac $VERSION"
curl -fL --progress-bar -o "$WORK/DiagnoMac.dmg" "$DMG_URL" || fail "The download failed."

say "Checking the app's signature"
hdiutil attach "$WORK/DiagnoMac.dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet </dev/null \
  || fail "Couldn't open the disk image."
SRC="$MOUNT/$APP_NAME"
[ -d "$SRC" ] || fail "The disk image doesn't contain $APP_NAME."
codesign --verify --deep --strict "$SRC" >/dev/null 2>&1 || fail "The app's signature isn't valid."
SIGNATURE=$(codesign -dv "$SRC" 2>&1)
printf '%s\n' "$SIGNATURE" | grep -qx "Identifier=$BUNDLE_ID" || fail "That isn't DiagnoMac ($BUNDLE_ID)."
printf '%s\n' "$SIGNATURE" | grep -qx "TeamIdentifier=$TEAM_ID" || fail "The app isn't signed by DiagnoMac's developer."

# Quit a copy running from where this one goes, before replacing it.
if pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1; then
  say "Quitting the running copy"
  pkill -f "$TARGET/Contents/MacOS/" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

say "Installing in $DEST"
ditto "$SRC" "$WORK/$APP_NAME"
rm -rf "$TARGET"
mv "$WORK/$APP_NAME" "$TARGET"

say "DiagnoMac $VERSION is installed"
if [ -z "${DM_NO_OPEN:-}" ]; then
  open "$TARGET"
fi
