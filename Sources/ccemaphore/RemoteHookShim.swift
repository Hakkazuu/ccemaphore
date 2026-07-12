import Foundation

/// Source of the portable Python 3 script deployed to a remote host as its Claude Code hook command
/// (`python3 ~/.claude/ccemaphore/bin/ccemaphore-hook.py --hook <event>`). Python was chosen over a POSIX
/// shell script because it needs to reliably parse/emit JSON (hook stdin, status files, pending-request
/// files) without depending on `jq` being present.
///
/// Deliberately a MINIMAL reimplementation of `HookHandler.run` + `PermissionBroker.runHook`'s
/// `permissionRequest` path — enough for status + permission parity with the local machine. It DOES now
/// mirror the load-bearing correctness bits of the local flow (the `nb_seq` non-broker counter + its
/// `flock`, the full `brokerStatusEvents` external-resolution exempt-set, and a readiness gate — here a
/// Mac-written beacon + `/proc` host-detection instead of `AppPresence`), but not every convenience
/// (allow-all/trusted-command memory lives app-side on the Mac in `StateEngine`, which auto-decides
/// remote requests before they ever reach a ribbon). The JSON shapes it writes match exactly what
/// `StatusReader.parse` / `PermissionBroker.PendingRequest` already decode, so `RemoteTranscriptPoller`/
/// `RemotePermissionRelay` need no shim-specific parsing.
enum RemoteHookShim {
    static let source = #"""
#!/usr/bin/env python3
# Deployed by ccemaphore's RemoteHooksInstaller — DO NOT EDIT BY HAND, it is overwritten on every
# (re)install. See Sources/ccemaphore/RemoteHookShim.swift in the ccemaphore repo for the source of truth.
import json, os, sys, time, uuid, fcntl
from datetime import datetime, timezone

BASE = os.path.expanduser("~/.claude/ccemaphore")
STATUS_DIR = os.path.expanduser("~/.claude/status")
PENDING_DIR = os.path.join(BASE, "pending")
# The Mac's RemotePermissionRelay touches this every poll tick while it is watching this host — see
# `beacon_fresh`. NOT inside pending/ (so it never trips a pending glob), mirroring the local beacon's
# baseDir-root placement (AppPresence).
BEACON = os.path.join(BASE, "mac-beacon")
POLL_TIMEOUT = 240.0
POLL_INTERVAL = 0.2
# ~3x the Mac relay's 2s poll: tolerates a single slow/dropped tick without falsely reading "Mac away"
# (which would drop the ribbon a watching Mac is about to show), while still noticing a closed app within
# a few seconds so a bare terminal isn't frozen for the full POLL_TIMEOUT.
BEACON_MAX_AGE = 6.0

# Mirror of PermissionBroker.brokerStatusEvents (Sources/ccemaphore/PermissionBroker.swift): the events
# the permission flow itself writes. Two uses, both mirroring the local machine — MUST stay in sync with
# the Swift set: (1) the `nb_seq` non-broker counter skips these, so a broker write can't hide a real
# pre/post/stop that landed just before it; (2) the external-resolution check treats them as "still ours"
# (not a sign the turn advanced elsewhere).
BROKER_EVENTS = {"permission", "permission-native", "permission-resolved", "permission-app-quit", "question-native"}

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

def read_nb(status_path):
    # LENIENT read of the non-broker counter (like HookHandler.nonBrokerCarry): the ONE reader for both
    # write_status's carry and the wait loop's baseline, so the two can't disagree about the same bytes.
    try:
        with open(status_path) as f:
            j = json.load(f)
        return int(j.get("nb_seq") or 0), j.get("nb_event")
    except Exception:
        return 0, None

def write_status(session_id, cwd, state, event):
    # Serialize the nb_seq read-modify-write across the concurrent hook/relay-decision processes that all
    # write this session's one file with a single flock'd sidecar — mirrors HookHandler.withStatusLock.
    # Best-effort: if the lock can't be taken the write still happens (a status file must never be lost to
    # a locking failure); flock self-releases if the process dies mid-section.
    os.makedirs(STATUS_DIR, exist_ok=True)
    path = os.path.join(STATUS_DIR, f"{session_id}.json")
    fd = -1
    try:
        fd = os.open(os.path.join(STATUS_DIR, ".lock"), os.O_CREAT | os.O_WRONLY, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError:
        pass
    try:
        nb_seq, nb_event = read_nb(path)
        # A broker-originated event carries the counter forward untouched — that's the point: its overwrite
        # of last_event can no longer hide the pre/post/stop that landed just before it.
        if event not in BROKER_EVENTS:
            nb_seq += 1
            nb_event = event
        out = {
            "session_id": session_id,
            "cwd": cwd,
            "project": os.path.basename(cwd.rstrip("/")) if cwd else "?",
            "state": state,
            "last_event": event,
            "updated_at": now_iso(),
            "pid": os.getppid(),
            "host": "ide",   # status host stays "ide" (drives the Mac's render/jump) — detect_host() below
                             # is used ONLY to gate the shim's own blocking wait, never this field.
            "nb_seq": nb_seq,
        }
        if nb_event is not None:
            out["nb_event"] = nb_event
        atomic_write(path, json.dumps(out, sort_keys=True).encode())
    finally:
        if fd >= 0:
            os.close(fd)   # releases the flock too

def beacon_fresh():
    # A fresh beacon ⇒ the Mac is up and actively polling this host, so it WILL relay a decision — blocking
    # for one is useful. Absent/stale ⇒ nobody will ever answer (app closed, host disabled, unreachable) —
    # don't block. Same clock domain both sides (the Mac writes it here over SSH, we read it here), so no
    # cross-machine skew. The remote analogue of the local AppPresence readiness gate.
    try:
        return (time.time() - os.path.getmtime(BEACON)) <= BEACON_MAX_AGE
    except OSError:
        return False

IDE_MARKERS = (".vscode-server", ".cursor-server", "vscode-server", "cursor-server", "code-server")

def detect_host():
    # "ide" (a VS Code / Cursor Remote extension host, where the native dialog shows ALONGSIDE the Mac
    # ribbon) vs "terminal" (a bare SSH/login shell, where the native prompt is inline in front of the
    # user). CONSERVATIVE by design: returns "ide" on ANY uncertainty (no /proc, unreadable exe, climb
    # error, cap reached) so the verified Remote-SSH setup — /proc shows a node under ~/.vscode-server or
    # ~/.cursor-server — always keeps its full blocking wait + ribbon. Only a chain fully walked to a
    # shallow root WITHOUT any IDE marker is confidently "terminal" (⇒ 0 wait, hand to Claude's inline
    # prompt, never a 240s freeze). Mirrors the local ProcTree.sessionContext host gate — but biased so a
    # misread degrades toward the EXISTING behavior, never away from a working ide session.
    try:
        pid = os.getppid()
        for _ in range(16):
            if pid <= 1:
                return "terminal"   # reached init without ever seeing an IDE marker → bare shell
            exe = ""
            try:
                exe = os.readlink("/proc/%d/exe" % pid)
            except OSError:
                try:
                    with open("/proc/%d/cmdline" % pid, "rb") as f:
                        exe = f.read().replace(b"\x00", b" ").decode("utf-8", "replace")
                except OSError:
                    return "ide"    # can't inspect this ancestor → uncertain → keep current behavior
            if any(m in exe.lower() for m in IDE_MARKERS):
                return "ide"
            try:
                with open("/proc/%d/stat" % pid) as f:
                    data = f.read()
                rp = data.rfind(")")   # comm field is parenthesized and may itself contain spaces/parens
                fields = data[rp + 2:].split()
                pid = int(fields[1])   # after comm: fields[0]=state, fields[1]=ppid
            except (OSError, ValueError, IndexError):
                return "ide"    # can't climb → uncertain → keep current behavior
        return "ide"    # walked the cap without a verdict → uncertain → keep current behavior
    except Exception:
        return "ide"

def gc_orphans():
    # Best-effort GC of pending/decision files a SIGKILLed shim left behind (a clean exit removes its own).
    # Anything older than POLL_TIMEOUT can no longer belong to a live wait (that shim has already given
    # up), so the Mac's relay would only re-show a dead ribbon for it. Safe: a live request's files are far
    # younger than POLL_TIMEOUT. Mirrors HookHandler.sweepStale / the relay's own stale age-out.
    try:
        now = time.time()
        for name in os.listdir(PENDING_DIR):
            if not (name.endswith(".json") or name.endswith(".decision")):
                continue
            p = os.path.join(PENDING_DIR, name)
            try:
                if now - os.path.getmtime(p) > POLL_TIMEOUT:
                    os.remove(p)
            except OSError:
                pass
    except OSError:
        pass

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
        # A NON-permission notification (idle_prompt / auth / unknown) is NOT written: `done` is owned by
        # `Stop`, and forcing `done` here turned a still-running workflow/subagent chat GREEN (CC #11964 —
        # notification_type is often absent, so this can't even be classified reliably), the app's worst
        # failure. Mirrors local HookHandler, which leaves the existing state untouched. (The "a blocking
        # permission shim should notice an interrupted tool" signal this used to double as is restored
        # precisely by the nb_seq non-broker event counter — see WP5 — not by a bogus `done`.)
        return
    if event in ("stop", "start"):
        state = "done"
    elif event == "precompact":
        state = "compacting"
    else:
        state = "working"   # prompt / pre / post heartbeat
    write_status(sid, cwd, state, event)

def summarize(tool, tool_input):
    # Bare tool name (NOT "tool: X") to match the local PermissionBroker.summarize — the ribbon shows
    # `detail ?? summary`, so this is what a no-detail tool displays (C2).
    if not isinstance(tool_input, dict):
        return tool, None
    detail = tool_input.get("command") or tool_input.get("file_path") or tool_input.get("url") \
        or tool_input.get("notebook_path")
    return tool, (str(detail) if detail is not None else None)

def handle_permission_request(payload):
    gc_orphans()   # opportunistic: reap pending/decision files an earlier killed shim abandoned
    sid = payload.get("session_id") or ""
    cwd = payload.get("cwd") or ""
    if not sid:   # nothing to track without a session id — hand to Claude's native prompt (emit nothing)
        return
    tool = payload.get("tool_name") or payload.get("tool") or "?"
    tool_input = payload.get("tool_input")
    if tool == "AskUserQuestion":
        write_status(sid, cwd, "waiting", "question-native")
        return   # no decision to make — release immediately, nothing to stdout

    # Readiness gate (mirrors PermissionBroker.runHook's `waitWindow = (host == .ide) ? presence : 0`):
    # only block for a decision when there's a real surface to answer at. A blocking wait makes sense only
    # if the Mac is actively watching this host (fresh beacon ⇒ it will relay a click) AND this is an IDE
    # host (its native dialog shows alongside the ribbon). A bare terminal, or an away Mac, gets 0 wait —
    # keep the chat red with the informational `permission-native` and hand straight to Claude's own
    # prompt, so we NEVER freeze a terminal for the full POLL_TIMEOUT. No pending file is written on this
    # path: there's no ribbon to answer it, and leaving one would orphan (gc_orphans would later reap it).
    if not (beacon_fresh() and detect_host() == "ide"):
        write_status(sid, cwd, "waiting", "permission-native")
        return

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

    status_path = os.path.join(STATUS_DIR, f"{sid}.json")
    # Baseline for the counter-based external-resolution check, taken BEFORE our own `permission` write.
    # The tool's `pre` has already fired (events are ordered pre -> PermissionRequest), so its nb_seq
    # increment is inside the baseline and can't self-resolve this request; anything landing from here on
    # raises the counter above this value. Read via the same lenient reader write_status's carry uses.
    # Mirrors PermissionBroker.runHook's externalBaseline.
    external_baseline, _ = read_nb(status_path)
    write_status(sid, cwd, "waiting", "permission")

    decision_file = os.path.join(PENDING_DIR, f"{req_id}.decision")
    deadline = time.time() + POLL_TIMEOUT
    decision = None
    resolved_externally = False
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
        # way. Two checks over one read, mirroring PermissionBroker.runHook:
        #  - last_event is a NON-broker event → the turn advanced elsewhere (the direct case);
        #  - nb_seq rose past the baseline → the MASKED case: a sibling PermissionRequest's `permission`
        #    write overwrote last_event within one poll interval, but the monotonic counter still shows a
        #    new non-broker event (pre/post/stop) landed — the stale-ribbon incident, remote.
        # Without this an auto-accepted tool pinned the hook (and ribbon) at "waiting" for the full
        # POLL_TIMEOUT despite the chat visibly continuing to work.
        try:
            with open(status_path) as sf:
                cur = json.load(sf)
            cur_event = cur.get("last_event")
            if cur_event is not None and cur_event not in BROKER_EVENTS:
                resolved_externally = True; break
            if int(cur.get("nb_seq") or 0) > external_baseline:
                resolved_externally = True; break
        except Exception:
            pass
        # Refresh updated_at periodically so a request the user takes a while to answer doesn't look
        # increasingly stale while it's genuinely still on screen (ccemaphore drops any session whose
        # last signal is older than its staleWindow). `permission-native` is a broker event ⇒ carries the
        # counter (no bump), so this refresh can't trip the masked check above.
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
    elif resolved_externally:
        # The tool ran WITHOUT our decision (native dialog answered, auto-accepted, or the turn advanced):
        # the external event already wrote the correct status (working/done). Do NOT rewrite it — mirrors
        # PermissionBroker.runHook, which drops its pending and emits nothing WITHOUT a status write, so a
        # resolved chat isn't re-marked as waiting. Claude's own flow already owns the outcome.
        pass
    else:
        # Genuine timeout: hand off to Claude's own native prompt — emit nothing, and keep the chat red
        # with the informational permission-native (it is still legitimately awaiting the user).
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
