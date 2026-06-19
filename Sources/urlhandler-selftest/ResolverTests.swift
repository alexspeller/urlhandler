import Foundation
import URLHandlerKit

@MainActor
func runResolverTests(_ h: Harness) async {
    h.suite("Resolver — offline behavior")

    // Non-http(s) input is rejected without touching the network.
    do {
        _ = try await Resolver(timeout: 1).finalURL(for: "mailto:x@example.com")
        h.fail("rejects non-http url", "did not throw")
    } catch let error as ResolverError {
        if case .invalidURL = error { h.expect(true, "rejects non-http url") }
        else { h.fail("rejects non-http url", "wrong case: \(error)") }
    } catch {
        h.fail("rejects non-http url", "wrong type: \(error)")
    }

    // withTimeout returns fast results and times out slow ones.
    do {
        let value = try await withTimeout(seconds: 1) { 42 }
        h.expectEqual(value, 42, "withTimeout passes through fast result")
    } catch {
        h.fail("withTimeout fast result", "threw \(error)")
    }
    do {
        _ = try await withTimeout(seconds: 0.1) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        h.fail("withTimeout times out", "did not throw")
    } catch let error as ResolverError {
        h.expectEqual(error, .timeout, "withTimeout times out")
    } catch {
        h.fail("withTimeout times out", "wrong type: \(error)")
    }
}
