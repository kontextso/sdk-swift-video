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
        let info = try await ads.format(.overlay, options: OverlayOptions(positions: [.top])).info
        #expect(info.id == "img-o1")
        #expect(info.format == .overlay)
        #expect(info.price.value > 0)
        #expect(info.position == .top)
        #expect(info.size == VideoAd.Size(width: 320, height: 90))
        #expect(info.sizes == [VideoAd.Size(width: 320, height: 90)])
        #expect(info.duration == 6)
        #expect(info.skipOffset == nil)
        #expect(info.reward == nil)
        #expect(try await ads.format(.overlay).info == info, "info is the held answer, no second request")
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

    @Test func linearFactsAreInSeconds() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.linearAd(id: "vid-l1", duration: 15_000, skipOffset: 5000, reward: ["label": "coins", "amount": 50]))
        let info = try await ads.format(.linear).info
        #expect(info.duration == 15)
        #expect(info.skipOffset == 5)
        #expect(info.reward == VideoAd.Reward(label: "coins", amount: 50))
        #expect(info.position == nil && info.sizes.isEmpty)
    }

    @Test func loadRendersWhatInfoDescribedWithTheSameFacts() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p2"))
        let info = try await ads.format(.pause).info
        let ad = try await ads.format(.pause).load()
        #expect(ad.isReady)
        #expect(ad.info == info, "the same facts; the expiry counts from the response, not from load()")
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
        _ = try await ads.format(.pause).info
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
        _ = try await ads.format(.pause).info
        await sleepMs(150)
        harness.serve(Fixtures.ad(id: "img-p8"))
        let ad = try await ads.format(.pause).load()
        #expect(ad.id == "img-p8")
        #expect(harness.server.requests(to: "/v2/video/ads").count == 2)
    }

    @Test func aTargetingChangeDropsAHeldAnswer() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-p9"))
        _ = try await ads.format(.pause).info
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
        _ = try await ads.format(.pause).info
        ads.destroy()
        do {
            _ = try await ads.format(.pause).load()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        do {
            _ = try await ads.format(.pause).info
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
        _ = try await ads.format(.pause).info
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
            _ = try await ads.format(.overlay).info
            Issue.record("expected noFill")
        } catch VideoAdError.noFill(let reason) {
            #expect(reason == "noAdMatch")
        }
        ads.destroy()
        do {
            _ = try await ads.format(.overlay).info
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }
}
}
