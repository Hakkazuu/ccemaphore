import Foundation

/// Source of the portable Python 3 script deployed to a remote host as its Claude Code hook command
/// (`python3 ~/.claude/ccemaphore/bin/ccemaphore-hook.py --hook <event>`). Python was chosen over a POSIX
/// shell script because it needs to reliably parse/emit JSON (hook stdin, status files, pending-request
/// files) without depending on `jq` being present.
///
/// Deliberately a MINIMAL reimplementation of `HookHandler.run` + `PermissionBroker.runHook`'s
/// `permissionRequest` path — enough for status + permission parity with the local machine, not a port
/// of every local nicety (no `nb_seq` non-broker counter, no allow-all/trusted-commands short-circuit,
/// no `AppPresence` readiness gate — the "GUI" here is a different machine, and its liveness is instead
/// tracked by `RemotePermissionRelay`'s own poll loop, which simply stops polling a host it can't reach).
/// The JSON shapes it writes match exactly what `StatusReader.parse` / `PermissionBroker.PendingRequest`
/// already decode, so `RemoteTranscriptPoller`/`RemotePermissionRelay` need no shim-specific parsing.
enum RemoteHookShim {
    static let source = #"""
#!/usr/bin/env python3
# Deployed by ccemaphore's RemoteHooksInstaller — DO NOT EDIT BY HAND, it is overwritten on every
# (re)install. See Sources/ccemaphore/RemoteHookShim.swift in the ccemaphore repo for the source of truth.
import json, os, sys, time, uuid, subprocess
from datetime import datetime, timezone

BASE = os.path.expanduser("~/.claude/ccemaphore")
STATUS_DIR = os.path.expanduser("~/.claude/status")
PENDING_DIR = os.path.join(BASE, "pending")
POLL_TIMEOUT = 240.0
POLL_INTERVAL = 0.2

def now_iso():
    return datetime.now(timezone.utc).isoformat()

def read_stdin_json():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw else {}
    except Exception:
        return {}

def atomic_write(path, data: bytes):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)

def write_status(session_id, cwd, state, event):
    out = {
        "session_id": session_id,
        "cwd": cwd,
        "project": os.path.basename(cwd.rstrip("/")) if cwd else "?",
        "state": state,
        "last_event": event,
        "updated_at": now_iso(),
        "pid": os.getppid(),
        "host": "ide",   # remote sessions are always the VS Code / IDE extension host, never a bare terminal
    }
    atomic_write(os.path.join(STATUS_DIR, f"{session_id}.json"), json.dumps(out, sort_keys=True).encode())

def handle_basic_event(event, payload):
    sid = payload.get("session_id") or ""
    cwd = payload.get("cwd") or ""
    if not sid:
        return
    if event == "end":
        write_status(sid, cwd, "done", "end")
        return
    if event == "notify":
        ntype = (payload.get("notification_type") or "").lower()
        msg = (payload.get("message") or "").lower()
        is_permission = ("permission" in ntype) if ntype else ("permission" in msg or "approve" in msg)
        if is_permission:
            write_status(sid, cwd, "waiting", "permission-native")
        else:
            # A NON-permission notification (e.g. "idle_prompt" — Claude is waiting for input again)
            # still means the turn ended one way or another, INCLUDING a user-interrupted tool that never
            # fires a normal Stop/PostToolUse. A blocking `permission-request` invocation for the SAME
            # session polls this file for exactly this kind of change to detect "resolved elsewhere" (see
            # `handle_permission_request`) — silently dropping this event (the previous behavior) meant an
            # interrupted tool's permission wait never noticed and sat red for the full POLL_TIMEOUT.
            write_status(sid, cwd, "done", "notify")
        return
    if event in ("stop", "start"):
        state = "done"
    elif event == "precompact":
        state = "compacting"
    else:
        state = "working"   # prompt / pre / post heartbeat
    write_status(sid, cwd, state, event)

def summarize(tool, tool_input):
    if not isinstance(tool_input, dict):
        return tool, None
    detail = tool_input.get("command") or tool_input.get("file_path") or tool_input.get("url") \
        or tool_input.get("notebook_path")
    return f"tool: {tool}", (str(detail) if detail is not None else None)

def handle_permission_request(payload):
    sid = payload.get("session_id") or ""
    cwd = payload.get("cwd") or ""
    tool = payload.get("tool_name") or payload.get("tool") or "?"
    tool_input = payload.get("tool_input")
    if tool == "AskUserQuestion":
        write_status(sid, cwd, "waiting", "question-native")
        return   # no decision to make — release immediately, nothing to stdout
    req_id = str(uuid.uuid4())
    summary, detail = summarize(tool, tool_input)
    req = {
        "requestId": req_id,
        "sessionId": sid,
        "tool": tool,
        "summary": summary,
        "detail": detail,
        "cwd": cwd,
        "createdAt": now_iso(),
        "toolUseId": payload.get("tool_use_id"),
    }
    os.makedirs(PENDING_DIR, exist_ok=True)
    atomic_write(os.path.join(PENDING_DIR, f"{req_id}.json"), json.dumps(req).encode())
    write_status(sid, cwd, "waiting", "permission")

    status_path = os.path.join(STATUS_DIR, f"{sid}.json")
    decision_file = os.path.join(PENDING_DIR, f"{req_id}.decision")
    deadline = time.time() + POLL_TIMEOUT
    decision = None
    tick = 0
    while time.time() < deadline:
        if os.path.exists(decision_file):
            try:
                with open(decision_file, "r") as f:
                    decision = f.read().strip()
            except Exception:
                decision = None
            break
        # External resolution: the tool already ran WITHOUT our decision — auto-accepted by Claude's own
        # permission mode, approved in the IDE's native dialog, or the turn otherwise advanced some other
        # way. A fresh pre/post/stop/prompt event for the SAME session overwrites this file's `last_event`
        # away from our own `permission`/`permission-native` writes, so treat that as "resolved elsewhere"
        # and stop blocking — mirrors `PermissionBroker.runHook`'s external-resolution check locally.
        # Without this, an auto-accepted tool left the hook (and the ribbon) pinned at "waiting" for the
        # full POLL_TIMEOUT despite the chat visibly continuing to work.
        try:
            with open(status_path) as sf:
                cur_event = json.load(sf).get("last_event")
            if cur_event not in (None, "permission", "permission-native"):
                break
        except Exception:
            pass
        # Refresh updated_at periodically so a request the user takes a while to answer doesn't look
        # increasingly stale while it's genuinely still on screen (ccemaphore drops any session whose
        # last signal is older than its staleWindow).
        tick += 1
        if tick % 10 == 0:
            write_status(sid, cwd, "waiting", "permission-native")
        time.sleep(POLL_INTERVAL)

    try:
        os.remove(os.path.join(PENDING_DIR, f"{req_id}.json"))
    except OSError:
        pass
    try:
        os.remove(decision_file)
    except OSError:
        pass

    if decision in ("allow", "allow-all"):
        write_status(sid, cwd, "working", "permission-resolved")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                                   "decision": {"behavior": "allow"}}}))
    elif decision == "deny":
        write_status(sid, cwd, "working", "permission-resolved")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                                   "decision": {"behavior": "deny"}}}))
    else:
        # Timeout, or explicit "ask": hand off to Claude's own native prompt — emit nothing.
        write_status(sid, cwd, "waiting", "permission-native")

def main():
    if len(sys.argv) < 3 or sys.argv[1] != "--hook":
        sys.exit(0)
    event = sys.argv[2]
    payload = read_stdin_json()
    if event == "permission-request":
        handle_permission_request(payload)
    else:
        handle_basic_event(event, payload)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)   # never crash-block a Claude Code hook on an unexpected shim error
"""#
}
