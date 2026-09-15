#!/usr/bin/env bash
# Dev-only helper to test the Sparkle auto-update flow locally, without touching
# GitHub or main. Not part of CI, not meant to be committed to a release.
#
# Usage:
#   scripts/test-sparkle-update.sh install <version>   # build+install a "current" copy at that version
#   scripts/test-sparkle-update.sh publish <version>   # build+sign a "new" version and publish it on the local appcast
#   scripts/test-sparkle-update.sh serve                # (re)start the local HTTP server on :8899
#   scripts/test-sparkle-update.sh clean                # stop the server and wipe the test dir
#
# Typical flow:
#   scripts/test-sparkle-update.sh install 1   # launches Beepbar "v1", pointed at localhost appcast
#   scripts/test-sparkle-update.sh publish 2   # builds v2, hosts it + a signed appcast entry
#   # in the running v1 app: Impostazioni -> "Cerca aggiornamenti…"
#   scripts/test-sparkle-update.sh publish 3   # bump again to test consecutive updates
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=/tmp/sparkle-test
PORT=8899
IDENTIFIER=io.github.tvaccari.beepbar
SPARKLE_TOOLS=/tmp/sparkle-tools/bin

mkdir -p "$TEST_DIR"

require_sparkle_tools() {
  if [ ! -x "$SPARKLE_TOOLS/sign_update" ]; then
    echo "Sparkle CLI tools not found at $SPARKLE_TOOLS. Download a release from"
    echo "https://github.com/sparkle-project/Sparkle/releases and extract bin/ there."
    exit 1
  fi
}

build_app() {
  local version="$1"
  cd "$ROOT"
  rm -rf build
  xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build \
    CODE_SIGNING_ALLOWED=NO "CURRENT_PROJECT_VERSION=$version" | tail -5
  codesign --force --deep --sign - --identifier "$IDENTIFIER" build/Release/Beepbar.app
  codesign --verify --deep --strict build/Release/Beepbar.app
}

serve() {
  if ! lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    (cd "$TEST_DIR" && nohup python3 -m http.server "$PORT" >"$TEST_DIR/server.log" 2>&1 &)
    sleep 1
  fi
  echo "serving $TEST_DIR at http://127.0.0.1:$PORT"
}

cmd_install() {
  local version="${1:?usage: install <version>}"
  require_sparkle_tools
  pkill -f "sparkle-test/Beepbar-current.app" 2>/dev/null || true
  build_app "$version"
  rm -rf "$TEST_DIR/Beepbar-current.app"
  cp -R build/Release/Beepbar.app "$TEST_DIR/Beepbar-current.app"
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" "$TEST_DIR/Beepbar-current.app/Contents/Info.plist"
  codesign --force --deep --sign - --identifier "$IDENTIFIER" "$TEST_DIR/Beepbar-current.app"
  xattr -dr com.apple.quarantine "$TEST_DIR/Beepbar-current.app"
  serve
  echo "launching Beepbar-current.app (version $version)…"
  "$TEST_DIR/Beepbar-current.app/Contents/MacOS/Beepbar" &
  disown
}

cmd_publish() {
  local version="${1:?usage: publish <version>}"
  require_sparkle_tools
  build_app "$version"
  local dmg="$TEST_DIR/Beepbar-v$version.dmg"
  rm -f "$dmg"
  "$ROOT/scripts/create-dmg.sh" build/Release/Beepbar.app "$dmg"
  local short_version
  short_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Release/Beepbar.app/Contents/Info.plist)
  local signature
  signature=$("$SPARKLE_TOOLS/sign_update" "$dmg" -p)
  local length
  length=$(stat -f%z "$dmg")
  local pubdate
  pubdate=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
  cat > "$TEST_DIR/appcast.xml" <<XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Beepbar</title>
    <item>
      <title>Latest build</title>
      <pubDate>$pubdate</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$short_version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="http://127.0.0.1:$PORT/Beepbar-v$version.dmg" sparkle:version="$version" sparkle:edSignature="$signature" length="$length" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XMLEOF
  serve
  echo "published version $version at http://127.0.0.1:$PORT/appcast.xml"
  echo "now trigger 'Cerca aggiornamenti…' in the running app."
}

cmd_clean() {
  pkill -f "sparkle-test/Beepbar-current.app" 2>/dev/null || true
  pkill -f "http.server $PORT" 2>/dev/null || true
  rm -rf "$TEST_DIR"
  echo "cleaned up"
}

case "${1:-}" in
  install) cmd_install "${2:-}" ;;
  publish) cmd_publish "${2:-}" ;;
  serve) serve ;;
  clean) cmd_clean ;;
  *) echo "usage: $0 {install|publish|serve|clean} [version]"; exit 1 ;;
esac
