#!/usr/bin/env bash
# Notarizes and staples the app or the DMG, then checks the result the way Gatekeeper will.
#
#   notarize.sh --app PATH     zip (ditto) → notarytool → staple the .app itself
#   notarize.sh --dmg PATH     notarytool → staple the DMG
#
# Credentials (never echoed): NOTARY_APPLE_ID + NOTARY_PASSWORD (app-specific password) + APPLE_TEAM_ID,
# or NOTARY_KEYCHAIN_PROFILE for a profile saved with `xcrun notarytool store-credentials` (local use).
#
# Order matters downstream: the app is stapled before it goes into the DMG (offline first launch of a
# drag-installed copy), and the DMG is stapled before generate_appcast signs it — stapling rewrites the
# DMG's bytes, so any EdDSA signature or length taken earlier would be wrong.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

KIND="" TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) KIND=app TARGET=$2; shift 2 ;;
    --dmg) KIND=dmg TARGET=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -e "$TARGET" ]] || die "usage: notarize.sh --app PATH | --dmg PATH"
need xcrun ditto

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]] ||
    die "set NOTARY_APPLE_ID, NOTARY_PASSWORD and APPLE_TEAM_ID (or NOTARY_KEYCHAIN_PROFILE)"
  AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SUBMISSION="$TARGET"
if [[ $KIND == app ]]; then
  SUBMISSION="$WORK/$(basename "$TARGET" .app).zip"
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$SUBMISSION"
fi

# Submit and wait. A failed upload (no submission id) is retried; a finished submission is never
# resubmitted — its status decides, and anything but Accepted prints Apple's log and fails.
ID="" STATUS=""
for attempt in 1 2 3; do
  OUT="$WORK/submit.json"
  xcrun notarytool submit "$SUBMISSION" "${AUTH[@]}" --wait --timeout 2h --output-format json \
    >"$OUT" 2>"$WORK/submit.err" || true
  ID="$(py json-get id <"$OUT" 2>/dev/null || true)"
  STATUS="$(py json-get status <"$OUT" 2>/dev/null || true)"
  [[ -z "$ID" ]] || break
  log "notarytool submit attempt $attempt failed:"
  sed 's/^/  /' "$WORK/submit.err" >&2
  [[ $attempt == 3 ]] || sleep $((attempt * 30))
done
[[ -n "$ID" ]] || die "could not submit $(basename "$SUBMISSION") for notarization"
log "notarization $ID: ${STATUS:-unknown}"
if [[ "$STATUS" != "Accepted" ]]; then
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  die "notarization of $(basename "$SUBMISSION") ended with status '${STATUS:-unknown}' (log above)"
fi

# Staple. The ticket can take a moment to become fetchable after "Accepted", so retry briefly.
stapled=0
for attempt in 1 2 3 4 5; do
  if xcrun stapler staple "$TARGET"; then
    stapled=1
    break
  fi
  sleep $((attempt * 15))
done
[[ $stapled == 1 ]] || die "could not staple the notarization ticket to $TARGET"
xcrun stapler validate "$TARGET"

# Gatekeeper's view. spctl is authoritative only where assessments are enabled (a CI runner may have
# them off); syspolicy_check is Apple's distribution-readiness report, printed for the log.
if [[ "$(spctl --status 2>/dev/null || true)" == *"assessments enabled"* ]]; then
  if [[ $KIND == app ]]; then
    ASSESS="$(spctl --assess --type execute --verbose=4 "$TARGET" 2>&1)" || die "Gatekeeper rejects the app: $ASSESS"
  else
    ASSESS="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$TARGET" 2>&1)" ||
      die "Gatekeeper rejects the DMG: $ASSESS"
  fi
  grep -q "source=Notarized Developer ID" <<<"$ASSESS" || die "Gatekeeper does not see a notarized Developer ID item: $ASSESS"
  log "Gatekeeper: $(tr '\n' ' ' <<<"$ASSESS")"
else
  warn "Gatekeeper assessments are disabled on this machine - skipping spctl"
fi
if [[ $KIND == app ]] && command -v syspolicy_check >/dev/null 2>&1; then
  syspolicy_check distribution "$TARGET" >&2 || warn "syspolicy_check distribution reported problems for $(basename "$TARGET") (see log)"
fi

log "ok: $(basename "$TARGET") is notarized and stapled"
