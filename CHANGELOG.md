# Changelog

All notable changes to **ccemaphore** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-10-12

**The last manual install.** 1.3.0 is the first version that updates itself. Coming from 1.2.x or
earlier, download it from the Releases page and drag it over the old copy one last time — from here on,
new versions arrive inside the app.

### Added
- **In-app updates** (Sparkle 2.10) — ccemaphore checks GitHub for new versions and installs them, no
  trip to the Releases page needed:
  - **Everything happens in the panel**, in the app's own language — update found, downloading, ready,
    errors. Sparkle's alerts never appear. After you click Update (or Install), a slow install may
    briefly show Sparkle's small installer progress window (in the macOS language).
  - **Your choice on first launch:** update automatically (check daily, download in the background),
    notify only (check daily; one click downloads, installs and relaunches) or off (no automatic checks;
    "Check now" still works). No automatic check runs before you choose. Change it any time in
    Settings ▸ Updates, which also shows your version and the last check.
  - **One-click restart:** once an update has downloaded in the background, Restart quits, swaps the app
    atomically and relaunches, and a one-time note confirms the new version. Quitting normally installs
    it too. If installing needs an administrator password (your account can't replace the app where
    it is: no write access, or another account installed it), the downloaded update waits for your
    Install click instead.
  - **Signed feed, signed archives:** the update feed and every download carry the project's EdDSA
    signature and are verified before anything is unpacked.
  - **Never cuts an agent off:** Restart, Update and Install are disabled while a permission request is
    pending, so the blocking permission hook always gets its answer.
  - **Safe fallbacks:** running from the DMG or a translocated location shows a "Move ccemaphore to
    Applications" note; if an install fails after the app quit, ccemaphore relaunches itself and says
    so instead of silently disappearing; if the app on disk is replaced while it runs (an update from
    another macOS account, or a manual reinstall), the panel offers a restart.
  - Sparkle's license and the notices for the code it includes ship inside the app
    (`ThirdPartyNotices.txt`).
- **Codex (ChatGPT app) support** — ccemaphore is now a traffic light for two agents. Codex threads from
  the ChatGPT app (and the Codex CLI) appear next to Claude Code chats with their own badge, title, branch,
  context % and token count. Mode A reads `~/.codex` only (rollout transcripts, the thread catalog, writer
  locks); nothing is installed. The thread's `codex://threads/<id>` link opens it in the ChatGPT app.
- **Codex hooks (opt-in)** — "Precise status via Codex hooks" writes ccemaphore's hooks to
  `~/.codex/hooks.json` for instant done/interrupted detection, plus a separate Codex permission hook
  (red light + ribbon when Codex asks for approval; trusted commands auto-allowed). Codex requires you to
  **trust** the file once (ChatGPT app → Codex settings → Hooks, or `/hooks` in the CLI); the Settings row
  shows where that stands.
- **Claude Code session registry** — Claude Code ≥ 2.1.29x publishes its own busy / idle / waiting
  state per running session (`~/.claude/sessions`). ccemaphore now uses it as the primary source: precise
  "waiting for permission" / "waiting for your answer" captions, user-given session names as titles, the
  stable launch folder as the project, and the host (desktop app / IDE / terminal) without hooks.
- **Claude desktop app** is a first-class host: chats from the Code tab get the right badge, "Open chat"
  raises the app and asks it to show the session, and the registry fills in what the process tree
  couldn't. The Allow/Deny ribbon for desktop chats is behind an experimental toggle until verified live.
- **Expandable chats** — a chat with sub-agents (Claude `Task` agents, workflow fan-outs, Codex
  sub-agent threads) grows a chevron; expand it to see each sub-agent's state, prompt and age.
- **Product groups** — group chats by product folder (backend + frontend + landing) instead of by status.
  ChatGPT app projects and folders with 2+ active repos are suggested automatically; add your own roots
  in Settings. Rows show `product › sub-repo`.
- **Codex limits** — the 5-hour / weekly usage windows Codex reports (used %, reset time) at the bottom of
  the Chats tab.
- **History for both agents** — the History window now covers Codex too (ccusage ≥ 20 reports Claude Code
  and Codex together): day bars split into Claude / Codex segments, per-agent totals, a Claude / Codex
  badge on each chat, and an All / Claude / Codex filter. Codex threads are labelled from Codex's own
  thread catalog (name, project). Claude-only installs see the window unchanged.
- **Priced Codex rows** — a Codex thread's row shows ccusage's cost once it has one, instead of only the
  catalog's token count.
- **Badges at the light** — permission, question and "done" ribbons carry the agent badge (Claude / Codex)
  and the host glyph next to the project, like the panel rows.
- **Badges** — every row carries an agent badge (Claude / Codex) and a host glyph (Claude app, IDE,
  Terminal, ChatGPT app). A thread the ChatGPT app imported from Claude keeps its Claude badge; a pure
  mirror (no Codex turns) is hidden so nothing is listed twice.
- Diagnostics: `--registry-dump`, `--codex-scan`, `--codex-probe <rollout>`, `--codex-db-probe`,
  `--groups-dump`, `--usage-dump`, `--codex-hooks-status`, `--install-codex-hooks`,
  `--uninstall-codex-hooks`, `--update-status`; `--scan` shows the registry overlay and sub-agent
  counts.

### Changed
- Permission hook wait policy is now per host: IDE chats block as before; Claude desktop chats block
  only with the experimental toggle; Codex chats never block (Codex shows its own prompt only after the
  hook returns), so the ribbon there is informational and opens the thread.
- Hook status files carry `agent` and `entrypoint`; Codex sessions are keyed `codex:<thread_id>`.
- **Version numbers now come from the build settings** (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`)
  instead of literals in `Info.plist`. Because of those literals, releases 1.0.1, 1.0.2 and 1.1.0
  reported themselves as 1.0.0 (build 1). From 1.3.0 on, the version always matches the release and the
  build number only ever goes up.
- **Releases are signed by a new Developer ID team** (the maintainer's company). macOS ties the
  Accessibility permission to the signer, so a permission granted to 1.2.x no longer applies after you
  install 1.3.0, even though System Settings ▸ Privacy & Security ▸ Accessibility may keep showing
  ccemaphore as allowed. Remove it there (−) and add it again (+), or switch it off and on.
- **Privacy wording:** the README now lists exactly what reaches the network — update checks to GitHub,
  optional ccusage / npm traffic and optional SSH to your own hosts — instead of "never sends anything".

### Fixed
- Launching ccemaphore straight from the mounted DMG, or from a translocated location, no longer
  re-points the Claude Code hooks at that temporary path — which made every hook fail with a "hook
  error" once the DMG was ejected. From such a location the hook self-heal (Claude Code and Codex) is
  skipped, installing hooks is refused, and ccemaphore asks you to move it to Applications first.

## [1.2.1] - 2026-07-19

### Fixed
- The floating widget no longer jumps above the Dock when a permission ribbon resizes it taller — the
  resize backstop clamp now preserves a Dock-level placement, matching the shared `clamp()`.
  Thanks @Striker72rus (Sergey Dontsov).

## [1.2.0] - 2026-07-19

### Added
- **Notifications & sound settings** — a new "Notifications & sound" section in Settings that finally
  lets you tune notifications instead of getting one fixed alert for everything:
  - Configure **show / sound / volume** independently for each notification type — **Completion**,
    **Permission request**, and **Agent question** — each inheriting a general default unless you turn
    on "Customize" for that type (so you can, e.g., silence "done" chats while keeping permission alerts
    loud).
  - **Built-in sound presets** — the ccemaphore chime plus a set of macOS system sounds (Glass, Ping,
    Hero, Submarine, Funk, Pop, Tink) — auditionable right in Settings.
  - **Import your own sound** (up to 5 seconds). It's validated and copied into the app's own storage,
    so deleting the original file never breaks the notification.
- **Collapsible settings sections** — every section in the Settings tab now collapses to its header, so
  the (now longer) settings screen opens compact; the expanded/collapsed state is remembered.

### Changed
- Wider settings panel (300 → 360 pt) and single-line section headers, for a less cramped layout.

## [1.1.0] - 2026-07-12

### Added
- **SSH remote-host monitoring** — watch Claude Code sessions running on remote machines over SSH and
  answer their permission prompts without switching to that machine's window.
- **Horizontal traffic-light layout** option for the floating widget.

### Thanks
- Community contributions — see the Credits section of the README.

## [1.0.1] - 2026-07-03 · [1.0.2] - 2026-07-03

Early patch releases following the initial launch. See the
[GitHub release notes](https://github.com/hakkazuu/ccemaphore/releases) for details.

## [1.0.0] - 2026-07-03

### Added
- Initial public release: a macOS menu-bar / floating traffic light that summarizes the status of many
  Claude Code sessions at a glance (🟡 working / 🟢 done / 🔴 needs you / ⚪ idle).
  - **Mode A** — always-on file-watch of `~/.claude/projects`, zero setup.
  - **Mode B** — opt-in Claude Code hooks for precise done/waiting detection and interactive permission
    prompts, plus token/cost stats via `ccusage`.
- Full localization: English, Русский, Español, Deutsch, Français.

[1.3.0]: https://github.com/hakkazuu/ccemaphore/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/hakkazuu/ccemaphore/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/hakkazuu/ccemaphore/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/hakkazuu/ccemaphore/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/hakkazuu/ccemaphore/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/hakkazuu/ccemaphore/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/hakkazuu/ccemaphore/releases/tag/v1.0.0
