import AppKit
import Foundation

/// Command-line entry points for setup/testing without being the system default browser.
/// (The default, argument-less invocation runs the resident agent — wired up separately.)
public enum CLI {
    @MainActor
    public static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 2
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "route":
            return await route(rest, launch: false)
        case "open":
            return await route(rest, launch: true)
        case "resolve":
            return await resolveCommand(rest)
        case "list-profiles":
            return listProfiles()
        case "set-default":
            return await setDefault()
        case "login-item":
            return loginItem(rest)
        case "-h", "--help", "help":
            printUsage()
            return 0
        default:
            errln("urlhandler: unknown command '\(command)'")
            printUsage()
            return 2
        }
    }

    /// `urlhandler route <url> [--from <bundleid>] [--name <appname>]`
    /// Runs the routing rules and prints the decision as JSON, without opening anything.
    @MainActor
    static func route(_ arguments: [String], launch: Bool) async -> Int32 {
        var url: String?
        var openerBundleID: String?
        var openerName: String?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--from": index += 1; openerBundleID = arguments[safe: index]
            case "--name": index += 1; openerName = arguments[safe: index]
            default: if url == nil { url = arg }
            }
            index += 1
        }
        guard let url else {
            errln("usage: urlhandler route <url> [--from <bundleid>] [--name <appname>]")
            return 2
        }

        do {
            let store = try ConfigStore(watch: false, logger: { level, message in
                errln("[\(level)] \(message)")
            })
            let (config, engine) = store.current()
            let ctx = makeContext(config: config, openerBundleID: openerBundleID, openerName: openerName)
            let decision = try await engine.route(url: url, ctx: ctx)
            printDecision(decision)
            if launch {
                return launchDecision(decision, originalURL: url, config: config)
            }
            return 0
        } catch {
            errln("error: \(error)")
            return 1
        }
    }

    /// Opens the decided browser. In CLI mode there is no chooser, so a `prompt` decision falls
    /// back to the configured default browser (the resident agent shows the chooser instead).
    static func launchDecision(_ decision: RouteDecision, originalURL: String, config: Config) -> Int32 {
        let key: String
        let target: String
        switch decision {
        case .browser(let browserKey, let url):
            key = browserKey
            target = url ?? originalURL
        case .prompt(let url):
            guard let def = config.defaultBrowser else {
                errln("decision is prompt and no default browser is configured; not opening")
                return 0
            }
            errln("decision is prompt; opening default browser \"\(def)\" (run the agent for the chooser)")
            key = def
            target = url ?? originalURL
        }
        guard let browser = config.browsers[key] else {
            errln("browser \"\(key)\" is not defined in config.json")
            return 1
        }
        do {
            try Launcher.launch(browser: browser, url: target)
            return 0
        } catch {
            errln("\(error)")
            return 1
        }
    }

    /// `urlhandler list-profiles` — print Chrome profile directory names for use in config.json.
    static func listProfiles() -> Int32 {
        do {
            let profiles = try ChromeProfiles.list()
            if profiles.isEmpty {
                errln("No Chrome profiles found.")
                return 0
            }
            let width = profiles.map { $0.directory.count }.max() ?? 10
            print("Chrome profiles (use the \"directory\" value as \"profile\" in config.json):\n")
            for profile in profiles {
                let padded = profile.directory.padding(toLength: max(width, 10), withPad: " ", startingAt: 0)
                print("  \(padded)  \(profile.name)")
            }
            return 0
        } catch {
            errln("could not read Chrome profiles: \(error)")
            return 1
        }
    }

    /// `urlhandler set-default` — register this bundle as the default http/https handler.
    /// Must run from the installed .app (NSWorkspace uses Bundle.main.bundleURL).
    @MainActor
    static func setDefault() async -> Int32 {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            errln(
                """
                set-default must be run from the installed .app bundle, e.g.
                  /Applications/URLHandler.app/Contents/MacOS/urlhandler set-default
                (or run `make set-default`).
                """
            )
            return 1
        }
        // Setting one web scheme usually applies to both (the unified "web browser" role), so a
        // redundant second call can return a benign permErr. Judge success by the actual end state.
        var errors: [String: Error] = [:]
        for scheme in ["http", "https"] {
            if let error = await setDefaultApplication(scheme: scheme, appURL: appURL) {
                errors[scheme] = error
            }
        }
        if isDefaultBrowser(appURL: appURL) {
            print("URLHandler is now the default browser for http and https.")
            return 0
        }
        for (scheme, error) in errors {
            errln("failed to set default handler for \(scheme): \(error)")
        }
        errln("Could not set the default browser. Set it in System Settings → Desktop & Dock → Default web browser.")
        return 1
    }

    private static func isDefaultBrowser(appURL: URL) -> Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else {
            return false
        }
        return handler.standardizedFileURL == appURL.standardizedFileURL
    }

    private static func setDefaultApplication(scheme: String, appURL: URL) async -> Error? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                continuation.resume(returning: error)
            }
        }
    }

    /// `urlhandler login-item [register|unregister|status]` — manage launch-at-login.
    static func loginItem(_ arguments: [String]) -> Int32 {
        switch arguments.first ?? "register" {
        case "register", "enable":
            do {
                try LoginItem.register()
                print("Registered as a login item (status: \(LoginItem.describe(LoginItem.status))).")
                return 0
            } catch {
                errln("failed to register login item: \(error)")
                return 1
            }
        case "unregister", "disable":
            do {
                try LoginItem.unregister()
                print("Unregistered login item.")
                return 0
            } catch {
                errln("failed to unregister login item: \(error)")
                return 1
            }
        case "status":
            print("login item: \(LoginItem.describe(LoginItem.status))")
            return 0
        default:
            errln("usage: urlhandler login-item [register|unregister|status]")
            return 2
        }
    }

    /// `urlhandler resolve <url>` — follow redirects and print the final URL (debugging the resolver).
    @MainActor
    static func resolveCommand(_ arguments: [String]) async -> Int32 {
        guard let url = arguments.first else {
            errln("usage: urlhandler resolve <url>")
            return 2
        }
        do {
            let final = try await Resolver().finalURL(for: url)
            print(final)
            return 0
        } catch {
            errln("resolve failed: \(error)")
            return 1
        }
    }

    /// Builds the `ctx` object passed to `route(url, ctx)`.
    public static func makeContext(config: Config, openerBundleID: String?, openerName: String?) -> [String: Any] {
        let opener = (openerBundleID == nil && openerName == nil)
            ? nil
            : OpenerInfo(bundleId: openerBundleID, name: openerName)
        return Router.context(config: config, opener: opener)
    }

    static func printDecision(_ decision: RouteDecision) {
        var object: [String: Any]
        switch decision {
        case .browser(let key, let url):
            object = ["decision": "browser", "browser": key]
            if let url { object["url"] = url }
        case .prompt(let url):
            object = ["decision": "prompt"]
            if let url { object["url"] = url }
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }

    static func printUsage() {
        errln(
            """
            urlhandler — route URLs to browsers/profiles

            Usage:
              urlhandler route <url> [--from <bundleid>] [--name <appname>]
                  Run the rules and print the decision as JSON (does not open a browser).

              urlhandler open <url> [--from <bundleid>] [--name <appname>]
                  Route the URL and open it in the chosen browser.

              urlhandler resolve <url>
                  Follow redirects and print the final URL.

              urlhandler list-profiles
                  List Chrome profile directory names for config.json.

              urlhandler set-default
                  Register this app as the default http/https handler (run from the .app).

              urlhandler help
                  Show this help.

            With no arguments, runs as the resident default-browser agent.
            Config + rules live in ~/.config/urlhandler/.
            """
        )
    }

    static func errln(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
