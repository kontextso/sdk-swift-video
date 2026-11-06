@testable import KontextVideoSDK
import Testing

/// One tap opens one URL, on plain numbers.
@Suite
struct TouchGateTests {
    @Test func aTouchLetsOneURLThroughWithinTheWindow() {
        var gate = TouchGate()
        let untouched = gate.consume(now: 0)
        #expect(!untouched, "no touch yet")
        gate.note(now: 100)
        let atTheEdge = gate.consume(now: 100 + TouchGate.window)
        #expect(atTheEdge, "at the window's edge")
        let again = gate.consume(now: 100.5)
        #expect(!again, "spent")
        gate.note(now: 200)
        let late = gate.consume(now: 200 + TouchGate.window + 0.01)
        #expect(!late, "too long ago")
    }

    @Test func aClockThatStartsAtZeroHasNoTouchUntilOneIsNoted() {
        var gate = TouchGate()
        let atZero = gate.consume(now: 0)
        #expect(!atZero, "no touch is not a touch at 0")
        let withinAWindowOfZero = gate.consume(now: TouchGate.window / 2)
        #expect(!withinAWindowOfZero)
        gate.note(now: 0)
        let touchedAtZero = gate.consume(now: 0)
        #expect(touchedAtZero, "a touch at 0 counts")
    }

    @Test func aLaterTouchReplacesAnEarlierOne() {
        var gate = TouchGate()
        gate.note(now: 10)
        gate.note(now: 10.8)
        let measuredFromTheLater = gate.consume(now: 11.5)
        #expect(measuredFromTheLater, "1.5 s after the first, 0.7 s after the second")
        let spent = gate.consume(now: 11.5)
        #expect(!spent, "two touches still open one URL: the gate holds the last only")
    }
}
