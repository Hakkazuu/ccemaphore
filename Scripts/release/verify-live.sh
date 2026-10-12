#!/usr/bin/env bash
# After publishing: fetch what installed apps will fetch and verify it like they will. No secrets.
#
#   verify-live.sh --tag TAG --version V --short-version X.Y.Z --build N --prerelease true|false
#                  [--pubkey BASE64] [--min-os 13.0] [--attempts 10]
#
# Stable: the feed every copy polls (releases/latest/download/appcast.xml) must now offer build N.
# Prerelease: never "latest" — its own releases/download/<tag>/appcast.xml must offer it (that's the
# URL a test Mac's `defaults write … SUFeedURL` points at).
# Then the DMG is downloaded from the item's URL and checked against the feed's length and EdDSA
# signature with SUPublicEDKey (default: the repository's Info.plist at this tag), and the feed's own
# signature is verified — the same checks Sparkle makes before it installs anything.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TAG="" VERSION="" SHORT_VERSION="" BUILD="" PRERELEASE="" PUBKEY="" MIN_OS="" ATTEMPTS=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG=$2; shift 2 ;;
    --version) VERSION=$2; shift 2 ;;
    --short-version) SHORT_VERSION=$2; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --prerelease) PRERELEASE=$2; shift 2 ;;
    --pubkey) PUBKEY=$2; shift 2 ;;
    --min-os) MIN_OS=$2; shift 2 ;;
    --attempts) ATTEMPTS=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$TAG" && -n "$VERSION" && -n "$SHORT_VERSION" && -n "$BUILD" && "$PRERELEASE" =~ ^(true|false)$ ]] ||
  die "usage: verify-live.sh --tag TAG --version V --short-version X.Y.Z --build N --prerelease true|false"
[[ -n "$PUBKEY" ]] || PUBKEY="$(plist_get "$DEFAULT_REPO_ROOT/Resources/Info.plist" SUPublicEDKey)"
[[ -n "$MIN_OS" ]] || MIN_OS="$(plist_get "$DEFAULT_REPO_ROOT/Resources/Info.plist" LSMinimumSystemVersion)"
need curl python3

if [[ "$PRERELEASE" == true ]]; then URL="$DOWNLOAD_BASE/$TAG/appcast.xml"; else URL="$FEED_URL"; fi
DMG_URL="$DOWNLOAD_BASE/$TAG/$(dmg_name "$VERSION")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The "latest" redirect follows the publish right away, but give the CDN a little slack.
found=0
for attempt in $(seq 1 "$ATTEMPTS"); do
  fetch_feed "$URL" "$WORK/appcast.xml"
  if [[ -f "$WORK/appcast.xml" ]]; then
    builds="$(py feed-summary "$WORK/appcast.xml" | sed -n 's/^builds=//p')"
    if [[ ",$builds," == *",$BUILD,"* ]]; then
      found=1
      break
    fi
  fi
  log "attempt $attempt/$ATTEMPTS: $URL does not offer build $BUILD yet"
  if [[ $attempt -lt $ATTEMPTS ]]; then sleep 15; fi
done
[[ $found == 1 ]] || die "$URL does not offer build $BUILD"

curl -fsSL --proto '=https' --proto-redir '=https' --retry 4 --retry-delay 5 --max-time 600 -o "$WORK/update.dmg" "$DMG_URL" ||
  die "could not download $DMG_URL"
py verify-feed --feed "$WORK/appcast.xml" --pubkey "$PUBKEY" --build "$BUILD" --short-version "$SHORT_VERSION" \
  --min-os "$MIN_OS" --url "$DMG_URL" --dmg "$WORK/update.dmg" || die "the live feed at $URL fails verification"
log "ok: $URL offers $SHORT_VERSION ($BUILD); the downloaded DMG matches its signature"
