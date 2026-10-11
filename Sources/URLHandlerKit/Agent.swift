import AppKit
import CoreServices
import Foundation

/// The resident background agent: an `LSUIElement` app that receives http/https URLs as the
/// system default browser (via the GetURL Apple Event) and routes them.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore?
    private var router: Router?
    private var statusController: StatusItemController?
    private lazy var chooser = Chooser(log: log)
    private let log = combineLoggers(
        makeOSLogger(),
        makeFileLogger(at: ConfigStore.defaultDirectory.appendingPathComponent("agent.log"))
    )

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Register BEFORE the launch URL is delivered (must be in willFinish, not didFinish).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        do {
            let store = try ConfigStore(logger: log)
            let router = Router(store: store, logger: log)
            router.presentChooser = { [weak self] url, promptKeys, config in
                self?.presentChooser(url: url, promptKeys: promptKeys, config: config)
            }
            self.store = store
            self.router = router
            self.statusController = StatusItemController(store: store, log: log)
            log("info", "agent started; config dir \(store.directory.path)")
        } catch {
            log("error", "failed to initialize: \(error)")
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            log("warn", "GetURL event with no URL")
            return
        }
        let opener = Self.opener(from: event)
        log("info", "received \(urlString) from \(opener?.name ?? opener?.bundleId ?? "unknown")")
        guard let router else {
            log("error", "no router; dropping \(urlString)")
            return
        }
        Task { await router.handle(urlString: urlString, opener: opener) }
    }

    /// As the default browser, macOS also routes local HTML file opens to us. Handle them by
    /// routing the file:// URL through the same rules (rather than letting AppKit's default
    /// document handling reject the file). `openFiles` only fires for document opens, never for
    /// http/https (those arrive via the GetURL Apple Event above), so there's no double-handling.
    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let router else {
            log("error", "no router; dropping \(filenames.count) file open(s)")
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        for filename in filenames {
            let fileURL = URL(fileURLWithPath: filename)
            log("info", "open file \(fileURL.path)")
            Task { await router.handle(urlString: fileURL.absoluteString, opener: nil) }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    /// Resolves the sending application from the event's sender PID, if available.
    static func opener(from event: NSAppleEventDescriptor) -> OpenerInfo? {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid != 0,
              let app = NSRunningApplication(processIdentifier: pid_t(pid))
        else {
            return nil
        }
        return OpenerInfo(bundleId: app.bundleIdentifier, name: app.localizedName)
    }

    private func presentChooser(url: String, promptKeys: [String], config: Config) {
        let options: [ChooserOption] = promptKeys.compactMap { key in
            guard let browser = config.browsers[key] else { return nil }
            return ChooserOption(key: key, browser: browser, icon: Chooser.icon(for: browser.app))
        }
        guard !options.isEmpty else {
            // No prompt list configured: fall back to the default browser rather than losing the URL.
            if let key = config.defaultBrowser, let browser = config.browsers[key] {
                log("warn", "no prompt browsers configured; opening default \(key)")
                router?.launch(browser: browser, key: key, url: url)
            } else {
                log("warn", "ambiguous URL and nothing to open it with: \(url)")
            }
            return
        }
        chooser.present(url: url, options: options) { [weak self] option in
            self?.router?.launch(browser: option.browser, key: option.key, url: url)
        }
    }
}

/// Process entry point. Bridges the synchronous main-thread start into main-actor context and
/// dispatches: no arguments runs the resident agent; otherwise runs the CLI.
public func runMain(_ argv: [String]) -> Never {
    MainActor.assumeIsolated {
        let args = Array(argv.dropFirst())
        if args.isEmpty {
            runAgent()  // Never
        }
        exit(runCLI(args))
    }
}

/// Runs the resident agent. Never returns.
@MainActor
public func runAgent() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    agentDelegate = delegate  // keep a strong reference (NSApplication.delegate is weak)
    app.delegate = delegate
    app.run()
    exit(0)
}

private var agentDelegate: AppDelegate?

/// Runs an async CLI command to completion on the main run loop, returning its exit code.
/// The run loop services the main-actor work (config load, routing, network resolve).
@MainActor
public func runCLI(_ args: [String]) -> Int32 {
    var code: Int32 = 0
    let task = Task { @MainActor in
        code = await CLI.run(args)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    withExtendedLifetime(task) {
        CFRunLoopRun()
    }
    return code
}
