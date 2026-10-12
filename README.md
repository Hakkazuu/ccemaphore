# ccemaphore

**English** · [Русский](README.ru.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md)

> A floating traffic light for your [Claude Code](https://claude.com/claude-code) and
> [Codex](https://chatgpt.com/codex) (ChatGPT app) sessions on macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Run the Claude desktop app, several Cursor / VS Code windows and the ChatGPT app's Codex side by side,
each with multiple agent chats, and one always-on-top indicator tells you — at a glance, without
switching windows — whether an agent is working, has finished, or needs you.

## ⬇️ Download

### **[Download the latest release (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Signed & notarized by Apple. Drag it into **Applications** and launch — no Gatekeeper warnings.
Requires **macOS 13 or later**. Once installed, it [updates itself](#updates).
[Full install steps ↓](#install)

📄 **[Changelog](CHANGELOG.md)** — what's new in each version.

```
🟡  at least one session is working
🟢  none working — everything finished cleanly
🔴  none working — at least one is waiting for you
⚪  no live sessions
```

---

## What it does

ccemaphore is a small **floating light** that hovers above everything (including fullscreen Spaces).
It aggregates the state of *all* your Claude Code chats across every window into one color — so you
never window-switch just to check status.

- **Hover the light** → a panel drops open with every live session grouped **Waiting → Working →
  Done**: project · git branch · chat title · context % · the running command. Its bottom bar holds
  **Chats**, **History**, **Settings** and **Quit**; **↻** at the top refreshes.
- **Drag** the light anywhere; switch on **Pin position** in Settings to lock it there.
- **A chat needs permission?** The light turns into a **ribbon** right where it sits — **Allow / Deny /
  All in chat** (allow everything in that chat from now on), plus the exact command — so you decide
  without opening the chat.
- **A chat finished?** A green "done" notice appears at the light; click **Open chat** to jump
  straight to it (it raises the right Cursor tab, or the terminal).
- **Compacting context?** The yellow lamp shows a small compress chip — busy, not stuck.
- **Two agents, one light.** Codex threads from the ChatGPT app (or the Codex CLI) sit next to Claude
  Code chats, each row with an agent badge (Claude / Codex) and a host glyph (Claude app, IDE, Terminal,
  ChatGPT app). **Open chat** — or a click on the chat's row in the panel — opens the right place: a
  Cursor tab, the Claude app session, or the Codex thread.
- **Sub-agents.** A chat that spawned sub-agents (Claude `Task` agents, workflows, Codex sub-agent
  threads) grows a chevron — expand it to see what each one is doing.
- **Group by product.** Working on a backend, a frontend and a landing of one product at once? Pick
  **By product** in **Settings ▸ Product groups**: the Chats tab then groups chats by product folder
  (`product › sub-repo`), with ChatGPT app projects and multi-repo folders suggested automatically.
- **Codex limits.** The 5-hour / weekly usage windows Codex reports, at the bottom of the Chats tab.

Everything happens *at the light*. There are no system notification toasts to chase.

Token & cost stats per session and a daily history window come from
[`ccusage`](https://github.com/ryoppippi/ccusage) when it's available — for Claude Code and Codex alike
(ccusage ≥ 20), with a Claude / Codex split and filter in the History window.

## Languages

ccemaphore ships fully localized in **English, Русский, Español, Deutsch, Français**, with **live**
switching — no relaunch. Open **Settings ▸ Language** and pick one from the menu (each shows its own
name and flag); the whole UI re-renders instantly. Leave it on **System** to follow your macOS
preferred languages (falling back to English).

This README is available in the same five languages — see the switcher at the top.

## Privacy

Everything ccemaphore shows is worked out on your Mac from local files — mainly `~/.claude` and
`~/.codex`. Chat content is never stored or sent anywhere. `~/.claude` is a dot-folder (not a
TCC-protected location), so no access prompt appears for it. No telemetry, no analytics.

Only these things reach the network:

- **Update checks → GitHub.** Unless you turn updates off, ccemaphore asks GitHub once a day whether
  there's a new version, and downloads it from there. GitHub sees your IP address, the app version (in
  the User-Agent, e.g. `ccemaphore/1.3.0 Sparkle/2.10.0`) and your preferred language (the
  `Accept-Language` header macOS adds). Each check also bumps the public download counter of the
  release's `appcast.xml` — one aggregate number anyone can see, with nothing that identifies you.
  Cookies are not stored, and no system profile is sent.
- **Your call.** On first launch the panel asks how to update — automatically, notify only, or off — and
  no automatic check runs before you answer. Change it any time in **Settings ▸ Updates**; with updates
  off, ccemaphore never checks on its own (you can still check by hand).
- **ccusage** (token & cost stats, only when Node or Bun is installed) runs via `bunx`/`npx`, which may
  fetch the package from the npm registry; ccusage itself may download current model pricing.
- **SSH remote hosts** (opt-in) — ccemaphore connects only to the hosts you add, using your own `ssh`.

Nothing else — no chat content and no identifiers ever leave your Mac. If you run an outbound firewall
(Little Snitch, LuLu), expect a one-time prompt for GitHub on the first update check.

## How it works

ccemaphore works out each session's state from local files, combining several sources per agent.

### Claude Code — session registry (primary, zero setup)

Claude Code 2.1.29x and later publishes its own state for every running session in
`~/.claude/sessions/<pid>.json`: busy / idle / waiting (with *what* it waits for — a permission prompt or
your answer), the session's name, where it runs (desktop app, IDE, terminal) and its launch folder.
ccemaphore treats this as the most precise signal and applies it over the inferred sources below. It is
Claude Code's own word, so no hooks are needed for it.

### Mode A — file-watch (always on, zero setup)

It watches `~/.claude/projects/**/*.jsonl` (the transcripts Claude Code writes live) with FSEvents and
classifies each session from the tail of its file:

- **working** — the last real line is recent and mid-turn (assistant `tool_use`, an unfinalized
  stream, a just-arrived `tool_result`, a fresh prompt, or an `api_error` retry).
- **done** — the turn finished cleanly (`stop_reason: end_turn`).
- **waiting** — best-effort: a cooled, still-live tail ending in an unpaired `tool_use`.

Sub-agent transcripts are folded into their parent session — a running sub-agent marks its parent as
working. Liveness is computed from the last real `timestamp`, **not** file mtime, because metadata
rewrites (titles, last-prompt) bump mtime long after a chat goes idle.

### Mode B — hooks (opt-in, one click)

Turn on **"Precise status detection"** in Settings and ccemaphore installs Claude Code hooks for:

- **Precise `done` / `waiting`** detection — more reliable than reading the transcript tail.
- **The interactive permission ribbon** (the 3-button **Allow / Deny / All in chat** prompt above).
- **Trusted commands** — a list of commands you auto-approve, so no ribbon ever appears for them
  (matched as a substring of the command).

The hook install is an idempotent merge into `~/.claude/settings.json` and is fully reversible.

### Codex (ChatGPT app) — file-watch + optional hooks

When `~/.codex` exists, ccemaphore also watches Codex: the rollout transcripts
(`~/.codex/sessions/**/rollout-*.jsonl` — `task_started` / `task_complete` / `turn_aborted` give
working / done), the thread catalog (`state_5.sqlite`, opened read-only — titles, folders, projects,
archive state) and the per-thread writer locks (held while the ChatGPT app has a thread open). Codex does
not write approval requests into its transcripts, so "needs you" for Codex comes only from hooks:
**Precise status via Codex hooks** writes ccemaphore's hooks to `~/.codex/hooks.json`, and the separate
**Codex permission prompts** toggle turns an approval request into a red light + ribbon (trusted commands
are auto-allowed). Codex only runs hooks it has **trusted**: after installing, approve `hooks.json` once
in the ChatGPT app (Codex settings → Hooks) or with `/hooks` in the Codex CLI — the Settings row tells you
where that stands. A thread the ChatGPT app *imported* from Claude Code keeps its Claude badge; a pure
mirror with no Codex turns is hidden, so nothing is listed twice.

## Install

1. [**Download the latest `.dmg`**](https://github.com/hakkazuu/ccemaphore/releases/latest) — it's
   signed & notarized, so Gatekeeper opens it without warnings.
2. Open the DMG and drag **ccemaphore** into **Applications**.
3. Launch it. ccemaphore runs as a menu-less background app (no Dock icon) — just the floating light.

### First-launch setup (optional but recommended)

- **Grant Accessibility** (System Settings ▸ Privacy & Security ▸ Accessibility: switch ccemaphore on,
  adding it with **+** if it isn't listed — the app never asks for it by itself). It's used only when
  you jump to a chat: to check that the right Cursor window is in front before the chat tab opens, and
  to raise an already-open VS Code Remote-SSH window instead of opening a new one.
- **Pick how ccemaphore updates** — the panel asks once: automatically, notify only, or off
  ([details ↓](#updates)).
- **Turn on "Precise status detection"** in Settings to enable Mode B (hooks + the permission ribbon).
- **Using Codex in the ChatGPT app?** It's picked up automatically. For instant done / needs-you,
  turn on **Precise status via Codex hooks** (and **Codex permission prompts**), then approve the hooks
  once in the ChatGPT app's Codex settings — the row shows when it's trusted.
- **Both apps notify you themselves.** If the light is enough, mute the Claude app / ChatGPT app in
  System Settings ▸ Notifications, or in each app's own notification settings.
- **For token & cost stats**, make sure Node or Bun is on your `PATH` — ccemaphore runs
  [`ccusage`](https://github.com/ryoppippi/ccusage) via `bunx`/`npx`. History still works without it;
  you just won't see token numbers.
- **If clicking a notice shuffles your desktops around** — that's macOS, not ccemaphore: the
  "Automatically rearrange Spaces based on most recent use" setting (System Settings ▸ Desktop & Dock ▸
  Mission Control). Turn it off, or run
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` — your Spaces keep their
  order, and jumping to the right window still works.

### Updates

ccemaphore keeps itself up to date with [Sparkle](https://sparkle-project.org):

- **Three modes**, chosen once on first launch and changeable in **Settings ▸ Updates** (which also shows
  your version and the last check):
  - **Automatic** — checks once a day and downloads in the background; when the new version is
    ready, a single **Restart** click swaps it in and relaunches. Quitting normally installs it too.
    If your account can't replace the app where it is (no write access, or another account installed
    it), the downloaded update waits for your **Install** click and an administrator password instead —
    quitting doesn't install it.
  - **Notify only** — checks once a day and tells you; one **Update** click downloads, installs and
    relaunches.
  - **Off** — never checks on its own; you can still check by hand.
- **Signed and verified.** An update is the same signed, notarized DMG as on the Releases page, and
  ccemaphore checks its EdDSA signature — and the signature of the update feed — before unpacking
  anything.
- **All in the panel**, in the app's language. Outside it you may still see Sparkle's small installer
  window with its progress, if an install takes a while; the macOS administrator password prompt, only if
  your account can't replace the app where it is (its message comes from Sparkle, in English); and, on
  macOS 13 to 14.3, Gatekeeper's "Verifying…" window the first time the updated app opens.
- **Never mid-permission.** While a permission request is waiting at the light, **Restart**, **Update**
  and **Install** wait too, so an agent's permission hook is never cut off.
- **Keep it in a normal folder.** Launched straight from the DMG (or from a temporary location macOS
  moves it to, called App Translocation), ccemaphore can't update — the panel asks you to move it to
  **Applications**.
- **Coming from 1.2.x or earlier?** Those versions have no updater: download 1.3.0 and drag it over the
  old copy once — from then on it updates itself. 1.3.0 is signed by a new developer team, so an
  Accessibility permission you gave an older version no longer applies, even though System Settings ▸
  Privacy & Security ▸ Accessibility may keep showing ccemaphore as allowed. Remove it there (**−**)
  and add it again (**+**), or switch it off and on.

## Contributing & building from source

Requires **macOS 13+** and **Xcode 26**. The project is a committed Xcode project (not SwiftPM), so
`swift build` won't work — open it in Xcode and press ⌘R (the floating light appears; there's no Dock
icon):

```sh
open ccemaphore.xcodeproj
```

To assemble a local (unsigned) `.app` for quick testing — a Release build via `xcodebuild`, written to
`build/ccemaphore.app`:

```sh
Scripts/package_app.sh
```

It runs as built. Don't re-sign it ad hoc with `--options runtime`: Hardened Runtime would then refuse to
load the embedded Sparkle framework, and the app would crash at launch.

Builds you make yourself (⌘R, `package_app.sh`) never update themselves — only Developer ID–signed
releases do. The one dependency, [Sparkle](https://sparkle-project.org), comes in as a Swift package
pinned to 2.10.0; Xcode fetches it the first time you open the project.

App Sandbox is **off** (required to read `~/.claude`), so distribution is outside the Mac App Store.
Issues and pull requests are welcome. Signed releases are cut by the maintainer via GitHub Actions —
see [`docs/RELEASING.md`](docs/RELEASING.md).

## Credits

Thanks to everyone who contributed features to ccemaphore:

- **[@Striker72rus](https://github.com/Striker72rus)** (Sergey Dontsov) — SSH remote-host monitoring
  & permission relay ([#1](https://github.com/hakkazuu/ccemaphore/pull/1)), plus the horizontal
  traffic-light layout and a fix for the floating widget escaping its Dock placement
  ([#2](https://github.com/hakkazuu/ccemaphore/pull/2)).

In-app updates are powered by [Sparkle](https://sparkle-project.org) (MIT License). Its license, together
with the notices of the code it includes, ships inside the app (open it from **Settings ▸ Updates**) and
in [`Resources/ThirdPartyNotices.txt`](Resources/ThirdPartyNotices.txt).

## License

MIT — see [LICENSE](LICENSE).
