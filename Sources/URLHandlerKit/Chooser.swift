import AppKit
import Foundation
import SwiftUI

/// One selectable browser in the chooser.
public struct ChooserOption: Identifiable, Sendable {
    public let key: String
    public let browser: BrowserConfig
    public let icon: NSImage?
    public var id: String { key }
    public var title: String { key }
    public var subtitle: String { browser.profile.map { "\(browser.app) · \($0)" } ?? browser.app }

    public init(key: String, browser: BrowserConfig, icon: NSImage?) {
        self.key = key
        self.browser = browser
        self.icon = icon
    }
}

/// The result of a key press in the chooser. Pure mapping so it can be unit-tested.
public enum ChooserAction: Equatable {
    case pick(Int)
    case copy
    case cancel
    case select(Int)
    /// Not a chooser key — a letter, space, Tab, an out-of-range digit, ⌘ + anything but C. The
    /// human is typing for another window and hasn't noticed the chooser.
    case stray
}

/// Maps a key event to a chooser action. `characters` is `charactersIgnoringModifiers`.
public func chooserKeyAction(
    keyCode: UInt16,
    characters: String?,
    command: Bool,
    optionsCount: Int,
    selected: Int
) -> ChooserAction {
    if command {
        return characters?.lowercased() == "c" ? .copy : .stray
    }
    switch keyCode {
    case 53: return .cancel                                   // esc
    case 36, 76: return .pick(selected)                       // return / enter
    case 125: return .select(min(selected + 1, max(optionsCount - 1, 0)))  // down
    case 126: return .select(max(selected - 1, 0))            // up
    default: break
    }
    if let characters, let n = Int(characters), n >= 1, n <= optionsCount {
        return .pick(n - 1)
    }
    return .stray
}

@MainActor
final class ChooserModel: ObservableObject {
    let url: String
    let options: [ChooserOption]
    @Published var selected: Int = 0
    /// False while the chooser is held back from input (`InteractionGrace`).
    @Published var live = false
    var onPick: (Int) -> Void = { _ in }

    init(url: String, options: [ChooserOption]) {
        self.url = url
        self.options = options
    }
}

/// What the chooser needs from the system. Production uses `.production`; the self-test injects
/// clocks and recorders so it can drive a real chooser without putting a window in front of the
/// developer or taking their focus.
public struct ChooserEnvironment {
    public var minimumDelay: TimeInterval = InteractionGrace.minimumDelay
    /// Doubled after each re-hold (see `Chooser`).
    public var requiredKeyboardIdle: TimeInterval = InteractionGrace.requiredKeyboardIdle
    public var clickQuietPeriod: TimeInterval = InteractionGrace.clickQuietPeriod
    public var keyboardIdle: () -> TimeInterval = InteractionGrace.secondsSinceLastKeyPress
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Put the panel on screen without making it key or activating this app, so keystrokes keep
    /// flowing to whatever the human was typing into.
    public var show: @MainActor (NSPanel) -> Void = { panel in
        Chooser.centerOnCursorScreen(panel)
        panel.orderFront(nil)  // documented to change neither the key nor the main window
    }
    /// Bring this app forward and make the panel key: the chooser going live.
    public var takeFocus: @MainActor (NSPanel) -> Void = { panel in
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    /// Give the focus back to the app the human was typing into.
    public var returnFocus: @MainActor (NSRunningApplication?) -> Void = { app in
        guard let app else {
            NSApp.deactivate()
            return
        }
        if #available(macOS 14.0, *) {
            // Cooperative activation: the active app (us) yields, then the target activates.
            NSApp.yieldActivation(to: app)
            app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate(options: [])
        }
    }
    /// The app the human is in, other than this one.
    public var frontmostApplication: @MainActor () -> NSRunningApplication? = {
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current
        else { return nil }
        return app
    }
    /// Call `handler` for every mouse button pressed in another app until the returned closure
    /// is called. A global mouse monitor needs no Accessibility or Input Monitoring grant (only
    /// key monitors do); checked from an ad-hoc signed app with neither.
    public var watchClicksElsewhere: @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void = { handler in
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    public static var production: ChooserEnvironment { ChooserEnvironment() }

    public init() {}
}

/// A small, keyboard-driven popup for choosing a browser when routing is ambiguous.
/// Number keys pick, ⌘C copies the URL, esc cancels, arrows + return move/confirm.
///
/// It appears **held**: in front, but not key and with this app not activated, so a human who is
/// typing or clicking elsewhere carries on undisturbed — their keys go to their own window and
/// a click elsewhere cannot dismiss it. It goes **live** (activates, takes the keyboard, and from
/// then on clicking away cancels) when `InteractionGrace` says the human has paused, or at once
/// when they click it. A live chooser that receives a key that isn't one of its own (a letter,
/// space…) concludes the human is still typing for another window: it hands the focus back and
/// is held again (that key is lost — it can't be re-sent without Accessibility), and each such
/// re-hold doubles the keyboard quiet it waits for, so a writer pausing between sentences isn't
/// interrupted every time.
@MainActor
public final class Chooser: NSObject, NSWindowDelegate {
    public enum State: Equatable {
        case idle, held, live
    }

    public private(set) var state = State.idle
    /// The panel while one is presented.
    public var window: NSPanel? { panel }

    private let environment: ChooserEnvironment
    private let log: JSEngine.Logger
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var stopWatchingClicks: (() -> Void)?
    private var model: ChooserModel?
    private var onSelect: ((ChooserOption) -> Void)?
    private var grace: InteractionGrace?
    /// Live and key: losing key now means the human clicked away.
    private var armed = false
    private var reholds = 0
    private var returnTo: NSRunningApplication?
    private var shownAt: TimeInterval = 0
    private var liveAt: TimeInterval?

    public init(environment: ChooserEnvironment = .production, log: @escaping JSEngine.Logger = { _, _ in }) {
        self.environment = environment
        self.log = log
        super.init()
    }

    public func present(
        url: String,
        options: [ChooserOption],
        onSelect: @escaping (ChooserOption) -> Void
    ) {
        if state != .idle { end("replaced by a new URL before a choice; not opened: \(model?.url ?? "?")", level: "warn") }
        guard !options.isEmpty else { return }

        let model = ChooserModel(url: url, options: options)
        model.onPick = { [weak self] index in self?.rowClicked(index) }
        self.model = model
        self.onSelect = onSelect

        let hosting = NSHostingView(rootView: ChooserView(model: model))
        hosting.layout()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .hudWindow, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open in…"
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        self.panel = panel

        state = .held
        armed = false
        reholds = 0
        liveAt = nil
        shownAt = environment.now()
        returnTo = environment.frontmostApplication()
        environment.show(panel)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(keyDown: event) ? nil : event
        }
        stopWatchingClicks = environment.watchClicksElsewhere { [weak self] in
            self?.grace?.clickedElsewhere()
        }
        startGrace()
    }

    /// What the chooser does with a key press that reaches it; true if it consumed the key.
    @discardableResult
    public func handle(keyDown event: NSEvent) -> Bool {
        guard let model, state != .idle else { return false }
        if state == .held {
            // Only reachable when the panel was made key by a click inside the minimum delay and
            // the human is typing: no key is a choice yet, and the focus goes back where it was.
            environment.returnFocus(returnTo)
            return true
        }
        let action = chooserKeyAction(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            command: event.modifierFlags.contains(.command),
            optionsCount: model.options.count,
            selected: model.selected
        )
        switch action {
        case .pick(let index): pick(index, via: "key")
        case .copy: copyURL()
        case .cancel: end("cancelled by esc")
        case .select(let index): model.selected = index
        case .stray: rehold()
        }
        return true
    }

    /// What a click on row `index` does: picks it when live. A held chooser takes the click as
    /// the human engaging with it, past the minimum delay.
    public func rowClicked(_ index: Int) {
        if state == .held { grace?.engage() }
        guard state == .live else { return }
        pick(index, via: "click")
    }

    /// Cancels the chooser without opening anything.
    public func dismiss() {
        guard state != .idle else { return }
        end("dismissed")
    }

    private func startGrace() {
        grace?.cancel()
        let grace = InteractionGrace(
            minimumDelay: environment.minimumDelay,
            requiredKeyboardIdle: requiredKeyboardIdle,
            clickQuietPeriod: environment.clickQuietPeriod,
            keyboardIdle: environment.keyboardIdle,
            now: environment.now,
            onLive: { [weak self] in self?.goLive() }
        )
        self.grace = grace
        grace.begin()
    }

    private var requiredKeyboardIdle: TimeInterval {
        environment.requiredKeyboardIdle * pow(2, Double(reholds))
    }

    private func goLive() {
        guard state == .held, let panel, let model else { return }
        state = .live
        liveAt = environment.now()
        model.live = true
        var held: [String] = []
        if grace?.heldForTyping == true { held.append("typing") }
        if grace?.heldForClicks == true { held.append("clicks elsewhere") }
        log("info", "chooser live at \(elapsed()) (held for \(held.isEmpty ? "nothing" : held.joined(separator: " and ")))")
        // The human may have clicked into another app while it was held; that's where they'll
        // want the focus back if they turn out to be typing.
        if let frontmost = environment.frontmostApplication() { returnTo = frontmost }
        environment.takeFocus(panel)
        if panel.isKeyWindow { armed = true }
    }

    private func rehold() {
        reholds += 1
        state = .held
        armed = false
        liveAt = nil
        model?.live = false
        log("info", "chooser held again at \(elapsed()): a key not meant for it; now waits for "
            + String(format: "%.1f", requiredKeyboardIdle) + " s of keyboard quiet")
        environment.returnFocus(returnTo)
        startGrace()
    }

    private func pick(_ index: Int, via: String) {
        guard let model, model.options.indices.contains(index) else { return }
        let option = model.options[index]
        let callback = onSelect
        end("picked \(option.key) by \(via)")
        callback?(option)
    }

    private func copyURL() {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.url, forType: .string)
        end("copied the URL")
    }

    /// Logs how the chooser ended and tears it down.
    private func end(_ outcome: String, level: String = "info") {
        let live = liveAt.map { " (live at \(milliseconds($0 - shownAt)))" } ?? " (never live)"
        log(level, "chooser \(outcome) at \(elapsed())\(live)")
        state = .idle
        armed = false
        grace?.cancel()
        grace = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        stopWatchingClicks?()
        stopWatchingClicks = nil
        panel?.delegate = nil  // avoid re-entering windowDidResignKey during our own teardown
        panel?.orderOut(nil)
        panel = nil
        model = nil
        onSelect = nil
        returnTo = nil
    }

    private func elapsed() -> String { milliseconds(environment.now() - shownAt) }

    private func milliseconds(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    /// Centers `panel` on whichever screen currently contains the mouse cursor, so the chooser
    /// appears on the display the user is actively pointing at (multi-monitor). Falls back to the
    /// main screen, then to AppKit's default centering, if the cursor isn't over any known screen.
    public static func centerOnCursorScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation  // global, bottom-left origin — same space as NSScreen.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else {
            panel.center()
            return
        }
        // Center within visibleFrame so we don't tuck under the menu bar / Dock.
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2
        ))
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        switch state {
        case .live:
            armed = true
        case .held:
            // Never made key while held, so the human clicked it.
            grace?.engage()
        case .idle:
            break
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Clicking away / switching apps cancels a live chooser. A held one never took the focus,
        // so losing it means nothing.
        if state == .live, armed { end("cancelled by clicking away") }
    }

    /// Resolves an application's icon from a name, bundle id, or path (best-effort).
    public static func icon(for app: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        let url: URL?
        if app.hasPrefix("/") {
            url = URL(fileURLWithPath: app)
        } else if Launcher.isBundleID(app) {
            url = workspace.urlForApplication(withBundleIdentifier: app)
        } else {
            url = applicationURL(named: app)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return workspace.icon(forFile: url.path)
    }

    /// Locates an app bundle by name in the standard application directories.
    private static func applicationURL(named name: String) -> URL? {
        let bundleName = name.hasSuffix(".app") ? name : name + ".app"
        let directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        let fm = FileManager.default
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(bundleName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private struct ChooserView: View {
    @ObservedObject var model: ChooserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(spacing: 2) {
                ForEach(Array(model.options.enumerated()), id: \.element.id) { index, option in
                    row(index: index, option: option)
                }
            }
            .opacity(model.live ? 1 : 0.5)

            Text(model.live
                 ? "1–\(model.options.count) open · ⌘C copy · esc cancel"
                 : "Waiting while you type or click elsewhere · click to choose now")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func row(index: Int, option: ChooserOption) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            if let icon = option.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "globe").frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(option.title.capitalized)
                Text(option.subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(index == model.selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.onPick(index) }
    }
}
