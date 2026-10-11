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
            (.initializationFailed, "/init failed, and retrying it failed too; no ads until it succeeds"),
            (.destroyed, "the VideoAds was destroyed"),
            (.disabled(reason: "publisherDisabled"), "the SDK is disabled by the server (publisherDisabled)"),
            (.placementBusy, "the placement already has an ad loading, or loaded and not yet shown"),
            (.invalidPlacement(.unknown(id: "nope")), "placement \"nope\" does not exist for this publisher token"),
            (.invalidPlacement(.formatMismatch(id: "x", expected: .overlay, actual: .pause)), "placement \"x\" is an overlay placement, not pause"),
            (.invalidPlacement(.formatMismatch(id: "x", expected: .pause, actual: .interstitial)), "placement \"x\" is a pause placement, not interstitial"),
            (.invalidPlacement(.formatMismatch(id: "x", expected: nil, actual: .overlay)), "placement \"x\" is not an overlay placement"),
            (.noFill(reason: "noAdMatch"), "no fill (noAdMatch)"),
            (.creativeFailed(code: 400), "the creative failed to load (VAST error 400)"),
            (.alreadyShown, "the ad was already shown"),
            (.invalidated(.expired), "the ad was invalidated (expired)"),
            (.containerTooSmall(minimum: CGSize(width: 150, height: 150)), "the player's view is too small for the ad; at least 150×150 points are needed"),
            (.cannotPresent, "the view controller cannot present now"),
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
        let ad = VideoAd(ad: try Fixtures.payload(Fixtures.ad(id: "d1")))
        delegate.videoAd(ad, didInvalidate: .expired)
        delegate.videoAdDidShow(ad)
        delegate.videoAdDidRecordImpression(ad)
        delegate.videoAd(ad, didClick: VideoAd.Click(url: URL(string: "https://x.test")!, area: "creative"))
        delegate.videoAd(ad, didEarn: VideoAd.Reward(label: "coins", amount: 1))
        delegate.videoAd(ad, didFail: .cannotPresent)
        delegate.videoAd(ad, didEnd: .completed)
    }

    @Test func delegateIsHeldWeakly() async throws {
        let ad = VideoAd(ad: try Fixtures.payload(Fixtures.ad(id: "d2")))
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

    // MARK: Placements

    @Test func placementsForwardTheirIdAndFormat() async {
        SDKHarness.reset()
        Environment.assertionFailure = { _ in }
        let ads = TestPlayer().ads(for: .init(id: "v", language: "en"))
        #expect(ads.overlayPlacement("a").id == "a")
        #expect(ads.pausePlacement("b").id == "b")
        #expect(ads.interstitialPlacement("c").id == "c")
        // Not initialized: every load throws before any request, which proves the forwarding reaches VideoAds.
        for work in [
            { try await ads.overlayPlacement("a").load() },
            { try await ads.pausePlacement("b").load() },
            { try await ads.interstitialPlacement("c").load() },
        ] as [() async throws -> VideoAd] {
            do {
                _ = try await work()
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
