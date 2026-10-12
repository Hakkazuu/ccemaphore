#!/usr/bin/env bash
# End-to-end self-test of the release scripts: no secrets, no network, nothing launched.
#
#   Scripts/release/selftest.sh [--sparkle-bin DIR] [--keep]
#
# Run it after changing anything in Scripts/release/ or .github/workflows/release.yml. It builds
# throwaway apps that look like ccemaphore to the release scripts — Info.plist with the updater keys and
# a throwaway Ed25519 key, a universal executable, the real Sparkle.framework — and ships two releases
# through sign-app.sh (ad-hoc) → check-app.sh → make-dmg.sh → make-appcast.sh → verify-appcast.sh, the
# second on top of the first one's feed exactly as CI does. Then the cases that MUST fail: a wrong EdDSA
# key (caught before generate_appcast, and — if that check is bypassed — by verify-appcast.sh, since
# generate_appcast itself exits 0), tampered DMGs and feeds, a wrong public key, a build number that did
# not go up, and every guard in check-version.sh / extract-notes.sh. Also: an EdDSA key rotation
# (make-appcast.sh --signing-pubkey) followed by a release with the new key, the release job's tag check
# (lib.sh assert_tag_at, against a stand-in `gh`), and how smoke-test.sh reads `--update-status` (against
# stand-in executables, plus the app source that prints it — only a Developer ID build can run it for real).
#
# The throwaway apps use a test bundle id and live in a temp dir: they are never opened, never registered
# with LaunchServices (verified at the end), and no keychain is touched. Everything is deleted on exit
# unless --keep. Sparkle's tools come from --sparkle-bin, $SPARKLE_BIN, or the package Xcode resolved
# into DerivedData (or run: xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath DIR).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SPARKLE_BIN="${SPARKLE_BIN:-}" KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sparkle-bin) SPARKLE_BIN=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [[ -z "$SPARKLE_BIN" ]]; then
  for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/ccemaphore-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    if [[ -x "$candidate/generate_appcast" ]]; then SPARKLE_BIN=$candidate; fi
  done
fi
[[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" ]] ||
  die "Sparkle's tools not found - pass --sparkle-bin <SourcePackages>/artifacts/sparkle/Sparkle/bin"
SPARKLE_BIN="$(cd "$SPARKLE_BIN" && pwd -P)"
FRAMEWORK="$SPARKLE_BIN/../Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || die "no Sparkle.framework next to $SPARKLE_BIN"
need clang ditto hdiutil codesign lipo plutil python3 perl

S="$RELEASE_DIR"
REPO="$DEFAULT_REPO_ROOT"
TEST_NAME="ccemaphore-selftest"
TEST_BUNDLE_ID="com.example.ccemaphore-selftest"
SPARKLE_NS_URI="http://www.andymatuschak.org/xml-namespaces/sparkle"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccemaphore-release-selftest.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/logs" "$WORK/bin" "$WORK/dist" "$WORK/home" "$WORK/tmp"
export TMPDIR="$WORK/tmp" # clang and the scripts' mktemp leave nothing behind outside $WORK
# generate_appcast caches every archive it unpacks in ~/Library/Caches/Sparkle_generate_appcast (keyed by
# the archive's SHA-256). CoreFoundation's home override keeps the throwaway apps out of the real one;
# cleanup() also removes exactly our entries from the real cache, should the override not apply.
REAL_CACHE="$HOME/Library/Caches/Sparkle_generate_appcast"
REAL_CACHE_EXISTED=0
if [[ -d "$REAL_CACHE" ]]; then REAL_CACHE_EXISTED=1; fi
export CFFIXED_USER_HOME="$WORK/home"

detach_leftovers() { # DMGs of ours that something left mounted (only after an interrupted run)
  hdiutil info -plist 2>/dev/null | python3 -I -c '
import plistlib, re, sys
work = sys.argv[1]
for image in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
    if image.get("image-path", "").startswith(work):
        for entity in image.get("system-entities", []):
            if re.fullmatch(r"/dev/disk[0-9]+", entity.get("dev-entry", "")):
                print(entity["dev-entry"])
' "$WORK" | while IFS= read -r device; do hdiutil detach -force "$device" >/dev/null 2>&1 || true; done
}
purge_real_cache() { # our DMGs' entries in the real generate_appcast cache, if any got there
  local dmg hash
  for dmg in "$WORK"/dist/*.dmg; do
    [[ -f "$dmg" ]] || continue
    hash="$(shasum -a 256 "$dmg" | cut -c1-64)"
    rm -rf "${REAL_CACHE:?}/$hash" "${REAL_CACHE:?}/$hash.tmp"
  done
  if [[ $REAL_CACHE_EXISTED == 0 ]]; then rmdir "$REAL_CACHE" 2>/dev/null || true; fi
}
cleanup() {
  local status=$?
  set +e
  detach_leftovers
  purge_real_cache
  if [[ $KEEP == 1 ]]; then log "kept $WORK"; else rm -rf "$WORK"; fi
  exit $status
}
trap cleanup EXIT

PASSED=0
pass() { PASSED=$((PASSED + 1)); log "  PASS  $*"; }
step() { log ""; log "== $*"; }
logfile() { printf '%s/logs/%s.log' "$WORK" "${1//[^A-Za-z0-9._-]/_}"; }
fail_with_log() { sed 's/^/        | /' "$2" >&2; die "FAIL  $1"; }
# expect_ok <name> <command...>; the output stays in $(logfile <name>).
expect_ok() {
  local name=$1 out
  shift
  out="$(logfile "$name")"
  if "$@" >"$out" 2>&1; then pass "$name"; else fail_with_log "$name" "$out"; fi
}
# expect_fail <name> <regex the output must contain> <command...>: must fail, and for the RIGHT reason.
expect_fail() {
  local name=$1 pattern=$2 out
  shift 2
  out="$(logfile "$name")"
  if "$@" >"$out" 2>&1; then fail_with_log "$name: expected a failure, but it succeeded" "$out"; fi
  grep -Eq -- "$pattern" "$out" || fail_with_log "$name: failed, but not with /$pattern/" "$out"
  pass "$name (rejected: $(grep -Eo -- "$pattern" "$out" | head -1))"
}
check() { # check <name> <command...>
  local name=$1
  shift
  if "$@"; then pass "$name"; else die "FAIL  $name"; fi
}
is_universal() {
  local archs
  archs=" $(lipo -archs "$1") "
  [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]]
}
differs() { ! cmp -s "$1" "$2"; }

# --- fixtures -------------------------------------------------------------------------------------

step "fixtures: throwaway keys, a universal test executable"
A_SEED="$(py random-seed)" B_SEED="$(py random-seed)"
A_PUB="$(printf '%s\n' "$A_SEED" | py ed25519-public-key)"
B_PUB="$(printf '%s\n' "$B_SEED" | py ed25519-public-key)"
check "derived public keys are valid SUPublicEDKeys" py ed25519-check-public-key "$A_PUB"
printf 'int main(void) { return 0; }\n' >"$WORK/bin/main.c"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -o "$WORK/bin/$TEST_NAME" "$WORK/bin/main.c"
check "test executable is universal" is_universal "$WORK/bin/$TEST_NAME"

make_app() { # make_app <dir> <short-version> <build> <SUPublicEDKey> -> prints the .app path
  local app="$1/$TEST_NAME.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$TEST_NAME</string>
	<key>CFBundleIdentifier</key><string>$TEST_BUNDLE_ID</string>
	<key>CFBundleName</key><string>$TEST_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$2</string>
	<key>CFBundleVersion</key><string>$3</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>SUFeedURL</key><string>$FEED_URL</string>
	<key>SUPublicEDKey</key><string>$4</string>
	<key>SURequireSignedFeed</key><true/>
	<key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict>
</plist>
PLIST
  cp "$WORK/bin/$TEST_NAME" "$app/Contents/MacOS/$TEST_NAME"
  ditto "$FRAMEWORK" "$app/Contents/Frameworks/Sparkle.framework"
  cp "$REPO/Resources/ThirdPartyNotices.txt" "$app/Contents/Resources/ThirdPartyNotices.txt"
  printf '%s\n' "$app"
}

# package <n> <short-version> <build> <SUPublicEDKey>: app → sign → check → DMG, written to
# $WORK/dist/$TEST_NAME-<short-version>.dmg, notes to $WORK/notes-<n>.md. (Not run in a $(...) subshell:
# the PASS counter has to survive.)
package() {
  local n=$1 short=$2 build=$3 pub=$4 app
  app="$(make_app "$WORK/r$n" "$short" "$build" "$pub")"
  expect_ok "r$n sign-app.sh --adhoc" "$S/sign-app.sh" --app "$app" --adhoc
  check "r$n Sparkle's XPCServices removed" test ! -e "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
  check "r$n app signature verifies" codesign --verify --deep --strict "$app"
  expect_ok "r$n check-app.sh" "$S/check-app.sh" --app "$app" --short-version "$short" --build "$build" \
    --bundle-id "$TEST_BUNDLE_ID" --pubkey "$pub"
  expect_ok "r$n make-dmg.sh" "$S/make-dmg.sh" --app "$app" --out "$WORK/dist/$TEST_NAME-$short.dmg" --volname "$TEST_NAME"
  printf '### Added\n- Self-test release %s with **Markdown** notes.\n' "$n" >"$WORK/notes-$n.md"
}

# release <n> <short-version> <build> <prev-feed or ""> [<SUPublicEDKey> <its private key>] (default: key
# A): package → appcast → verify, exactly as CI does.
release() {
  local n=$1 short=$2 build=$3 prev=$4 pub=${5:-$A_PUB} seed=${6:-$A_SEED} dmg="$WORK/dist/$TEST_NAME-$2.dmg" prefix
  step "release $n: $short ($build)${prev:+, on top of the previous feed}"
  package "$n" "$short" "$build" "$pub"
  prefix="$DOWNLOAD_BASE/v$short-selftest/"
  # shellcheck disable=SC2086 # ${prev:+...} instead of an array: an empty array trips `set -u` in bash 3.2
  expect_ok "r$n make-appcast.sh" env SPARKLE_ED_PRIVATE_KEY="$seed" "$S/make-appcast.sh" --dmg "$dmg" --build "$build" \
    --notes "$WORK/notes-$n.md" --out-dir "$WORK/feed$n" --download-prefix "$prefix" --sparkle-bin "$SPARKLE_BIN" \
    --release-page "https://github.com/$REPO_SLUG/releases/tag/v$short-selftest" --pubkey "$pub" ${prev:+--prev-feed "$prev"}
  expect_ok "r$n verify-appcast.sh (+ sign_update)" env SPARKLE_ED_PRIVATE_KEY="$seed" "$S/verify-appcast.sh" \
    --feed "$WORK/feed$n/appcast.xml" --dmg "$dmg" --build "$build" --short-version "$short" \
    --url "$prefix$(basename "$dmg")" --min-os 13.0 --pubkey "$pub" --notes "$WORK/notes-$n.md" --sparkle-bin "$SPARKLE_BIN"
}

release 1 9.8.6 1000 ""
release 2 9.8.7 1001 "$WORK/feed1/appcast.xml"
DMG1="$WORK/dist/$TEST_NAME-9.8.6.dmg" DMG2="$WORK/dist/$TEST_NAME-9.8.7.dmg"
FEED2="$WORK/feed2/appcast.xml"
URL2="$DOWNLOAD_BASE/v9.8.7-selftest/$(basename "$DMG2")"

step "the second feed carries the first release over unchanged"
SUMMARY2="$(py feed-summary "$FEED2")"
check "feed 2 lists builds 1001,1000" grep -qx 'builds=1001,1000' <<<"$SUMMARY2"
check "feed 2 is signed" grep -qx 'signed=true' <<<"$SUMMARY2"
check "build 1000 keeps its own tag's URL" test "$(py feed-item "$FEED2" 1000 url)" = "$DOWNLOAD_BASE/v9.8.6-selftest/$(basename "$DMG1")"
check "build 1000 keeps its signature" test "$(py feed-item "$FEED2" 1000 ed_signature)" = "$(py feed-item "$WORK/feed1/appcast.xml" 1000 ed_signature)"
check "no hardware requirement for a universal app" test -z "$(grep -o 'hardwareRequirements' "$FEED2" || true)"
check "notes are embedded as Markdown" grep -q 'sparkle:format="markdown"' "$FEED2"

# --- negative cases -------------------------------------------------------------------------------

step "a wrong EdDSA private key"
expect_fail "make-appcast.sh refuses a key that is not SUPublicEDKey's" "does not belong to SUPublicEDKey" \
  env SPARKLE_ED_PRIVATE_KEY="$B_SEED" "$S/make-appcast.sh" --dmg "$DMG2" --build 1001 --notes "$WORK/notes-2.md" \
  --out-dir "$WORK/bad-key" --download-prefix "$DOWNLOAD_BASE/v9.8.7-selftest/" --sparkle-bin "$SPARKLE_BIN" \
  --pubkey "$A_PUB" --prev-feed "$WORK/feed1/appcast.xml"
expect_ok "generate_appcast itself exits 0 with the wrong key" \
  env SPARKLE_ED_PRIVATE_KEY="$B_SEED" "$S/make-appcast.sh" --dmg "$DMG2" --build 1001 --notes "$WORK/notes-2.md" \
  --out-dir "$WORK/bad-key" --download-prefix "$DOWNLOAD_BASE/v9.8.7-selftest/" --sparkle-bin "$SPARKLE_BIN" \
  --pubkey "$A_PUB" --prev-feed "$WORK/feed1/appcast.xml" --skip-key-check
check "  ... only warning that the item is left unsigned" grep -q "does not match key" "$(logfile "generate_appcast itself exits 0 with the wrong key")"
expect_fail "verify-appcast.sh rejects that feed" "no sparkle:edSignature|feed signature does not verify" \
  "$S/verify-appcast.sh" --feed "$WORK/bad-key/appcast.xml" --dmg "$DMG2" --build 1001 --short-version 9.8.7 \
  --url "$URL2" --min-os 13.0 --pubkey "$A_PUB"
sign_update_verify() { printf '%s\n' "$1" | "$SPARKLE_BIN/sign_update" --ed-key-file - --verify "${@:2}"; }
expect_fail "sign_update --verify: a signature over other bytes" "failed to pass signing verification" \
  sign_update_verify "$A_SEED" "$DMG1" "$(py feed-item "$FEED2" 1001 ed_signature)"
expect_fail "sign_update --verify: the feed under another key" "failed to pass signing verification" \
  sign_update_verify "$B_SEED" "$FEED2"

step "tampered or mismatched artifacts"
cp "$DMG2" "$WORK/appended.dmg"
printf 'x' >>"$WORK/appended.dmg"
expect_fail "a DMG with one extra byte" "enclosure length is" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$WORK/appended.dmg" --build 1001 --short-version 9.8.7 --url "$URL2" --min-os 13.0 --pubkey "$A_PUB"
cp "$DMG2" "$WORK/flipped.dmg"
python3 -I -c 'import sys; d = bytearray(open(sys.argv[1], "rb").read()); d[4096] ^= 0xFF; open(sys.argv[1], "wb").write(d)' "$WORK/flipped.dmg"
check "  (one byte flipped, same length)" differs "$DMG2" "$WORK/flipped.dmg"
expect_fail "a DMG with one flipped byte (same length)" "signature does not verify over" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$WORK/flipped.dmg" --build 1001 --short-version 9.8.7 --url "$URL2" --min-os 13.0 --pubkey "$A_PUB"
sed 's/Self-test release 2/Self-test release Z/' "$FEED2" >"$WORK/edited-feed.xml"
check "  (the edit changed the feed)" differs "$FEED2" "$WORK/edited-feed.xml"
expect_fail "a feed edited after signing" "feed signature does not verify" \
  "$S/verify-appcast.sh" --feed "$WORK/edited-feed.xml" --dmg "$DMG2" --build 1001 --short-version 9.8.7 --url "$URL2" --min-os 13.0 --pubkey "$A_PUB"
expect_fail "a different SUPublicEDKey" "does not verify" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$DMG2" --build 1001 --short-version 9.8.7 --url "$URL2" --min-os 13.0 --pubkey "$B_PUB"
expect_fail "an unexpected build number" "expected exactly one item with sparkle:version 1002" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$DMG2" --build 1002 --short-version 9.8.7 --url "$URL2" --min-os 13.0 --pubkey "$A_PUB"
expect_fail "an item that is not the newest" "is not the newest item" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$DMG1" --build 1000 --short-version 9.8.6 \
  --url "$DOWNLOAD_BASE/v9.8.6-selftest/$(basename "$DMG1")" --min-os 13.0 --pubkey "$A_PUB"
expect_fail "a wrong download URL" "enclosure URL is" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$DMG2" --build 1001 --short-version 9.8.7 --url "${URL2/v9.8.7/v0.0.0}" --min-os 13.0 --pubkey "$A_PUB"
expect_fail "a wrong minimum macOS" "minimumSystemVersion is" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$DMG2" --build 1001 --short-version 9.8.7 --url "$URL2" --min-os 14.0 --pubkey "$A_PUB"
expect_fail "release notes that differ" "release notes are missing or differ" \
  "$S/verify-appcast.sh" --feed "$FEED2" --dmg "$DMG2" --build 1001 --short-version 9.8.7 --url "$URL2" --min-os 13.0 --pubkey "$A_PUB" --notes "$WORK/notes-1.md"
expect_fail "a build number that did not go up" "is not above the previous feed's newest build 1001" \
  env SPARKLE_ED_PRIVATE_KEY="$A_SEED" "$S/make-appcast.sh" --dmg "$DMG2" --build 1001 --notes "$WORK/notes-2.md" \
  --out-dir "$WORK/no-bump" --download-prefix "$DOWNLOAD_BASE/v9.8.8-selftest/" --sparkle-bin "$SPARKLE_BIN" --pubkey "$A_PUB" --prev-feed "$FEED2"
expect_fail "make-appcast.sh refuses a non-empty output folder" "is not empty" \
  env SPARKLE_ED_PRIVATE_KEY="$A_SEED" "$S/make-appcast.sh" --dmg "$DMG2" --build 1002 --notes "$WORK/notes-2.md" \
  --out-dir "$WORK/feed2" --download-prefix "$DOWNLOAD_BASE/v9.8.8-selftest/" --sparkle-bin "$SPARKLE_BIN" --pubkey "$A_PUB"
expect_fail "check-app.sh: wrong build in the bundle" "CFBundleVersion is '1001', expected '1002'" \
  "$S/check-app.sh" --app "$WORK/r2/$TEST_NAME.app" --short-version 9.8.7 --build 1002 --bundle-id "$TEST_BUNDLE_ID" --pubkey "$A_PUB"
expect_fail "check-app.sh: another SUPublicEDKey in the bundle" "SUPublicEDKey is" \
  "$S/check-app.sh" --app "$WORK/r2/$TEST_NAME.app" --short-version 9.8.7 --build 1001 --bundle-id "$TEST_BUNDLE_ID" --pubkey "$B_PUB"
lipo -thin arm64 "$WORK/bin/$TEST_NAME" -output "$WORK/bin/$TEST_NAME-arm64"
THIN_APP="$(make_app "$WORK/thin" 9.8.7 1001 "$A_PUB")"
cp "$WORK/bin/$TEST_NAME-arm64" "$THIN_APP/Contents/MacOS/$TEST_NAME"
expect_fail "check-app.sh: an arm64-only executable" "not universal" \
  "$S/check-app.sh" --app "$THIN_APP" --short-version 9.8.7 --build 1001 --bundle-id "$TEST_BUNDLE_ID" --pubkey "$A_PUB"

# --- an EdDSA key rotation while the old key is still at hand (docs/RELEASING.md) ----------------------

step "key rotation: release 3 carries key B but is signed with key A, the key installed copies trust"
package 3 9.8.8 1002 "$B_PUB"
DMG3="$WORK/dist/$TEST_NAME-9.8.8.dmg" PREFIX3="$DOWNLOAD_BASE/v9.8.8-selftest/" FEED3="$WORK/feed3/appcast.xml"
URL3="${PREFIX3}$(basename "$DMG3")"
rotate() { # rotate <private key> <out-dir> [make-appcast.sh options]: release 3's feed on top of feed 2
  local seed=$1 out=$2
  shift 2
  env SPARKLE_ED_PRIVATE_KEY="$seed" "$S/make-appcast.sh" --dmg "$DMG3" --build 1002 --notes "$WORK/notes-3.md" \
    --out-dir "$out" --download-prefix "$PREFIX3" --sparkle-bin "$SPARKLE_BIN" --prev-feed "$FEED2" \
    --release-page "https://github.com/$REPO_SLUG/releases/tag/v9.8.8-selftest" --pubkey "$B_PUB" "$@"
}
expect_fail "without --signing-pubkey, the old key is refused for an app with the new one" "does not belong to SUPublicEDKey" \
  rotate "$A_SEED" "$WORK/rotate-plain"
expect_fail "--signing-pubkey needs that key's private key" "does not belong to --signing-pubkey" \
  rotate "$B_SEED" "$WORK/rotate-wrong" --signing-pubkey "$A_PUB"
expect_fail "--signing-pubkey equal to the app's own key" "only for a key rotation" \
  rotate "$B_SEED" "$WORK/rotate-same" --signing-pubkey "$B_PUB"
expect_ok "r3 make-appcast.sh --signing-pubkey <key A>" rotate "$A_SEED" "$WORK/feed3" --signing-pubkey "$A_PUB"
check "  ... generate_appcast alone would have left the item unsigned" grep -q "does not match key" "$(logfile "r3 make-appcast.sh --signing-pubkey <key A>")"
expect_ok "r3 verify-appcast.sh against key A (+ sign_update)" env SPARKLE_ED_PRIVATE_KEY="$A_SEED" "$S/verify-appcast.sh" \
  --feed "$FEED3" --dmg "$DMG3" --build 1002 --short-version 9.8.8 --url "$URL3" --min-os 13.0 --pubkey "$A_PUB" \
  --notes "$WORK/notes-3.md" --sparkle-bin "$SPARKLE_BIN"
expect_fail "  ... and the feed is not signed with key B" "feed signature does not verify" \
  "$S/verify-appcast.sh" --feed "$FEED3" --dmg "$DMG3" --build 1002 --short-version 9.8.8 --url "$URL3" --min-os 13.0 --pubkey "$B_PUB"
check "feed 3 lists builds 1002,1001,1000" grep -qx 'builds=1002,1001,1000' <<<"$(py feed-summary "$FEED3")"
check "build 1001 keeps its signature through the rotation" test "$(py feed-item "$FEED3" 1001 ed_signature)" = "$(py feed-item "$FEED2" 1001 ed_signature)"
check "the notes stay embedded as Markdown" grep -q 'sparkle:format="markdown"' "$FEED3"
cp "$FEED3" "$WORK/rotated-twice.xml"
expect_fail "feed-set-ed-signature refuses an item that is already signed" "already signed" \
  py feed-set-ed-signature "$WORK/rotated-twice.xml" 1002 "$(py feed-item "$FEED3" 1002 ed_signature)"
release 4 9.8.9 1003 "$FEED3" "$B_PUB" "$B_SEED"
check "after the rotation, feed 4 (key B) lists builds 1003,1002,1001" \
  grep -qx 'builds=1003,1002,1001' <<<"$(py feed-summary "$WORK/feed4/appcast.xml")"

# --- the release job's tag check (lib.sh assert_tag_at) against a stand-in gh ------------------------

step "assert_tag_at: the tag must still point at the commit the run builds"
mkdir -p "$WORK/fakebin"
cat >"$WORK/fakebin/gh" <<'SH'
#!/bin/bash
# Stand-in for `gh api repos/<repo>/commits/refs/tags/<tag> --jq .sha`: answers $FAKE_TAG_SHA, or fails the
# way GitHub does for a tag that no longer exists when it is empty.
[[ "$1" == api && "$2" == repos/*/commits/refs/tags/* ]] || { echo "fake gh: unexpected call: $*" >&2; exit 2; }
# FAKE_GH_FLAKY names a file holding how many calls fail like a GitHub outage before the answer comes.
if [[ -n "${FAKE_GH_FLAKY:-}" && -s "$FAKE_GH_FLAKY" ]] && (( $(<"$FAKE_GH_FLAKY") > 0 )); then
  echo $(( $(<"$FAKE_GH_FLAKY") - 1 )) >"$FAKE_GH_FLAKY"
  echo "gh: HTTP 502: Bad Gateway (https://api.github.com/${2})" >&2
  exit 1
fi
if [[ -n "${FAKE_TAG_SHA:-}" ]]; then printf '%s\n' "$FAKE_TAG_SHA"; exit 0; fi
echo "gh: No commit found for SHA: ${2#*/commits/} (HTTP 422)" >&2
exit 1
SH
chmod +x "$WORK/fakebin/gh"
BUILT_SHA=0123456789abcdef0123456789abcdef01234567 MOVED_SHA=89abcdef0123456789abcdef0123456789abcdef
tag_check() { # tag_check <what GitHub answers>
  env PATH="$WORK/fakebin:$PATH" FAKE_TAG_SHA="$1" bash -c 'source "$1/lib.sh"; assert_tag_at v9.8.7 "$2"' _ "$S" "$BUILT_SHA"
}
expect_ok "the tag still points at the built commit" tag_check "$BUILT_SHA"
expect_fail "the tag was moved" "now points at $MOVED_SHA" tag_check "$MOVED_SHA"
expect_fail "the tag was deleted" "cannot resolve tag v9.8.7" tag_check ""
deleted_tag_not_retried() { # a 4xx (here 422) is GitHub's answer: it must fail at once, with no retry
  local out
  out="$(TAG_CHECK_RETRY_DELAY=0 tag_check "" 2>&1)" && return 1
  [[ "$out" != *retrying* && "$out" == *"cannot resolve tag v9.8.7"* ]]
}
check "  ... at once, without a retry" deleted_tag_not_retried
expect_fail "an answer that is not a commit" "unexpected answer" tag_check "not-a-sha"
tag_check_flaky() { # tag_check_flaky <calls that fail like an outage before GitHub answers the built commit>
  printf '%s\n' "$1" >"$WORK/gh-flaky"
  env PATH="$WORK/fakebin:$PATH" FAKE_TAG_SHA="$BUILT_SHA" FAKE_GH_FLAKY="$WORK/gh-flaky" TAG_CHECK_RETRY_DELAY=0 \
    bash -c 'source "$1/lib.sh"; assert_tag_at v9.8.7 "$2"' _ "$S" "$BUILT_SHA"
}
expect_ok "a transient GitHub error is retried" tag_check_flaky 2
expect_fail "a GitHub error that persists fails closed" "cannot resolve tag v9.8.7" tag_check_flaky 9

# --- how smoke-test.sh reads `--update-status` ----------------------------------------------------------

step "smoke-test.sh and the launch gate row the app prints"
APP_STATUS_SOURCE="$REPO/Sources/ccemaphore/UpdateSupport.swift"
# Anchored to the code line itself (indent, then the call): the CI CONTRACT comment above it in
# UpdateSupport.swift names the row too, and a bare substring grep would pass on that comment alone.
check "UpdateSupport.printStatus() still prints the 'launch gate' row" \
  grep -Eq '^[[:space:]]+row\("launch gate", describe\(launchGate\(\)\)\)[[:space:]]*$' "$APP_STATUS_SOURCE"
check "  ... and describe(.enabled) still starts with 'enabled'" grep -Eq 'case \.enabled: return "enabled([^A-Za-z]|")' "$APP_STATUS_SOURCE"
fake_cli() { # fake_cli <dir> <what --update-status prints>: a stand-in for the signed app's executable
  local app="$1/$TEST_NAME.app"
  mkdir -p "$app/Contents/MacOS"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>%s</string><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' \
    "$TEST_NAME" "$TEST_BUNDLE_ID" >"$app/Contents/Info.plist"
  printf '%s\n' "$2" >"$app/Contents/MacOS/status.txt"
  cat >"$app/Contents/MacOS/$TEST_NAME" <<'SH'
#!/bin/bash
case "$1" in
  --help) echo "Usage: stand-in [options]" ;;
  --update-status) cat "$(dirname "$0")/status.txt" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$app/Contents/MacOS/$TEST_NAME"
}
gate_row() { printf '  %-32s%s' "launch gate" "$1"; } # UpdateSupport.printStatus's row(): two spaces, label padded to 32
fake_cli "$WORK/smoke-enabled" "$(printf 'ccemaphore — in-app updater status\n\n%s\n%s' "$(gate_row "enabled — Sparkle starts")" "$(printf '  %-32s%s' SUFeedURL x)")"
expect_ok "smoke-test.sh: launch gate enabled" "$S/smoke-test.sh" --app "$WORK/smoke-enabled/$TEST_NAME.app"
fake_cli "$WORK/smoke-unsigned" "$(gate_row "notDeveloperIDSigned — local build, never swapped for the release")"
expect_fail "smoke-test.sh: a launch gate that is not enabled" "launch gate is 'notDeveloperIDSigned'" \
  "$S/smoke-test.sh" --app "$WORK/smoke-unsigned/$TEST_NAME.app"
fake_cli "$WORK/smoke-reworded" "$(printf '  %-32s%s' "updater" "enabled")"
expect_fail "smoke-test.sh: a reworded status (no 'launch gate' row)" "printed no 'launch gate' row" \
  "$S/smoke-test.sh" --app "$WORK/smoke-reworded/$TEST_NAME.app"

# --- check-version.sh / extract-notes.sh against a scratch copy of the repository files ------------

step "check-version.sh and extract-notes.sh"
FAKE="$WORK/repo"
reset_fake_repo() {
  rm -rf "$FAKE"
  mkdir -p "$FAKE/Resources" "$FAKE/ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  cp "$REPO/ccemaphore.xcodeproj/project.pbxproj" "$FAKE/ccemaphore.xcodeproj/"
  cp "$REPO/ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "$FAKE/ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/"
  cp "$REPO/Resources/Info.plist" "$FAKE/Resources/"
  plutil -replace SUPublicEDKey -string "$A_PUB" "$FAKE/Resources/Info.plist"
  cp "$REPO/CHANGELOG.md" "$FAKE/"
}
reset_fake_repo
PBX="$FAKE/ccemaphore.xcodeproj/project.pbxproj"
MARKETING="$(py pbxproj-setting "$PBX" MARKETING_VERSION)" BUILD="$(py pbxproj-setting "$PBX" CURRENT_PROJECT_VERSION)"
TAG="v$MARKETING"
cv() { "$S/check-version.sh" --repo-root "$FAKE" --skip-release-scan "$@"; }
cat >"$WORK/old-feed.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="$SPARKLE_NS_URI"><channel><title>old</title>
<item><title>0.0.1</title><sparkle:version>$((BUILD - 1))</sparkle:version><sparkle:shortVersionString>0.0.1</sparkle:shortVersionString>
<enclosure url="https://example.invalid/a.dmg" length="1" type="application/octet-stream"/></item>
</channel></rss>
XML

expect_ok "a stable tag matching the project ($TAG, build $BUILD), first release" cv --tag "$TAG" --no-feed
check "  ... reports a stable release" grep -qx 'is_prerelease=false' "$(logfile "a stable tag matching the project ($TAG, build $BUILD), first release")"
expect_ok "a stable tag over an older live feed" cv --tag "$TAG" --feed-file "$WORK/old-feed.xml"
expect_ok "a prerelease tag" cv --tag "$TAG-rc.1" --no-feed
check "  ... reports a prerelease" grep -qx 'is_prerelease=true' "$(logfile "a prerelease tag")"
for bad_tag in "${TAG%.*}" "$TAG.1" "${TAG#v}" "$TAG-" "$TAG+build.5" "$TAG-rc_1" "x$TAG"; do
  expect_fail "tag '$bad_tag' is refused" "is not releasable" cv --tag "$bad_tag" --no-feed
done
NEXT_MINOR="$(awk -F. '{ printf "%d.%d.0", $1, $2 + 1 }' <<<"$MARKETING")"
expect_fail "a tag that is not MARKETING_VERSION" "MARKETING_VERSION is $MARKETING but the tag says $NEXT_MINOR" cv --tag "v$NEXT_MINOR" --no-feed
expect_fail "a build not above every published build" "must be greater than 1001" cv --tag "$TAG-rc.2" --feed-file "$FEED2"
expect_fail "a stable version not above the live feed's" "is not above the live feed's 9.8.7" cv --tag "$TAG" --feed-file "$FEED2"

plutil -replace SUPublicEDKey -string "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" "$FAKE/Resources/Info.plist"
expect_fail "the SUPublicEDKey placeholder" "still the placeholder" cv --tag "$TAG" --no-feed
plutil -replace SUPublicEDKey -string "$(printf 'not a key' | base64)" "$FAKE/Resources/Info.plist"
expect_fail "an SUPublicEDKey that is not an Ed25519 key" "decodes to 9 bytes" cv --tag "$TAG" --no-feed
reset_fake_repo
plutil -replace CFBundleVersion -string "$BUILD" "$FAKE/Resources/Info.plist"
expect_fail "a literal CFBundleVersion in Info.plist" "must keep CFBundleVersion" cv --tag "$TAG" --no-feed
reset_fake_repo
plutil -replace SUFeedURL -string "https://example.invalid/appcast.xml" "$FAKE/Resources/Info.plist"
expect_fail "another SUFeedURL" "SUFeedURL must be" cv --tag "$TAG" --no-feed
reset_fake_repo
plutil -replace SURequireSignedFeed -bool NO "$FAKE/Resources/Info.plist"
expect_fail "SURequireSignedFeed off" "SURequireSignedFeed" cv --tag "$TAG" --no-feed
reset_fake_repo
perl -0pi -e "s/^## \\[\Q$MARKETING\E\\]/## [0.0.0-removed]/m" "$FAKE/CHANGELOG.md"
expect_fail "no CHANGELOG section" "has no '## \\[$MARKETING\\]' section" cv --tag "$TAG" --no-feed
reset_fake_repo
RESOLVED="$FAKE/ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
perl -pi -e 's/("version" : ")(\d+\.\d+\.\d+)(")/${1}0.0.1${3}/ if /"version" : "\d+\.\d+\.\d+"/' "$RESOLVED"
expect_fail "Package.resolved out of sync with the project" "Package.resolved pins sparkle 0.0.1" cv --tag "$TAG" --no-feed
rm -f "$RESOLVED"
expect_fail "Package.resolved missing" "Package.resolved is missing" cv --tag "$TAG" --no-feed
reset_fake_repo
# Xcode's General tab writes Version/Build at the TARGET level; that value wins (with a warning).
perl -0pi -e "s/(INFOPLIST_FILE = Resources\\/Info.plist;\\n)/\${1}\\t\\t\\t\\tMARKETING_VERSION = $NEXT_MINOR;\\n/g" "$PBX"
check "target-level MARKETING_VERSION overrides the project level" test "$(py pbxproj-setting "$PBX" MARKETING_VERSION 2>/dev/null)" = "$NEXT_MINOR"
check "  ... same answer as plutil's parse" test "$(plutil -convert json -o - "$PBX" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); o = d["objects"]
target = [v for v in o.values() if v.get("isa") == "PBXNativeTarget" and v.get("name") == "ccemaphore"][0]
project = o[d["rootObject"]]
def configs(i): return {o[c]["name"]: o[c]["buildSettings"] for c in o[i]["buildConfigurations"]}
t, p = configs(target["buildConfigurationList"]), configs(project["buildConfigurationList"])
print(",".join(sorted({t[n].get("MARKETING_VERSION", p[n].get("MARKETING_VERSION")) for n in t})))')" = "$NEXT_MINOR"
expect_fail "the old tag once the target says $NEXT_MINOR" "MARKETING_VERSION is $NEXT_MINOR but the tag says $MARKETING" cv --tag "$TAG" --no-feed
reset_fake_repo
perl -0pi -e "s/(INFOPLIST_FILE = Resources\\/Info.plist;\\n)/\${1}\\t\\t\\t\\tMARKETING_VERSION = $NEXT_MINOR;\\n/" "$PBX"
expect_fail "Debug and Release disagree" "MARKETING_VERSION differs between build configurations" cv --tag "v$NEXT_MINOR" --no-feed
reset_fake_repo

expect_ok "extract-notes.sh: stable" "$S/extract-notes.sh" "$MARKETING" "$WORK/notes/stable.md" --changelog "$FAKE/CHANGELOG.md"
check "  ... matches the CHANGELOG section" cmp -s "$WORK/notes/stable.md" <(py changelog-section "$FAKE/CHANGELOG.md" "$MARKETING")
check "  ... without the heading or link references" test -z "$(grep -E '^## |^\[[^]]+\]: ' "$WORK/notes/stable.md" || true)"
expect_ok "extract-notes.sh: a prerelease falls back to its version's section" "$S/extract-notes.sh" "$MARKETING-rc.1" "$WORK/notes/rc.md" --changelog "$FAKE/CHANGELOG.md"
check "  ... same notes" cmp -s "$WORK/notes/stable.md" "$WORK/notes/rc.md"
expect_fail "extract-notes.sh: an unknown version" "no release notes for 0.0.0" "$S/extract-notes.sh" 0.0.0 "$WORK/notes/none.md" --changelog "$FAKE/CHANGELOG.md"

# --- hygiene ----------------------------------------------------------------------------------------

step "nothing leaked"
# make-appcast.sh hands generate_appcast a throwaway home, so its archive cache (an unpacked, signed
# copy of every app it read) ends up in neither the test's home nor the real one, and is deleted.
check "generate_appcast's cache is not in the test's home" test ! -e "$WORK/home/Library/Caches/Sparkle_generate_appcast"
check "  ... nor in the real one" test ! -e "$REAL_CACHE/$(shasum -a 256 "$DMG2" | cut -c1-64)"
check "  ... and make-appcast.sh removed its throwaway home" \
  test -z "$(find "$WORK/tmp" -name Sparkle_generate_appcast -print 2>/dev/null | head -1)"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -dump >"$WORK/lsregister.txt" 2>/dev/null || true
  if grep -q "$TEST_BUNDLE_ID" "$WORK/lsregister.txt"; then
    sed -n 's/^path: *\(.*ccemaphore-selftest\.app\).*/\1/p' "$WORK/lsregister.txt" | while IFS= read -r stray; do
      "$LSREGISTER" -u "$stray" 2>/dev/null || true
    done
    die "FAIL  LaunchServices registered a self-test app (unregistered it again)"
  fi
  pass "LaunchServices never saw the self-test apps"
fi

log ""
log "selftest: all $PASSED checks passed (Sparkle tools: $SPARKLE_BIN)"
