import Foundation

/// Minimal test harness for the self-test executable. Accumulates pass/fail counts across
/// suites and exits non-zero if anything failed. Confined to the main actor because the code
/// under test (JSEngine, Chooser) is main-actor isolated.
@MainActor
final class Harness {
    private(set) var total = 0
    private(set) var failed = 0

    func suite(_ name: String) {
        print("\n• \(name)")
    }

    func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        total += 1
        if condition {
            print("  ok   \(name)")
        } else {
            failed += 1
            let d = detail()
            print("  FAIL \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        expect(actual == expected, name, "got \(actual), expected \(expected)")
    }

    func fail(_ name: String, _ detail: String = "") {
        total += 1
        failed += 1
        print("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func finish() -> Never {
        let passed = total - failed
        print("\n\(passed)/\(total) checks passed" + (failed == 0 ? "  ✅" : "  ❌ (\(failed) failed)"))
        exit(failed == 0 ? 0 : 1)
    }
}
