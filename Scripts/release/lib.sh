# shellcheck shell=bash
# Shared helpers for Scripts/release/*.sh — sourced, never executed.
#
# The constants below are the distribution contract baked into every shipped build (Resources/Info.plist
# SUFeedURL): installed copies poll FEED_URL forever, so changing it (or renaming the repository without
# keeping the old URL serving) strands them. See docs/RELEASING.md.

[[ -n "${CCEM_RELEASE_LIB:-}" ]] && return 0
CCEM_RELEASE_LIB=1

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$RELEASE_DIR/../.." && pwd)"

REPO_SLUG="hakkazuu/ccemaphore"
FEED_URL="https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml"
DOWNLOAD_BASE="https://github.com/$REPO_SLUG/releases/download"
APP_NAME="ccemaphore"
BUNDLE_ID="com.hakkazuu.ccemaphore"
# vX.Y.Z is a stable release (served to every installed copy); vX.Y.Z-<suffix> is a prerelease (never
# "latest", so only a Mac pointed at its own appcast sees it). Nothing else is releasable.
STABLE_TAG_RE='^v([0-9]+\.[0-9]+\.[0-9]+)$'
PRERELEASE_TAG_RE='^v([0-9]+\.[0-9]+\.[0-9]+)-[0-9A-Za-z.-]+$'

log() { printf '%s\n' "$*" >&2; }

warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::warning::%s\n' "$*" >&2; else printf 'warning: %s\n' "$*" >&2; fi
}

die() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::error::%s\n' "$*" >&2; else printf 'error: %s\n' "$*" >&2; fi
  exit 1
}

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
}

# The Python helper (standard library only); -I keeps the environment and user site-packages out of it.
py() { python3 -I "$RELEASE_DIR/release_tool.py" "$@"; }

plist_get() { py plist-get "$1" "$2"; }

# set_output <key> <value>: a job output in GitHub Actions, and always echoed for logs / local runs.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
  printf '%s=%s\n' "$1" "$2"
}

# with_timeout <seconds> <command...>: SIGALRM survives exec, so a hung command is killed (exit 142).
with_timeout() {
  local seconds=$1
  shift
  perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$seconds" "$@"
}

# fetch_feed <url> <out-file>: downloads a feed over https only. On HTTP 404 (no Sparkle release there
# yet) it leaves no file and returns 0; any other failure is fatal — an outage must never be mistaken
# for "first release", which would skip the version guards.
fetch_feed() {
  local url=$1 out=$2 code
  rm -f "$out" "$out.part"
  code=$(curl -sS -L --proto '=https' --proto-redir '=https' --retry 4 --retry-delay 5 \
    --connect-timeout 20 --max-time 120 -o "$out.part" -w '%{http_code}' "$url") ||
    die "could not fetch $url (curl exit $?)"
  case "$code" in
    200) mv "$out.part" "$out" || die "could not write $out" ;;
    404) rm -f "$out.part" ;;
    *)
      rm -f "$out.part"
      die "unexpected HTTP $code fetching $url"
      ;;
  esac
}

# The DMG's file name; also the basename generate_appcast pairs the release notes (.md) with.
dmg_name() { printf '%s-%s.dmg' "$APP_NAME" "$1"; }

# assert_tag_at <tag> <commit-sha>: the tag on GitHub still points at the commit this run builds.
# A workflow run keeps its GITHUB_SHA while it waits for approval and when it is re-run, even after the
# tag was moved or deleted - without this check it would publish that old commit under the tag.
# commits/refs/tags/<tag> resolves annotated and lightweight tags to their commit; a deleted tag makes
# the call fail (HTTP 422). Needs an authenticated `gh` (GH_TOKEN in Actions). A failure that isn't
# GitHub's answer (a 5xx, the network) is retried a few times before it fails closed: the second check
# runs after notarization, and re-running the job repeats the whole build. TAG_CHECK_RETRY_DELAY (seconds,
# default 10, multiplied by the attempt) exists for selftest.sh.
assert_tag_at() {
  local tag=$1 sha=$2 out repo="${GITHUB_REPOSITORY:-$REPO_SLUG}" attempt delay="${TAG_CHECK_RETRY_DELAY:-10}"
  need gh
  for attempt in 1 2 3 4; do
    out="$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha 2>&1)" && break
    if [[ "$out" == *"(HTTP 4"[0-9][0-9]")"* || $attempt -eq 4 ]]; then
      die "cannot resolve tag $tag on GitHub: $out - if the tag was deleted, cancel this run"
    fi
    log "resolving tag $tag failed ($out) - retrying in $((attempt * delay))s"
    sleep $((attempt * delay))
  done
  [[ "$out" =~ ^[0-9a-f]{40}$ ]] || die "unexpected answer resolving tag $tag on GitHub: $out"
  [[ "$out" == "$sha" ]] ||
    die "tag $tag now points at $out, but this run builds $sha - the tag was moved: cancel or reject this run (the run the moved tag started releases it)"
  log "ok: tag $tag still points at $sha"
}
