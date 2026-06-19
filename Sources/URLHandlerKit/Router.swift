import Foundation

/// The application that asked the OS to open a URL (from the GetURL Apple Event sender).
public struct OpenerInfo: Equatable, Sendable {
    public let bundleId: String?
    public let name: String?
    public init(bundleId: String?, name: String?) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// Orchestrates handling one incoming URL: ensure config/rules are fresh, run the rules, then
/// either launch the chosen browser or present the chooser (and fall back to the chooser on error
/// or an unknown browser key, so a URL is never silently lost).
@MainActor
public final class Router {
    private let store: ConfigStore
    private let logger: JSEngine.Logger

    /// Presents the chooser for an ambiguous decision. Injected by the agent (NSPanel chooser).
    public var presentChooser: (_ url: String, _ promptKeys: [String], _ config: Config) -> Void

    public init(
        store: ConfigStore,
        logger: @escaping JSEngine.Logger = { _, _ in },
        presentChooser: @escaping (String, [String], Config) -> Void = { _, _, _ in }
    ) {
        self.store = store
        self.logger = logger
        self.presentChooser = presentChooser
    }

    public func handle(urlString: String, opener: OpenerInfo?) async {
        let (config, engine) = store.current()
        let ctx = Self.context(config: config, opener: opener)

        let decision: RouteDecision
        do {
            decision = try await engine.route(url: urlString, ctx: ctx)
        } catch {
            logger("error", "route() failed for \(urlString): \(error)")
            presentChooser(urlString, config.prompt, config)
            return
        }

        switch decision {
        case .browser(let key, let url):
            let target = url ?? urlString
            guard let browser = config.browsers[key] else {
                logger("warn", "rule chose unknown browser \"\(key)\"; showing chooser")
                presentChooser(target, config.prompt, config)
                return
            }
            launch(browser: browser, key: key, url: target)
        case .prompt(let url):
            presentChooser(url ?? urlString, config.prompt, config)
        }
    }

    public func launch(browser: BrowserConfig, key: String, url: String) {
        do {
            try Launcher.launch(browser: browser, url: url)
            logger("info", "opened \(url) in \(key)")
        } catch {
            logger("error", "\(error)")
        }
    }

    /// Builds the `ctx` object passed to `route(url, ctx)`.
    public nonisolated static func context(config: Config, opener: OpenerInfo?) -> [String: Any] {
        let openerValue: Any
        if let opener, opener.bundleId != nil || opener.name != nil {
            openerValue = [
                "bundleId": opener.bundleId.map { $0 as Any } ?? NSNull(),
                "name": opener.name.map { $0 as Any } ?? NSNull(),
            ]
        } else {
            openerValue = NSNull()
        }
        return [
            "opener": openerValue,
            "browsers": Array(config.browsers.keys),
            "default": config.defaultBrowser.map { $0 as Any } ?? NSNull(),
        ]
    }
}
