@testable import KontextVideoSDK
import Testing

/// An overlay's duration in seconds of video: playback counts, a seek or a loop does not, and the player's speed
/// (when it tells one) sets how fast playback may be. Serialized: it moves `Environment.now`.
extension SerialSuites {
@Suite
@MainActor
struct ContentTimeClockTests {
    init() {
        Environment.reset()
    }

    @Test func aShortSeekCountsNothingAndALateSampleOfRealPlaybackCounts() {
        let seek = ContentTimeClock(duration: 1, at: 10)
        #expect(!seek.advance(to: 11.5, isCounting: true) && seek.elapsed == 0, "1.5 s at once, before any time passed: a seek")
        let late = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 3)
        #expect(!late.advance(to: 3, isCounting: true) && late.elapsed == 3, "3 s of video after 3 s: playback, sampled late")
        let jumped = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 1)
        jumped.resync(to: 0.8)   // an AVPlayer time jump
        #expect(!jumped.advance(to: 0.8, isCounting: true) && jumped.elapsed == 0)
    }

    @Test func fasterPlaybackCountsItsVideoSeconds() {
        let unknown = ContentTimeClock(duration: 10, at: 0)
        let known = ContentTimeClock(duration: 100, at: 0)
        for second in 1...4 {
            advanceClock(by: 0.25)
            _ = unknown.advance(to: Double(second), isCounting: true)              // 4×, speed not told
            _ = known.advance(to: Double(second) * 2, isCounting: true, rate: 8)   // 8×, an AVPlayer's rate
        }
        #expect(abs(unknown.elapsed - 4) < 0.001 && abs(known.elapsed - 8) < 0.001)
        let seek = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 0.25)
        #expect(!seek.advance(to: 2, isCounting: true, rate: 1) && seek.elapsed == 0, "2 s in a quarter second at 1×: a seek")
    }

    @Test func aNonFiniteSpeedReadsAsUnknown() {
        for rate in [Double.nan, .infinity, -.infinity] {
            let playing = ContentTimeClock(duration: 10, at: 0)
            advanceClock(by: 1)
            _ = playing.advance(to: 1, isCounting: true, rate: rate)
            #expect(playing.elapsed == 1, "\(rate): a second of playback counts")
            let seek = ContentTimeClock(duration: 10, at: 0)
            advanceClock(by: 0.25)
            _ = seek.advance(to: 60, isCounting: true, rate: rate)
            #expect(seek.elapsed == 0, "\(rate): a seek counts nothing")
        }
    }

    @Test func pausedRewoundOrNotCountingCountsNothing() {
        let paused = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 1)
        _ = paused.advance(to: 1, isCounting: true, rate: 0)
        #expect(paused.elapsed == 1, "a rate of 0 (paused as the sample was taken) still allows normal speed")
        let rewind = ContentTimeClock(duration: 10, at: 5)
        advanceClock(by: 1)
        _ = rewind.advance(to: 4, isCounting: true, rate: -1)
        #expect(rewind.elapsed == 0, "backwards counts nothing")
        let hidden = ContentTimeClock(duration: 10, at: 0)
        advanceClock(by: 1)
        _ = hidden.advance(to: 1, isCounting: false)
        #expect(hidden.elapsed == 0, "not counting: nothing")
    }

    @Test func theDurationIsReachedExactlyAtItsEnd() {
        let clock = ContentTimeClock(duration: 2, at: 0)
        advanceClock(by: 1)
        #expect(!clock.advance(to: 1, isCounting: true))
        advanceClock(by: 1)
        #expect(clock.advance(to: 2, isCounting: true), "elapsed == duration is the end")
    }

    @Test func aLoopBackCountsNothingAndPlaybackAfterItCounts() {
        let clock = ContentTimeClock(duration: 100, at: 0)
        advanceClock(by: 1)
        _ = clock.advance(to: 1, isCounting: true)
        advanceClock(by: 0.25)
        _ = clock.advance(to: 0, isCounting: true)   // the looper went back to the start
        advanceClock(by: 1)
        _ = clock.advance(to: 1, isCounting: true)
        #expect(clock.elapsed == 2, "one second before the loop, one after")
    }
}
}
