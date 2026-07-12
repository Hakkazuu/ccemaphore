# ccemaphore

**English** · [Русский](README.ru.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md)

> A floating traffic light for your [Claude Code](https://claude.com/claude-code) sessions on macOS.

![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Latest release](https://img.shields.io/github/v/release/hakkazuu/ccemaphore?sort=semver)](https://github.com/hakkazuu/ccemaphore/releases/latest)

<p align="center">
  <img src="docs/media/demo.gif" alt="ccemaphore demo" width="700">
</p>

Run several Cursor / VS Code windows, each with multiple Claude Code chats, and one always-on-top
indicator tells you — at a glance, without switching windows — whether an agent is working, has
finished, or needs you.

## ⬇️ Download

### **[Download the latest release (.dmg)](https://github.com/hakkazuu/ccemaphore/releases/latest)**

Signed & notarized by Apple. Drag it into **Applications** and launch — no Gatekeeper warnings.
Requires **macOS 13 or later**. [Full install steps ↓](#install)

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

- **Hover the light** → a panel drops open with every live session grouped **WAITING → WORKING →
  DONE**: project · git branch · chat title · context % · the running command. From here you also get
  **Refresh**, **History**, **Settings**, and **Quit**.
- **Drag** the light anywhere; **pin** it to lock the position.
- **A chat needs permission?** The light turns into a **ribbon** right where it sits — **Allow once /
  Allow all in this chat / Deny**, plus the exact command — so you decide without opening the chat.
- **A chat finished?** A green "done" notice appears at the light; click **Go to chat** to jump
  straight to it (it raises the right Cursor tab, or the terminal).
- **Compacting context?** The yellow lamp shows a small compress chip — busy, not stuck.

Everything happens *at the light*. There are no system notification toasts to chase.

Token & cost stats per session and a daily history window come from
[`ccusage`](https://github.com/ryoppippi/ccusage) when it's available.

## Languages

ccemaphore ships fully localized in **English, Русский, Español, Deutsch, Français**, with **live**
switching — no relaunch. Open **Settings ▸ Language** and pick one from the menu (each shows its own
name and flag); the whole UI re-renders instantly. Leave it on **System** to follow your macOS
preferred languages (falling back to English).

This README is available in the same five languages — see the switcher at the top.

## Privacy

ccemaphore **only reads local files** and **never sends anything off your machine**. No telemetry.
It reads `~/.claude/projects` (transcripts) for status only — it does not parse, store, or transmit
chat content. `~/.claude` is a dot-folder (not a TCC-protected location), so no access prompt appears
for it.

## How it works

ccemaphore has two cooperating modes.

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
- **The interactive permission ribbon** (the 3-button Allow / Allow-all / Deny prompt above).
- **Trusted commands** — a list of commands you auto-approve, so no ribbon ever appears for them
  (matched as a substring of the command).

The hook install is an idempotent merge into `~/.claude/settings.json` and is fully reversible.

## Install

1. [**Download the latest `.dmg`**](https://github.com/hakkazuu/ccemaphore/releases/latest) — it's
   signed & notarized, so Gatekeeper opens it without warnings.
2. Open the DMG and drag **ccemaphore** into **Applications**.
3. Launch it. ccemaphore runs as a menu-less background app (no Dock icon) — just the floating light.

### First-launch setup (optional but recommended)

- **Grant Accessibility** (System Settings ▸ Privacy & Security ▸ Accessibility). It's used only to
  raise the exact Cursor window/tab when you click **Go to chat**, and to skip a notice for the chat
  you're already looking at.
- **Turn on "Precise status detection"** in Settings to enable Mode B (hooks + the permission ribbon).
- **For token & cost stats**, make sure Node or Bun is on your `PATH` — ccemaphore runs
  [`ccusage`](https://github.com/ryoppippi/ccusage) via `bunx`/`npx`. History still works without it;
  you just won't see token numbers.
- **If clicking a notice shuffles your desktops around** — that's macOS, not ccemaphore: the
  "Automatically rearrange Spaces based on most recent use" setting (System Settings ▸ Desktop & Dock ▸
  Mission Control). Turn it off, or run
  `defaults write com.apple.dock mru-spaces -bool false && killall Dock` — your Spaces keep their
  order, and jumping to the right window still works.

## Contributing & building from source

Requires **macOS 13+** and **Xcode 26**. The project is a committed Xcode project (not SwiftPM), so
`swift build` won't work — open it in Xcode:

```sh
open ccemaphore.xcodeproj   # then ⌘R — floating light, no Dock icon
```

To assemble a local (unsigned) `.app` for quick testing:

```sh
Scripts/package_app.sh    # → build/ccemaphore.app  (Release build via xcodebuild)
```

App Sandbox is **off** (required to read `~/.claude`), so distribution is outside the Mac App Store.
Issues and pull requests are welcome. Signed releases are cut by the maintainer via GitHub Actions —
see [`docs/RELEASING.md`](docs/RELEASING.md).

## Credits

Thanks to everyone who contributed features to ccemaphore:

- **[@Striker72rus](https://github.com/Striker72rus)** (Sergey Dontsov) — SSH remote-host monitoring
  & permission relay ([#1](https://github.com/hakkazuu/ccemaphore/pull/1)), plus the horizontal
  traffic-light layout and a fix for the floating widget escaping its Dock placement
  ([#2](https://github.com/hakkazuu/ccemaphore/pull/2)).

## License

MIT — see [LICENSE](LICENSE).
