import Foundation
@testable import KontextVideoSDK
import Testing

/// `ads.format(_:options:)` and `VideoAd.Bid`: the answer it holds, nothing rendered until `load()`, the
/// busy rule, expiry, and what a targeting change or `destroy()` does to a held answer.
extension SerialSuites {
@Suite
@MainActor
struct BidTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()

    init() {
        pages.install()
    }

    private func makeAds() async -> VideoAds {
        _ = await harness.initialize()
        return harness.player.ads(for: .init(id: "ep-1", language: "en"))
    }

    @Test func aBidGivesTheFactsAndRendersNothing() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.overlayAd(id: "img-o1", duration: 6000, position: "top"))
        let bid = try await ads.format(.overlay, options: OverlayOptions(positions: [.top]))
        #expect(bid.id == "img-o1")
        #expect(bid.format == .overlay)
        #expect(bid.price.value > 0)
        #expect(bid.position == .top)
        #expect(bid.size == VideoAd.Size(width: 320, height: 90))
        #expect(bid.sizes == [VideoAd.Size(width: 320, height: 90)])
        #expect(bid.duration == 6)
        #expect(bid.skipOffset == nil)
        #expect(bid.reward == nil)
        #expect(try await ads.format(.overlay) === bid, "the held answer, no second request")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1)
        #expect(pages.served.isEmpty, "no page was loaded")
        #expect(harness.server.beacons.isEmpty, "no beacon fired")
        let formats = harness.server.requests(to: "/v2/video/ads").first?.body?["formats"] as? [[String: Any]]
        #expect((formats?.first?["options"] as? [String: Any])?["positions"] as? [String] == ["top"])
    }

    @Test func aSecondLoadOnTheSameBidReturnsTheSameAd() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p15"))
        let bid = try await ads.format(.pause)
        let first = try await bid.load()
        let second = try await bid.load()
        #expect(first === second, "a bid is not a factory")
        #expect(pages.served == ["img-p15"])
    }

    @Test func everyCallForTheSameAnswerGetsTheSameBidSoItIsRenderedOnce() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p16"))
        let pause = try await ads.format(.pause)            // look at the price first
        let ad = try await ads.format(.pause).load()        // then load through a second call
        try ad.show(in: harness.player.view)
        let again = try await pause.load()                  // the first handle, after the ad was shown
        #expect(again === ad, "the same answer is the same ad, not a second render")
        #expect(pages.served == ["img-p16"], "one page load")
        ad.dismiss()
    }

    @Test func linearFactsAreInSeconds() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.linearAd(id: "vid-l1", duration: 15_000, skipOffset: 5000, reward: ["label": "coins", "amount": 50]))
        let bid = try await ads.format(.linear)
        #expect(bid.duration == 15)
        #expect(bid.skipOffset == 5)
        #expect(bid.reward == VideoAd.Reward(label: "coins", amount: 50))
        #expect(bid.position == nil && bid.sizes.isEmpty)
    }

    @Test func loadRendersWhatInfoDescribedWithTheSameFacts() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p2"))
        let bid = try await ads.format(.pause)
        let ad = try await ads.format(.pause).load()
        #expect(ad.isReady)
        #expect(ad.id == bid.id && ad.price == bid.price && ad.sizes == bid.sizes, "the same facts; the expiry counts from the response, not from load()")
        #expect(pages.served == ["img-p2"])
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1, "load rendered the held answer")
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("loaded") })
    }

    @Test func aLoadedUnshownAdKeepsTheLoaderBusyUntilShown() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p3"))
        let ad = try await ads.format(.pause).load()
        do {
            _ = try await ads.format(.pause).load()
            Issue.record("expected formatBusy")
        } catch VideoAdError.formatBusy {}
        do {
            _ = try await ads.format(.pause, options: .default)
            Issue.record("expected formatBusy")
        } catch VideoAdError.formatBusy {}
        try ad.show(in: harness.player.view)
        harness.serve(Fixtures.ad(id: "img-p4"))
        let next = try await ads.format(.pause).load()
        #expect(next.id == "img-p4", "an ad on screen does not block the next")
        ad.dismiss()
    }

    @Test func theSameOptionsGetTheHeldAnswerOtherOptionsANewOne() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p5"))
        _ = try await ads.format(.pause)
        let same = try await ads.format(.pause, options: .default)
        #expect(same.id == "img-p5", "asked with the declared options: the held answer, no request")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1)
        harness.serve(Fixtures.ad(id: "img-p6"))
        let fresh = try await ads.format(.pause, options: PauseOptions(positions: [.fullscreen]))
        #expect(fresh.id == "img-p6", "other options: a new request")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2)
        #expect(try await ads.format(.pause).load().id == "img-p6", "the fresh answer is the held one now")
        #expect(pages.served == ["img-p6"], "the replaced answer was never rendered")
    }

    @Test func anExpiredHeldAnswerIsFetchedAgain() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p7", expires: 100))
        _ = try await ads.format(.pause)
        await sleepMs(150)
        harness.serve(Fixtures.ad(id: "img-p8"))
        let ad = try await ads.format(.pause).load()
        #expect(ad.id == "img-p8")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2)
    }

    @Test func aTargetingChangeDropsAHeldAnswer() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p9"))
        _ = try await ads.format(.pause)
        KontextVideo.shared.variantId = "b"
        harness.serve(Fixtures.ad(id: "img-p10"))
        let ad = try await ads.format(.pause).load()
        #expect(ad.id == "img-p10", "the next request carries the new targeting")
        let last = harness.server.requests(to: "/v2/video/ads").last?.body
        #expect(last?["variantId"] as? String == "b")
    }

    @Test func destroyMakesTheLoaderThrowDestroyed() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p11"))
        _ = try await ads.format(.pause)
        ads.destroy()
        do {
            _ = try await ads.format(.pause).load()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        do {
            _ = try await ads.format(.pause)
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }

    @Test func aBidKeptAfterItsVideoAdsWasReleasedThrowsDestroyed() async throws {
        var ads: VideoAds? = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p12"))
        let bid = try await ads!.format(.pause)
        ads = nil
        do {
            _ = try await bid.load()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }

    @Test func aCreativeFailureSurfacesAtLoadNotAtTheBid() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "err-p13"))
        _ = try await ads.format(.pause)
        do {
            _ = try await ads.format(.pause).load()
            Issue.record("expected creativeFailed")
        } catch VideoAdError.creativeFailed(let code) {
            #expect(code == 502, "the page's own code")
        }
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("error") })
        harness.serve(Fixtures.ad(id: "img-p14"))
        #expect(try await ads.format(.pause).load().id == "img-p14", "the failed answer is spent; the next load fetches")
    }

    @Test func theBidThrowsTheRequestSideErrors() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("noAdMatch", format: "overlay")))
        do {
            _ = try await ads.format(.overlay)
            Issue.record("expected noFill")
        } catch VideoAdError.noFill(let reason) {
            #expect(reason == "noAdMatch")
        }
        ads.destroy()
        do {
            _ = try await ads.format(.overlay)
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }
}
}
