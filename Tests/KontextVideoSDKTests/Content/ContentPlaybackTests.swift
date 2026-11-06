import AVFoundation
@testable import KontextVideoSDK
import Testing

/// The tracked player on its own, without an ad: an `AVPlayer` gone reads as not playing at 0, a nil item is
/// another item, a stopped binding drops what an old player still sends, and a player belongs to one playback at a
/// time (`PlayerOwnership`). Serialized: ownership is process-wide.
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
}
}
