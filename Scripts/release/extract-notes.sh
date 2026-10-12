#!/usr/bin/env bash
# Writes this version's CHANGELOG.md section — the release notes for both the GitHub Release body and
# the appcast (embedded as Markdown, so the update UI shows them and the feed signature covers them).
#
#   extract-notes.sh <version> <out.md> [--changelog FILE]
#
# <version> is the tag without "v". A prerelease (1.3.0-rc.1) uses its own "## [1.3.0-rc.1]" section if
# there is one, else the "## [1.3.0]" section it previews.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -ge 2 ]] || die "usage: extract-notes.sh <version> <out.md> [--changelog FILE]"
VERSION=$1 OUT=$2
shift 2
CHANGELOG="$DEFAULT_REPO_ROOT/CHANGELOG.md"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --changelog) CHANGELOG=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

VERSIONS=("$VERSION")
if [[ "$VERSION" == *-* ]]; then VERSIONS+=("${VERSION%%-*}"); fi
mkdir -p "$(dirname "$OUT")"
if ! py changelog-section "$CHANGELOG" "${VERSIONS[@]}" >"$OUT.tmp"; then
  rm -f "$OUT.tmp"
  die "no release notes for $VERSION in $CHANGELOG"
fi
mv "$OUT.tmp" "$OUT"
[[ -s "$OUT" ]] || die "no release notes extracted for $VERSION"
log "release notes for $VERSION -> $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
