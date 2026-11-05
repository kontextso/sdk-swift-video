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
}
