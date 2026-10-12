#!/usr/bin/env bash
# Signs ccemaphore.app for Developer ID distribution, inside-out, the way Sparkle documents it
# (sparkle-project.org/documentation/sandboxing → Code Signing) — never `codesign --deep`.
#
#   sign-app.sh --app PATH --identity SHA1_OR_NAME --team TEAMID
#   sign-app.sh --app PATH --adhoc          (selftest only: ad-hoc, no timestamp, no team checks)
#
# An --adhoc bundle is for packaging tests only and cannot even run: under the Hardened Runtime, library
# validation refuses to load Sparkle.framework into a process without a Team ID (dyld: "different Team
# IDs"). That is the same failure smoke-test.sh exists to catch for a mis-signed release.
#
# 1. Removes Sparkle's XPC services: they exist for sandboxed apps; ccemaphore isn't sandboxed and
#    never sets SUEnableInstallerLauncherService / SUEnableDownloaderService.
# 2. Signs Autoupdate → Updater.app → Sparkle.framework → the app, each with Hardened Runtime and a
#    secure timestamp. Sparkle ships these helpers ad-hoc signed; Autoupdate must carry OUR team ID or
#    Sparkle skips its atomic bundle swap and the Gatekeeper pre-warm (SUPlainInstaller), and
#    notarization rejects ad-hoc code.
# 3. Verifies: `codesign --verify --deep --strict` (fine for verifying), and every Mach-O in the bundle
#    signed by --team with runtime + timestamp; the four signed items additionally by a
#    "Developer ID Application" leaf.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP="" IDENTITY="" TEAM="" ADHOC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --identity) IDENTITY=$2; shift 2 ;;
    --team) TEAM=$2; shift 2 ;;
    --adhoc) ADHOC=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -d "$APP" ]] || die "usage: sign-app.sh --app PATH (--identity ID --team TEAMID | --adhoc)"
if [[ $ADHOC == 0 ]]; then
  [[ -n "$IDENTITY" && -n "$TEAM" ]] || die "--identity and --team are required (or --adhoc for tests)"
fi
need codesign file

FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$FW/Versions/B" ]] || die "$APP has no Sparkle.framework"

# 1. XPC services (the versioned directory and the top-level symlink).
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
[[ ! -e "$FW/Versions/B/XPCServices" && ! -L "$FW/XPCServices" ]] || die "could not remove Sparkle's XPCServices"

# 2. Inside-out signing.
sign() {
  if [[ $ADHOC == 1 ]]; then
    codesign --force --sign - --options runtime --timestamp=none "$1"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$1"
  fi
}
for item in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW" "$APP"; do
  [[ -e "$item" ]] || die "missing $item"
  sign "$item"
  log "signed ${item#"$APP"/}"
done

# 3. Verification.
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ $ADHOC == 1 ]]; then
  log "ok: ad-hoc signed (test mode, no team / timestamp checks)"
  exit 0
fi

details() { codesign --display --verbose=4 "$1" 2>&1; }
check_signature() { # check_signature <path> <require-developer-id: 0|1>
  local info
  info="$(details "$1")"
  grep -qx "TeamIdentifier=$TEAM" <<<"$info" ||
    die "${1#"$APP"/}: TeamIdentifier is '$(sed -n 's/^TeamIdentifier=//p' <<<"$info")', expected the signing team"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' <<<"$info" || die "${1#"$APP"/}: Hardened Runtime is not enabled"
  grep -q '^Timestamp=' <<<"$info" || die "${1#"$APP"/}: no secure timestamp"
  if [[ $2 == 1 ]]; then
    grep -q '^Authority=Developer ID Application: ' <<<"$info" || die "${1#"$APP"/}: not signed by a Developer ID Application certificate"
  fi
}
for item in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW" "$APP"; do
  check_signature "$item" 1
done
macho_count=0
while IFS= read -r -d '' candidate; do
  if [[ "$(file -b "$candidate")" == *Mach-O* ]]; then
    check_signature "$candidate" 0
    macho_count=$((macho_count + 1))
  fi
done < <(find "$APP" -type f -perm -u+x -print0)
[[ $macho_count -ge 4 ]] || die "found only $macho_count Mach-O files in $APP - is the bundle complete?"

log "ok: $(basename "$APP") and its $macho_count Mach-O files are signed by the expected team (runtime, timestamp)"
