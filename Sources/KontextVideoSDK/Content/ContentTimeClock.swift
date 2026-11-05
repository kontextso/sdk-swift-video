import Foundation

/// An overlay's `duration` in seconds of video, the twin of `OnScreenTimeClock`: that one counts time on screen,
/// this one video time: the playhead's progress while the overlay is on screen and
/// its scene active (`resync` when the scene comes back, so time hidden counts nothing). A step backwards,
/// or one faster than the playback speed allows for the real time since the playhead last moved, is a seek
/// or a loop: it counts nothing, and counting goes on from the new position. An `AVPlayer` gives its speed,
/// and its time jumps start the count again; for a custom player the limit is `maxRate`, so a seek that
/// looks like playback (small, or after a long stall) can count.
@MainActor
final class ContentTimeClock {
    /// The speed allowed when the player does not tell its own: 4× playback and a late sample still count.
    static let maxRate: Double = 4.25
    /// Room above a known speed for a late sample.
    static let rateMargin: Double = 1.25
    /// What a step may exceed `maxRate` by: the sampling's own jitter.
    static let slack: TimeInterval = 0.25
    let duration: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private var last: TimeInterval
    private var lastMovedAt: TimeInterval

    init(duration: TimeInterval, at playhead: TimeInterval) {
        self.duration = duration
        last = playhead
        lastMovedAt = Environment.now()
    }

    /// The count goes on from `playhead`, nothing counted for the way there.
    func resync(to playhead: TimeInterval) {
        last = playhead
        lastMovedAt = Environment.now()
    }

    /// Takes the playhead now; counts the step when `isCounting` and it looks like playback at `rate` (the
    /// player's speed, `nil` when unknown). `true` once the duration is reached.
    func advance(to playhead: TimeInterval, isCounting: Bool, rate: Double? = nil) -> Bool {
        let step = playhead - last
        if step != 0 {
            let now = Environment.now()
            let real = now - lastMovedAt
            last = playhead
            lastMovedAt = now
            let speed = rate.map { max(abs($0) * Self.rateMargin, 1) } ?? Self.maxRate
            if isCounting, step > 0, step <= real * speed + Self.slack { elapsed += step }
        }
        return elapsed >= duration
    }
}
