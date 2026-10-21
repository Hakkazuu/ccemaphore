#!/usr/bin/env python3
"""End-to-end test of ccemaphore's Codex hook support, against a built binary — no GUI, temp dirs only.

    python3 -I Scripts/test/codex_hooks_e2e.py --binary <path to …/ccemaphore.app/Contents/MacOS/ccemaphore>
                                                [--codex <path to the codex binary>] [--keep]

Part 1 — trust, against the REAL Codex (skipped when no codex binary is found; by default the one inside
ChatGPT.app): our `--install-codex-hooks` writes hooks.json into an isolated CODEX_HOME seeded with
foreign hooks; Codex's own app-server (`hooks/list`) must report exactly the hashes we compute; Codex then
records trust (`config/batchWrite`, what "Review hooks" does) and our `--codex-hooks-status` must read
it as trusted. Re-install must leave the file untouched, uninstall must restore the foreign hooks.

Part 2 — the light: a fixture ~/.codex with a running chat and a sub-agent, hook records (written by the
real hook binary where it can run without the GUI, by hand for the permission broker, which records a
wait only while the app runs), and `--codex-watch` as the observer. Checks every rule of
`CodexHookOverlay`: approval → red, the thread moving on → clear, a sub-agent's approval → its parent
red, compaction chip, a hook never deciding done, the rollout's task_complete deciding it, and no red
where Codex's auto-review (not the user) answers approvals.

Nothing touches the real ~/.codex, ~/.claude or the app's logs (CCEMAPHORE_* seams). Exit 1 on failure.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone

DEFAULT_CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
FAILURES = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        FAILURES.append(what)


def iso(t=None):
    return datetime.fromtimestamp(t or time.time(), timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


# MARK: - Part 1: trust against the real Codex

def codex_rpc(codex, home, cwd, edits=None):
    """initialize → [config/batchWrite edits] → hooks/list, over the app-server's stdio JSON-RPC."""
    p = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=dict(os.environ, CODEX_HOME=home), cwd=cwd, text=True)

    def send(o):
        p.stdin.write(json.dumps(o) + "\n")
        p.stdin.flush()

    def recv(want, deadline=30):
        end = time.time() + deadline
        while time.time() < end:
            line = p.stdout.readline()
            if not line:
                break
            o = json.loads(line)
            if o.get("id") == want:
                return o
        raise RuntimeError(f"codex app-server: no reply to request {want}")

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "ccemaphore-e2e", "version": "0"}}})
        recv(1)
        send({"method": "initialized"})
        if edits:
            send({"id": 3, "method": "config/batchWrite", "params": {"edits": edits}})
            reply = recv(3)
            if "error" in reply:
                raise RuntimeError(f"config/batchWrite: {reply['error']}")
        send({"id": 2, "method": "hooks/list", "params": {"cwds": [cwd]}})
        return recv(2)["result"]["data"][0]["hooks"]
    finally:
        p.kill()


def our_status(binary, env):
    out = subprocess.run([binary, "--codex-hooks-status"], env=env, capture_output=True, text=True).stdout
    entries = {}
    current = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("["):
            trust, label = s[1:].split("]", 1)
            current = label.split()[0]
            entries[current] = {"trust": trust.strip()}
        elif s.startswith("current:") and current:
            entries[current]["hash"] = s.split(":", 1)[1].strip()
        elif s.startswith("install:"):
            summary = s
    return entries, summary


def part_trust(binary, codex, root, base_env):
    print("Part 1 — trust model vs the real Codex")
    home, cwd = os.path.join(root, "trust-home"), os.path.join(root, "trust-cwd")
    os.makedirs(home)
    os.makedirs(cwd)
    hooks_path = os.path.join(home, "hooks.json")
    foreign = {"hooks": {
        "PreToolUse": [{"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "'/u/gate'", "timeout": 5}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "'/u/notify'"}]}],
    }}
    with open(hooks_path, "w") as f:
        json.dump(foreign, f)
    env = dict(base_env, CCEMAPHORE_CODEX_HOOKS_PATH=hooks_path,
               CCEMAPHORE_CODEX_CONFIG_PATH=os.path.join(home, "config.toml"))
    subprocess.run([binary, "--install-codex-hooks"], env=env, capture_output=True, check=True)

    listed = {h["key"].rsplit("hooks.json:", 1)[1]: h for h in codex_rpc(codex, home, cwd)}
    ours = {k: h for k, h in listed.items() if h["command"].endswith("--agent codex")}
    mine, summary = our_status(binary, env)
    check(len(ours) == 5, f"Codex sees our 5 hooks ({sorted(ours)})")
    check("stop:0:0" in listed and "'/u/notify'" in listed["stop:0:0"]["command"], "the foreign Stop hook keeps index 0")
    check(set(mine) == set(ours), "we report the same hook keys as Codex")
    for k, h in ours.items():
        check(mine.get(k, {}).get("hash") == h["currentHash"], f"{k}: our hash == Codex's current_hash")
        check(h["trustStatus"] == "untrusted", f"{k}: Codex starts it untrusted")
    check("needsApproval(count: 5" in summary, f"we say 5 need approval ({summary})")

    edits = [{"keyPath": "hooks.state." + json.dumps(h["key"]) + ".trusted_hash",
              "value": h["currentHash"], "mergeStrategy": "upsert"} for h in ours.values()]
    after = {h["key"].rsplit("hooks.json:", 1)[1]: h for h in codex_rpc(codex, home, cwd, edits)}
    check(all(after[k]["trustStatus"] == "trusted" for k in ours), "Codex trusts them once approved")
    mine, summary = our_status(binary, env)
    check(all(v["trust"] == "trusted" for v in mine.values()) and "summary: trusted" in summary,
          f"we read Codex's approval as trusted ({summary})")

    before = open(hooks_path, "rb").read()
    subprocess.run([binary, "--install-codex-hooks"], env=env, capture_output=True, check=True)
    check(open(hooks_path, "rb").read() == before, "re-install leaves an approved file untouched")
    subprocess.run([binary, "--uninstall-codex-hooks"], env=env, capture_output=True, check=True)
    check(json.load(open(hooks_path)) == foreign, "uninstall restores exactly the foreign hooks")


# MARK: - Part 2: the light, through --codex-watch

class Watch:
    """Runs `--codex-watch` and tracks the latest state line of one chat."""

    def __init__(self, binary, env, chat_id8, seconds):
        self.state, self.chat = None, chat_id8
        self.history = []
        self.cond = threading.Condition()
        self.p = subprocess.Popen([binary, "--codex-watch", str(seconds)], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            if f"({self.chat}): " not in line:
                continue
            state = line.split(f"({self.chat}): ", 1)[1].split("  [", 1)[0].strip()
            with self.cond:
                self.state = state
                self.history.append(state)
                self.cond.notify_all()

    def expect(self, state, what, within=7.0):
        end = time.time() + within
        with self.cond:
            while self.state != state and time.time() < end:
                self.cond.wait(timeout=0.2)
            check(self.state == state, f"{what} → '{state}' (saw '{self.state}')")

    def holds(self, state, what, seconds=3.0):
        end = time.time() + seconds
        ok = True
        with self.cond:
            while time.time() < end:
                ok = ok and self.state == state
                self.cond.wait(timeout=0.2)
            ok = ok and self.state == state
        check(ok, f"{what} → stays '{state}' (saw '{self.state}')")

    def stop(self):
        self.p.kill()


def rollout_line(kind, payload, t=None):
    return json.dumps({"timestamp": iso(t), "type": kind, "payload": payload}) + "\n"


def append(path, text):
    with open(path, "a") as f:
        f.write(text)


def status_record(status_dir, thread, state, event):
    os.makedirs(status_dir, exist_ok=True)
    rec = {"session_id": f"codex:{thread}", "agent": "codex", "cwd": "/w", "project": "w",
           "state": state, "last_event": event, "updated_at": iso(), "host": "codexApp"}
    with open(os.path.join(status_dir, f"codex-{thread}.json"), "w") as f:
        json.dump(rec, f)


def run_hook(binary, env, event, thread, rollout):
    payload = {"session_id": thread, "transcript_path": rollout, "cwd": "/w", "hook_event_name": event}
    subprocess.run([binary, "--hook", event, "--agent", "codex"], input=json.dumps(payload),
                   env=env, capture_output=True, text=True, check=True)


def part_light(binary, root, base_env):
    print("Part 2 — the light (rollout + hook records → --codex-watch)")
    codex_home, status_dir = os.path.join(root, "codex"), os.path.join(root, "status")
    day = datetime.now().strftime("%Y/%m/%d")
    sessions = os.path.join(codex_home, "sessions", day)
    os.makedirs(sessions)
    os.makedirs(status_dir)
    chat, kid = str(uuid.uuid4()), str(uuid.uuid4())
    stamp = datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
    chat_path = os.path.join(sessions, f"rollout-{stamp}-{chat}.jsonl")
    kid_path = os.path.join(sessions, f"rollout-{stamp}-{kid}.jsonl")
    append(chat_path, rollout_line("session_meta", {"id": chat, "cwd": "/w", "thread_source": "user",
                                                    "originator": "codex_work_desktop", "source": "vscode"})
           + rollout_line("event_msg", {"type": "task_started", "turn_id": "t1"})
           + rollout_line("response_item", {"type": "function_call"}))
    append(kid_path, rollout_line("session_meta", {"id": kid, "thread_source": "subagent", "source": {
               "subagent": {"thread_spawn": {"parent_thread_id": chat, "agent_nickname": "Hooke"}}}})
           + rollout_line("event_msg", {"type": "task_started", "turn_id": "k1"}))
    env = dict(base_env, CCEMAPHORE_CODEX_HOME=codex_home, CCEMAPHORE_STATUS_DIR=status_dir)
    w = Watch(binary, env, chat[:8], seconds=90)
    try:
        w.expect("working", "a chat with an open turn")

        time.sleep(1.5)   # hook records have whole-second precision; keep clear of the scan's lines
        status_record(status_dir, chat, "waiting", "permission-native")
        w.expect("waiting (permission)", "Codex asks for approval in the chat")
        w.holds("waiting (permission)", "nothing written meanwhile", seconds=3)

        append(chat_path, rollout_line("response_item", {"type": "function_call_output"}))
        w.expect("working", "the chat moved on (approved or denied)")

        time.sleep(1.5)
        status_record(status_dir, kid, "waiting", "permission-native")
        w.expect("waiting (permission)", "a sub-agent asks for approval → its parent chat")
        append(chat_path, rollout_line("response_item", {"type": "reasoning"}))
        w.holds("waiting (permission)", "the parent's own activity doesn't clear the sub-agent's wait", seconds=3)
        append(kid_path, rollout_line("response_item", {"type": "function_call_output"}))
        w.expect("working", "the sub-agent moved on")

        time.sleep(1.5)
        run_hook(binary, env, "precompact", chat, chat_path)
        w.expect("working (compacting)", "the real PreCompact hook → compacting chip")
        run_hook(binary, env, "postcompact", chat, chat_path)
        w.expect("working", "the real PostCompact hook ends it")

        run_hook(binary, env, "stop", chat, chat_path)
        w.holds("working", "a Stop hook alone never decides done (the rollout owns it)", seconds=3)

        append(kid_path, rollout_line("event_msg", {"type": "task_complete", "turn_id": "k1"}))
        append(chat_path, rollout_line("event_msg", {"type": "task_complete", "turn_id": "t1"}))
        w.expect("done", "task_complete in the rollout")

        status_record(status_dir, chat, "waiting", "permission-native")
        w.holds("done", "a wait recorded after the turn ended is ignored", seconds=3)
    finally:
        w.stop()

    # A chat whose approvals go to Codex's auto-review: the PermissionRequest hook still fires, but a
    # guardian decides and nobody is asked — so no red.
    auto = str(uuid.uuid4())
    auto_path = os.path.join(sessions, f"rollout-{stamp}-{auto}.jsonl")
    append(auto_path, rollout_line("session_meta", {"id": auto, "cwd": "/w", "thread_source": "user",
                                                    "originator": "codex_work_desktop", "source": "vscode"})
           + rollout_line("event_msg", {"type": "thread_settings_applied",
                                        "thread_settings": {"approvals_reviewer": "auto_review"}})
           + rollout_line("event_msg", {"type": "task_started", "turn_id": "a1"}))
    w = Watch(binary, env, auto[:8], seconds=40)
    try:
        w.expect("working", "an auto-reviewed chat with an open turn")
        time.sleep(1.5)
        status_record(status_dir, auto, "waiting", "permission-native")
        w.holds("working", "auto-review decides alone → no red", seconds=4)
    finally:
        w.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--codex", default=DEFAULT_CODEX)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    root = tempfile.mkdtemp(prefix="ccemaphore-codex-e2e-")
    base_env = dict(os.environ, CCEMAPHORE_LOG_DIR=os.path.join(root, "logs"),
                    CCEMAPHORE_STATUS_DIR=os.path.join(root, "status-trust"))
    try:
        if os.access(a.codex, os.X_OK):
            part_trust(a.binary, a.codex, root, base_env)
        else:
            print(f"Part 1 skipped: no codex binary at {a.codex}")
        part_light(a.binary, root, base_env)
    finally:
        if a.keep:
            print(f"kept: {root}")
        else:
            shutil.rmtree(root, ignore_errors=True)
    print(f"\n{len(FAILURES)} failed" if FAILURES else "\nall passed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
