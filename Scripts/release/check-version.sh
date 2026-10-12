#!/usr/bin/env bash
# Preflight release gate — needs no secrets, so CI runs it before the `release` environment's approval.
#
#   check-version.sh --tag v1.3.0 [--repo-root DIR] [--feed-file FILE | --no-feed]
#                    [--skip-release-scan] [--require-on-main]
#
# Refuses the tag unless all of these hold:
#   1. it is vX.Y.Z (stable) or vX.Y.Z-<suffix> (prerelease, e.g. v1.3.0-rc.1);
#   2. project.pbxproj has one effective MARKETING_VERSION and CURRENT_PROJECT_VERSION across Debug and
#      Release, MARKETING_VERSION == X.Y.Z and CURRENT_PROJECT_VERSION is a positive integer;
#   3. Resources/Info.plist takes its versions from those settings and carries the updater keys: the
#      canonical SUFeedURL, SURequireSignedFeed, SUVerifyUpdateBeforeExtraction and a real Ed25519
#      SUPublicEDKey (never the placeholder);
#   4. CHANGELOG.md has a "## [X.Y.Z]" section (a prerelease may have its own "## [X.Y.Z-suffix]");
#   5. Package.resolved is committed and pins Sparkle to the exact version the project requires;
#   6. CURRENT_PROJECT_VERSION is above every sparkle:version ever published — the live stable feed AND
#      each release's own appcast.xml (prereleases consume build numbers too) — and a stable X.Y.Z is
#      above the newest version in the live feed; no published release exists for this tag yet;
#   7. with --require-on-main, a stable tag points at a commit on origin/main.
#
# Outputs (stdout, and $GITHUB_OUTPUT in Actions): version, short_version, build, is_prerelease,
# make_latest, dmg_name.
#   --feed-file FILE      use this file as the live stable feed instead of downloading it (tests)
#   --no-feed             behave as if no stable feed exists yet (tests)
#   --skip-release-scan   don't list the repository's releases (tests, or no `gh` available locally)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

TAG="" REPO_ROOT="$DEFAULT_REPO_ROOT" FEED_FILE="" NO_FEED=0 SKIP_SCAN=0 REQUIRE_ON_MAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG=$2; shift 2 ;;
    --repo-root) REPO_ROOT=$2; shift 2 ;;
    --feed-file) FEED_FILE=$2; shift 2 ;;
    --no-feed) NO_FEED=1; shift ;;
    --skip-release-scan) SKIP_SCAN=1; shift ;;
    --require-on-main) REQUIRE_ON_MAIN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$TAG" ]] || die "usage: check-version.sh --tag vX.Y.Z[-suffix] [options]"
need python3 curl

PBXPROJ="$REPO_ROOT/ccemaphore.xcodeproj/project.pbxproj"
RESOLVED="$REPO_ROOT/ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PLIST="$REPO_ROOT/Resources/Info.plist"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The tag.
if [[ "$TAG" =~ $STABLE_TAG_RE ]]; then
  SHORT_VERSION="${BASH_REMATCH[1]}" IS_PRERELEASE=false
elif [[ "$TAG" =~ $PRERELEASE_TAG_RE ]]; then
  SHORT_VERSION="${BASH_REMATCH[1]}" IS_PRERELEASE=true
else
  die "tag '$TAG' is not releasable: use vX.Y.Z for a release or vX.Y.Z-<suffix> (e.g. v1.3.0-rc.1) for a prerelease"
fi
VERSION="${TAG#v}"
log "tag $TAG: version $VERSION ($([[ $IS_PRERELEASE == true ]] && echo prerelease || echo stable))"

# 2. Project versions — the single source of truth Info.plist expands at build time.
MARKETING="$(py pbxproj-setting "$PBXPROJ" MARKETING_VERSION)" || die "cannot determine MARKETING_VERSION (see above)"
BUILD="$(py pbxproj-setting "$PBXPROJ" CURRENT_PROJECT_VERSION)" || die "cannot determine CURRENT_PROJECT_VERSION (see above)"
[[ "$MARKETING" == "$SHORT_VERSION" ]] ||
  die "MARKETING_VERSION is $MARKETING but the tag says $SHORT_VERSION - bump the version in Xcode (or fix the tag)"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] ||
  die "CURRENT_PROJECT_VERSION must be a positive integer (Sparkle orders updates by it); it is '$BUILD'"
log "project: MARKETING_VERSION $MARKETING, CURRENT_PROJECT_VERSION $BUILD"

# 3. Info.plist.
[[ "$(plist_get "$PLIST" CFBundleShortVersionString)" == '$(MARKETING_VERSION)' ]] ||
  die "Resources/Info.plist must keep CFBundleShortVersionString = \$(MARKETING_VERSION)"
[[ "$(plist_get "$PLIST" CFBundleVersion)" == '$(CURRENT_PROJECT_VERSION)' ]] ||
  die "Resources/Info.plist must keep CFBundleVersion = \$(CURRENT_PROJECT_VERSION)"
[[ "$(plist_get "$PLIST" SUFeedURL)" == "$FEED_URL" ]] ||
  die "Resources/Info.plist SUFeedURL must be $FEED_URL (every installed copy polls it)"
[[ "$(plist_get "$PLIST" SURequireSignedFeed)" == true ]] || die "Resources/Info.plist must set SURequireSignedFeed = YES"
[[ "$(plist_get "$PLIST" SUVerifyUpdateBeforeExtraction)" == true ]] ||
  die "Resources/Info.plist must set SUVerifyUpdateBeforeExtraction = YES"
PUBKEY="$(plist_get "$PLIST" SUPublicEDKey)"
py ed25519-check-public-key "$PUBKEY" || die "Resources/Info.plist has no usable SUPublicEDKey"
log "Info.plist: updater keys present, SUPublicEDKey is a valid Ed25519 key"

# 4. Release notes.
NOTE_VERSIONS=("$SHORT_VERSION")
if [[ "$IS_PRERELEASE" == true ]]; then NOTE_VERSIONS=("$VERSION" "$SHORT_VERSION"); fi
py changelog-section "$CHANGELOG" "${NOTE_VERSIONS[@]}" >"$WORK/notes.md" ||
  die "add a '## [$SHORT_VERSION] - YYYY-MM-DD' section to CHANGELOG.md (see above)"
log "CHANGELOG.md: release notes found ($(wc -l <"$WORK/notes.md" | tr -d ' ') lines)"

# 5. Package pins — the release job builds with -onlyUsePackageVersionsFromResolvedFile.
SPARKLE_VERSION="$(py package-pin "$PBXPROJ" "$RESOLVED" sparkle)" || die "the Sparkle package pin is not releasable (see above)"
log "Package.resolved: Sparkle $SPARKLE_VERSION (exact)"

# 6. Build numbers must only ever grow, across everything ever published.
MAX_BUILD=0 MAX_SOURCE="nothing published yet"
note_feed() { # note_feed <feed-file> <label>
  local summary build
  summary="$(py feed-summary "$1")" || die "cannot read the appcast of $2 (see above)"
  build="$(sed -n 's/^max_build=//p' <<<"$summary")"
  [[ -n "$build" ]] || return 0
  if [[ "$(py version-compare "$build" "$MAX_BUILD")" == 1 ]]; then MAX_BUILD=$build MAX_SOURCE=$2; fi
}

LIVE_FEED="$WORK/live-appcast.xml"
if [[ $NO_FEED == 1 ]]; then
  :
elif [[ -n "$FEED_FILE" ]]; then
  cp "$FEED_FILE" "$LIVE_FEED"
else
  fetch_feed "$FEED_URL" "$LIVE_FEED"
fi
if [[ -f "$LIVE_FEED" ]]; then
  note_feed "$LIVE_FEED" "the live feed"
  LIVE_SHORT="$(py feed-summary "$LIVE_FEED" | sed -n 's/^max_short_version=//p')"
  log "live feed: newest build $MAX_BUILD, newest version ${LIVE_SHORT:-?}"
  if [[ "$IS_PRERELEASE" == false && -n "$LIVE_SHORT" && "$(py version-compare "$SHORT_VERSION" "$LIVE_SHORT")" != 1 ]]; then
    die "version $SHORT_VERSION is not above the live feed's $LIVE_SHORT - a stable release must move forward"
  fi
else
  log "live feed: none yet (HTTP 404) - this is the first release with the updater"
fi

if [[ $SKIP_SCAN == 1 ]]; then
  warn "skipping the scan of published releases (--skip-release-scan)"
elif ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  [[ -z "${GITHUB_ACTIONS:-}" ]] || die "gh is not available/authenticated - set GH_TOKEN for this step"
  warn "gh is not available/authenticated - not scanning published releases"
else
  # Every published release (prereleases included) that carries an appcast.xml.
  gh api --paginate "repos/$REPO_SLUG/releases?per_page=100" \
    --jq '.[] | select(.draft | not) | [.tag_name, ([.assets[] | select(.name == "appcast.xml") | .browser_download_url] | first // "")] | @tsv' \
    >"$WORK/releases.tsv" || die "cannot list the releases of $REPO_SLUG"
  while IFS=$'\t' read -r release_tag appcast_url; do
    [[ "$release_tag" != "$TAG" ]] ||
      die "a published release for $TAG already exists - releases are immutable here; delete it first or tag a new version"
    [[ -n "$appcast_url" ]] || continue
    fetch_feed "$appcast_url" "$WORK/release-appcast.xml"
    if [[ -f "$WORK/release-appcast.xml" ]]; then note_feed "$WORK/release-appcast.xml" "release $release_tag"; fi
  done <"$WORK/releases.tsv"
  log "published releases: $(wc -l <"$WORK/releases.tsv" | tr -d ' ') scanned"
fi
[[ "$(py version-compare "$BUILD" "$MAX_BUILD")" == 1 ]] ||
  die "CURRENT_PROJECT_VERSION $BUILD must be greater than $MAX_BUILD (from $MAX_SOURCE) - Sparkle would not offer it; bump it in Xcode"
log "build $BUILD is above everything published (max $MAX_BUILD)"

# 7. Stable releases ship from main.
if [[ $REQUIRE_ON_MAIN == 1 && "$IS_PRERELEASE" == false ]]; then
  git -C "$REPO_ROOT" rev-parse --verify --quiet origin/main >/dev/null ||
    die "origin/main is not available in this checkout (fetch-depth: 0 is required)"
  git -C "$REPO_ROOT" merge-base --is-ancestor HEAD origin/main ||
    die "stable tag $TAG is not on main - push the commit to main first (prereleases may come from any branch)"
  log "the tagged commit is on main"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### %s %s\n\n' "$APP_NAME" "$VERSION"
    printf '| | |\n|---|---|\n'
    printf '| Kind | %s |\n' "$([[ $IS_PRERELEASE == true ]] && echo 'prerelease (not served to users)' || echo 'stable (served to every installed copy)')"
    printf '| CFBundleShortVersionString / CFBundleVersion | %s / %s |\n' "$SHORT_VERSION" "$BUILD"
    printf '| Highest build published so far | %s (%s) |\n' "$MAX_BUILD" "$MAX_SOURCE"
    printf '| Sparkle | %s |\n\n' "$SPARKLE_VERSION"
    printf '#### Release notes (from CHANGELOG.md)\n\n'
    cat "$WORK/notes.md"
  } >>"$GITHUB_STEP_SUMMARY"
fi

set_output version "$VERSION"
set_output short_version "$SHORT_VERSION"
set_output build "$BUILD"
set_output is_prerelease "$IS_PRERELEASE"
set_output make_latest "$([[ $IS_PRERELEASE == true ]] && echo false || echo true)"
set_output dmg_name "$(dmg_name "$VERSION")"
