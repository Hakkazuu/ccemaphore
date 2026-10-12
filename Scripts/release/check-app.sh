#!/usr/bin/env bash
# Asserts that a built ccemaphore.app is the one the tag promises, before anything gets signed.
#
#   check-app.sh --app PATH --short-version X.Y.Z --build N
#                [--bundle-id ID] [--pubkey BASE64] [--allow-thin] [--no-notices]
#
# - CFBundleShortVersionString / CFBundleVersion are the expected ones (Info.plist expands
#   $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION); a stale literal would ship a wrong build number);
# - the updater keys made it into the bundle: canonical SUFeedURL, SURequireSignedFeed,
#   SUVerifyUpdateBeforeExtraction, and SUPublicEDKey equal to the repository's (default) / --pubkey;
# - the executable is universal (arm64 + x86_64): an arm64-only build makes generate_appcast add a
#   hardware requirement and Intel Macs silently stop getting updates (--allow-thin to skip);
# - Sparkle.framework with its Autoupdate / Updater.app helpers is embedded, and the third-party
#   notices (Sparkle's license, which its BSD parts require in binary distributions) ship in Resources.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP="" SHORT_VERSION="" BUILD="" EXPECT_BUNDLE_ID="$BUNDLE_ID" PUBKEY="" ALLOW_THIN=0 NOTICES=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --short-version) SHORT_VERSION=$2; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --bundle-id) EXPECT_BUNDLE_ID=$2; shift 2 ;;
    --pubkey) PUBKEY=$2; shift 2 ;;
    --allow-thin) ALLOW_THIN=1; shift ;;
    --no-notices) NOTICES=0; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -d "$APP" && -n "$SHORT_VERSION" && -n "$BUILD" ]] ||
  die "usage: check-app.sh --app PATH --short-version X.Y.Z --build N [options]"
[[ -n "$PUBKEY" ]] || PUBKEY="$(plist_get "$DEFAULT_REPO_ROOT/Resources/Info.plist" SUPublicEDKey)"
need python3 lipo

PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "$APP has no Contents/Info.plist"
expect() { # expect <key> <expected value>
  local actual
  actual="$(plist_get "$PLIST" "$1")" || die "$APP: Info.plist has no $1"
  [[ "$actual" == "$2" ]] || die "$APP: $1 is '$actual', expected '$2'"
}
expect CFBundleIdentifier "$EXPECT_BUNDLE_ID"
expect CFBundleShortVersionString "$SHORT_VERSION"
expect CFBundleVersion "$BUILD"
expect SUFeedURL "$FEED_URL"
expect SURequireSignedFeed true
expect SUVerifyUpdateBeforeExtraction true
py ed25519-check-public-key "$PUBKEY" || die "the expected SUPublicEDKey is not usable"
expect SUPublicEDKey "$PUBKEY"
MIN_OS="$(plist_get "$PLIST" LSMinimumSystemVersion)" || die "$APP: Info.plist has no LSMinimumSystemVersion"

EXECUTABLE="$APP/Contents/MacOS/$(plist_get "$PLIST" CFBundleExecutable)"
[[ -x "$EXECUTABLE" ]] || die "$APP: the main executable is missing or not executable"
ARCHS="$(lipo -archs "$EXECUTABLE")"
if [[ $ALLOW_THIN == 0 ]]; then
  [[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] ||
    die "$APP: the executable is '$ARCHS', not universal (arm64 + x86_64) - Intel Macs would stop getting updates"
fi

FW="$APP/Contents/Frameworks/Sparkle.framework"
for part in Versions/B/Sparkle Versions/B/Autoupdate Versions/B/Updater.app; do
  [[ -e "$FW/$part" ]] || die "$APP: Sparkle.framework/$part is missing"
done
SPARKLE_SHORT="$(plist_get "$FW/Versions/B/Resources/Info.plist" CFBundleShortVersionString)"
if [[ $NOTICES == 1 ]]; then
  grep -qs "Sparkle" "$APP/Contents/Resources/ThirdPartyNotices.txt" ||
    die "$APP: Contents/Resources/ThirdPartyNotices.txt (Sparkle's license) is missing"
fi

log "ok: $(basename "$APP") $SHORT_VERSION ($BUILD), $ARCHS, macOS $MIN_OS+, Sparkle $SPARKLE_SHORT, updater keys in place"
