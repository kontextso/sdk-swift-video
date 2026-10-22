import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The smaller public pieces: error descriptions, delegate defaults, placements.
@MainActor
struct SupportTests {
    // MARK: VideoAdError

    @Test func everyErrorReadsAsASentence() {
        let cases: [(VideoAdError, String)] = [
            (.notInitialized, "KontextVideo.shared.initialize(with:) was not called"),
            (.initializationFailed, "/config failed, and retrying it failed too; no ads until it succeeds"),
            (.destroyed, "the VideoAds was destroyed"),
            (.disabled(reason: "publisherDisabled"), "the SDK is disabled by the server (publisherDisabled)"),
            (.formatBusy, "this format already has an ad loading, or loaded and not yet shown"),
            (.noFill(reason: "noAdMatch"), "no fill (noAdMatch)"),
            (.anotherAdShowing, "another ad of this VideoAds is on screen; dismiss it first"),
            (.creativeFailed(code: 400), "the creative failed to load (VAST error 400)"),
            (.alreadyShown, "the ad was already shown"),
            (.invalidated(.expired), "the ad was invalidated (expired)"),
            (.containerTooSmall(minimum: CGSize(width: 150, height: 150)), "the player's view is too small for the ad; at least 150×150 points are needed"),
            (.presenterUnavailable, "no view controller can present the ad now"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
            #expect(error.errorDescription == expected)
            #expect("\(error)" == expected, "string interpolation uses the description")
        }
        let request = VideoAdError.request(URLError(.timedOut))
        #expect(request.description.hasPrefix("request failed: "))
    }

    // MARK: VideoAdDelegate

    @Test func delegateMethodsAllHaveDefaults() async throws {
        final class Minimal: VideoAdDelegate {}
        let delegate = Minimal()
        let ad = VideoAd(received: try Fixtures.received(Fixtures.ad(id: "d1")))
        delegate.videoAd(ad, didInvalidate: .expired)
        delegate.videoAdDidRecordImpression(ad)
        delegate.videoAd(ad, didClick: VideoAd.Click(url: URL(string: "https://x.test")!, area: "creative"))
        delegate.videoAd(ad, didEarn: VideoAd.Reward(label: "coins", amount: 1))
        delegate.videoAd(ad, didFail: .presenterUnavailable)
        delegate.videoAd(ad, didEnd: .completed)
    }

    @Test func delegateIsHeldWeakly() async throws {
        let ad = VideoAd(received: try Fixtures.received(Fixtures.ad(id: "d2")))
        var delegate: RecordingDelegate? = RecordingDelegate()
        ad.delegate = delegate
        #expect(ad.delegate != nil)
        delegate = nil
        #expect(ad.delegate == nil)
    }

    @Test func endReasonsAndClicksAreEquatable() {
        #expect(VideoAd.EndReason.completed == .completed)
        #expect(VideoAd.EndReason.completed != .dismissed)
        let url = URL(string: "https://x.test")!
        #expect(VideoAd.Click(url: url, area: "a") == VideoAd.Click(url: url, area: "a"))
        #expect(VideoAd.Click(url: url, area: "a") != VideoAd.Click(url: url, area: "b"))
        #expect(VideoAd.InvalidationReason.creativeFailed(code: 1) != .creativeFailed(code: 2))
    }

    // MARK: Loaders

    @Test func loadersForwardToTheirVideoAds() async {
        SDKHarness.reset()
        Environment.assertionFailure = { _ in }
        let ads = TestPlayer().ads(for: .init(id: "v", language: "en"))
        // Not initialized: every load and fetch throws before any request, which proves the forwarding reaches VideoAds.
        for work in [
            { _ = try await ads.format(.overlay).load() },
            { _ = try await ads.format(.pause).load() },
            { _ = try await ads.format(.linear).load() },
            { _ = try await ads.format(.overlay, options: .default) },
            { _ = try await ads.format(.pause, options: .default) },
            { _ = try await ads.format(.linear, options: .default) },
        ] as [() async throws -> Void] {
            do {
                try await work()
                Issue.record("expected notInitialized")
            } catch VideoAdError.notInitialized {
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
        SDKHarness.reset()
    }

    // MARK: Logger

    @Test func loggerLevelIsSettable() {
        Logger.level = .debug
        #expect(Logger.level == .debug)
        Logger.level = .none
        #expect(Logger.level == .none)
        Logger.level = .warning
    }
}
