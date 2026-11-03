import Combine
import Foundation
import KontextVideoSDK
import os

extension VideoAds {
    /// Follows a TTSDK `TTVideoEngine`: `ads.track(ttVideoEngine: engine)`. TTSDK ships as a CocoaPod, which a
    /// Swift package cannot depend on, so the SDK reads the engine by its Objective-C properties
    /// (`currentPlaybackTime`, `playbackState`, `playbackSpeed`) and needs nothing from TTSDK to build. The engine
    /// is held weakly, and its `delegate` stays the app's: TTSDK has one delegate, so the SDK reads the engine
    /// four times a second while an overlay or pause ad is on screen, and at every `show`.
    ///
    /// Playing is TTSDK's playback state: paused or stopped is not playing, buffering is. Pass `currentItem` to
    /// tell the episode (its vid, its URL): an overlay or pause ad of this `VideoAds` then throws
    /// `invalidated(.contentChanged)` at `show` once it differs from the one at `track`. In a feed, track each
    /// page's engine with that page's `VideoAds` when the page becomes current. An object that is not a
    /// `TTVideoEngine` (it lacks those properties) is followed as never playing, with an error on the console.
    public func track(ttVideoEngine engine: NSObject, currentItem: (@MainActor () -> AnyHashable?)? = nil) {
        // One adapter per engine: the SDK tells an engine tracked by two `VideoAds` by the adapter it is given.
        let adapter = TTVideoEngineAdapter.adapter(for: engine)
        adapter.item = currentItem
        track(adapter)
    }
}

/// A TTSDK engine as the SDK reads it, through key-value coding on the properties TTSDK declares.
@MainActor
final class TTVideoEngineAdapter: VideoAdsPlayer {
    /// `TTVideoEnginePlaybackStatePlaying`.
    static let playbackStatePlaying = 1

    private static let adapters = NSMapTable<NSObject, TTVideoEngineAdapter>.weakToWeakObjects()

    static func adapter(for engine: NSObject) -> TTVideoEngineAdapter {
        if let adapter = adapters.object(forKey: engine) { return adapter }
        let adapter = TTVideoEngineAdapter(engine: engine)
        adapters.setObject(adapter, forKey: engine)
        return adapter
    }

    private weak var engine: NSObject?
    private let readable: Bool
    var item: (@MainActor () -> AnyHashable?)?

    init(engine: NSObject) {
        self.engine = engine
        // A key the object does not have would raise an Objective-C exception, which Swift cannot catch.
        readable = ["currentPlaybackTime", "playbackState"].allSatisfy { engine.responds(to: NSSelectorFromString($0)) }
        if !readable {
            let name = String(describing: type(of: engine))
            os.Logger(subsystem: "so.kontext.video", category: "KontextVideoTTSDK")
                .error("track(ttVideoEngine:): \(name, privacy: .public) has no currentPlaybackTime or playbackState; the content counts as not playing")
        }
    }

    private func number(_ key: String) -> NSNumber? {
        guard readable, let engine, engine.responds(to: NSSelectorFromString(key)) else { return nil }
        return engine.value(forKey: key) as? NSNumber
    }

    var currentTime: TimeInterval { max(0, number("currentPlaybackTime")?.doubleValue ?? 0) }

    var isPlaying: Bool { number("playbackState")?.intValue == Self.playbackStatePlaying }

    var playbackSpeed: Double? { number("playbackSpeed")?.doubleValue }

    var currentItem: AnyHashable? { item?() }

    // TTSDK has one delegate, the app's: the SDK reads the engine instead of hearing it.
    var isPlayingPublisher: AnyPublisher<Bool, Never>? { nil }
    var seekPublisher: AnyPublisher<Void, Never>? { nil }
    var contentChangedPublisher: AnyPublisher<Void, Never>? { nil }
}
