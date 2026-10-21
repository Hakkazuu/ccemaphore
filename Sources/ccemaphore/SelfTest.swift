import Foundation

/// `ccemaphore --self-test [filter]` — the unit tests, built into the binary because the project has no
/// XCTest target (an Xcode-project app, verified headlessly; see CLAUDE.md). They exercise pure logic and
/// throwaway files under a temp dir only: no GUI, no network, never the user's ~/.claude or ~/.codex.
/// Exit status 0 = all passed. `filter` keeps the suites whose name contains it.
enum SelfTest {
    struct Suite {
        let name: String
        let body: (inout Tester) -> Void
    }

    static func allSuites() -> [Suite] {
        codexSuites() + agentSuites() + settingsSuites()
    }

    static func run(filter: String?) -> Int32 {
        var t = Tester()
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("ccemaphore-selftest-\(UUID().uuidString)")
        t.tempRoot = root
        defer { try? FileManager.default.removeItem(atPath: root) }
        let suites = allSuites().filter { s in filter.map { s.name.localizedCaseInsensitiveContains($0) } ?? true }
        for suite in suites {
            t.suite = suite.name
            let before = t.failures.count
            suite.body(&t)
            print("\(t.failures.count == before ? "ok  " : "FAIL") \(suite.name)")
        }
        print("\n\(t.checks) checks in \(suites.count) suites, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        return t.failures.isEmpty ? 0 : 1
    }
}

/// The assertion API the suites use. Failures are collected (one bad check never hides the next).
struct Tester {
    fileprivate(set) var checks = 0
    fileprivate(set) var failures: [String] = []
    fileprivate var suite = ""
    fileprivate var tempRoot = NSTemporaryDirectory()
    private var tempCount = 0

    mutating func expect(_ condition: Bool, _ what: @autoclosure () -> String,
                         file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if !condition { failures.append("\(suite): \(what())  (\(file):\(line))") }
    }

    mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: @autoclosure () -> String,
                                      file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if actual != expected {
            failures.append("\(suite): \(what()) — got \(actual), expected \(expected)  (\(file):\(line))")
        }
    }

    /// A fresh empty directory under this run's temp root (removed when the run ends).
    mutating func tempDir() -> String {
        tempCount += 1
        let dir = (tempRoot as NSString).appendingPathComponent("\(suite.replacingOccurrences(of: " ", with: "_"))-\(tempCount)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}
