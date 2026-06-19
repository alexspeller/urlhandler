import Foundation

public enum ResolverError: Error, CustomStringConvertible, Equatable {
    case invalidURL(String)
    case timeout
    case network(String)

    public var description: String {
        switch self {
        case .invalidURL(let s): return "not an http(s) URL: \(s)"
        case .timeout: return "timed out following redirects"
        case .network(let m): return "network error: \(m)"
        }
    }
}

/// Follows HTTP redirects to a URL's final destination, for rules that need to look past
/// link shorteners/trackers (`await resolve(url)` in rules.js). Uses a HEAD request (cheap),
/// falling back to a tiny ranged GET for servers that reject HEAD, with a hard overall timeout.
public struct Resolver: Sendable {
    public let timeout: Double

    public init(timeout: Double = 5) {
        self.timeout = timeout
    }

    public func finalURL(for urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ResolverError.invalidURL(urlString)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // Hard wall-clock cap on top of URLSession's own timeouts, so the user is never left waiting.
        return try await withTimeout(seconds: timeout + 1) {
            func attempt(method: String, ranged: Bool) async throws -> (final: String, status: Int) {
                var request = URLRequest(url: url)
                request.httpMethod = method
                if ranged { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (response.url?.absoluteString ?? urlString, status)
            }

            do {
                let head = try await attempt(method: "HEAD", ranged: false)
                // Some servers reject HEAD without redirecting; retry with a minimal GET.
                if [400, 403, 405, 501].contains(head.status) {
                    return try await attempt(method: "GET", ranged: true).final
                }
                return head.final
            } catch is CancellationError {
                throw ResolverError.timeout
            } catch {
                return try await attempt(method: "GET", ranged: true).final
            }
        }
    }
}

/// Runs `operation`, throwing `ResolverError.timeout` if it doesn't finish within `seconds`.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ResolverError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ResolverError.timeout }
        return result
    }
}
