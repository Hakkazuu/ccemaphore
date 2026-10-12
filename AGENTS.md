# AGENTS.md

Guidance for AI agents (Codex and others) working in this repo. Read this before building, "running", or
touching app bundles. This file mirrors `CLAUDE.md` — change both together.

## What this is

**ccemaphore** — a macOS menu-bar traffic light for [Claude Code](https://claude.com/claude-code)
and [Codex](https://chatgpt.com/codex) (ChatGPT app) sessions. One indicator (🟡 working / 🟢 done /
🔴 needs you / ⚪ idle) summarizes many agent chats across windows and apps, so you never window-switch
to check status.

Sources of state, per agent:
- **Claude Code — session registry (primary, zero setup)** — Claude Code ≥ 2.1.29x writes
  `~/.claude/sessions/<pid>.json` (busy / idle / waiting + `waitingFor`, name, entrypoint, launch cwd).
  `SessionRegistryReader` reads it; `StateEngine.render()` applies it over the two inferred sources below.
- **Claude Code — Mode A (always on)** — FSEvents file-watch of `~/.claude/projects/**/*.jsonl`; infers
  state from each transcript's tail. Also supplies title/branch/context % and sub-agent children.
- **Claude Code — Mode B (opt-in)** — installs Claude Code hooks for *precise* `done`/`waiting`
  detection and the interactive permission ribbon (Allow / Deny / All in chat).
- **Codex — Mode A (always on when `~/.codex` exists)** — FSEvents over `~/.codex/sessions/**/rollout-*.jsonl`
  + the SQLite thread catalog (`state_5.sqlite`, read-only) + writer locks (`thread-writer-locks/`).
  `CodexSessionStore`/`CodexRolloutParser`/`CodexIndex`/`CodexPaths`. Sessions are keyed `codex:<thread_id>`.
- **Codex — Mode B (opt-in)** — `CodexHooksInstaller` writes our hooks (tagged `--agent codex`) to
  `~/.codex/hooks.json`; Codex must then TRUST the file (hash-bound, user action in the ChatGPT app or
  `/hooks`). We never write that trust record ourselves.
- Hosts (`SessionHost`): `ide` (Cursor/VS Code), `terminal`, `desktop` (Claude app), `codexApp`
  (ChatGPT app). The permission broker may block only where the host shows its own prompt alongside
  (`PermissionBroker.mayBlock`): IDE yes; desktop behind `WidgetSettings.desktopPermissionWait`; Codex never.

Token/cost stats and the daily-history window come from [`ccusage`](https://github.com/ryoppippi/ccusage)
when present. ccusage ≥ 20 reports Claude Code AND Codex in one unified output (`agent` per session row,
`daily --by-agent` for the per-day split); `UsageProvider` keys Codex rows `codex:<thread_id>` so they join
the live list, and the History window shows the Claude/Codex split + an agent filter when Codex usage exists.

**In-app updates (GUI process only):** Sparkle 2.10.0 driven by a custom `SPUUserDriver`, so every update
state renders inside ccemaphore's own panel in the live in-app language — Sparkle's alerts never appear.
After the user clicks Update / Install, a slow install may briefly show Sparkle's small installer progress
window (`Updater.app`, in the macOS language); the silent Restart path shows none. Modes `automatic` /
`notifyOnly` / `off`, chosen once in a first-launch consent row. Feed: the `appcast.xml` asset of the
latest GitHub release (`SURequireSignedFeed` + `SUVerifyUpdateBeforeExtraction`; the archive is the
notarized, stapled, EdDSA-signed DMG). The updater never runs in Debug builds, in builds not signed with a
Developer ID, or from a read-only / translocated location. Release pipeline and the live update test:
`docs/RELEASING.md`.

**Privacy:** status comes from local files only (mainly `~/.claude`, `~/.codex`); chat content is never
stored or transmitted, and there is no telemetry. What reaches the network: Sparkle update checks and
downloads from GitHub (asked on first launch; automatic / notify-only / off; GitHub sees the IP, the app
version in the User-Agent and the preferred language; each check bumps the public download counter of
`appcast.xml`; cookies are not stored), `ccusage` via `bunx`/`npx` when Node/Bun is present (npm
registry, pricing data), and the opt-in SSH remote hosts. Keep the README ×5 privacy sections in sync
with any change here.

## Stack

- **Swift 6 + SwiftUI + AppKit** — a floating, non-activating `NSPanel` widget plus a manual
  `NSStatusItem`; FSEvents. No `MenuBarExtra` and no `UNUserNotificationCenter`: everything is shown at
  the light.
- **Xcode project** (`ccemaphore.xcodeproj`) — **not** SwiftPM. There is no `Package.swift`; `swift build`
  / `swift test` will not work. Compile via `xcodebuild`.
- **One package dependency: Sparkle 2.10.0** (SPM, `exactVersion`), pinned in
  `ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (committed). A Sparkle
  bump is a planned change that re-runs the live update test — never bump it casually.
- macOS 13+, Xcode 26. App Sandbox **off** (needed to read `~/.claude`); Hardened Runtime on.
- Optional runtime dependency: `ccusage` CLI (graceful if absent).

## Architecture map

- **State / orchestration:** `StateEngine` (`@MainActor ObservableObject`, the single source the UI
  observes), `SessionStore` (Claude transcripts + sub-agent children), `SessionRegistryReader`
  (Claude Code's own registry), `CodexSessionStore` (Codex), `ProductGroups` (grouping by product folder),
  `Models`.
- **Transcript watching / classification:** `TranscriptWatcher` (FSEvents), `TranscriptParser`,
  `TailReader`, `StatusReader`, `SessionPath`; Codex: `CodexPaths`, `CodexRolloutParser`, `CodexIndex`
  (SQLite3, read-only, retried).
- **Mode B hooks:** `HookHandler` (`--hook <event> [--agent codex]` writes `~/.claude/status/<id>.json`,
  no `jq` dep), `HooksInstaller` (idempotent settings.json merge), `CodexHooksInstaller`
  (`~/.codex/hooks.json`, trust state), `PermissionBroker` (blocking PermissionRequest flow +
  allow-all memory + per-host `mayBlock`), `PermissionRules` (skip calls Claude Code auto-approves +
  trusted commands), `AppPresence` (GUI liveness beacon the blocking hook checks), `ProcTree` (owner pid +
  host; honours `CLAUDE_CODE_ENTRYPOINT`).
- **Ribbons / sound / focus:** in-widget ribbons only, no system notifications — `NotificationSettings`
  + `NotificationSettingsView` (per-type show / sound / volume), `SoundPlayer` / `SoundCatalog` /
  `SoundImporter`; `FocusResolver` (Accessibility trust + `--ax-dump`), `DeepLinker` (Open chat / a row
  click: the Cursor window + exact chat, the Claude app, the Codex thread).
- **Usage:** `UsageProvider` (ccusage `session` / `daily [--by-agent]`; the join key is `period`).
- **Remote hosts (SSH, opt-in):** `RemoteHosts`, `RemoteExec` (the only place that runs `ssh`),
  `RemoteTranscriptPoller`, `RemotePermissionRelay`, `RemoteHooksInstaller` + `RemoteHookShim`,
  `RemoteHostsView`.
- **Updates (Sparkle 2.10, GUI only):** `UpdateModel` (the contract — `UpdateAvailability`, `UpdateMode`,
  `UpdateInfo`, `UpdateRequirement`, `UpdateFailure`, `UpdatePhase`; no `import Sparkle`, so no view
  depends on a Sparkle type), `AppUpdater` (the owner: launch gates → `availability`, modes + persistence,
  consent, the phase precedence in `recomputePhase`, silent background install + one-click restart,
  relaunch watchdog; Restart / Update / Install are disabled while `StateEngine.pendingRequests` is
  non-empty), `UpdateUserDriver` (custom `SPUUserDriver`: every Sparkle state becomes an `UpdatePhase` in
  the panel), `UpdateSupport` (Developer-ID / read-only-volume / App Translocation gates, the relaunch
  watchdog, `--update-status`), `UpdateViews` (the panel row + the Settings section). Hook and CLI
  processes never create the updater, but dyld still loads Sparkle.framework into every one of them:
  measured at about +1.1 ms per hook spawn, ~0.77 ms of it loading Sparkle.framework.
- **UI:** `FloatingWidgetController` (the floating light + management panel), `LightTowerView`,
  `PermissionRibbonView`, `FloatingPanelView` (panel: chats by status or by product, settings),
  `StatusItemController` (menu-bar item), `WidgetQuickSettings`, `WidgetSettings`, `SessionBadges`
  (agent badge, host glyph, child rows), `HistoryView`, `UIHelpers`, `DesignTokens`, `App` / `AppDelegate`.
- **Localization:** `Localization.swift` (`Loc` resolver, `L`/`Lf`/`Lcount`/`Lplural`, `LocalizationManager`);
  strings in `Resources/Localizable.xcstrings`. See the localization rules below.
- **Diagnostics:** `Diagnostic`, `CodexDiagnostic`, `Log` (file + console logging shared by every process).

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
   Text shown **outside SwiftUI** (menu items, AppKit window titles) must be refreshed in
   `LocalizationManager.set` (see how the history window retitles) or rebuilt when shown.
5. Dates/numbers: format via `Fmt` (it's already locale-aware), not hand-built strings.
6. **Update UI:** never show Sparkle's own strings or an error's `localizedDescription` — they follow the
   macOS language, not the in-app one. Map to `UpdateFailure` / `UpdatePhase` and render with `L()`.

**What is NOT localized** (leave as-is): proper nouns (`ccemaphore`, `Claude Code`, `Cursor`, `ccusage`,
`settings.json`), emoji, and the developer-facing CLI (`--help`/diagnostic output) — English is fine there.

**Verify** with `ccemaphore --l10n-check` (see below) — it prints strings + plurals + dates for every
language so you can confirm resolution headlessly, without the GUI.

## How to verify changes

There is **no XCTest suite**. Verification = compile check + the headless diagnostic CLI.

- **Compile check** — build into a *throwaway* derived-data path, then clean it up (see rule 2 below).
  Point SwiftPM at a persistent checkout cache so each throwaway build reuses the pinned Sparkle instead of
  re-resolving it:
  ```sh
  DD="$(mktemp -d)"
  SPM="$HOME/Library/Caches/ccemaphore-spm"   # any stable path outside the repo
  xcodebuild -project ccemaphore.xcodeproj -scheme ccemaphore -configuration Debug \
    -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -disableAutomaticPackageResolution \
    build CODE_SIGNING_ALLOWED=NO
  ```
  Dropping the two package flags also works — SPM then resolves into `$DD/SourcePackages` (network on
  first use) — but never let a build change `Package.resolved`.
- **Headless diagnostic CLI** (no GUI, exits immediately, never starts the updater — safe to run):
  - `ccemaphore --scan` — one-shot classification pass over `~/.claude/projects`.
  - `ccemaphore --probe <file.jsonl>` — per-stage heuristic result for one transcript.
  - `ccemaphore --status-dump` — current mode-B hook status files.
  - `ccemaphore --l10n-check` — print localized strings + plurals + dates for every language (verify i18n).
  - `ccemaphore --hooks-status` / `--install-hooks` / `--uninstall-hooks`.
  - `ccemaphore --registry-dump` — Claude Code's live session registry as the engine reads it.
  - `ccemaphore --codex-scan` / `--codex-probe <rollout.jsonl>` / `--codex-db-probe` — the Codex side.
  - `ccemaphore --codex-hooks-status` / `--install-codex-hooks` / `--uninstall-codex-hooks`.
  - `ccemaphore --groups-dump` — product groups (manual + Codex projects).
  - `ccemaphore --usage-dump` — run ccusage once; per-day totals with the Claude/Codex split + Codex join keys.
  - `ccemaphore --update-status` — the updater as this copy sees it, local checks only (no network, no
    Sparkle): version/build, signature + team, read-only / translocated location, the launch gate
    (`UpdateAvailability`), the `SU*` Info.plist keys (flags the placeholder `SUPublicEDKey`), the
    `update.*` / `SU*` defaults (mode, last check) and any `SUFeedURL` override. On a compile-check
    (Debug) build the gate is `debugBuild`.
  - `--relaunch-watchdog` is **internal**: the GUI spawns it (detached) right before it quits to install
    an update or to restart into a newer bundle; it waits for the quit and for Sparkle's installer, then
    reopens that bundle unless the same bundle (matched by its resolved path, as Sparkle does) is already
    running again — so a failed install never leaves the light gone. Another copy with the same bundle id
    (an Xcode Debug build) is reported but doesn't count. Never run it by hand;
    `--relaunch-watchdog <pid> <bundle> <install|restart> --dry-run` only reports what it would do.
  - Test seams: `CCEMAPHORE_SETTINGS_PATH` (Claude settings.json), `CCEMAPHORE_CODEX_HOOKS_PATH` +
    `CCEMAPHORE_CODEX_CONFIG_PATH` (Codex hooks.json / config.toml), `CCEMAPHORE_CODEX_HOME` (a fixture
    `~/.codex`), `CCEMAPHORE_REGISTRY_DIR` (a fixture `~/.claude/sessions`), `CCEMAPHORE_BASE_DIR`.
  - New Swift files must be registered in `ccemaphore.xcodeproj/project.pbxproj` by hand (explicit file
    refs, no synchronized groups). Mirror an existing file such as `UpdateModel.swift`: a
    `PBXFileReference`, a `PBXBuildFile` pointing at it, the reference in the `ccemaphore` group's
    `children` and the build file in the target's `PBXSourcesBuildPhase`, each under a fresh unique
    24-hex-digit ID.
- **Release scripts** — after changing anything in `Scripts/release/` or `.github/workflows/release.yml`,
  run `Scripts/release/selftest.sh`: no secrets, no network, nothing launched or registered (throwaway
  bundles under a test bundle id), everything deleted on exit.
- **Updates can't be exercised from a Debug build.** `AppUpdater` reports `debugBuild` there and never
  starts Sparkle (Sparkle would otherwise replace the DerivedData copy with the Developer-ID release and
  break the signature-keyed grants below). To review the update UI, use the DEBUG-only
  **Debug: Simulate Update** submenu of the status-bar (left-click) menu, which drives
  `AppUpdater.simulate(_:)` through every `UpdatePhase` ("Clear" ends it). A mode picked there (consent
  row, Settings) stays in memory: a Debug build never writes `update.mode` into the defaults domain it
  shares with the release.
  Real updates are tested only with notarized builds: two GitHub prereleases plus
  `defaults write com.hakkazuu.ccemaphore SUFeedURL <prerelease appcast URL>` on the user's Mac. The
  procedure and its checklist are in `docs/RELEASING.md`; it has two separate runs, because "Check now"
  always takes the click-driven path (available → Update → install and relaunch, no Restart click) and
  only a background check takes the silent automatic one (download → "ready to install" → Restart or
  install on quit). Only the user runs it, with the Xcode ⌘R copy quit for the whole test: that copy
  shares the bundle id and the defaults domain (`update.mode`, `SU*`) with the release, two running
  lights would answer the same sessions and permission requests, and every GUI launch of it re-points the
  Claude Code hooks in `~/.claude/settings.json` at its DerivedData binary (the launch-time heal) — open
  the `/Applications` copy once afterwards to point them back.

## 🚫 Hard rules — ad-hoc builds & running the app

These exist because macOS identifies the app by bundle id + code signature. The one privacy grant
ccemaphore uses — **Accessibility** (TCC; `FocusResolver`, Open chat) — is recorded against the
designated requirement of the copy the user approved, and **LaunchServices** keeps a record for every
registered copy of `com.hakkazuu.ccemaphore`. Extra copies registered under **different** signatures (the
properly-signed Xcode build vs. ad-hoc/unsigned builds in `/tmp`, scratchpad, or `build/`) make
LaunchServices resolve the bundle id to the wrong copy, and leave the user's Accessibility toggle bound to
a different signature than the one that runs (System Settings shows it on, `AXIsProcessTrusted()` says
no). The app no longer uses `UNUserNotificationCenter`, so the old "notifications silently die" symptom is
gone — the rules stay exactly as strict.

1. **Only the user runs and UI-tests the app, via Xcode (⌘R).** Agents must not `open`, launch, or
   leave the GUI app running. Do not leave a `ccemaphore` process alive.
2. **You MAY create ad-hoc/unsigned builds for compile-checking — but you MUST remove them right
   after**, so none linger. Build to a temp `-derivedDataPath`, then unregister + delete it — including
   Sparkle's nested `Updater.app`, which LaunchServices registers too. Unregister both paths once more
   after the delete: a nested `Updater.app` record can survive the first pass, and `lsregister -u` also
   works on a path that no longer exists.
   ```sh
   LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
   APP="$DD/Build/Products/Debug/ccemaphore.app"          # Release: …/Products/Release/ccemaphore.app
   UPD="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
   "$LSR" -u "$UPD"; "$LSR" -u "$APP"     # unregister from LaunchServices
   rm -rf "$DD"                           # delete the build
   "$LSR" -u "$UPD"; "$LSR" -u "$APP"     # again, on the now-missing paths
   "$LSR" -dump | grep -E 'path: .*(ccemaphore|Sparkle)'
   ```
   The last command must list only the user's own copies: the Xcode DerivedData build
   (`~/Library/Developer/Xcode/DerivedData/ccemaphore-*`) and any `/Applications/ccemaphore.app`, each
   possibly with its nested `Updater.app`. A `Sparkle/…/Updater.app` under another app's cache (e.g.
   `~/Library/Caches/com.openai.codex/…`) belongs to that app — leave it alone. Anything under your
   temp path means the cleanup isn't finished.
3. **Never build ad-hoc (`CODE_SIGNING_ALLOWED=NO`) into the default DerivedData** path
   (`~/Library/Developer/Xcode/DerivedData/ccemaphore-*`) — that overwrites the user's properly-signed
   build with an ad-hoc one and breaks their Accessibility grant. Always use a separate temp path.
4. **Do not run `Scripts/package_app.sh`** (it produces an ad-hoc `build/ccemaphore.app`) unless asked;
   if you do, treat its output as an ad-hoc copy and clean it up per rule 2.
5. To kill a stray running copy if one ever appears: `pkill -x ccemaphore`.
6. **Leave the app's update settings alone.** Never `defaults write` / `defaults delete` in
   `com.hakkazuu.ccemaphore` (Sparkle's `SU*` keys such as `SUFeedURL` / `SULastCheckTime`, or our
   `update.*` keys) unless the user explicitly asks — a stray `SUFeedURL` silently points the user's
   installed copy at another feed (`--update-status` flags such an override).

## Further docs

- **Releasing** (signing, notarization, the appcast, CI secrets, security model, the live update test):
  `docs/RELEASING.md` — the tracked, authoritative procedure.
- **In-app updates** — how it works lives in the code comments: the phase contract in `UpdateModel.swift`,
  the flows and the phase precedence (`recomputePhase`) in `AppUpdater.swift` / `UpdateUserDriver.swift`,
  the gates and the watchdog in `UpdateSupport.swift`.
- `docs/internal/` is **git-ignored on purpose**: the maintainer's local notes (e.g. the Russian design
  record `docs/internal/auto-update-plan.md`) exist only on their Mac and are missing from any other
  checkout. Never rely on them, and never put a procedure only there.
- Non-obvious verified contracts and gotchas (ccusage JSON shape, the signature / TCC gotcha,
  statusLine usage capture, history retention, etc.) are captured inline in the code comments near the
  relevant types — see the architecture map above for where each lives.
