import Foundation
@testable import KontextVideoSDK
@testable import KontextVideoTTSDK
import Testing

/// The TTSDK adapter reads an engine by its Objective-C properties; a stand-in declares the same ones.
@Suite
@MainActor
struct TTVideoEngineAdapterTests {
    /// TTSDK's `TTVideoEngine`, as far as the adapter reads it.
    final class FakeEngine: NSObject {
        @objc dynamic var currentPlaybackTime: TimeInterval = 0
        @objc dynamic var playbackState: Int = 1
        @objc dynamic var playbackSpeed: CGFloat = 1
    }

    @Test func itReadsTheEnginesTimeStateAndSpeed() {
        let engine = FakeEngine()
        let adapter = TTVideoEngineAdapter(engine: engine)
        engine.currentPlaybackTime = 12.5
        engine.playbackSpeed = 1.5
        #expect(adapter.currentTime == 12.5)
        #expect(adapter.isPlaying)
        #expect(adapter.playbackSpeed == 1.5)
        engine.playbackState = 2 // paused
        #expect(!adapter.isPlaying)
        engine.playbackState = 0 // stopped
        #expect(!adapter.isPlaying)
    }

    @Test func aNegativeTimeBeforeTheEngineIsPreparedIsZero() {
        let engine = FakeEngine()
        engine.currentPlaybackTime = -1
        #expect(TTVideoEngineAdapter(engine: engine).currentTime == 0)
    }

    @Test func anObjectThatIsNotAnEngineIsNeverPlayingAndNeverCrashes() {
        let adapter = TTVideoEngineAdapter(engine: NSObject())
        #expect(!adapter.isPlaying)
        #expect(adapter.currentTime == 0)
        #expect(adapter.playbackSpeed == nil)
    }

    @Test func aTimeThatIsNoNumberIsZeroAndAnyStateButPlayingIsNotPlaying() {
        let engine = FakeEngine()
        let adapter = TTVideoEngineAdapter(engine: engine)
        for (time, expected) in [(Double.nan, 0.0), (-0.0, 0), (-.infinity, 0), (0, 0), (86_400.25, 86_400.25)] {
            engine.currentPlaybackTime = time
            #expect(adapter.currentTime == expected, "\(time)")
        }
        for (state, playing) in [(0, false), (1, true), (2, false), (3, false), (-1, false), (Int.max, false)] {
            engine.playbackState = state
            #expect(adapter.isPlaying == playing, "state \(state)")
        }
        engine.playbackSpeed = 0
        #expect(adapter.playbackSpeed == 0, "a paused speed is read as given; what it means is ContentPlayback's")
    }

    /// An engine as an older TTSDK declares it: time and state, no speed.
    final class EngineWithoutSpeed: NSObject {
        @objc dynamic var currentPlaybackTime: TimeInterval = 3
        @objc dynamic var playbackState: Int = 1
    }

    /// An object with a time but no playback state.
    final class TimeOnly: NSObject {
        @objc dynamic var currentPlaybackTime: TimeInterval = 3
    }

    @Test func aMissingSpeedIsUnknownAndAMissingStateMakesTheObjectUnreadable() {
        let olderEngine = EngineWithoutSpeed(), timeOnlyObject = TimeOnly()   // held: the adapter holds its engine weakly
        let older = TTVideoEngineAdapter(engine: olderEngine)
        #expect(older.currentTime == 3 && older.isPlaying && older.playbackSpeed == nil)
        let timeOnly = TTVideoEngineAdapter(engine: timeOnlyObject)
        #expect(timeOnly.currentTime == 0 && !timeOnly.isPlaying, "both properties or nothing is read")
        withExtendedLifetime((olderEngine, timeOnlyObject)) {}
    }

    @Test func theEngineIsHeldWeakly() {
        var engine: FakeEngine? = FakeEngine()
        let adapter = TTVideoEngineAdapter(engine: engine!)
        engine = nil
        #expect(adapter.currentTime == 0)
        #expect(!adapter.isPlaying)
    }

    @Test func oneAdapterPerEngineSoTwoVideoAdsSeeTheSamePlayer() {
        let engine = FakeEngine()
        let first = TTVideoEngineAdapter.adapter(for: engine)
        #expect(TTVideoEngineAdapter.adapter(for: engine) === first)
        #expect(TTVideoEngineAdapter.adapter(for: FakeEngine()) !== first)
    }

    @Test func theItemIsTheAppsWhenGiven() {
        let adapter = TTVideoEngineAdapter(engine: FakeEngine())
        #expect(adapter.currentItem == nil)
        adapter.item = { "vid-1" }
        #expect(adapter.currentItem == AnyHashable("vid-1"))
    }

    @Test func itNeverReportsThroughPublishersSoTheSDKReadsIt() {
        let adapter = TTVideoEngineAdapter(engine: FakeEngine())
        #expect(adapter.isPlayingPublisher == nil)
        #expect(adapter.seekPublisher == nil)
        #expect(adapter.contentChangedPublisher == nil)
    }
}

/// The adapter is shared by every `VideoAds` tracking one engine. Serialized: it creates `VideoAds`.
extension SerialSuites {
@Suite
@MainActor
struct TTVideoEngineOwnersTests {
    private let harness = SDKHarness()

    @Test func aDestroyedVideoAdsLeavesTheSharedAdapterAlone() async {
        _ = await harness.initialize()
        let engine = TTVideoEngineAdapterTests.FakeEngine()
        let live = VideoAds(content: .init(id: "ep-tt-live", language: "en"))
        let gone = VideoAds(content: .init(id: "ep-tt-gone", language: "en"))
        defer { live.destroy() }
        live.track(ttVideoEngine: engine) { "episode-1" }
        gone.destroy()
        gone.track(ttVideoEngine: engine) { "episode-2" }
        #expect(TTVideoEngineAdapter.adapter(for: engine).currentItem == AnyHashable("episode-1"), "the live owner's episode stays")
    }
}
}
