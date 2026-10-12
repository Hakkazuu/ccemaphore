#!/usr/bin/env bash
# Packs the (already notarized + stapled) app into the distribution DMG: the drag-to-install image for
# new users AND the archive Sparkle downloads for updates (SUVerifyUpdateBeforeExtraction checks the
# DMG's EdDSA signature before mounting it).
#
#   make-dmg.sh --app PATH --out DMG [--identity SHA1_OR_NAME --team TEAMID] [--volname NAME]
#
# Plain hdiutil (no Finder/AppleScript window styling, which is flaky on headless CI): the app plus an
# /Applications symlink, HFS+ / UDZO. With --identity the DMG itself is Developer ID signed (that
# signature also lets a future EdDSA key rotation ride on code signing, see Sparkle's docs).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP="" OUT="" IDENTITY="" TEAM="" VOLNAME="$APP_NAME"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --identity) IDENTITY=$2; shift 2 ;;
    --team) TEAM=$2; shift 2 ;;
    --volname) VOLNAME=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -d "$APP" && -n "$OUT" ]] || die "usage: make-dmg.sh --app PATH --out DMG [--identity ID --team TEAMID]"
[[ -z "$IDENTITY" || -n "$TEAM" ]] || die "--identity needs --team"
need hdiutil ditto codesign

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >&2
hdiutil verify "$OUT" >&2 2>&1 || die "hdiutil verify failed for $OUT"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$OUT"
  codesign --verify --strict --verbose=2 "$OUT"
  INFO="$(codesign --display --verbose=4 "$OUT" 2>&1)"
  grep -qx "TeamIdentifier=$TEAM" <<<"$INFO" || die "the DMG is not signed by the expected team"
  grep -q '^Timestamp=' <<<"$INFO" || die "the DMG signature has no secure timestamp"
fi

log "ok: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes$([[ -n "$IDENTITY" ]] && echo ', signed'))"
