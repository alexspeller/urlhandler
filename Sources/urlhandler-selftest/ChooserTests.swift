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
    /// When a mouse button last went down anywhere (the session counter); nil reads as an hour ago.
    var lastClick: Date?
    var alwaysTyping = false
    var focusTaken = 0
    var focusReturned = 0
    var clickHandler: (@MainActor () -> Void)?
    var logs: [String] = []
    /// "url → browser key" for every pick.
    var picked: [String] = []

    var keyboardIdle: TimeInterval {
        if alwaysTyping { return 0 }
        return lastKey.map { Date().timeIntervalSince($0) } ?? 3600
    }

    var mouseIdle: TimeInterval { lastClick.map { Date().timeIntervalSince($0) } ?? 3600 }

    /// A click in another app, as both the counter and the global monitor see it.
    func clickElsewhere() {
        lastClick = Date()
        clickHandler?()
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

    /// Timings scaled down from production: 0.1 s minimum, 0.25 s keyboard and mouse quiet, clicks
    /// on it blocked for 0.2 s, focus lost within 0.3 s of going live holds it again, and a click
    /// or key within 0.2 s counts as the human causing a focus loss.
    init() {
        let state = self.state
        var env = ChooserEnvironment()
        env.minimumDelay = 0.1
        env.requiredKeyboardIdle = 0.25
        env.clickQuietPeriod = 0.25
        env.clickBlockPeriod = 0.2
        env.focusLossHoldWindow = 0.3
        env.userActionWindow = 0.2
        env.keyboardIdle = { MainActor.assumeIsolated { state.keyboardIdle } }
        env.mouseIdle = { MainActor.assumeIsolated { state.mouseIdle } }
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
        chooser.present(url: url, options: options) { option in state.picked.append("\(url) → \(option.key)") }
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

    /// The close button: AppKit asks the delegate, then closes.
    func clickCloseButton() -> Bool {
        guard let window = chooser.window, chooser.windowShouldClose(window) else { return false }
        chooser.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        return true
    }

    func logged(_ fragment: String) -> Bool { state.logs.contains { $0.contains(fragment) } }

    func tearDown() { chooser.dismiss() }
}

@MainActor
private func runChooserHoldTests(_ h: Harness) async {
    h.suite("Chooser — held while the human is busy, live once they pause")
    NSApplication.shared.setActivationPolicy(.accessory)
    let a = "https://example.com/a"

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
        h.expect(rig.press("2", keyCode: 19) && rig.state.picked == ["\(a) → dexory"], "typing: a digit picks once live")
        h.expect(rig.chooser.state == .idle && rig.chooser.window == nil, "typing: the chooser is gone after a pick")
        h.expect(rig.logged("picked dexory by key"), "typing: the log records the pick and how")
        h.expect(rig.state.clickHandler == nil, "typing: the click watcher is stopped with the chooser")
    }

    do {
        // Live, then a letter: the human is still typing for another window.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.2)
        h.expect(rig.chooser.state == .live, "stray key: live at the minimum delay when nobody is typing")
        rig.state.lastKey = Date()
        h.expect(rig.press("h", keyCode: 4), "stray key: swallowed, not beeped")
        h.expect(rig.chooser.state == .held && rig.state.focusReturned == 1 && rig.state.picked.isEmpty,
                 "stray key: focus goes back and the chooser is held again, nothing picked")
        h.expect(rig.logged("held again") && rig.logged("a key not meant for it"), "stray key: logged")
        // The quiet it now waits for has doubled: 0.5 s instead of 0.25 s.
        spinRunLoop(seconds: 0.35)
        h.expect(rig.chooser.state == .held, "stray key: waits for twice the keyboard quiet")
        spinRunLoop(seconds: 0.3)
        h.expect(rig.chooser.state == .live && rig.state.focusTaken == 2, "stray key: live again after the longer quiet")
        h.expect(rig.press("\u{1b}", keyCode: 53) && rig.chooser.state == .idle && rig.state.picked.isEmpty,
                 "stray key: esc still cancels")
        h.expect(rig.logged("cancelled by esc"), "stray key: the cancel is logged")
    }

    do {
        // Losing focus: never matters while held; soon after going live it holds it again.
        let rig = ChooserRig()
        rig.present()
        rig.resignKey()
        h.expect(rig.chooser.state == .held, "focus loss: no effect while held")
        spinRunLoop(seconds: 0.15)
        h.expect(rig.chooser.state == .live, "focus loss: live")
        rig.becomeKey()
        rig.state.clickElsewhere()
        rig.resignKey()
        h.expect(rig.chooser.state == .held && rig.state.picked.isEmpty && rig.state.focusReturned == 0,
                 "focus loss: a click away just after going live holds it again instead of cancelling")
        h.expect(rig.logged("lost focus"), "focus loss: logged")
        // Mouse quiet doubled to 0.5 s from that click.
        spinRunLoop(seconds: 0.35)
        h.expect(rig.chooser.state == .held, "focus loss: waits twice as long for the mouse to be quiet")
        spinRunLoop(seconds: 0.3)
        h.expect(rig.chooser.state == .live, "focus loss: live again once quiet")
        rig.tearDown()
    }

    do {
        // Later than that, clicking away is a deliberate dismissal.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.15)
        rig.becomeKey()
        spinRunLoop(seconds: 0.35)
        rig.state.clickElsewhere()
        rig.resignKey()
        h.expect(rig.chooser.state == .idle && rig.state.picked.isEmpty, "click away: cancels once it's been live a while")
        h.expect(rig.logged("cancelled by clicking away"), "click away: logged")
    }

    do {
        // ...but losing focus with no click or key from the human (the browser just picked coming
        // forward, an app activating itself) holds it again.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.15)
        rig.becomeKey()
        spinRunLoop(seconds: 0.35)
        rig.resignKey()
        h.expect(rig.chooser.state == .held, "app took focus: held again, not cancelled")
        h.expect(rig.logged("another app took focus"), "app took focus: logged")
        rig.tearDown()
    }

    do {
        // Clicking around in other apps holds it too.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.02)
        rig.state.clickElsewhere()
        spinRunLoop(seconds: 0.15)
        h.expect(rig.chooser.state == .held, "clicks: a click elsewhere holds it past the minimum delay")
        spinRunLoop(seconds: 0.25)
        h.expect(rig.chooser.state == .live && rig.logged("held for clicks elsewhere"),
                 "clicks: live once the clicking stops, and logged")
        rig.tearDown()
    }

    do {
        // Clicking a row: blocked for the click block, even past the minimum delay.
        let rig = ChooserRig()
        rig.state.alwaysTyping = true
        rig.present()
        rig.chooser.rowClicked(1)
        h.expect(rig.chooser.state == .held && rig.state.picked.isEmpty, "row click: right as it appears, nothing happens")
        spinRunLoop(seconds: 0.15)
        rig.chooser.rowClicked(1)
        h.expect(rig.chooser.state == .held && rig.state.picked.isEmpty,
                 "row click: past the minimum delay but inside the click block, still nothing")
        spinRunLoop(seconds: 0.1)
        rig.chooser.rowClicked(1)
        h.expect(rig.state.picked == ["\(a) → dexory"] && rig.chooser.state == .idle,
                 "row click: after the block it picks, keyboard busy or not")
        h.expect(rig.logged("picked dexory by click"), "row click: logged")
    }

    do {
        // Live early (nobody typing) doesn't lift the click block.
        let rig = ChooserRig()
        rig.present()
        spinRunLoop(seconds: 0.15)
        h.expect(rig.chooser.state == .live, "row click: live at the minimum delay")
        rig.chooser.rowClicked(0)
        h.expect(rig.chooser.state == .live && rig.state.picked.isEmpty,
                 "row click: a live chooser still ignores a click inside the block")
        rig.tearDown()
    }

    do {
        // Clicking the panel itself (it becomes key) after the block makes it live.
        let rig = ChooserRig()
        rig.state.alwaysTyping = true
        rig.present()
        spinRunLoop(seconds: 0.15)
        rig.becomeKey()
        h.expect(rig.chooser.state == .held && rig.state.focusTaken == 0,
                 "engage: clicking it inside the click block doesn't make it live")
        spinRunLoop(seconds: 0.1)
        rig.becomeKey()
        h.expect(rig.chooser.state == .live && rig.state.focusTaken == 1,
                 "engage: clicking it after the block makes it live")
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
        // The close button is a click like any other.
        let rig = ChooserRig()
        rig.present()
        h.expect(!rig.clickCloseButton() && rig.chooser.state == .held, "close: blocked inside the click block")
        spinRunLoop(seconds: 0.25)
        h.expect(rig.clickCloseButton() && rig.chooser.state == .idle && rig.state.picked.isEmpty,
                 "close: closes it afterwards, opening nothing")
        h.expect(rig.logged("chooser closed"), "close: logged")
    }

    h.suite("Chooser — URLs arriving while one is up are queued")

    do {
        let rig = ChooserRig()
        let b = "https://example.com/b"
        let c = "https://example.com/c"
        rig.present(a)
        rig.present(b)
        h.expect(rig.chooser.state == .held && rig.chooser.queuedURLs == [b],
                 "queue: a second URL waits behind the first")
        h.expect(rig.logged("queued \(b) (1 waiting)"), "queue: logged")
        rig.present(a)
        rig.present(b)
        h.expect(rig.chooser.queuedURLs == [b] && rig.logged("ignoring the duplicate"),
                 "queue: a URL already up or already queued is ignored")
        rig.present(c)
        h.expect(rig.chooser.queuedURLs == [b, c], "queue: first in, first out")

        spinRunLoop(seconds: 0.15)
        rig.press("1", keyCode: 18)
        h.expect(rig.state.picked == ["\(a) → personal"], "queue: the pick opens the first URL")
        h.expect(rig.chooser.state == .held && rig.chooser.queuedURLs == [c] && rig.logged("showing chooser for \(b)"),
                 "queue: the next URL's chooser appears at once, held afresh")
        spinRunLoop(seconds: 0.15)
        h.expect(rig.chooser.state == .live, "queue: and goes live like any other")
        rig.press("\u{1b}", keyCode: 53)
        h.expect(rig.state.picked == ["\(a) → personal"] && rig.chooser.state == .held
                    && rig.chooser.queuedURLs.isEmpty && rig.logged("showing chooser for \(c)"),
                 "queue: esc cancels only the current URL; the next one comes up")
        spinRunLoop(seconds: 0.15)
        rig.press("3", keyCode: 20)
        h.expect(rig.state.picked == ["\(a) → personal", "\(c) → safari"] && rig.chooser.state == .idle,
                 "queue: each URL's pick goes to its own callback")
    }

    do {
        // Closing one shows the next; dismissing drops everything, logging what wasn't opened.
        let rig = ChooserRig()
        rig.present(a)
        rig.present("https://example.com/b")
        rig.present("https://example.com/c")
        spinRunLoop(seconds: 0.25)
        _ = rig.clickCloseButton()
        h.expect(rig.chooser.state == .held && rig.chooser.queuedURLs == ["https://example.com/c"],
                 "queue: closing one brings up the next")
        rig.tearDown()
        h.expect(rig.chooser.state == .idle && rig.chooser.window == nil && rig.chooser.queuedURLs.isEmpty,
                 "dismiss: tears everything down")
        h.expect(rig.logged("[warn] chooser dismissed; queued URL not opened: https://example.com/c"),
                 "dismiss: the dropped queued URL is in the log")
    }
}
