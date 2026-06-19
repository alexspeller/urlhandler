import AppKit
import Foundation

/// Menu-bar item for the resident agent: set-as-default, reveal/reload config, launch-at-login,
/// quit, plus a live reload-status line (errors from a bad edit surface here).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: ConfigStore
    private let log: JSEngine.Logger

    init(store: ConfigStore, log: @escaping JSEngine.Logger) {
        self.store = store
        self.log = log
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "URLHandler"
        )
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild on open so the reload status and login-item check reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        disabledItem(menu, "URLHandler")
        if let error = store.lastError {
            disabledItem(menu, "⚠ \(truncated(error))")
        } else {
            disabledItem(menu, "✓ rules loaded \(relativeReload())")
        }

        menu.addItem(.separator())
        actionItem(menu, "Set as Default Browser", #selector(setDefault))
        actionItem(menu, "Open Config Folder…", #selector(openConfigFolder))
        actionItem(menu, "Reload Config & Rules", #selector(reload))

        menu.addItem(.separator())
        let login = actionItem(menu, "Launch at Login", #selector(toggleLogin))
        login.state = (LoginItem.status == .enabled) ? .on : .off

        menu.addItem(.separator())
        actionItem(menu, "Quit URLHandler", #selector(quit), key: "q")
    }

    // MARK: - Actions

    @objc private func setDefault() {
        let appURL = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { [log] error in
                if let error { log("error", "set default for \(scheme) failed: \(error)") }
            }
        }
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func reload() {
        store.forceReload()
        log("info", "manual reload (\(store.lastError ?? "ok"))")
    }

    @objc private func toggleLogin() {
        do {
            if LoginItem.status == .enabled {
                try LoginItem.unregister()
                log("info", "login item disabled")
            } else {
                try LoginItem.register()
                log("info", "login item enabled (status: \(LoginItem.describe(LoginItem.status)))")
            }
        } catch {
            log("error", "login item toggle failed: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    @discardableResult
    private func actionItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ menu: NSMenu, _ title: String) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
    }

    private func truncated(_ string: String, max: Int = 60) -> String {
        let flat = string.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }

    private func relativeReload() -> String {
        let seconds = Int(Date().timeIntervalSince(store.lastReload))
        if seconds < 5 { return "(just now)" }
        if seconds < 90 { return "(\(seconds)s ago)" }
        return "(\(seconds / 60)m ago)"
    }
}
