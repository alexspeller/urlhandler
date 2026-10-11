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
/// A deliberate click on the chooser itself (`engage()`) makes it live at once, once
/// `clickBlockPeriod` has passed.
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

    /// The counter reading the grace waits for: the quiet period itself, trusting the counter to
    /// see each key — a probe of this Mac on 2026-10-11 saw every key published within 5 ms, so
    /// the chooser goes live 1 s after the last key.
    ///
    /// convenient-security once measured the counter publishing in half-second steps, each key
    /// dated to the start of its step, so steady typing read anything up to just over a second;
    /// it waits 1.5 s (quiet plus a step) because a 1 s threshold is then crossed mid-sentence.
    /// Here that would only make the chooser go live while someone is still typing, and their
    /// next key is stray and holds it again (`Chooser`), so the wait stays at 1 s.
    nonisolated public static let requiredKeyboardIdle: TimeInterval = keyboardQuietPeriod

    /// How long since the last click in another app before the chooser takes focus. Clicks
    /// are seen exactly (a global mouse monitor, `Chooser`), and only those after the chooser
    /// appeared count, so the click that opened the link never delays it.
    nonisolated public static let clickQuietPeriod: TimeInterval = 1.0

    /// How long after the chooser appears (or is held again) a click on it does nothing — no row,
    /// no close button, no engaging it. A click in flight as it appears lands on whatever it
    /// appeared over; this is longer than `minimumDelay` because a click is aimed at a spot, and
    /// the chooser may have appeared on that spot.
    nonisolated public static let clickBlockPeriod: TimeInterval = 1.0

    /// A live chooser that loses focus this soon after going live is held again rather than
    /// cancelled: the human was busy elsewhere and hadn't seen it.
    nonisolated public static let focusLossHoldWindow: TimeInterval = 2.0

    /// Later than `focusLossHoldWindow`, losing focus cancels the chooser only if the human did
    /// it — a click elsewhere or a key (⌘Tab) this recently. Anything else (the browser just
    /// picked coming forward from a cold launch, an app activating itself) holds it again.
    /// Generous enough for a counter that dates an event up to a half-second step early.
    nonisolated public static let userActionWindow: TimeInterval = 1.0

    /// Seconds since a key last went down anywhere in the login session, read from the window
    /// server's event state: when, never which key. Event taps and global key monitors need the
    /// Input Monitoring grant; this counter does not.
    nonisolated public static func secondsSinceLastKeyPress() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Seconds since any mouse button last went down anywhere in the session, from the same
    /// counter. Read synchronously, so it already knows about the click that is taking the focus
    /// away when the chooser hears it has lost key — the global monitor's callback may arrive
    /// after that.
    nonisolated public static func secondsSinceLastClick() -> TimeInterval {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
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
    private let clickBlockPeriod: TimeInterval
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
    ///   - clickBlockPeriod: how long after `begin()` a click on the chooser does nothing.
    ///   - keyboardIdle: seconds since a key last went down; `secondsSinceLastKeyPress()` in
    ///     production. Tests inject a clock, so the developer typing while the suite runs
    ///     changes nothing.
    ///   - now: a monotonic clock in seconds.
    ///   - onLive: runs once, when the hold ends.
    public init(
        minimumDelay: TimeInterval = InteractionGrace.minimumDelay,
        requiredKeyboardIdle: TimeInterval = InteractionGrace.requiredKeyboardIdle,
        clickQuietPeriod: TimeInterval = InteractionGrace.clickQuietPeriod,
        clickBlockPeriod: TimeInterval = InteractionGrace.clickBlockPeriod,
        keyboardIdle: @escaping () -> TimeInterval = InteractionGrace.secondsSinceLastKeyPress,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onLive: @escaping () -> Void
    ) {
        self.minimumDelay = minimumDelay
        self.requiredKeyboardIdle = requiredKeyboardIdle
        self.clickQuietPeriod = clickQuietPeriod
        self.clickBlockPeriod = clickBlockPeriod
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

    /// A click landed in another app `secondsAgo` while the chooser was held: wait out
    /// `clickQuietPeriod` from it. The pending check picks it up, so nothing is rescheduled here.
    /// A chooser held again because a click took its focus passes that click in, since it came a
    /// moment before this hold began.
    public func clickedElsewhere(secondsAgo: TimeInterval = 0) {
        guard phase == .waiting, secondsAgo.isFinite, secondsAgo >= 0 else { return }
        let at = now() - secondsAgo
        lastClickElsewhere = max(lastClickElsewhere ?? at, at)
    }

    /// Whether a click on the chooser counts yet: false for `clickBlockPeriod` after `begin()`,
    /// live or not, since the click may have been in flight as the chooser appeared.
    public var acceptsClicks: Bool {
        phase != .pending && phase != .cancelled && now() - beganAt >= clickBlockPeriod
    }

    /// The human clicked the chooser itself. Past the click block that is a deliberate act and
    /// the chooser goes live at once, whatever the keyboard is doing; inside it, the hold carries
    /// on. Returns whether the chooser is now live.
    @discardableResult
    public func engage() -> Bool {
        guard phase == .waiting else { return phase == .live }
        guard acceptsClicks else { return false }
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
