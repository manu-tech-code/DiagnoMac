#!/bin/zsh
# Writes build/appcast.xml for a release .dmg: Sparkle's EdDSA signature (with
# the update key in the login Keychain) and the release notes from GitHub,
# embedded as HTML so the update window shows just the notes.
#   scripts/appcast.sh build/DiagnoMac-<version>.dmg
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
DMG="${1:?usage: scripts/appcast.sh <dmg>}"
VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CFBundleVersion:/ {print $2; exit}' project.yml)
REPO=manu-tech-code/DiagnoMac
REPO_URL="https://github.com/$REPO"
SIGN_UPDATE="$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

SIGNATURE=$("$SIGN_UPDATE" --account com.amalitech.DiagnoMac "$DMG")   # sparkle:edSignature="…" length="…"

# The release's notes (generated from the merged PRs), rendered by GitHub.
NOTES=$(gh release view "v$VERSION" --repo "$REPO" --json body --jq .body 2>/dev/null || true)
if [[ -n "$NOTES" ]]; then
  NOTES_HTML=$(gh api markdown -f text="$NOTES" -f mode=gfm -f context="$REPO")
else
  NOTES_HTML="<p>DiagnoMac $VERSION</p>"
fi

APPCAST="$ROOT/build/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DiagnoMac</title>
    <link>$REPO_URL</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
<style>
  :root { color-scheme: light dark; }
  body { font: -apple-system-body; margin: 10px 14px; line-height: 1.45; }
  h1, h2, h3 { font-size: 1.05em; margin: 0.6em 0 0.3em; }
  ul { padding-left: 1.2em; margin: 0.3em 0; }
  li { margin: 0.2em 0; }
  a { color: -apple-system-control-accent; text-decoration: none; }
  code { font: 0.9em ui-monospace, monospace; }
</style>
$NOTES_HTML
]]></description>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/DiagnoMac-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "appcast $APPCAST (build $BUILD, notes $([[ -n "$NOTES" ]] && echo "from v$VERSION" || echo "placeholder"))"
