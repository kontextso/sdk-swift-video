import AVFoundation
@testable import KontextVideoSDK
import Testing

/// The tracked player on its own, without an ad: an `AVPlayer` gone reads as not playing at 0, a nil item is
/// another item, a stopped binding drops what an old player still sends, and a player belongs to one playback at a
/// time (`PlayerOwnership`), also when it is tracked again. A custom player that reports no item cannot tell the
/// episode, and a speed that is not finite is unknown. Serialized: ownership is process-wide.
extension SerialSuites {
@Suite
@MainActor
struct ContentPlaybackTests {
    final class Changes {
        var all: [ContentPlayback.Change] = []
    }

    private func playback() -> (ContentPlayback, Changes) {
        let playback = ContentPlayback()
        let changes = Changes()
        playback.onChange = { changes.all.append($0) }
        return (playback, changes)
    }

    @Test func aDeallocatedPlayerReadsAsNotPlayingAtZero() {
        let (playback, _) = playback()
        do {
            let player = AVPlayer()
            player.rate = 1
            playback.track(player)
        }
        #expect(playback.isTracking && !playback.isPlaying && playback.playhead == 0, "the AVPlayer is held weakly")
        playback.stop()
    }

    @Test func aNilItemIsContentChanged() async {
        let (playback, changes) = playback()
        let player = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")))
        playback.track(player)
        player.replaceCurrentItem(with: nil)
        #expect(await waitUntil { changes.all.contains(.contentChanged) })
        playback.stop()
    }

    @Test func aRateChangeAfterStopIsDropped() async {
        let (playback, changes) = playback()
        let player = AVPlayer()
        playback.track(player)
        playback.stop()
        await Task.detached { await MainActor.run { player.rate = 1 } }.value
        await sleepMs(50)
        #expect(changes.all.isEmpty, "a binding stopped before the change: \(changes.all)")
    }

    @Test func claimingAPlayerMakesThePreviousOwnerLoseIt() {
        let first = ContentPlayback()
        let second = ContentPlayback()
        let player = TestPlayer()
        first.track(player)
        #expect(!first.hasLostPlayer)
        second.track(player)
        #expect(first.hasLostPlayer && first.playsAnotherEpisode && !first.isTracking, "one playback at a time")
        #expect(!second.hasLostPlayer && second.isTracking)
        second.stop()
    }

    /// A custom player that reports the item and the speed it is given.
    final class ItemPlayer: ContentPlayer {
        var currentTime: TimeInterval = 0
        var isPlaying = true
        var playbackSpeed: Double?
        var currentItem: AnyHashable?
        init(item: AnyHashable?) { currentItem = item }
    }

    @Test func aCustomPlayerReportingNoItemAfterOneCannotTellAndKeepsItsEpisode() async {
        let previous = ContentPlayback.tickInterval
        ContentPlayback.tickInterval = 0.02
        defer { ContentPlayback.tickInterval = previous }
        let (playback, changes) = playback()
        playback.isFollowerShown = { true }
        let player = ItemPlayer(item: "ep-1")
        playback.track(player)
        player.currentItem = nil
        #expect(!playback.playsAnotherEpisode, "no item: it cannot tell")
        #expect(await waitUntil { changes.all.count >= 3 }, "ticks run over the missing item")
        #expect(changes.all.allSatisfy { $0 == .tick }, "a missing item is no other episode: \(changes.all)")
        player.currentItem = "ep-1"
        #expect(!playback.playsAnotherEpisode, "the missing item was not adopted: ep-1 is still this episode")
        player.currentItem = "ep-2"
        #expect(playback.playsAnotherEpisode)
        playback.stop()
    }

    @Test func trackingTheSamePlayerAgainKeepsItAndItsItemNowIsTheEpisode() {
        let (playback, changes) = playback()
        let player = ItemPlayer(item: "ep-1")
        playback.track(player)
        player.currentItem = "ep-2"
        #expect(playback.playsAnotherEpisode)
        playback.isFollowerShown = { true }
        playback.track(player)
        #expect(playback.isTracking && !playback.hasLostPlayer, "its own claim does not take the player from itself")
        #expect(!playback.playsAnotherEpisode, "the item at the new track is this episode")
        #expect(changes.all == [.contentChanged], "an overlay on screen followed the old binding: it hears the handover")
        playback.stop()
    }

    @Test(arguments: [(Double.nan, nil), (.infinity, nil), (-.infinity, nil), (nil, nil), (0, 0), (2, 2)] as [(Double?, Double?)])
    func aSpeedThatIsNotFiniteReadsAsUnknown(speed: Double?, expected: Double?) {
        let (playback, _) = playback()
        let player = ItemPlayer(item: nil)
        player.playbackSpeed = speed
        playback.track(player)
        #expect(playback.rate == expected)
        playback.stop()
    }
}
}
