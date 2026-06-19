import Foundation
import URLHandlerKit

@MainActor
func runJSEngineTests(_ h: Harness) async {
    h.suite("JSEngine — async bridge & decisions")

    // The critical mechanism: a JS route() that `await`s a native async function must resume
    // and return its result to Swift (native->JS promise, microtask draining on later fulfill,
    // JS-promise -> Swift-async bridge).
    do {
        let rules = "async function route(url, ctx){ return { browser: await resolve(url) }; }"
        let engine = try JSEngine(rulesSource: rules, resolver: { input in
            try await Task.sleep(nanoseconds: 30_000_000)
            return input + "#resolved"
        })
        let decision = try await engine.route(url: "https://example.com/x", ctx: ["opener": NSNull()])
        h.expectEqual(decision, .browser(key: "https://example.com/x#resolved", url: nil), "async resolve bridge")
    } catch {
        h.fail("async resolve bridge", "threw \(error)")
    }

    // Sync decisions + the prelude's URL shim (new URL(...).hostname).
    do {
        let rules = """
            function route(url, ctx){
              if (new URL(url).hostname.endsWith("github.com")) return { browser: "work" };
              return { prompt: true };
            }
            """
        let engine = try JSEngine(rulesSource: rules, resolver: { $0 })
        let work = try await engine.route(url: "https://github.com/a/b", ctx: ["opener": NSNull()])
        h.expectEqual(work, .browser(key: "work", url: nil), "sync host match -> browser")
        let prompt = try await engine.route(url: "https://unknown.example/x", ctx: ["opener": NSNull()])
        h.expectEqual(prompt, .prompt(url: nil), "sync no-match -> prompt")
    } catch {
        h.fail("sync decisions / URL shim", "threw \(error)")
    }

    // No return value -> prompt.
    do {
        let engine = try JSEngine(rulesSource: "function route(u,c){ /* nothing */ }", resolver: { $0 })
        let d = try await engine.route(url: "https://x.example", ctx: ["opener": NSNull()])
        h.expectEqual(d, .prompt(url: nil), "undefined return -> prompt")
    } catch {
        h.fail("undefined return", "threw \(error)")
    }

    // Rewritten URL carried through.
    do {
        let rules = #"function route(u,c){ return { browser: "work", url: "https://rewritten.example/" }; }"#
        let engine = try JSEngine(rulesSource: rules, resolver: { $0 })
        let d = try await engine.route(url: "https://orig.example", ctx: ["opener": NSNull()])
        h.expectEqual(d, .browser(key: "work", url: "https://rewritten.example/"), "rewrite url carried")
    } catch {
        h.fail("rewrite url", "threw \(error)")
    }

    // Thrown exception surfaces as .jsException.
    do {
        let engine = try JSEngine(rulesSource: "function route(u,c){ throw new Error('boom'); }", resolver: { $0 })
        _ = try await engine.route(url: "https://x.example", ctx: ["opener": NSNull()])
        h.fail("thrown exception surfaces", "did not throw")
    } catch let error as JSEngineError {
        if case .jsException(let m) = error {
            h.expect(m.contains("boom"), "thrown exception surfaces", "message: \(m)")
        } else {
            h.fail("thrown exception surfaces", "wrong case: \(error)")
        }
    } catch {
        h.fail("thrown exception surfaces", "wrong type: \(error)")
    }

    // Rejected native promise surfaces as .jsRejected.
    do {
        struct StubError: Error {}
        let engine = try JSEngine(
            rulesSource: "async function route(u,c){ return { browser: await resolve(u) }; }",
            resolver: { _ in throw StubError() }
        )
        _ = try await engine.route(url: "https://x.example", ctx: ["opener": NSNull()])
        h.fail("rejected promise surfaces", "did not throw")
    } catch let error as JSEngineError {
        if case .jsRejected = error {
            h.expect(true, "rejected promise surfaces")
        } else {
            h.fail("rejected promise surfaces", "wrong case: \(error)")
        }
    } catch {
        h.fail("rejected promise surfaces", "wrong type: \(error)")
    }

    // Missing route function.
    do {
        let engine = try JSEngine(rulesSource: "var notRoute = 1;", resolver: { $0 })
        _ = try await engine.route(url: "https://x", ctx: [:])
        h.fail("missing route function", "did not throw")
    } catch let error as JSEngineError {
        h.expectEqual(error, .noRouteFunction, "missing route function")
    } catch {
        h.fail("missing route function", "wrong type: \(error)")
    }

    // Syntax error in rules -> init throws.
    do {
        _ = try JSEngine(rulesSource: "function route( { ", resolver: { $0 })
        h.fail("syntax error rejected at init", "did not throw")
    } catch let error as JSEngineError {
        if case .evaluationFailed = error {
            h.expect(true, "syntax error rejected at init")
        } else {
            h.fail("syntax error rejected at init", "wrong case: \(error)")
        }
    } catch {
        h.fail("syntax error rejected at init", "wrong type: \(error)")
    }

    h.suite("Prelude — unwrap() link-tracker decoding")

    // unwrap() runs entirely in JS (prelude). Verify via a rule that returns the unwrapped URL.
    let unwrapRules = #"function route(url, ctx){ return { browser: unwrap(url) }; }"#
    func unwrapped(_ input: String) async throws -> String {
        let engine = try JSEngine(rulesSource: unwrapRules, resolver: { $0 })
        let d = try await engine.route(url: input, ctx: ["opener": NSNull()])
        if case .browser(let key, _) = d { return key }
        return "<prompt>"
    }
    do {
        h.expectEqual(
            try await unwrapped("https://slack-redir.net/link?url=https%3A%2F%2Fexample.com%2Fa"),
            "https://example.com/a", "slack-redir.net")
        h.expectEqual(
            try await unwrapped("https://nam01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fb&data=x"),
            "https://example.com/b", "safelinks")
        h.expectEqual(
            try await unwrapped("https://www.google.com/url?url=https%3A%2F%2Fexample.com%2Fc&sa=D"),
            "https://example.com/c", "google /url")
        h.expectEqual(
            try await unwrapped("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.com%2Fd"),
            "https://example.com/d", "facebook l.php")
        h.expectEqual(
            try await unwrapped("https://urldefense.proofpoint.com/v2/url?u=https-3A__example.com_e&d=x"),
            "https://example.com/e", "proofpoint v2")
        h.expectEqual(
            try await unwrapped("https://example.com/plain?x=1"),
            "https://example.com/plain?x=1", "non-wrapper passthrough")
    } catch {
        h.fail("unwrap table", "threw \(error)")
    }
}
