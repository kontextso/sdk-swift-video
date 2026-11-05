import Foundation

/// One tap opens one URL. A touch on the ad's page lets a single click, open or navigation through within
/// `window` seconds; the first one it lets through spends it, so a page that reports a tap and also navigates on it
/// does not open twice. Without a touch, a URL the page asks for is a forced redirect and goes nowhere.
struct TouchGate {
    /// A URL may be opened this long after the viewer touched the page.
    static let window: TimeInterval = 1

    private var lastTouchAt: TimeInterval = -.infinity

    /// The viewer touched the page at `now`.
    mutating func note(now: TimeInterval) {
        lastTouchAt = now
    }

    /// Whether a touch within the window lets this URL through; one that does is spent.
    mutating func consume(now: TimeInterval) -> Bool {
        guard now - lastTouchAt <= Self.window else { return false }
        lastTouchAt = -.infinity
        return true
    }
}
