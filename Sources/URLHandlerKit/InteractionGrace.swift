import CoreGraphics
import Foundation

/// Holds a freshly shown chooser back from the keyboard and mouse while the human is busy
/// elsewhere, so the keystrokes and clicks they already have in flight keep going where they
/// meant them instead of picking a browser, cancelling the chooser, or clicking it away.
///
/// The problem: a chooser is often raised by something other than a click the human is waiting
/// on — a CLI or agent opening a URL, a redirect `resolve()` finishing seconds later, a link
/// ⌘-clicked in a terminal while they carry on typing. The instant it appeared it took focus, so
/// the next Return or digit of their sentence picked a browser, Escape cancelled it, and the
/// click back into their own window dismissed it — the link was lost.
///
/// The grace is the timing half of the fix (`Chooser` does the window work): it decides when
/// the chooser may go live. That is at least `minimumDelay` after it appeared, and then only
/// once (a) the session's keyboard counter reads `requiredKeyboardIdle` and (b) no click in
/// another app has landed for `clickQuietPeriod`. A human who was waiting for the chooser gets
/// it at the minimum delay; one who keeps typing or clicking has not seen it, so there is no cap.
/// A deliberate click on the chooser itself (`engage()`) makes it live at once, past the minimum
/// delay.
///
/// Ported from convenient-security's `PromptInteractionGrace`, which guards its approval panels
/// the same way.
@MainActor
public final class InteractionGrace: NSObject {
    /// The shortest time a newly shown chooser ignores input: long enough for the click or
    /// keystroke in flight as it appears (the second click of a double-click on the link
    /// included) to land elsewhere; short enough that a human who was waiting for it rarely
    /// notices.
    nonisolated public static let minimumDelay: TimeInterval = 0.5

    /// How long the keyboard must have been still before the chooser takes it. Longer than the
    /// gaps between keys in a typed sentence, so a typist who has not noticed the chooser keeps
    /// typing into their own window.
    nonisolated public static let keyboardQuietPeriod: TimeInterval = 1.0

    /// How coarsely the session's keyboard counter may see key presses. convenient-security
    /// measured it publishing in half-second steps, each dated to the start of its step, so
    /// steady typing read anything up to just over a second; a probe of the same Mac on
    /// 2026-10-11 saw every key within 5 ms. Waiting out one step as margin is right either way:
    /// with a precise counter it only means going live 1.5 s after the last key instead of 1 s.
    nonisolated public static let keyboardCounterStep: TimeInterval = 0.5

    /// The counter reading the grace waits for: the quiet period plus one step, which steady
    /// typing never reaches even on a stepped counter.
    nonisolated public static let requiredKeyboardIdle: TimeInterval =
        keyboardQuietPeriod + keyboardCounterStep

    /// How long since the last click in another app before the chooser takes focus. Clicks
    /// are seen exactly (a global mouse monitor, `Chooser`), and only those after the chooser
    /// appeared count, so the click that opened the link never delays it.
    nonisolated public static let clickQuietPeriod: TimeInterval = 1.0

    /// Seconds since a key last went down anywhere in the login session, read from the window
    /// server's event state: when, never which key. Event taps and global key monitors need the
    /// Input Monitoring grant; this counter does not.
    nonisolated public static func secondsSinceLastKeyPress() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    public enum Phase: Equatable {
        /// `begin()` has not been called.
        case pending
        /// The chooser is shown but must not take focus or act on input yet.
        case waiting
        /// The hold is over; `onLive` has run.
        case live
        /// The owner ended the hold before it elapsed.
        case cancelled
    }

    public private(set) var phase = Phase.pending
    /// Whether a busy keyboard held the chooser past the minimum delay (for the log).
    public private(set) var heldForTyping = false
    /// Whether a click elsewhere held the chooser past the minimum delay (for the log).
    public private(set) var heldForClicks = false

    private let minimumDelay: TimeInterval
    private let requiredKeyboardIdle: TimeInterval
    private let clickQuietPeriod: TimeInterval
    private let keyboardIdle: () -> TimeInterval
    private let now: () -> TimeInterval
    private let onLive: () -> Void
    private var beganAt: TimeInterval = 0
    private var lastClickElsewhere: TimeInterval?
    private var timer: Timer?

    /// - Parameters:
    ///   - minimumDelay: the shortest hold; `minimumDelay` in production.
    ///   - requiredKeyboardIdle: the `keyboardIdle` reading the grace waits for.
    ///   - clickQuietPeriod: how long after a click elsewhere the grace waits.
    ///   - keyboardIdle: seconds since a key last went down; `secondsSinceLastKeyPress()` in
    ///     production. Tests inject a clock, so the developer typing while the suite runs
    ///     changes nothing.
    ///   - now: a monotonic clock in seconds.
    ///   - onLive: runs once, when the hold ends.
    public init(
        minimumDelay: TimeInterval = InteractionGrace.minimumDelay,
        requiredKeyboardIdle: TimeInterval = InteractionGrace.requiredKeyboardIdle,
        clickQuietPeriod: TimeInterval = InteractionGrace.clickQuietPeriod,
        keyboardIdle: @escaping () -> TimeInterval = InteractionGrace.secondsSinceLastKeyPress,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onLive: @escaping () -> Void
    ) {
        self.minimumDelay = minimumDelay
        self.requiredKeyboardIdle = requiredKeyboardIdle
        self.clickQuietPeriod = clickQuietPeriod
        self.keyboardIdle = keyboardIdle
        self.now = now
        self.onLive = onLive
        super.init()
    }

    /// Start the hold. Calling it more than once is a no-op.
    public func begin() {
        guard phase == .pending else { return }
        phase = .waiting
        beganAt = now()
        schedule(after: minimumDelay)
    }

    /// A click landed in another app while the chooser was held: wait out `clickQuietPeriod`
    /// from now. The pending check picks it up, so nothing is rescheduled here.
    public func clickedElsewhere() {
        guard phase == .waiting else { return }
        lastClickElsewhere = now()
    }

    /// The human clicked the chooser itself. Past the minimum delay that is a deliberate act and
    /// the chooser goes live at once, whatever the keyboard is doing; inside it, the click may
    /// have been in flight as the chooser appeared, so the hold carries on. Returns whether the
    /// chooser is now live.
    @discardableResult
    public func engage() -> Bool {
        guard phase == .waiting else { return phase == .live }
        guard now() - beganAt >= minimumDelay else { return false }
        becomeLive()
        return true
    }

    /// Stop the hold for good; `onLive` will not run.
    public func cancel() {
        timer?.invalidate()
        timer = nil
        if phase == .waiting || phase == .pending { phase = .cancelled }
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        // A target/selector timer fires straight from the main run loop into this main-actor
        // object. A block that hopped through `DispatchQueue.main.async` would stall whenever the
        // run loop is spun from inside a main-queue callback, which is how the self-test pumps it.
        let timer = Timer(
            timeInterval: interval, target: self, selector: #selector(check(_:)),
            userInfo: nil, repeats: false
        )
        // `.common` so it still fires while the human is dragging or tracking a menu elsewhere.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The minimum delay is over; hold on while the keyboard or mouse is still busy, and look
    /// again when both would have been quiet long enough.
    @objc private func check(_ timer: Timer) {
        guard phase == .waiting else { return }
        var wait: TimeInterval = 0
        let idle = keyboardIdle()
        // A reading that is not a duration holds nothing back.
        if idle.isFinite, idle >= 0, idle < requiredKeyboardIdle {
            heldForTyping = true
            wait = max(wait, requiredKeyboardIdle - idle)
        }
        if let lastClickElsewhere {
            let sinceClick = now() - lastClickElsewhere
            if sinceClick < clickQuietPeriod {
                heldForClicks = true
                wait = max(wait, clickQuietPeriod - sinceClick)
            }
        }
        if wait > 0 {
            schedule(after: max(wait, Self.minimumRecheck))
            return
        }
        becomeLive()
    }

    /// The soonest a busy keyboard or mouse is looked at again, so a counter that lags the clock
    /// cannot spin the run loop.
    private static let minimumRecheck: TimeInterval = 0.05

    private func becomeLive() {
        guard phase == .waiting else { return }
        timer?.invalidate()
        timer = nil
        phase = .live
        onLive()
    }
}
