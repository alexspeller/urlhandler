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
    /// How many URLs are queued behind this one.
    @Published var waiting = 0
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
    /// Doubled after each re-hold, like `requiredKeyboardIdle`.
    public var clickQuietPeriod: TimeInterval = InteractionGrace.clickQuietPeriod
    public var clickBlockPeriod: TimeInterval = InteractionGrace.clickBlockPeriod
    public var focusLossHoldWindow: TimeInterval = InteractionGrace.focusLossHoldWindow
    public var userActionWindow: TimeInterval = InteractionGrace.userActionWindow
    public var keyboardIdle: () -> TimeInterval = InteractionGrace.secondsSinceLastKeyPress
    public var mouseIdle: () -> TimeInterval = InteractionGrace.secondsSinceLastClick
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
/// a click elsewhere cannot dismiss it. Clicks on it do nothing for `clickBlockPeriod`. It goes
/// **live** (activates and takes the keyboard) when `InteractionGrace` says the human has paused,
/// or when they click it after the block.
///
/// A live chooser is **held again** — dimmed, waiting twice as long for quiet each time, so a
/// writer pausing between sentences isn't interrupted every time — when it gets a key that isn't
/// one of its own (a letter, space…: the human is still typing for another window, so the focus
/// goes back there; that key is lost, as re-sending it needs Accessibility), when it loses focus
/// within `focusLossHoldWindow` of going live (they hadn't seen it), or when it loses focus later
/// without the human clicking or pressing a key (another app took it). Only a pick, esc, ⌘C, its
/// close button, or clicking away later than that ends it.
///
/// URLs that arrive while a chooser is up are **queued** (first in, first out; a URL already up or
/// queued is ignored) and each gets its own chooser, held afresh, when the one before it ends.
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
    private var queue: [Request] = []

    private struct Request {
        let url: String
        let options: [ChooserOption]
        let onSelect: (ChooserOption) -> Void
    }

    /// URLs waiting behind the current chooser, oldest first.
    public var queuedURLs: [String] { queue.map(\.url) }

    public init(environment: ChooserEnvironment = .production, log: @escaping JSEngine.Logger = { _, _ in }) {
        self.environment = environment
        self.log = log
        super.init()
    }

    /// Shows a chooser for `url`, or queues it behind the one already up.
    public func present(
        url: String,
        options: [ChooserOption],
        onSelect: @escaping (ChooserOption) -> Void
    ) {
        guard !options.isEmpty else { return }
        let request = Request(url: url, options: options, onSelect: onSelect)
        guard state == .idle else {
            if model?.url == url || queue.contains(where: { $0.url == url }) {
                log("info", "chooser already has \(url); ignoring the duplicate")
                return
            }
            queue.append(request)
            model?.waiting = queue.count
            log("info", "chooser busy; queued \(url) (\(queue.count) waiting)")
            return
        }
        show(request)
    }

    private func show(_ request: Request) {
        log("info", "showing chooser for \(request.url) with \(request.options.count) options")
        let model = ChooserModel(url: request.url, options: request.options)
        model.waiting = queue.count
        model.onPick = { [weak self] index in self?.rowClicked(index) }
        self.model = model
        self.onSelect = request.onSelect

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
            // Only reachable when the panel was made key by a click inside the click block and
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
        case .stray: holdAgain("a key not meant for it", returningFocus: true)
        }
        return true
    }

    /// What a click on row `index` does. Nothing for `clickBlockPeriod` after the chooser
    /// appeared or was held again — the click may have been in flight; after that, a held chooser
    /// takes it as the human engaging with it, and a live one picks the row.
    public func rowClicked(_ index: Int) {
        guard grace?.acceptsClicks == true else { return }
        if state == .held { grace?.engage() }
        guard state == .live else { return }
        pick(index, via: "click")
    }

    /// Cancels the chooser and everything queued behind it, without opening anything.
    public func dismiss() {
        for request in queue { log("warn", "chooser dismissed; queued URL not opened: \(request.url)") }
        queue.removeAll()
        guard state != .idle else { return }
        end("dismissed")
    }

    private func startGrace() {
        grace?.cancel()
        let grace = InteractionGrace(
            minimumDelay: environment.minimumDelay,
            requiredKeyboardIdle: requiredKeyboardIdle,
            clickQuietPeriod: clickQuietPeriod,
            clickBlockPeriod: environment.clickBlockPeriod,
            keyboardIdle: environment.keyboardIdle,
            now: environment.now,
            onLive: { [weak self] in self?.goLive() }
        )
        self.grace = grace
        grace.begin()
    }

    /// Each time the chooser is held again it waits twice as long for quiet.
    private var backoff: Double { pow(2, Double(reholds)) }
    private var requiredKeyboardIdle: TimeInterval { environment.requiredKeyboardIdle * backoff }
    private var clickQuietPeriod: TimeInterval { environment.clickQuietPeriod * backoff }

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

    /// Back to held: dimmed, acting on nothing, waiting (twice as long as last time) for quiet.
    private func holdAgain(_ reason: String, returningFocus: Bool) {
        reholds += 1
        state = .held
        armed = false
        liveAt = nil
        model?.live = false
        log("info", "chooser held again at \(elapsed()): \(reason); now waits for "
            + String(format: "%.1f s of keyboard and %.1f s of mouse quiet", requiredKeyboardIdle, clickQuietPeriod))
        if returningFocus { environment.returnFocus(returnTo) }
        startGrace()
        // The click that took the focus (if that's what happened) came just before this hold
        // began, so the hold's own click watching never saw it: count it, or the chooser would
        // take the focus straight back from someone still clicking around.
        grace?.clickedElsewhere(secondsAgo: environment.mouseIdle())
    }

    /// Whether the human clicked or pressed a key (⌘Tab…) just now, i.e. caused a focus loss.
    private var humanActedJustNow: Bool {
        func recent(_ idle: TimeInterval) -> Bool {
            idle.isFinite && idle >= 0 && idle < environment.userActionWindow
        }
        return recent(environment.mouseIdle()) || recent(environment.keyboardIdle())
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

    /// Logs how the chooser ended, tears it down, and shows the next queued URL.
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
        if !queue.isEmpty { show(queue.removeFirst()) }
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
        // A held chooser never took the focus, so losing it means nothing.
        guard state == .live, armed, let liveAt else { return }
        let liveFor = environment.now() - liveAt
        if liveFor < environment.focusLossHoldWindow {
            holdAgain("lost focus \(milliseconds(liveFor)) after going live", returningFocus: false)
        } else if humanActedJustNow {
            end("cancelled by clicking away")
        } else {
            holdAgain("another app took focus", returningFocus: false)
        }
    }

    /// The close button, which is blocked like any other click for `clickBlockPeriod`.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        grace?.acceptsClicks ?? true
    }

    public func windowWillClose(_ notification: Notification) {
        guard state != .idle else { return }
        end("closed")
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
            HStack(spacing: 6) {
                Text(model.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.waiting > 0 {
                    Spacer(minLength: 0)
                    Text("+\(model.waiting) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

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
