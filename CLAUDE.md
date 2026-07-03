# CLAUDE.md

Guidance for AI agents working in this repo. Read this before building, "running", or touching app
bundles.

## What this is

**ccemaphore** — a macOS menu-bar traffic light for [Claude Code](https://claude.com/claude-code)
sessions. One indicator (🟡 working / 🟢 done / 🔴 needs you / ⚪ idle) summarizes many Claude Code
chats across windows, so you never window-switch to check status.

Two cooperating modes:
- **Mode A (always on)** — FSEvents file-watch of `~/.claude/projects/**/*.jsonl`; infers state from
  each transcript's tail. Zero setup.
- **Mode B (opt-in, one click in the menu)** — installs Claude Code hooks for *precise* `done`/`waiting`
  detection, plus macOS notifications (tap → jump to the chat) and an optional interactive permission
  prompt (Allow once / Allow all in chat / Deny) right from the notification.

Token/cost stats and the daily-history window come from [`ccusage`](https://github.com/ryoppippi/ccusage)
when present. **Privacy:** reads local files only, never transmits anything; reads `~/.claude` for
status, never parses or stores chat content.

## Stack

- **Swift 6 + SwiftUI + AppKit**, `MenuBarExtra` (`.window` style), FSEvents, `UNUserNotificationCenter`.
- **Xcode project** (`ccemaphore.xcodeproj`) — **not** SwiftPM. There is no `Package.swift`; `swift build`
  / `swift test` will not work. Compile via `xcodebuild`.
- macOS 13+, Xcode 26. App Sandbox **off** (needed to read `~/.claude`); Hardened Runtime on.
- Optional runtime dependency: `ccusage` CLI (graceful if absent).

## Architecture map

- **State / orchestration:** `StateEngine` (`@MainActor ObservableObject`, the single source the UI
  observes), `SessionStore`, `Models`.
- **Transcript watching / classification:** `TranscriptWatcher` (FSEvents), `TranscriptParser`,
  `TailReader`, `StatusReader`, `SessionPath`.
- **Mode B hooks:** `HookHandler` (`--hook <event>` writes `~/.claude/status/<id>.json`, no `jq` dep),
  `HooksInstaller` (idempotent settings.json merge), `PermissionBroker` (blocking PreToolUse flow +
  allow-all memory), `StatusLineHandler` (limits/context capture).
- **Notifications / focus:** `NotificationManager` (done/waiting/permission categories + auth status),
  `DeepLinker` / `FocusResolver` (focus the Cursor window + exact chat).
- **Usage:** `UsageProvider`, `UsageStatusReader` (ccusage join key is `period`).
- **UI:** `MenuContentView` (popover), `HistoryView`, `UIHelpers`, `App` / `AppDelegate`.
- **Localization:** `Localization.swift` (`Loc` resolver, `L`/`Lf`/`Lcount`/`Lplural`, `LocalizationManager`);
  strings in `Resources/Localizable.xcstrings`. See the localization rules below.
- **Diagnostics:** `Diagnostic`.

## 🌐 Localization — NEVER hardcode UI text

The app is fully localized (**en = source/base, plus ru, es, de, fr**) with **live** language switching.
**Any user-facing text you add MUST go through the localization layer — no hardcoded string literals in
the UI, notifications, or user-facing errors.** A new feature that shows text is not done until its
strings exist in all five languages.

**How to add text:**
1. Add a key to `Resources/Localizable.xcstrings` with values for **all 5 languages** (`en` is the
   source — write that first; translate the rest). It's plain JSON; keep `%@`/`%lld`/`%1$@` placeholders
   identical across languages.
2. Use it in code: `L("key")` for plain text, `Lf("key", args…)` for formatted/positional, `Lcount("noun.x", n)`
   for "N things", `Lplural("noun.x", n)` for the bare pluralized noun. (Defined in `Localization.swift`.)
3. **Plurals** are manual CLDR, stored as flat sub-keys `noun.x.{one,few,many,other}`: Russian needs
   `one`/`few`/`many`, the others `one`/`other`. Don't use catalog `%#@@` plural variations.
4. If the text lives in a **new top-level view**, make it observe `LocalizationManager.shared` (e.g.
   `@ObservedObject private var loc = LocalizationManager.shared`) so it re-renders on language change.
   Text shown **outside SwiftUI** (notification action titles, AppKit window titles) must be refreshed in
   `LocalizationManager.set` (see how notification categories re-register / the history window retitles).
5. Dates/numbers: format via `Fmt` (it's already locale-aware), not hand-built strings.

**What is NOT localized** (leave as-is): proper nouns (`ccemaphore`, `Claude Code`, `Cursor`, `ccusage`,
`settings.json`), emoji, and the developer-facing CLI (`--help`/diagnostic output) — English is fine there.

**Verify** with `ccemaphore --l10n-check` (see below) — it prints strings + plurals + dates for every
language so you can confirm resolution headlessly, without the GUI.

## How to verify changes

There is **no XCTest suite**. Verification = compile check + the headless diagnostic CLI.

- **Compile check** — build into a *throwaway* derived-data path, then clean it up (see rule below):
  ```sh
  DD="$(mktemp -d)"
  xcodebuild -project ccemaphore.xcodeproj -scheme ccemaphore -configuration Debug \
    -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO
  ```
- **Headless diagnostic CLI** (no GUI, exits immediately, does not request notifications — safe to run):
  - `ccemaphore --scan` — one-shot classification pass over `~/.claude/projects`.
  - `ccemaphore --probe <file.jsonl>` — per-stage heuristic result for one transcript.
  - `ccemaphore --status-dump` — current mode-B hook status files.
  - `ccemaphore --l10n-check` — print localized strings + plurals + dates for every language (verify i18n).
  - `ccemaphore --hooks-status` / `--install-hooks` / `--uninstall-hooks`.
  - Test seam: set `CCEMAPHORE_SETTINGS_PATH` to point hook install/uninstall at a scratch
    settings.json instead of the user's real `~/.claude/settings.json`.

## 🚫 Hard rules — ad-hoc builds & running the app

These exist because macOS keys notification authorization on bundle id + code signature. Multiple
copies of `com.hakkazuu.ccemaphore` registered under **different** signatures (the properly-signed
Xcode build vs. ad-hoc/unsigned builds in `/tmp`, scratchpad, or `build/`) poison the grant, and
`requestAuthorization` then returns `notificationsNotAllowed` — notifications silently die.

1. **Only the user runs and UI-tests the app, via Xcode (⌘R).** Agents must not `open`, launch, or
   leave the GUI app running. Do not leave a `ccemaphore` process alive.
2. **You MAY create ad-hoc/unsigned builds for compile-checking — but you MUST remove them right
   after**, so none linger. Build to a temp `-derivedDataPath`, then unregister + delete it:
   ```sh
   LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
   APP="$DD/Build/Products/Debug/ccemaphore.app"
   [ -e "$APP" ] && "$LSR" -u "$APP"     # unregister from LaunchServices
   rm -rf "$DD"                           # delete the build
   ```
   Verify nothing stray remains:
   `"$LSR" -dump | grep -i 'ccemaphore\.app'` — only the user's Xcode DerivedData copy (and any
   `/Applications` install) should resolve to a real on-disk path.
3. **Never build ad-hoc (`CODE_SIGNING_ALLOWED=NO`) into the default DerivedData** path
   (`~/Library/Developer/Xcode/DerivedData/ccemaphore-*`) — that overwrites the user's properly-signed
   build with an ad-hoc one and breaks their notifications. Always use a separate temp path.
4. **Do not run `Scripts/package_app.sh`** (it produces an ad-hoc `build/ccemaphore.app`) unless asked;
   if you do, treat its output as an ad-hoc copy and clean it up per rule 2.
5. To kill a stray running copy if one ever appears: `pkill -x ccemaphore`.

## Further docs

- **Releasing** (signing, notarization, CI secrets, security model): `docs/RELEASING.md`.
- Non-obvious verified contracts and gotchas (ccusage JSON shape, the notification signature gotcha,
  statusLine usage capture, history retention, etc.) are captured inline in the code comments near the
  relevant types — see the architecture map above for where each lives.
