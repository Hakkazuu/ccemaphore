#!/usr/bin/env bash
# Build a release ccemaphore.app via Xcode and drop it in build/ for local use.
# Distribution (Developer ID signing + notarization + DMG + update feed) is done in CI — see docs/RELEASING.md.
#
# The copy runs as built: the linker's ad-hoc signature is enough on this Mac. Don't re-sign it with
# `codesign --options runtime --sign -`: under the Hardened Runtime, library validation then refuses the
# embedded Sparkle.framework ("different Team IDs") and the app dies at launch, along with every hook
# that points at it. Being ad-hoc, it never updates itself (only the Developer ID release does).
set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DD="$(mktemp -d)"
cleanup() {
  # The build registered the temporary bundle with LaunchServices; drop that before deleting it, so no
  # stray com.hakkazuu.ccemaphore entry is left behind (see the hard rules in CLAUDE.md). The second pass
  # runs on the deleted paths: a nested Updater.app record can survive the first.
  local app="$DD/Build/Products/Release/ccemaphore.app"
  unregister() {
    "$LSREGISTER" -u "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
    "$LSREGISTER" -u "$app" 2>/dev/null || true
  }
  if [[ -x "$LSREGISTER" ]]; then unregister; fi
  rm -rf "$DD"
  if [[ -x "$LSREGISTER" ]]; then unregister; fi
}
trap cleanup EXIT

xcodebuild -project ccemaphore.xcodeproj -scheme ccemaphore -configuration Release \
  -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/dev/null

rm -rf build/ccemaphore.app
mkdir -p build
cp -R "$DD/Build/Products/Release/ccemaphore.app" build/ccemaphore.app

# Absolute paths in what's printed: the script works from any directory (it cds to the repo root), and the
# commands pasted from its output must too.
APP_OUT="$PWD/build/ccemaphore.app"
echo "Built $APP_OUT (ad-hoc; it runs as is - do not re-sign it with --options runtime)"
echo "Run:       open \"$APP_OUT\""
echo "Clean up (unregister, delete, then unregister the deleted paths once more):"
echo "  LSR=$LSREGISTER"
echo "  APP=\"$APP_OUT\""
echo "  U=\"\$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app\""
echo "  \"\$LSR\" -u \"\$U\"; \"\$LSR\" -u \"\$APP\"; rm -rf \"\$APP\""
echo "  \"\$LSR\" -u \"\$U\"; \"\$LSR\" -u \"\$APP\""
