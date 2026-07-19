# Changelog

All notable changes to **ccemaphore** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.2.1]: https://github.com/hakkazuu/ccemaphore/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/hakkazuu/ccemaphore/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/hakkazuu/ccemaphore/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/hakkazuu/ccemaphore/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/hakkazuu/ccemaphore/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/hakkazuu/ccemaphore/releases/tag/v1.0.0
