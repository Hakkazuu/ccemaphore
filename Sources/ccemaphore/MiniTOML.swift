import Foundation

/// Read-only flattening of a TOML document into `[key path] → scalar`, just enough for the few Codex
/// `config.toml` keys ccemaphore reads (`hooks.state."<key>".trusted_hash` / `.enabled`,
/// `features.hooks`). Not a validating parser: it understands the shapes those keys can take — table
/// headers with dotted and quoted keys, dotted keys on the left of `=`, inline tables — and steps over
/// everything else (arrays, multi-line strings, numbers, dates, array-of-tables bodies) without
/// misattributing it. A line it can't make sense of is skipped, never fatal: the caller treats a missing
/// key as "no record", which is the safe reading for trust.
///
/// `config.toml` is the user's file, written by Codex (toml_edit) and by hand; we never write it.
enum MiniTOML {
    enum Value: Equatable, Sendable {
        case string(String)
        case bool(Bool)
        /// A number, date, array or anything else — present, but not a type we read.
        case other
    }

    static func flatten(_ text: String) -> [[String]: Value] {
        var p = Parser(Array(text.unicodeScalars))
        p.run()
        return p.out
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var table: [String] = []
        var out: [[String]: Value] = [:]

        init(_ s: [Unicode.Scalar]) { self.s = s }

        private var atEnd: Bool { i >= s.count }
        private func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }
        private func starts(_ lit: String) -> Bool {
            var j = i
            for c in lit.unicodeScalars {
                guard j < s.count, s[j] == c else { return false }
                j += 1
            }
            return true
        }

        mutating func run() {
            while true {
                skipBlankAndComments()
                guard let c = peek() else { return }
                let lineStart = i
                if c == "[" {
                    parseHeader()
                } else if let path = parseKeyPath(), peek() == "=" {
                    i += 1
                    skipInlineSpace()
                    parseValue(at: table + path)
                } else {
                    i = lineStart
                }
                skipToNextLine(from: lineStart)
            }
        }

        // MARK: Structure

        private mutating func parseHeader() {
            let isArray = peek(1) == "["
            i += isArray ? 2 : 1
            skipInlineSpace()
            guard let path = parseKeyPath() else { table = ["\u{0}invalid"]; return }
            // An array-of-tables body is never something we read; park it under a path no real key can
            // collide with, so `[[x]]` followed by `trusted_hash = …` can't masquerade as a hook record.
            table = isArray ? path + ["\u{0}array"] : path
            if peek() == "]" { i += isArray ? 2 : 1 }
        }

        /// `a.b."c d".'e'` — returns nil when no key starts here.
        private mutating func parseKeyPath() -> [String]? {
            var path: [String] = []
            while true {
                skipInlineSpace()
                guard let key = parseKey() else { return path.isEmpty ? nil : path }
                path.append(key)
                skipInlineSpace()
                guard peek() == "." else { return path }
                i += 1
            }
        }

        private mutating func parseKey() -> String? {
            guard let c = peek() else { return nil }
            if c == "\"" { i += 1; return parseBasicString() }
            if c == "'" { i += 1; return parseLiteralString() }
            var key = ""
            while let c = peek(), c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_" || c == "-" {
                key.unicodeScalars.append(c)
                i += 1
            }
            return key.isEmpty ? nil : key
        }

        private mutating func parseValue(at path: [String]) {
            guard let c = peek() else { return }
            if starts("\"\"\"") {
                i += 3
                out[path] = parseMultilineBasic().map(Value.string) ?? .other
            } else if starts("'''") {
                i += 3
                out[path] = parseMultilineLiteral().map(Value.string) ?? .other
            } else if c == "\"" {
                i += 1
                out[path] = parseBasicString().map(Value.string) ?? .other
            } else if c == "'" {
                i += 1
                out[path] = parseLiteralString().map(Value.string) ?? .other
            } else if c == "{" {
                i += 1
                parseInlineTable(at: path)
            } else if c == "[" {
                skipArray()
                out[path] = .other
            } else if starts("true"), !isBareChar(peek(4)) {
                i += 4
                out[path] = .bool(true)
            } else if starts("false"), !isBareChar(peek(5)) {
                i += 5
                out[path] = .bool(false)
            } else {
                while let c = peek(), c != "\n", c != ",", c != "}", c != "#" { i += 1 }
                out[path] = .other
            }
        }

        private mutating func parseInlineTable(at path: [String]) {
            while true {
                skipInlineSpace()
                guard let c = peek() else { return }
                if c == "}" { i += 1; return }
                if c == "," { i += 1; continue }
                if c == "\n" || c == "#" { return }   // malformed / unterminated: give up on this line
                guard let key = parseKeyPath(), peek() == "=" else { return }
                i += 1
                skipInlineSpace()
                parseValue(at: path + key)
            }
        }

        /// Skip a (possibly multi-line, nested) array, respecting strings and comments inside it.
        private mutating func skipArray() {
            var depth = 0
            while let c = peek() {
                if c == "\"" || c == "'" {
                    if starts("\"\"\"") { i += 3; _ = parseMultilineBasic() }
                    else if starts("'''") { i += 3; _ = parseMultilineLiteral() }
                    else if c == "\"" { i += 1; _ = parseBasicString() }
                    else { i += 1; _ = parseLiteralString() }
                    continue
                }
                if c == "#" { while let c = peek(), c != "\n" { i += 1 }; continue }
                i += 1
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1; if depth == 0 { return } }
            }
        }

        // MARK: Strings

        /// After the opening `"`. nil on an unterminated string (the cursor stops at the line end).
        private mutating func parseBasicString() -> String? {
            var str = ""
            while let c = peek() {
                if c == "\n" { return nil }
                i += 1
                if c == "\"" { return str }
                if c == "\\" { guard appendEscape(into: &str) else { return nil } }
                else { str.unicodeScalars.append(c) }
            }
            return nil
        }

        private mutating func parseLiteralString() -> String? {
            var str = ""
            while let c = peek() {
                if c == "\n" { return nil }
                i += 1
                if c == "'" { return str }
                str.unicodeScalars.append(c)
            }
            return nil
        }

        private mutating func parseMultilineBasic() -> String? {
            var str = ""
            if peek() == "\n" { i += 1 } else if peek() == "\r", peek(1) == "\n" { i += 2 }
            while !atEnd {
                if starts("\"\"\"") {
                    i += 3
                    // Up to two quotes may sit right before the closing delimiter.
                    while peek() == "\"" { str.unicodeScalars.append("\""); i += 1 }
                    return str
                }
                let c = s[i]
                i += 1
                if c == "\\" {
                    // A line-ending backslash trims the newline and the leading whitespace after it.
                    var j = i
                    while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                    if j < s.count, s[j] == "\n" || s[j] == "\r" {
                        i = j
                        while let w = peek(), w == " " || w == "\t" || w == "\n" || w == "\r" { i += 1 }
                        continue
                    }
                    guard appendEscape(into: &str) else { return nil }
                } else {
                    str.unicodeScalars.append(c)
                }
            }
            return nil
        }

        private mutating func parseMultilineLiteral() -> String? {
            var str = ""
            if peek() == "\n" { i += 1 } else if peek() == "\r", peek(1) == "\n" { i += 2 }
            while !atEnd {
                if starts("'''") {
                    i += 3
                    while peek() == "'" { str.unicodeScalars.append("'"); i += 1 }
                    return str
                }
                str.unicodeScalars.append(s[i])
                i += 1
            }
            return nil
        }

        /// The escape after a `\` (already consumed). false on an invalid escape.
        private mutating func appendEscape(into str: inout String) -> Bool {
            guard let e = peek() else { return false }
            i += 1
            switch e {
            case "b": str.unicodeScalars.append("\u{08}")
            case "t": str.unicodeScalars.append("\t")
            case "n": str.unicodeScalars.append("\n")
            case "f": str.unicodeScalars.append("\u{0C}")
            case "r": str.unicodeScalars.append("\r")
            case "e": str.unicodeScalars.append("\u{1B}")
            case "\"": str.unicodeScalars.append("\"")
            case "\\": str.unicodeScalars.append("\\")
            case "x": return appendHex(digits: 2, into: &str)
            case "u": return appendHex(digits: 4, into: &str)
            case "U": return appendHex(digits: 8, into: &str)
            default: return false
            }
            return true
        }

        private mutating func appendHex(digits: Int, into str: inout String) -> Bool {
            guard i + digits <= s.count else { return false }
            let hex = String(String.UnicodeScalarView(s[i..<(i + digits)]))
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { return false }
            str.unicodeScalars.append(scalar)
            i += digits
            return true
        }

        // MARK: Whitespace

        private func isBareChar(_ c: Unicode.Scalar?) -> Bool {
            guard let c else { return false }
            return c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_" || c == "-"
        }

        private mutating func skipInlineSpace() {
            while let c = peek(), c == " " || c == "\t" { i += 1 }
        }

        private mutating func skipBlankAndComments() {
            while let c = peek() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
                else if c == "#" { while let c = peek(), c != "\n" { i += 1 } }
                else { return }
            }
        }

        /// Finish the current line (trailing comment / junk). Always makes progress past `lineStart`, so a
        /// line the parser couldn't read can't stall the loop.
        private mutating func skipToNextLine(from lineStart: Int) {
            if i <= lineStart { i = lineStart + 1 }
            while let c = peek(), c != "\n" { i += 1 }
        }
    }
}
