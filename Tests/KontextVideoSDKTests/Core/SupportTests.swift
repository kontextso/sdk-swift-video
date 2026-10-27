import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The smaller public pieces: error descriptions, delegate defaults, formats. Serialized: it resets the
/// shared instance and the stub server, which other suites are using.
extension SerialSuites {
@Suite
@MainActor
struct SupportTests {
    // MARK: VideoAdError

    @Test func everyErrorReadsAsASentence() {
        let cases: [(VideoAdError, String)] = [
            (.notInitialized, "KontextVideo.shared.initialize(with:) was not called"),
            (.initializationFailed, "/config failed, and retrying it failed too; no ads until it succeeds"),
            (.destroyed, "the VideoAds was destroyed"),
            (.disabled(reason: "publisherDisabled"), "the SDK is disabled by the server (publisherDisabled)"),
            (.noFill(reason: .noAdMatch), "no fill (noAdMatch)"),
            (.noFill(reason: .other("brandNew")), "no fill (brandNew)"),
            (.anotherAdShowing, "another ad is on screen; show this one after it ended"),
            (.creativeFailed(code: 400), "the creative failed to load (VAST error 400)"),
            (.alreadyShown, "the ad was already shown"),
            (.invalidated(.expired), "the ad ended before it was shown (expired)"),
            (.notLoaded, "the ad is not loaded yet; call load() first"),
            (.containerTooSmall(minimum: CGSize(width: 150, height: 150)), "the view is too small for the ad; at least 150×150 points are needed"),
            (.presenterUnavailable, "no view controller can present the ad now"),
            (.wrongPresentation, "this call does not fit the ad's format (show(in:) for overlay and pause, show() for linear; dismiss() only for overlay and pause)"),
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
        Environment.assertionFailure = { _ in }
        defer { Environment.reset() }
        let ads = VideoAds(content: .init(id: "v", language: "en"))
        let ad = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "d1")), owner: ads)
        delegate.videoAdDidRecordImpression(ad)
        delegate.videoAd(ad, didClick: VideoAd.Click(url: URL(string: "https://x.test")!, area: .creative))
        delegate.videoAd(ad, didFail: .presenterUnavailable)
        delegate.videoAd(ad, didEnd: .completed)
    }

    @Test func delegateIsHeldWeakly() async throws {
        Environment.assertionFailure = { _ in }
        defer { Environment.reset() }
        let ads = VideoAds(content: .init(id: "v", language: "en"))
        let ad = VideoAd(descriptor: try Fixtures.descriptor(Fixtures.ad(id: "d2")), owner: ads)
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
        #expect(VideoAd.Click(url: url, area: .creative) == VideoAd.Click(url: url, area: .creative))
        #expect(VideoAd.Click(url: url, area: .creative) != VideoAd.Click(url: url, area: .other("creative")), "the page's label 'creative' is the creative, but the enum is honest about what it was given")
        #expect(VideoAd.Click.Area(nil) == .creative && VideoAd.Click.Area("endCard") == .endCard && VideoAd.Click.Area("cta") == .other("cta"))
        #expect(VideoAd.InvalidationReason.creativeFailed(code: 1) != .creativeFailed(code: 2))
        #expect(VideoAd.RejectReason.outbid(winningPrice: 2) != .outbid())
        #expect(VideoAd.RejectReason.notUsed == .notUsed)
    }

    // MARK: Formats

    @Test func everyFormatThrowsNotInitializedBeforeInitialize() async {
        SDKHarness.reset()
        Environment.assertionFailure = { _ in }
        let ads = TestPlayer().ads(for: .init(id: "v", language: "en"))
        for format in AdFormat.allCases {
            let work = { _ = try await ads.format(format) }
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
}
