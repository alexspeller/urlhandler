import AppKit
import Foundation

public enum LauncherError: Error, CustomStringConvertible {
    case launchFailed(app: String, underlying: String)

    public var description: String {
        switch self {
        case .launchFailed(let app, let underlying): return "failed to launch \(app): \(underlying)"
        }
    }
}

/// Opens a URL in a configured browser/profile by shelling out to `/usr/bin/open`.
///
/// Chrome (and other Chromium browsers) require `-n` plus `--profile-directory=` to target a
/// specific profile: without `-n`, macOS hands the URL to the already-running Chrome and
/// silently drops `--args`. Using `open` (not AppleScript) needs no Automation permission.
public enum Launcher {

    enum Family {
        case chromium  // --profile-directory=<dir>
        case firefox   // -P <name>
        case other     // no profile concept
    }

    /// The arguments passed to `/usr/bin/open`. Pure and unit-tested.
    public static func openArguments(for browser: BrowserConfig, url: String) -> [String] {
        let family = family(of: browser.app)
        let hasProfile = (browser.profile?.isEmpty == false)

        var browserArgs: [String] = []
        if hasProfile, let profile = browser.profile {
            switch family {
            case .chromium: browserArgs.append("--profile-directory=\(profile)")
            case .firefox: browserArgs += ["-P", profile]
            case .other: break  // profile ignored for non-profile browsers
            }
        }
        browserArgs += browser.args ?? []

        // A new instance (-n) is needed for profile switching to take effect.
        let needsNewInstance = hasProfile && (family == .chromium || family == .firefox)

        var arguments: [String] = []
        if needsNewInstance { arguments.append("-n") }
        arguments += appSelector(browser.app)
        if browserArgs.isEmpty {
            arguments.append(url)
        } else {
            arguments.append("--args")
            arguments += browserArgs
            arguments.append(url)
        }
        return arguments
    }

    /// Opens `url` in `browser`. Returns once `open` has been spawned (does not block on the browser).
    public static func launch(browser: BrowserConfig, url: String) throws {
        let arguments = openArguments(for: browser, url: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw LauncherError.launchFailed(app: browser.app, underlying: String(describing: error))
        }

        // A profile launch uses `-n` (a new instance that delegates the URL to the already-running
        // browser and exits), which loses activation — so the tab can open behind the frontmost app
        // (e.g. Slack). Re-activate the browser shortly after via a plain `open -a/-b` (LaunchServices
        // activation; no Automation permission needed).
        if arguments.first == "-n" {
            activate(browser: browser, afterSeconds: 0.4)
        }
    }

    /// Brings the browser to the front (used after profile launches; see `launch`).
    static func activate(browser: BrowserConfig, afterSeconds: Double) {
        let selector = appSelector(browser.app)
        DispatchQueue.main.asyncAfter(deadline: .now() + afterSeconds) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = selector  // `open -a "<app>"` / `open -b <bundleid>` — activate, no URL
            try? process.run()
        }
    }

    // MARK: - Heuristics

    static func family(of app: String) -> Family {
        let name = app.lowercased()
        let chromium = ["chrome", "chromium", "brave", "edge", "vivaldi", "arc", "opera", "thorium"]
        let firefox = ["firefox", "tor", "librewolf", "waterfox", "zen"]
        if chromium.contains(where: name.contains) { return .chromium }
        if firefox.contains(where: name.contains) { return .firefox }
        return .other
    }

    /// Chooses `open`'s app selector: `-b` for a bundle id, `-a` for a name or absolute path.
    static func appSelector(_ app: String) -> [String] {
        if app.hasPrefix("/") { return ["-a", app] }
        if isBundleID(app) { return ["-b", app] }
        return ["-a", app]
    }

    static func isBundleID(_ string: String) -> Bool {
        guard !string.contains(" "), !string.contains("/"), string.contains(".") else { return false }
        return string.range(
            of: "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+$",
            options: .regularExpression
        ) != nil
    }
}

extension Launcher.Family: Equatable {}
