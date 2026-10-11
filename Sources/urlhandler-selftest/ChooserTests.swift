import AppKit
import Foundation
import URLHandlerKit

@MainActor
func runChooserTests(_ h: Harness) async {
    h.suite("Chooser — key handling")

    // Digit keys pick by 1-based index (regardless of current selection).
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "1", command: false, optionsCount: 5, selected: 3),
        .pick(0), "digit 1 picks first")
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "5", command: false, optionsCount: 5, selected: 0),
        .pick(4), "digit 5 picks fifth")
    // A digit beyond the options isn't a chooser key: someone is typing.
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "6", command: false, optionsCount: 5, selected: 0),
        .stray, "digit beyond count is stray")

    // ⌘C copies; ⌘ + another key is meant for another app.
    h.expectEqual(
        chooserKeyAction(keyCode: 8, characters: "c", command: true, optionsCount: 3, selected: 0),
        .copy, "cmd-c copies")
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "x", command: true, optionsCount: 3, selected: 0),
        .stray, "cmd-other is stray")

    // Letters, space and Tab are typing.
    h.expectEqual(
        chooserKeyAction(keyCode: 4, characters: "h", command: false, optionsCount: 3, selected: 0),
        .stray, "letter is stray")
    h.expectEqual(
        chooserKeyAction(keyCode: 49, characters: " ", command: false, optionsCount: 3, selected: 0),
        .stray, "space is stray")
    h.expectEqual(
        chooserKeyAction(keyCode: 48, characters: "\t", command: false, optionsCount: 3, selected: 0),
        .stray, "tab is stray")

    // Esc cancels.
    h.expectEqual(
        chooserKeyAction(keyCode: 53, characters: nil, command: false, optionsCount: 3, selected: 1),
        .cancel, "esc cancels")

    // Return/enter pick the current selection.
    h.expectEqual(
        chooserKeyAction(keyCode: 36, characters: nil, command: false, optionsCount: 3, selected: 2),
        .pick(2), "return picks selected")

    // Arrows move selection within bounds.
    h.expectEqual(
        chooserKeyAction(keyCode: 125, characters: nil, command: false, optionsCount: 3, selected: 0),
        .select(1), "down moves selection")
    h.expectEqual(
        chooserKeyAction(keyCode: 125, characters: nil, command: false, optionsCount: 3, selected: 2),
        .select(2), "down clamps at last")
    h.expectEqual(
        chooserKeyAction(keyCode: 126, characters: nil, command: false, optionsCount: 3, selected: 0),
        .select(0), "up clamps at first")

    await runChooserHoldTests(h)
}

/// What the rig's environment records, and the clocks it reads.
@MainActor
private final class RigState {
    /// When a key last went down; nil reads as an hour ago.
    var lastKey: Date?
    var alwaysTyping = false
    var focusTaken = 0
    var focusReturned = 0
    var clickHandler: (@MainActor () -> Void)?
    var logs: [String] = []
    var picked: [String] = []

    var keyboardIdle: TimeInterval {
        if alwaysTyping { return 0 }
        return lastKey.map { Date().timeIntervalSince($0) } ?? 3600
    }
}

/// A real chooser whose panel is parked offscreen and transparent, and whose focus steps are
/// recorders, so the suite never puts a window in front of the developer or takes their focus —
/// which would be this feature's own bug.
@MainActor
private final class ChooserRig {
    let state = RigState()
    let chooser: Chooser
    let options = [
        ChooserOption(key: "personal", browser: BrowserConfig(app: "Google Chrome", profile: "Default"), icon: nil),
        ChooserOption(key: "dexory", browser: BrowserConfig(app: "Google Chrome", profile: "Profile 1"), icon: nil),
        ChooserOption(key: "safari", browser: BrowserConfig(app: "Safari"), icon: nil),
    ]

    /// Timings scaled down from production: 0.1 s minimum, 0.25 s keyboard quiet, 0.25 s since a click.
    init() {
        let state = self.state
        var env = ChooserEnvironment()
        env.minimumDelay = 0.1
        env.requiredKeyboardIdle = 0.25
        env.clickQuietPeriod = 0.25
        env.keyboardIdle = { MainActor.assumeIsolated { state.keyboardIdle } }
        env.show = { panel in
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            panel.orderFront(nil)
        }
        env.takeFocus = { _ in state.focusTaken += 1 }
        env.returnFocus = { _ in state.focusReturned += 1 }
        env.frontmostApplication = { nil }
        env.watchClicksElsewhere = { handler in
            state.clickHandler = handler
            return { state.clickHandler = nil }
        }
        chooser = Chooser(environment: env, log: { level, message in
            MainActor.assumeIsolated { state.logs.append("[\(level)] \(message)") }
        })
    }

    func present(_ url: String = "https://example.com/a") {
        let state = self.state
        chooser.present(url: url, options: options) { option in state.picked.append(option.key) }
    }

    /// A key going down, delivered as the chooser's key monitor delivers it.
    @discardableResult
    func press(_ characters: String, keyCode: UInt16) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: chooser.window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return false }
        return chooser.handle(keyDown: event)
    }

    func becomeKey() {
        chooser.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: chooser.window))
    }

    func resignKey() {
        chooser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: chooser.window))
    }

    func logged(_ fragment: String) -> Bool { state.logs.contains { $0.contains(fragment) } }

    func tearDown() { chooser.dismiss() }
}

@MainActor
private func runChooserHoldTests(_ h: Harness) async {
    h.suite("Chooser — held while the human is busy, live once they pause")
    NSApplication.shared.setActivationPolicy(.accessory)

    do {
        // Typing as it appears: it shows without focus, and the typing goes on undisturbed.
        let rig = ChooserRig()
        rig.state.lastKey = Date()
        rig.present()
        h.expect(rig.chooser.state == .held && rig.chooser.window?.isVisible == true,
                 "typing: shown, held")
        h.expect(rig.chooser.window?.isKeyWindow == false && rig.state.focusTaken == 0,
                 "typing: never key and never activated while held")
        for _ in 0..<4 {
            spinRunLoop(seconds: 0.1)
            rig.state.lastKey = Date()
        }
        h.expect(rig.chooser.state == .held && rig.state.focusTaken == 0, "typing: still held while the typing goes on")
        rig.resignKey()
        h.expect(rig.chooser.state == .held, "typing: losing key while held doesn't cancel it")
        spinRunLoop(seconds: 0.4)
        h.expect(rig.chooser.state == .live && rig.state.focusTaken == 1, "typing: live and focused once the typing stops")
        h.expect(rig.logged("chooser live at") && rig.logged("held for typing"), "typing: the log says it was held for typing")
        h.expect(rig.press("2", keyCode: 19) && rig.state.picked == ["dexory"], "typing: a digit picks once live")
        h.expect(rig.chooser.state == .idle && rig.chooser.window == nil, "typing: the chooser is gone after a pick")
        h.expect(rig.logged("picked dexory by key"), "typing: the log records the pick and how")
        h.expect(rig.state.clickHandler == nil, "typing: the click watcher is stopped with the chooser")
    }

    do {
        // Live, then a letter: the human is still typing for another window.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.2)
        h.expect(rig.chooser.state == .live, "re-hold: live at the minimum delay when nobody is typing")
        rig.state.lastKey = Date()
        h.expect(rig.press("h", keyCode: 4), "re-hold: the stray key is swallowed, not beeped")
        h.expect(rig.chooser.state == .held && rig.state.focusReturned == 1 && rig.state.picked.isEmpty,
                 "re-hold: focus goes back and the chooser is held again, nothing picked")
        h.expect(rig.logged("held again"), "re-hold: logged")
        // The quiet it now waits for has doubled: 0.5 s instead of 0.25 s.
        spinRunLoop(seconds: 0.35)
        h.expect(rig.chooser.state == .held, "re-hold: waits for twice the keyboard quiet")
        spinRunLoop(seconds: 0.3)
        h.expect(rig.chooser.state == .live && rig.state.focusTaken == 2, "re-hold: live again after the longer quiet")
        h.expect(rig.press("\u{1b}", keyCode: 53) && rig.chooser.state == .idle && rig.state.picked.isEmpty,
                 "re-hold: esc still cancels")
        h.expect(rig.logged("cancelled by esc"), "re-hold: the cancel is logged")
    }

    do {
        // Clicking away cancels a live chooser, never a held one.
        let rig = ChooserRig()
        rig.present()
        rig.resignKey()
        h.expect(rig.chooser.state == .held, "click away: no effect while held")
        spinRunLoop(seconds: 0.2)
        rig.becomeKey()
        rig.resignKey()
        h.expect(rig.chooser.state == .idle && rig.state.picked.isEmpty, "click away: cancels once live")
        h.expect(rig.logged("cancelled by clicking away"), "click away: logged")
    }

    do {
        // Clicking around in other apps holds it too.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.02)
        rig.state.clickHandler?()
        spinRunLoop(seconds: 0.15)
        h.expect(rig.chooser.state == .held, "clicks: a click elsewhere holds it past the minimum delay")
        spinRunLoop(seconds: 0.25)
        h.expect(rig.chooser.state == .live && rig.logged("held for clicks elsewhere"),
                 "clicks: live once the clicking stops, and logged")
        rig.tearDown()
    }

    do {
        // Clicking a row: deliberate past the minimum delay, even with the keyboard busy.
        let rig = ChooserRig()
        rig.state.alwaysTyping = true
        rig.present()
        rig.chooser.rowClicked(1)
        h.expect(rig.chooser.state == .held && rig.state.picked.isEmpty,
                 "row click: inside the minimum delay it may be in flight, so nothing happens")
        spinRunLoop(seconds: 0.15)
        rig.chooser.rowClicked(1)
        h.expect(rig.state.picked == ["dexory"] && rig.chooser.state == .idle,
                 "row click: past the minimum delay it picks, keyboard busy or not")
        h.expect(rig.logged("picked dexory by click"), "row click: logged")
    }

    do {
        // Clicking the panel itself (it becomes key) past the minimum delay makes it live.
        let rig = ChooserRig()
        rig.state.alwaysTyping = true
        rig.present()
        spinRunLoop(seconds: 0.15)
        rig.becomeKey()
        h.expect(rig.chooser.state == .live && rig.state.focusTaken == 1,
                 "engage: clicking the held chooser makes it live")
        rig.tearDown()
    }

    do {
        // Made key by a click as it appeared, and the human types: no key is a choice yet.
        let rig = ChooserRig()
        rig.state.alwaysTyping = true
        rig.present()
        rig.becomeKey()
        h.expect(rig.press("1", keyCode: 18) && rig.state.picked.isEmpty && rig.chooser.state == .held,
                 "held + key: a key reaching a held chooser picks nothing")
        h.expect(rig.state.focusReturned == 1, "held + key: the focus goes back to the app being typed into")
        rig.tearDown()
    }

    do {
        // A new URL while one is up: the old one is logged so it isn't silently lost.
        let rig = ChooserRig()
        rig.present("https://example.com/first")
        rig.present("https://example.com/second")
        h.expect(rig.logged("[warn] chooser replaced by a new URL") && rig.logged("https://example.com/first"),
                 "replace: the dropped URL is in the log")
        h.expect(rig.chooser.state == .held, "replace: the new chooser is held like any other")
        rig.tearDown()
        h.expect(rig.chooser.state == .idle && rig.chooser.window == nil, "dismiss: tears the chooser down")
    }
}
