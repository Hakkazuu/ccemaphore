#!/usr/bin/env bash
# The gate between generate_appcast and publishing: proves the feed will be accepted by installed apps.
#
#   verify-appcast.sh --feed appcast.xml --dmg PATH --build N --short-version X.Y.Z --url URL
#                     [--min-os 13.0] [--pubkey BASE64] [--notes NOTES.md] [--sparkle-bin DIR]
#
# generate_appcast exits 0 even when it could not sign the new item (SUPublicEDKey / private key
# mismatch) or skipped the DMG altogether, so nothing it prints can be trusted. Checked here:
#   - independently, against SUPublicEDKey (--pubkey, default: the repository's Info.plist), with the
#     Ed25519 verifier in release_tool.py: the feed signature that SURequireSignedFeed demands, the
#     new item's EdDSA signature over the DMG's bytes, its length, URL, versions, minimum macOS, notes,
#     and that it is the newest item (see verify_feed() there);
#   - with Sparkle's own tool as well, when --sparkle-bin and SPARKLE_ED_PRIVATE_KEY are available:
#     `sign_update --verify` for the DMG signature and for the feed signature.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

FEED="" DMG="" BUILD="" SHORT_VERSION="" URL="" MIN_OS="" PUBKEY="" NOTES="" SPARKLE_BIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feed) FEED=$2; shift 2 ;;
    --dmg) DMG=$2; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --short-version) SHORT_VERSION=$2; shift 2 ;;
    --url) URL=$2; shift 2 ;;
    --min-os) MIN_OS=$2; shift 2 ;;
    --pubkey) PUBKEY=$2; shift 2 ;;
    --notes) NOTES=$2; shift 2 ;;
    --sparkle-bin) SPARKLE_BIN=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -f "$FEED" && -f "$DMG" && -n "$BUILD" && -n "$SHORT_VERSION" && -n "$URL" ]] ||
  die "usage: verify-appcast.sh --feed XML --dmg PATH --build N --short-version X.Y.Z --url URL [options]"
[[ -n "$PUBKEY" ]] || PUBKEY="$(plist_get "$DEFAULT_REPO_ROOT/Resources/Info.plist" SUPublicEDKey)"
[[ -n "$MIN_OS" ]] || MIN_OS="$(plist_get "$DEFAULT_REPO_ROOT/Resources/Info.plist" LSMinimumSystemVersion)"

VERIFY=(verify-feed --feed "$FEED" --pubkey "$PUBKEY" --build "$BUILD" --short-version "$SHORT_VERSION"
  --min-os "$MIN_OS" --url "$URL" --dmg "$DMG")
if [[ -n "$NOTES" ]]; then VERIFY+=(--notes "$NOTES"); fi
py "${VERIFY[@]}" || die "$FEED must not be published"

if [[ -n "$SPARKLE_BIN" && -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  KEY="${SPARKLE_ED_PRIVATE_KEY//[[:space:]]/}"
  # sign_update echoes a key it cannot decode; make sure it never gets one.
  printf '%s\n' "$KEY" | py ed25519-public-key >/dev/null || die "SPARKLE_ED_PRIVATE_KEY is not a Sparkle EdDSA private key"
  SIGNATURE="$(py feed-item "$FEED" "$BUILD" ed_signature)"
  printf '%s\n' "$KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - --verify "$DMG" "$SIGNATURE" >&2 ||
    die "sign_update rejects the DMG signature in $FEED"
  printf '%s\n' "$KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - --verify "$FEED" >&2 ||
    die "sign_update rejects the feed signature of $FEED"
  log "ok: sign_update agrees (DMG and feed signatures)"
fi
