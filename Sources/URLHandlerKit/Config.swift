import Foundation

/// One routable browser target.
public struct BrowserConfig: Codable, Equatable, Sendable {
    /// Application name ("Google Chrome"), bundle id ("com.google.Chrome"), or absolute path.
    public let app: String
    /// Chrome on-disk profile directory ("Default", "Profile 1") or Firefox profile name.
    public let profile: String?
    /// Extra command-line arguments passed to the browser (advanced; usually unset).
    public let args: [String]?

    public init(app: String, profile: String? = nil, args: [String]? = nil) {
        self.app = app
        self.profile = profile
        self.args = args
    }
}

/// The parsed `config.json`: the browser inventory plus chooser/default settings.
public struct Config: Codable, Equatable, Sendable {
    public var browsers: [String: BrowserConfig]
    public var defaultBrowser: String?
    public var prompt: [String]
    public var resolveTimeoutSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case browsers
        case defaultBrowser = "default"
        case prompt
        case resolveTimeoutSeconds
    }

    public init(
        browsers: [String: BrowserConfig],
        defaultBrowser: String? = nil,
        prompt: [String] = [],
        resolveTimeoutSeconds: Double? = nil
    ) {
        self.browsers = browsers
        self.defaultBrowser = defaultBrowser
        self.prompt = prompt
        self.resolveTimeoutSeconds = resolveTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.browsers = try c.decodeIfPresent([String: BrowserConfig].self, forKey: .browsers) ?? [:]
        self.defaultBrowser = try c.decodeIfPresent(String.self, forKey: .defaultBrowser)
        self.prompt = try c.decodeIfPresent([String].self, forKey: .prompt) ?? []
        self.resolveTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .resolveTimeoutSeconds)
    }

    /// Redirect-following timeout, defaulting to 5s when unset.
    public var resolveTimeout: Double { resolveTimeoutSeconds ?? 5 }

    /// Non-fatal configuration problems (referenced-but-missing browser keys).
    public func warnings() -> [String] {
        var out: [String] = []
        if let def = defaultBrowser, browsers[def] == nil {
            out.append("default browser \"\(def)\" is not defined in browsers")
        }
        for key in prompt where browsers[key] == nil {
            out.append("prompt browser \"\(key)\" is not defined in browsers")
        }
        return out
    }
}

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case notUTF8
    case parse(String)

    public var description: String {
        switch self {
        case .notUTF8: return "config.json is not valid UTF-8"
        case .parse(let m): return "config.json parse error: \(m)"
        }
    }
}

extension Config {
    public static func load(from url: URL) throws -> Config {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> Config {
        guard let raw = String(data: data, encoding: .utf8) else { throw ConfigError.notUTF8 }
        let stripped = stripJSONComments(raw)
        do {
            return try JSONDecoder().decode(Config.self, from: Data(stripped.utf8))
        } catch let error as DecodingError {
            throw ConfigError.parse(Self.describe(error))
        } catch {
            throw ConfigError.parse(String(describing: error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing key \"\(key.stringValue)\""
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}

/// Removes `//` line comments and `/* */` block comments from JSON while preserving comment-like
/// sequences inside string literals (so values such as `https://…` survive).
func stripJSONComments(_ input: String) -> String {
    var out = String()
    out.reserveCapacity(input.count)
    let chars = Array(input)
    var i = 0
    var inString = false
    var escaped = false
    while i < chars.count {
        let c = chars[i]
        if inString {
            out.append(c)
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString = false
            }
            i += 1
            continue
        }
        if c == "\"" {
            inString = true
            out.append(c)
            i += 1
            continue
        }
        if c == "/", i + 1 < chars.count {
            let next = chars[i + 1]
            if next == "/" {
                i += 2
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if next == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
        }
        out.append(c)
        i += 1
    }
    return out
}
