#!/usr/bin/env bash
# Runs the SIGNED binary headlessly before it is notarized and shipped.
#
#   smoke-test.sh --app PATH
#
# The same executable is the GUI app and the hook CLI that every Claude Code / Codex tool call spawns,
# and it now links Sparkle.framework: a signing or library-validation mistake (e.g. a framework signed
# by another team under the Hardened Runtime) would make dyld kill every hook. `--help` proves the
# binary loads; `--update-status` proves the shipped app will actually start its updater — the
# Developer ID gate accepts this signature and SUPublicEDKey is real ("launch gate  enabled").
# CONTRACT with the app: UpdateSupport.printStatus() prints that row as two spaces, the padded label
# "launch gate", then the gate's case name (`describe`). Change both sides together; selftest.sh checks
# that the Swift source still prints it, because only a Developer ID build in CI can run this check.
# Neither command opens a window or touches the network; each is killed after 60 s just in case.
# Running the binary still registers its bundle with LaunchServices: irrelevant on a CI runner, but on a
# Mac unregister the copy afterwards (`lsregister -u`, see CLAUDE.md) so no stray build lingers.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -d "$APP" ]] || die "usage: smoke-test.sh --app PATH"
need perl

BIN="$APP/Contents/MacOS/$(plist_get "$APP/Contents/Info.plist" CFBundleExecutable)"

run() { # run <flag>: prints the output, fails on a non-zero exit or a timeout
  local out status=0
  out="$(with_timeout 60 "$BIN" "$1" 2>&1)" || status=$?
  printf '%s\n' "$out" | sed "s/^/  [$1] /" >&2
  case $status in
    0) ;;
    142) die "'$(basename "$BIN") $1' did not exit within 60 s (did it start the GUI?)" ;;
    *) die "'$(basename "$BIN") $1' exited with status $status" ;;
  esac
  RUN_OUTPUT=$out
}

run --help
grep -q "Usage:" <<<"$RUN_OUTPUT" || die "--help did not print the usage text"

run --update-status
GATE="$(sed -nE 's/^[[:space:]]*launch gate[[:space:]]+([A-Za-z]+).*/\1/p' <<<"$RUN_OUTPUT" | head -1)"
[[ -n "$GATE" ]] ||
  die "--update-status printed no 'launch gate' row - its format changed (UpdateSupport.printStatus); update smoke-test.sh with it"
[[ "$GATE" == enabled ]] ||
  die "the signed app would not start its updater: its launch gate is '$GATE', expected 'enabled' (see the output above)"

log "ok: the signed binary loads Sparkle and its updater launch gate is enabled"
