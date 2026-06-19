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
    case ignore
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
        return characters?.lowercased() == "c" ? .copy : .ignore
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
    return .ignore
}

@MainActor
final class ChooserModel: ObservableObject {
    let url: String
    let options: [ChooserOption]
    @Published var selected: Int = 0
    var onPick: (Int) -> Void = { _ in }

    init(url: String, options: [ChooserOption]) {
        self.url = url
        self.options = options
    }
}

/// A small, keyboard-driven popup for choosing a browser when routing is ambiguous.
/// Number keys pick, ⌘C copies the URL, esc cancels, arrows + return move/confirm.
@MainActor
public final class Chooser: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitor: Any?
    private var model: ChooserModel?
    private var onSelect: ((ChooserOption) -> Void)?
    private var armed = false  // becomes true once the panel is key, so setup doesn't self-dismiss

    public override init() { super.init() }

    public func present(
        url: String,
        options: [ChooserOption],
        onSelect: @escaping (ChooserOption) -> Void
    ) {
        dismiss()
        guard !options.isEmpty else { return }

        let model = ChooserModel(url: url, options: options)
        model.onPick = { [weak self] index in self?.pick(index) }
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
        Chooser.centerOnCursorScreen(panel)
        panel.delegate = self
        self.panel = panel
        armed = false

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let action = chooserKeyAction(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            command: event.modifierFlags.contains(.command),
            optionsCount: model.options.count,
            selected: model.selected
        )
        switch action {
        case .pick(let index): pick(index)
        case .copy: copyURL()
        case .cancel: dismiss()
        case .select(let index): model.selected = index
        case .ignore: return false
        }
        return true
    }

    private func pick(_ index: Int) {
        guard let model, model.options.indices.contains(index) else { return }
        let option = model.options[index]
        let callback = onSelect
        dismiss()
        callback?(option)
    }

    private func copyURL() {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.url, forType: .string)
        dismiss()
    }

    public func dismiss() {
        armed = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.delegate = nil  // avoid re-entering windowDidResignKey during our own teardown
        panel?.orderOut(nil)
        panel = nil
        model = nil
        onSelect = nil
    }

    /// Centers `panel` on whichever screen currently contains the mouse cursor, so the chooser
    /// appears on the display the user is actively pointing at (multi-monitor). Falls back to the
    /// main screen, then to AppKit's default centering, if the cursor isn't over any known screen.
    static func centerOnCursorScreen(_ panel: NSPanel) {
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

    // MARK: - NSWindowDelegate (defocus cancels)

    public func windowDidBecomeKey(_ notification: Notification) {
        armed = true
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Clicking away / switching apps cancels the open and hides the chooser.
        if armed { dismiss() }
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

            Text("1–\(model.options.count) open · ⌘C copy · esc cancel")
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
