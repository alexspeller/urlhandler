import Foundation
import URLHandlerKit

/// Runs the main run loop, which is what fires the grace's timers.
@MainActor
func spinRunLoop(seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Seconds since a key went down, as convenient-security measured the session counter: a key
/// press is published only when the step it fell in has closed, dated to that step's start;
/// before any closed step holds one, an hour.
private func steppedKeyboardIdle(keys: [TimeInterval], now: TimeInterval, step: TimeInterval) -> TimeInterval {
    let published = keys
        .map { floor($0 / step) * step }
        .filter { $0 + step <= now }
        .max()
    guard let published else { return 3600 }
    return now - published
}

/// The hold's timing. All on scaled-down periods with injected keyboard clocks, so the developer
/// typing or clicking while the suite runs changes nothing.
@MainActor
func runInteractionGraceTests(_ h: Harness) async {
    h.suite("InteractionGrace — holding the chooser while the human is busy")

    do {
        // A human who was waiting, not typing, gets it at the minimum delay and no sooner.
        var lives = 0
        let grace = InteractionGrace(
            minimumDelay: 0.15, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.3,
            keyboardIdle: { 3600 }, onLive: { lives += 1 })
        grace.begin()
        spinRunLoop(seconds: 0.05)
        h.expect(grace.phase == .waiting && lives == 0, "quiet keyboard: held for the minimum delay")
        spinRunLoop(seconds: 0.2)
        h.expect(grace.phase == .live && lives == 1, "quiet keyboard: live at the minimum delay")
        h.expect(!grace.heldForTyping && !grace.heldForClicks, "quiet keyboard: nothing reported as holding it")
    }

    do {
        // Typing as it appears and on past the minimum delay: every key restarts the wait.
        var lastKey = Date()
        var lives = 0
        let grace = InteractionGrace(
            minimumDelay: 0.1, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.3,
            keyboardIdle: { Date().timeIntervalSince(lastKey) }, onLive: { lives += 1 })
        grace.begin()
        spinRunLoop(seconds: 0.2)
        h.expect(grace.phase == .waiting, "typing: a keyboard still busy past the minimum delay holds it")
        lastKey = Date()
        spinRunLoop(seconds: 0.3)
        h.expect(grace.phase == .waiting, "typing: each key pressed while held starts the wait again")
        spinRunLoop(seconds: 0.35)
        h.expect(grace.phase == .live && lives == 1, "typing: live once the keyboard has been quiet long enough")
        h.expect(grace.heldForTyping && !grace.heldForClicks, "typing: reported as held for typing")
    }

    do {
        // The counter as convenient-security measured it (scaled to a quarter-second step):
        // waiting for the quiet period plus one step stays held while the typing goes on.
        let step = 0.25
        let quiet = 0.25
        let started = Date()
        let keys = stride(from: -0.5, through: 1.0, by: 0.06).map { $0 }
        let counter: () -> TimeInterval = {
            steppedKeyboardIdle(keys: keys, now: Date().timeIntervalSince(started), step: step)
        }
        let grace = InteractionGrace(
            minimumDelay: 0.1, requiredKeyboardIdle: quiet + step, clickQuietPeriod: 0.3,
            keyboardIdle: counter, onLive: {})
        grace.begin()
        var liveWhileTyping = false
        while Date().timeIntervalSince(started) < 1.0 {
            spinRunLoop(seconds: 0.02)
            if grace.phase != .waiting { liveWhileTyping = true }
        }
        h.expect(!liveWhileTyping, "stepped counter: never reads quiet while the typing goes on")
        spinRunLoop(seconds: 0.85)
        h.expect(grace.phase == .live, "stepped counter: live within a step of the quiet period after typing stops")

        // What waiting for the quiet period alone does: the same typing reads past it inside every
        // step, and the chooser would go live mid-sentence.
        let restarted = Date()
        let early = InteractionGrace(
            minimumDelay: 0.1, requiredKeyboardIdle: quiet, clickQuietPeriod: 0.3,
            keyboardIdle: { steppedKeyboardIdle(keys: keys, now: Date().timeIntervalSince(restarted), step: step) },
            onLive: {})
        early.begin()
        spinRunLoop(seconds: 0.3)
        h.expect(early.phase == .live,
                 "stepped counter: without the step as margin, steady typing reads as quiet (the bug this guards)")
        early.cancel()
    }

    for reading in [-1.0, .nan, .infinity] {
        let grace = InteractionGrace(
            minimumDelay: 0.05, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.3,
            keyboardIdle: { reading }, onLive: {})
        grace.begin()
        spinRunLoop(seconds: 0.2)
        h.expect(grace.phase == .live, "a keyboard reading of \(reading), which is not a duration, holds nothing back")
    }

    do {
        // Clicking around in another app holds it too, measured from the last click.
        var lives = 0
        let grace = InteractionGrace(
            minimumDelay: 0.1, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.3,
            keyboardIdle: { 3600 }, onLive: { lives += 1 })
        grace.clickedElsewhere()  // before the chooser appeared: the click that opened the link
        grace.begin()
        spinRunLoop(seconds: 0.05)
        grace.clickedElsewhere()
        spinRunLoop(seconds: 0.2)
        h.expect(grace.phase == .waiting, "clicks: a click elsewhere holds it past the minimum delay")
        spinRunLoop(seconds: 0.25)
        h.expect(grace.phase == .live && lives == 1, "clicks: live once the mouse has been quiet long enough")
        h.expect(grace.heldForClicks && !grace.heldForTyping, "clicks: reported as held for clicks elsewhere")
    }

    do {
        // Only clicks after it appeared count: the click that opened the link never delays it.
        let grace = InteractionGrace(
            minimumDelay: 0.1, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.5,
            keyboardIdle: { 3600 }, onLive: {})
        grace.clickedElsewhere()
        grace.begin()
        spinRunLoop(seconds: 0.2)
        h.expect(grace.phase == .live, "clicks: one before it appeared doesn't hold it")
    }

    do {
        // Clicking the chooser itself: blocked for the click block, even past the minimum delay,
        // since it may have been in flight; after it, deliberate, and it beats a busy keyboard.
        var lives = 0
        let grace = InteractionGrace(
            minimumDelay: 0.1, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.3, clickBlockPeriod: 0.3,
            keyboardIdle: { 0 }, onLive: { lives += 1 })
        h.expect(!grace.acceptsClicks, "engage: no clicks before it has begun")
        grace.begin()
        spinRunLoop(seconds: 0.05)
        h.expect(!grace.acceptsClicks && !grace.engage() && grace.phase == .waiting,
                 "engage: a click inside the minimum delay doesn't make it live")
        spinRunLoop(seconds: 0.12)
        h.expect(!grace.acceptsClicks && !grace.engage() && grace.phase == .waiting,
                 "engage: past the minimum delay but inside the click block, a click still does nothing")
        spinRunLoop(seconds: 0.18)
        h.expect(grace.phase == .waiting, "engage: a keyboard that never goes quiet keeps it held")
        h.expect(grace.acceptsClicks && grace.engage() && grace.phase == .live && lives == 1,
                 "engage: a click after the block makes it live at once, keyboard busy or not")
        h.expect(grace.engage() && lives == 1, "engage: engaging a live chooser again changes nothing")
        spinRunLoop(seconds: 0.1)
        h.expect(lives == 1, "engage: the pending re-check never fires once it's live")
    }

    do {
        // The click block is measured from when it appeared, not from going live: a chooser live
        // at the minimum delay still ignores clicks until the block is over.
        let grace = InteractionGrace(
            minimumDelay: 0.05, requiredKeyboardIdle: 0.4, clickQuietPeriod: 0.3, clickBlockPeriod: 0.3,
            keyboardIdle: { 3600 }, onLive: {})
        grace.begin()
        spinRunLoop(seconds: 0.15)
        h.expect(grace.phase == .live && !grace.acceptsClicks, "click block: still blocking clicks after going live early")
        spinRunLoop(seconds: 0.2)
        h.expect(grace.acceptsClicks, "click block: clicks count once it's over")
        grace.cancel()
    }

    do {
        // The owner finished while it was held: the re-check it had scheduled must never fire.
        var lives = 0
        let grace = InteractionGrace(
            minimumDelay: 0.05, requiredKeyboardIdle: 0.3, clickQuietPeriod: 0.3,
            keyboardIdle: { 0 }, onLive: { lives += 1 })
        grace.begin()
        spinRunLoop(seconds: 0.15)
        grace.cancel()
        spinRunLoop(seconds: 0.4)
        h.expect(grace.phase == .cancelled && lives == 0, "cancel: a cancelled hold never goes live")
        h.expect(!grace.engage(), "cancel: a cancelled hold can't be engaged")
    }

    h.expect(
        InteractionGrace.minimumDelay == 0.5
            && InteractionGrace.keyboardQuietPeriod == 1.0
            && InteractionGrace.keyboardCounterStep == 0.5
            && InteractionGrace.requiredKeyboardIdle == 1.5
            && InteractionGrace.clickQuietPeriod == 1.0
            && InteractionGrace.clickBlockPeriod == 1.0,
        "production: ≥0.5 s, then 1 s of keyboard quiet plus the counter's 0.5 s step, and 1 s since a click; clicks on it blocked for 1 s")
    h.expect(
        InteractionGrace.focusLossHoldWindow == 2.0 && InteractionGrace.userActionWindow == 1.0,
        "production: losing focus within 2 s of going live holds it again; later, only a click or key in the last 1 s cancels")
    let sinceClick = InteractionGrace.secondsSinceLastClick()
    h.expect(sinceClick.isFinite && sinceClick >= 0,
             "production: this process can read how long since the last click (no grant needed)")
    let idle = InteractionGrace.secondsSinceLastKeyPress()
    h.expect(idle.isFinite && idle >= 0,
             "production: this process can read how long the keyboard has been quiet (no Input Monitoring needed)")
}
