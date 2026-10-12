#!/usr/bin/env bash
# Generates the signed Sparkle feed for a release — strictly AFTER the DMG is notarized and stapled.
#
#   SPARKLE_ED_PRIVATE_KEY=... make-appcast.sh --dmg PATH --build N --notes NOTES.md --out-dir DIR
#       --download-prefix https://github.com/<owner>/<repo>/releases/download/<tag>/
#       --sparkle-bin DIR [--prev-feed appcast.xml] [--release-page URL] [--link URL] [--pubkey BASE64]
#       [--signing-pubkey BASE64]
#
# --build is the DMG app's CFBundleVersion. It must be above everything in --prev-feed: with an equal
# number generate_appcast silently overwrites the existing item, with a lower one it inserts an item no
# client is offered (or moves the DMG to old_updates/) — and exits 0 either way.
#
# Writes DIR/appcast.xml. The input folder generate_appcast sees holds exactly three things:
#   - appcast.xml  — the previous live feed (if any): its items are kept untouched, URLs included, and
#                    trimmed to the newest --maximum-versions per branch (a short history);
#   - the DMG      — becomes the new item: EdDSA signature + length of these exact (stapled) bytes,
#                    absolute per-tag URL from --download-prefix (Sparkle resolves relative URLs against
#                    the post-redirect GitHub asset host, which would break them);
#   - <dmg>.md     — the CHANGELOG notes, embedded as Markdown so the feed signature covers them.
# Deltas are off (one small DMG). Because the app sets SURequireSignedFeed, the whole feed is signed too.
#
# The private key travels only through stdin (`--ed-key-file -`), never argv or disk. Before running
# generate_appcast we check that it belongs to SUPublicEDKey (--pubkey, default: the repository's
# Info.plist): generate_appcast itself only prints a warning on a mismatch and writes an unsigned item.
#
# --signing-pubkey OLD is for ONE release only: rotating to a new EdDSA key while the old private key is
# still at hand (docs/RELEASING.md, "Losing or leaking the EdDSA key"). The app then carries the new
# SUPublicEDKey (--pubkey), but every installed copy still trusts OLD, so the private key must belong to
# OLD and the feed AND the DMG are signed with it - installed copies take it like any update and trust the
# new key afterwards. generate_appcast refuses to sign an archive whose app carries another key, so the
# DMG's signature is added here with sign_update and the edited feed signed again. Verify the result with
# verify-appcast.sh --pubkey OLD. CI never passes it: there the key must match the app's.
#
# generate_appcast also keeps an unpacked copy of every archive it reads (~/Library/Caches/
# Sparkle_generate_appcast: a fully signed ccemaphore.app); it runs with a throwaway home, removed on exit.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DMG="" BUILD="" NOTES="" OUT_DIR="" PREFIX="" SPARKLE_BIN="" PREV_FEED="" RELEASE_PAGE="" LINK="https://github.com/$REPO_SLUG"
PUBKEY="" SIGNING_PUBKEY="" KEY_CHECK=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) DMG=$2; shift 2 ;;
    --build) BUILD=$2; shift 2 ;;
    --notes) NOTES=$2; shift 2 ;;
    --out-dir) OUT_DIR=$2; shift 2 ;;
    --download-prefix) PREFIX=$2; shift 2 ;;
    --sparkle-bin) SPARKLE_BIN=$2; shift 2 ;;
    --prev-feed) PREV_FEED=$2; shift 2 ;;
    --release-page) RELEASE_PAGE=$2; shift 2 ;;
    --link) LINK=$2; shift 2 ;;
    --pubkey) PUBKEY=$2; shift 2 ;;
    --signing-pubkey) SIGNING_PUBKEY=$2; shift 2 ;;
    --skip-key-check) KEY_CHECK=0; shift ;; # selftest only: lets it produce the bad feed verify must reject
    *) die "unknown argument: $1" ;;
  esac
done
[[ -f "$DMG" && "$BUILD" =~ ^[0-9]+$ && -s "$NOTES" && -n "$OUT_DIR" && -n "$PREFIX" && -x "$SPARKLE_BIN/generate_appcast" ]] ||
  die "usage: make-appcast.sh --dmg PATH --build N --notes MD --out-dir DIR --download-prefix URL --sparkle-bin DIR [options]"
[[ "$PREFIX" == https://*/ ]] || die "--download-prefix must be an absolute https URL ending in /"
[[ -z "$PREV_FEED" || -f "$PREV_FEED" ]] || die "--prev-feed $PREV_FEED does not exist"
if [[ -n "$PREV_FEED" ]]; then
  PREV_MAX="$(py feed-summary "$PREV_FEED" | sed -n 's/^max_build=//p')"
  if [[ -n "$PREV_MAX" && "$(py version-compare "$BUILD" "$PREV_MAX")" != 1 ]]; then
    die "build $BUILD is not above the previous feed's newest build $PREV_MAX"
  fi
fi
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || die "SPARKLE_ED_PRIVATE_KEY is not set"
[[ -n "$PUBKEY" ]] || PUBKEY="$(plist_get "$DEFAULT_REPO_ROOT/Resources/Info.plist" SUPublicEDKey)"
if [[ -n "$SIGNING_PUBKEY" ]]; then
  py ed25519-check-public-key "$SIGNING_PUBKEY" || die "--signing-pubkey is not a usable Ed25519 public key"
  [[ "$SIGNING_PUBKEY" != "$PUBKEY" ]] ||
    die "--signing-pubkey equals the app's SUPublicEDKey - it is only for a key rotation; drop it"
  [[ -x "$SPARKLE_BIN/sign_update" ]] || die "--signing-pubkey needs sign_update in $SPARKLE_BIN"
  warn "KEY ROTATION: the app carries SUPublicEDKey $PUBKEY; the feed and the DMG are signed with $SIGNING_PUBKEY, the key installed copies trust"
fi

# The key exactly as generate_keys -x writes it: one base64 line. Strip stray whitespace/newlines a
# copy-paste may have added (printf is a builtin, so the key never shows up in a process list).
KEY="${SPARKLE_ED_PRIVATE_KEY//[[:space:]]/}"
if [[ $KEY_CHECK == 1 ]]; then
  DERIVED="$(printf '%s\n' "$KEY" | py ed25519-public-key)" || die "SPARKLE_ED_PRIVATE_KEY is not a Sparkle EdDSA private key"
  if [[ -n "$SIGNING_PUBKEY" ]]; then
    [[ "$DERIVED" == "$SIGNING_PUBKEY" ]] ||
      die "SPARKLE_ED_PRIVATE_KEY does not belong to --signing-pubkey - installed copies would reject the update"
  else
    [[ "$DERIVED" == "$PUBKEY" ]] ||
      die "SPARKLE_ED_PRIVATE_KEY does not belong to SUPublicEDKey in Info.plist - every update would be rejected"
  fi
fi

DMG_NAME="$(basename "$DMG")"
if [[ -e "$OUT_DIR" && -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]]; then
  die "--out-dir $OUT_DIR is not empty - generate_appcast would pick up whatever is in it"
fi
mkdir -p "$OUT_DIR"
cp "$DMG" "$OUT_DIR/$DMG_NAME"
cp "$NOTES" "$OUT_DIR/${DMG_NAME%.dmg}.md"
if [[ -n "$PREV_FEED" ]]; then cp "$PREV_FEED" "$OUT_DIR/appcast.xml"; fi

ARGS=(--ed-key-file -
  --download-url-prefix "$PREFIX"
  --embed-release-notes
  --link "$LINK"
  --maximum-deltas 0
  --maximum-versions 3
  -o "$OUT_DIR/appcast.xml")
if [[ -n "$RELEASE_PAGE" ]]; then ARGS+=(--full-release-notes-url "$RELEASE_PAGE"); fi

APPCAST_HOME="$(mktemp -d)"
trap 'rm -rf "$APPCAST_HOME"' EXIT
printf '%s\n' "$KEY" | CFFIXED_USER_HOME="$APPCAST_HOME" "$SPARKLE_BIN/generate_appcast" "${ARGS[@]}" "$OUT_DIR" >&2

[[ -s "$OUT_DIR/appcast.xml" ]] || die "generate_appcast wrote no appcast.xml"
# generate_appcast moves archives it considers old into old_updates/ and still exits 0.
[[ -f "$OUT_DIR/$DMG_NAME" ]] || die "generate_appcast moved $DMG_NAME aside - its build number is not new"
cmp -s "$DMG" "$OUT_DIR/$DMG_NAME" || die "the staged DMG no longer matches $DMG"

if [[ -n "$SIGNING_PUBKEY" ]]; then
  # generate_appcast signed the feed with the installed copies' key but left the new item unsigned (its
  # app carries the new key): sign the DMG with that same key, add the signature, re-sign the feed.
  SIGNATURE="$(printf '%s\n' "$KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$OUT_DIR/$DMG_NAME")" ||
    die "sign_update could not sign $DMG_NAME"
  py feed-set-ed-signature "$OUT_DIR/appcast.xml" "$BUILD" "$SIGNATURE" ||
    die "could not add the DMG's signature to $OUT_DIR/appcast.xml"
  printf '%s\n' "$KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$OUT_DIR/appcast.xml" >&2 ||
    die "sign_update could not sign $OUT_DIR/appcast.xml"
  log "key rotation: the new item and the feed are signed with --signing-pubkey's key"
fi
log "ok: $OUT_DIR/appcast.xml (verify it with verify-appcast.sh before publishing)"
