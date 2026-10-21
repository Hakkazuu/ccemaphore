import Foundation
import CryptoKit

/// Codex's per-hook trust model, mirrored READ-ONLY so the Settings row can say where things stand.
/// Verified 2026-10-20 against the real codex-cli 0.163 app-server (`hooks/list` and `config/batchWrite`
/// on an isolated CODEX_HOME — the hash vectors in `SelfTests` come from it) and openai/codex
/// (`hooks/src/engine/discovery.rs`, `hooks/src/lib.rs`, `config/src/fingerprint.rs`):
///  - Codex does NOT trust hooks.json as a file. Every handler of every matcher group is trusted on its
///    own, under the key `<realpath(CODEX_HOME)>/hooks.json:<event label>:<group index>:<handler index>`;
///  - its `current_hash` is `sha256:` + the hex SHA-256 of the compact, key-sorted JSON of a NORMALIZED
///    identity: `{"event_name", "matcher"?, "hooks": [handler]}` with the timeout filled in / clamped and
///    `commandWindows` dropped (`declarationHash`);
///  - approving one ("Review hooks" in the ChatGPT app, `/hooks` in the CLI) writes
///    `[hooks.state."<key>"] trusted_hash = "<current_hash>"` to config.toml; switching it off adds
///    `enabled = false`. Equal hash → trusted, different → modified, none → untrusted (skipped until
///    approved).
/// ccemaphore never writes that record: trust stays the user's act in Codex.
enum CodexHookTrust {
    enum Trust: String, Sendable, Equatable {
        case trusted, untrusted, modified
    }

    /// One of OUR handlers in hooks.json, with Codex's verdict on it.
    struct Entry: Sendable, Equatable {
        let event: String
        let key: String
        let currentHash: String
        let trustedHash: String?
        let enabled: Bool

        var trust: Trust {
            guard let trustedHash else { return .untrusted }
            return trustedHash == currentHash ? .trusted : .modified
        }
    }

    /// The `[hooks.state."<key>"]` record Codex keeps per handler.
    struct State: Sendable, Equatable {
        var trustedHash: String?
        var enabled: Bool?
    }

    // MARK: - Codex's identity rules

    /// `hook_event_key_label` — the event's name inside a trust key and inside the hashed identity.
    static func eventLabel(_ event: String) -> String? {
        switch event {
        case "PreToolUse":        return "pre_tool_use"
        case "PermissionRequest": return "permission_request"
        case "PostToolUse":       return "post_tool_use"
        case "PreCompact":        return "pre_compact"
        case "PostCompact":       return "post_compact"
        case "SessionStart":      return "session_start"
        case "SessionEnd":        return "session_end"
        case "UserPromptSubmit":  return "user_prompt_submit"
        case "SubagentStart":     return "subagent_start"
        case "SubagentStop":      return "subagent_stop"
        case "Stop":              return "stop"
        case "Interrupt":         return "interrupt"
        default:                  return nil
        }
    }

    /// `matcher_pattern_for_event`: these events ignore a matcher, so it is not part of their identity.
    private static let matcherlessEvents: Set<String> = ["UserPromptSubmit", "Stop", "Interrupt"]

    /// Only these events may carry `additionalContextLimit` (any other value is dropped, as Codex does).
    private static let contextLimitEvents: Set<String> =
        ["PreToolUse", "PostToolUse", "SessionStart", "UserPromptSubmit", "SubagentStart"]
    private static let defaultContextLimit = 2500

    /// `normalize_command_hook`: SessionEnd / Interrupt default to 1 s and are clamped to 1…3 s; every
    /// other event defaults to 600 s, minimum 1.
    static func normalizedTimeout(event: String, timeout: Int?) -> Int {
        if event == "SessionEnd" || event == "Interrupt" { return min(max(timeout ?? 1, 1), 3) }
        return max(timeout ?? 600, 1)
    }

    /// `<hooks.json path>:<label>:<group>:<handler>`. `hooksPath` must already be the physical path
    /// Codex sees (it canonicalizes CODEX_HOME — verified with a symlinked home).
    static func key(hooksPath: String, event: String, group: Int, handler: Int) -> String? {
        eventLabel(event).map { "\(hooksPath):\($0):\(group):\(handler)" }
    }

    /// The `current_hash` Codex computes for one command handler. nil for what Codex itself would skip or
    /// not hash this way (a non-command handler, an empty command, an unknown event).
    static func declarationHash(event: String, matcher: String?, handler: [String: Any]) -> String? {
        guard let label = eventLabel(event),
              handler["type"] as? String == "command",
              let command = handler["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var normalized: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": normalizedTimeout(event: event, timeout: (handler["timeout"] as? NSNumber)?.intValue),
            "async": (handler["async"] as? NSNumber)?.boolValue ?? false,
        ]
        if let message = handler["statusMessage"] as? String { normalized["statusMessage"] = message }
        if contextLimitEvents.contains(event),
           let limit = (handler["additionalContextLimit"] as? NSNumber)?.intValue, limit != defaultContextLimit {
            normalized["additionalContextLimit"] = limit
        }
        var identity: [String: Any] = ["event_name": label, "hooks": [normalized]]
        if !matcherlessEvents.contains(event), let matcher { identity["matcher"] = matcher }
        let digest = SHA256.hash(data: Data(CanonicalJSON.encode(identity).utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading the user's files

    /// Our handlers in a parsed hooks.json, each with its key, current hash and Codex's state record.
    /// `isOurs` picks the handlers by command.
    static func entries(hooksRoot: [String: Any], hooksPath: String, states: [String: State],
                        isOurs: (String) -> Bool) -> [Entry] {
        guard let hooks = hooksRoot["hooks"] as? [String: Any] else { return [] }
        var out: [Entry] = []
        for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
            guard let groups = value as? [[String: Any]] else { continue }
            for (g, group) in groups.enumerated() {
                let matcher = group["matcher"] as? String
                for (h, handler) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated() {
                    guard let command = handler["command"] as? String, isOurs(command),
                          let key = key(hooksPath: hooksPath, event: event, group: g, handler: h),
                          let hash = declarationHash(event: event, matcher: matcher, handler: handler) else { continue }
                    let state = states[key]
                    out.append(Entry(event: event, key: key, currentHash: hash,
                                     trustedHash: state?.trustedHash, enabled: state?.enabled ?? true))
                }
            }
        }
        return out
    }

    /// Every `hooks.state."<key>"` record in a flattened config.toml.
    static func states(in config: [[String]: MiniTOML.Value]) -> [String: State] {
        var out: [String: State] = [:]
        for (path, value) in config where path.count == 4 && path[0] == "hooks" && path[1] == "state" {
            switch (path[3], value) {
            case ("trusted_hash", .string(let h)): out[path[2], default: State()].trustedHash = h
            case ("enabled", .bool(let b)):        out[path[2], default: State()].enabled = b
            default: break
            }
        }
        return out
    }

    /// `[features] hooks = false` (or the deprecated `codex_hooks`) turns every hook off. On by default.
    static func hooksFeatureEnabled(in config: [[String]: MiniTOML.Value]) -> Bool {
        for key in ["hooks", "codex_hooks"] {
            if case .bool(false) = config[["features", key]] { return false }
        }
        return true
    }
}

/// Where ccemaphore's Codex hooks stand — what the Settings row shows and `--codex-hooks-status` prints.
struct CodexHooksStatus: Sendable, Equatable {
    enum Install: String, Sendable, Equatable {
        /// Nothing of ours in hooks.json.
        case none
        /// Exactly the current set (`CodexHooksInstaller.events`).
        case current
        /// Ours, but not the current set — an earlier version's layout, a missing event, or the un-tagged
        /// Claude-shaped copies ChatGPT.app's import writes. "Update" rewrites them.
        case outdated
    }

    /// One sentence's worth of state, in the order the user has to act on it.
    enum Summary: Sendable, Equatable {
        case notInstalled
        case outdated
        case featureOff
        /// `count` handlers wait for "Review hooks"; `modifiedOnly` when all of them were approved before
        /// and changed since (the wording differs: "approve again").
        case needsApproval(count: Int, modifiedOnly: Bool)
        case disabled(count: Int)
        case trusted
    }

    var install: Install = .none
    var featureEnabled = true
    var entries: [CodexHookTrust.Entry] = []

    static let notInstalled = CodexHooksStatus()

    var isInstalled: Bool { install != .none }

    var summary: Summary {
        switch install {
        case .none: return .notInstalled
        case .outdated: return .outdated
        case .current: break
        }
        guard featureEnabled else { return .featureOff }
        let pending = entries.filter { $0.trust != .trusted }
        if !pending.isEmpty {
            return .needsApproval(count: pending.count, modifiedOnly: pending.allSatisfy { $0.trust == .modified })
        }
        let off = entries.filter { !$0.enabled }.count
        return off > 0 ? .disabled(count: off) : .trusted
    }
}

/// serde_json's compact output after `sort_all_objects` — the exact bytes Codex hashes. Keys sorted by
/// UTF-8 bytes, no whitespace, `/` and non-ASCII left as is, `"` `\` and control characters escaped.
/// Written by hand instead of `JSONSerialization` because the latter escapes `/` and doesn't promise
/// this key order or escape set, and a single differing byte changes the hash.
enum CanonicalJSON {
    static func encode(_ value: Any) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: Any, into out: inout String) {
        switch value {
        case let d as [String: Any]:
            out += "{"
            for (n, key) in d.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }).enumerated() {
                if n > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(d[key]!, into: &out)
            }
            out += "}"
        case let a as [Any]:
            out += "["
            for (n, item) in a.enumerated() {
                if n > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case let s as String:
            writeString(s, into: &out)
        case let b as Bool:
            out += b ? "true" : "false"
        case let n as Int:
            out += String(n)
        default:
            out += "null"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
