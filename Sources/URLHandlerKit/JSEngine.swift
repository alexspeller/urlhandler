import Foundation
import JavaScriptCore

/// The decision a routing rule returns for a URL.
public enum RouteDecision: Equatable, Sendable {
    /// Open `url` (or the original URL if `url` is nil) in the browser identified by `key`.
    case browser(key: String, url: String?)
    /// Show the chooser. `url` optionally rewrites which URL is offered/copied.
    case prompt(url: String?)
}

public enum JSEngineError: Error, CustomStringConvertible, Equatable {
    case contextCreationFailed
    case evaluationFailed(String)
    case noRouteFunction
    case routeCallFailed
    case jsException(String)
    case jsRejected(String)

    public var description: String {
        switch self {
        case .contextCreationFailed: return "Failed to create JSContext"
        case .evaluationFailed(let m): return "Script evaluation failed: \(m)"
        case .noRouteFunction: return "rules.js does not define a global `route` function"
        case .routeCallFailed: return "Calling route() returned no value"
        case .jsException(let m): return "JS exception in route(): \(m)"
        case .jsRejected(let m): return "route() promise rejected: \(m)"
        }
    }
}

/// Evaluates the user's `rules.js` (a classic script defining a global
/// `async function route(url, ctx)`) inside a JavaScriptCore context and bridges the
/// async result back to Swift.
///
/// All `JSContext`/`JSValue` access is confined to the main actor. Native async work
/// (`resolve`) is bridged into a JS Promise that is fulfilled from a `@MainActor` Task,
/// so calling the promise's resolve function is an outermost JS entry point — JSC drains
/// its microtask queue when it returns, advancing any awaiting `route()` continuation.
@MainActor
public final class JSEngine {
    /// Follows redirects (network) and returns the final URL. Injected so rules can `await resolve(url)`.
    public typealias AsyncResolver = @MainActor (String) async throws -> String
    /// Receives `console`/diagnostic output as `(level, message)`.
    public typealias Logger = (String, String) -> Void

    private let context: JSContext

    public init(
        preludeSource: String = preludeJS,
        rulesSource: String,
        resolver: @escaping AsyncResolver,
        logger: @escaping Logger = { _, _ in }
    ) throws {
        guard let context = JSContext() else { throw JSEngineError.contextCreationFailed }
        self.context = context

        context.exceptionHandler = { ctx, exception in
            guard let exception else { return }
            let stack = exception.objectForKeyedSubscript("stack")?.toString()
            let message = exception.toString() ?? "unknown JS exception"
            logger("error", stack.map { "\(message)\n\($0)" } ?? message)
            ctx?.exception = exception  // re-store so callers can detect it via context.exception
        }

        // __log(level, message)
        let logBlock: @convention(block) (String, String) -> Void = { level, message in
            logger(level, message)
        }
        context.setObject(logBlock, forKeyedSubscript: "__log" as NSString)

        // __parseURL(input, base) -> object | null  (Foundation-backed URL parsing)
        let parseBlock: @convention(block) (String, JSValue) -> Any? = { input, base in
            JSEngine.parseURL(input, base: base)
        }
        context.setObject(parseBlock, forKeyedSubscript: "__parseURL" as NSString)

        // resolve(url) -> Promise<string>  (native async redirect follower, injected)
        let resolveBlock: @convention(block) (JSValue) -> JSValue? = { arg in
            let ctx = JSContext.current()!
            let input = arg.toString() ?? ""
            return JSValue(newPromiseIn: ctx) { resolveFn, rejectFn in
                Task { @MainActor in
                    do {
                        let finalURL = try await resolver(input)
                        resolveFn?.call(withArguments: [finalURL])
                    } catch {
                        rejectFn?.call(withArguments: [String(describing: error)])
                    }
                }
            }
        }
        context.setObject(resolveBlock, forKeyedSubscript: "resolve" as NSString)

        context.exception = nil
        context.evaluateScript(preludeSource, withSourceURL: URL(string: "urlhandler://prelude.js"))
        if let ex = context.exception {
            context.exception = nil
            throw JSEngineError.evaluationFailed("prelude: \(ex.toString() ?? "?")")
        }
        context.evaluateScript(rulesSource, withSourceURL: URL(string: "urlhandler://rules.js"))
        if let ex = context.exception {
            context.exception = nil
            throw JSEngineError.evaluationFailed(ex.toString() ?? "?")
        }
    }

    /// Runs `route(url, ctx)` and resolves its (possibly async) result into a `RouteDecision`.
    public func route(url: String, ctx: [String: Any]) async throws -> RouteDecision {
        guard let routeFn = context.objectForKeyedSubscript("route"),
              routeFn.isObject
        else {
            throw JSEngineError.noRouteFunction
        }
        context.exception = nil
        guard let result = routeFn.call(withArguments: [url, ctx]) else {
            throw JSEngineError.routeCallFailed
        }
        if let ex = context.exception {
            context.exception = nil
            throw JSEngineError.jsException(ex.toString() ?? "?")
        }
        let settled = try await JSEngine.awaitPromise(result)
        return RouteDecision(jsValue: settled)
    }

    // MARK: - Promise bridging (JS Promise -> Swift async)

    nonisolated static func awaitPromise(_ value: JSValue) async throws -> JSValue {
        guard let ctx = value.context,
              let promiseCtor = ctx.objectForKeyedSubscript("Promise"),
              value.isInstance(of: promiseCtor)
        else {
            return value  // a synchronous (non-promise) return value
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSValue, Error>) in
            let onResolved: @convention(block) (JSValue) -> Void = { resolved in
                continuation.resume(returning: resolved)
            }
            let onRejected: @convention(block) (JSValue) -> Void = { reason in
                continuation.resume(throwing: JSEngineError.jsRejected(reason.toString() ?? "rejected"))
            }
            value.invokeMethod("then", withArguments: [onResolved, onRejected])
        }
    }

    // MARK: - Native URL parsing for the prelude's URL shim

    nonisolated static func parseURL(_ input: String, base baseValue: JSValue) -> [String: Any]? {
        var target = input
        if !baseValue.isUndefined, !baseValue.isNull,
           let baseString = baseValue.toString(), !baseString.isEmpty,
           let baseURL = URL(string: baseString),
           let absolute = URL(string: input, relativeTo: baseURL)?.absoluteURL.absoluteString {
            target = absolute
        }
        guard let comps = URLComponents(string: target), let scheme = comps.scheme else { return nil }
        let hostname = comps.host ?? ""
        let portString = comps.port.map(String.init) ?? ""
        let host = portString.isEmpty ? hostname : "\(hostname):\(portString)"
        let queryItems: [[String]] = (comps.queryItems ?? []).map { [$0.name, $0.value ?? ""] }
        return [
            "href": comps.string ?? target,
            "protocol": scheme + ":",
            "host": host,
            "hostname": hostname,
            "port": portString,
            "pathname": comps.percentEncodedPath,
            "search": comps.percentEncodedQuery.map { "?\($0)" } ?? "",
            "hash": comps.percentEncodedFragment.map { "#\($0)" } ?? "",
            "origin": "\(scheme)://\(host)",
            "queryItems": queryItems,
        ]
    }
}

extension RouteDecision {
    /// Parses the object a rule returns: `{browser, url?}` -> `.browser`; anything else -> `.prompt`.
    init(jsValue value: JSValue) {
        guard !value.isUndefined, !value.isNull, value.isObject else {
            self = .prompt(url: nil)
            return
        }
        let urlValue = value.objectForKeyedSubscript("url")
        let url: String? = (urlValue?.isString == true) ? urlValue?.toString() : nil
        let browserValue = value.objectForKeyedSubscript("browser")
        if let browserValue, browserValue.isString,
           let key = browserValue.toString(), !key.isEmpty {
            self = .browser(key: key, url: url)
        } else {
            self = .prompt(url: url)
        }
    }
}
