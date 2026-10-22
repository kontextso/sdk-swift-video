import Foundation
@testable import KontextVideoSDK
import Testing

/// `fetch()` and `VideoAd.Bid`: the server's answer without a WebView, `load()` on it, the busy rule,
/// expiry, and what a targeting change or `destroy()` does to a pending bid.
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

    @Test func fetchReturnsTheFactsAndRendersNothing() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.overlayAd(id: "img-b1", duration: 6000, position: "top"))
        let bid = try await ads.overlay.fetch(OverlayOptions(positions: [.top]))
        #expect(bid.id == "img-b1")
        #expect(bid.format == .overlay)
        #expect(bid.price.value > 0)
        #expect(bid.position == .top)
        #expect(bid.size == VideoAd.Size(width: 320, height: 90))
        #expect(bid.sizes == [VideoAd.Size(width: 320, height: 90)])
        #expect(bid.duration == 6)
        #expect(bid.skipOffset == nil)
        #expect(bid.reward == nil)
        #expect(bid.isPending)
        #expect(pages.served.isEmpty, "no page was loaded")
        #expect(harness.server.beacons.isEmpty, "no beacon fired")
        let request = harness.server.requests(to: "/v2/video/ads").first?.body
        let formats = request?["formats"] as? [[String: Any]]
        #expect((formats?.first?["options"] as? [String: Any])?["positions"] as? [String] == ["top"])
    }

    @Test func loadOnTheBidRendersAndReturnsAReadyAdWithTheSameFacts() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b2"))
        let bid = try await ads.pause.fetch()
        let ad = try await bid.load()
        #expect(ad.isReady)
        #expect(ad.id == bid.id)
        #expect(ad.info.receivedAt == bid.info.receivedAt, "the expiry counts from the response, not from load()")
        #expect(pages.served == ["img-b2"])
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("loaded") })
        #expect(bid.isPending == false)
        #expect(harness.server.requests(to: "/v2/video/ads").count == 1, "no second request")
    }

    @Test func aSecondLoadReturnsTheSameAd() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b3"))
        let bid = try await ads.pause.fetch()
        let first = try await bid.load()
        let second = try await bid.load()
        #expect(first === second)
        #expect(pages.served == ["img-b3"], "rendered once")
    }

    @Test func aPendingBidMakesTheLoaderBusyAndDroppingItFreesIt() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b4"))
        var bid: VideoAd.Bid? = try await ads.pause.fetch()
        do {
            _ = try await ads.pause.fetch()
            Issue.record("expected formatBusy")
        } catch VideoAdError.formatBusy {}
        do {
            let held = try await ads.pause.bid
            #expect(held === bid, "the loader's answer is the bid the app holds")
        }
        bid = nil
        harness.serve(Fixtures.ad(id: "img-b5"))
        let next = try await ads.pause.fetch()
        #expect(next.id == "img-b5", "a dropped bid costs nothing and frees the loader")
        withExtendedLifetime(bid) {}
    }

    @Test func loadRendersTheBidTheAppHolds() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b4b"))
        let bid = try await ads.pause.fetch()
        let ad = try await ads.pause.load()
        #expect(ad.id == bid.id)
        #expect(bid.ad === ad, "one render; the bid now carries the ad")
    }

    @Test func aLoadedBidsAdKeepsTheLoaderBusyUntilShown() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b6"))
        let bid = try await ads.pause.fetch()
        let ad = try await bid.load()
        do {
            _ = try await ads.pause.fetch()
            Issue.record("expected formatBusy")
        } catch VideoAdError.formatBusy {}
        withExtendedLifetime(ad) {}
    }

    @Test func loadAfterExpiryThrowsInvalidatedExpired() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b7", expires: 100))
        let bid = try await ads.pause.fetch()
        await sleepMs(150)
        #expect(bid.isPending == false)
        do {
            _ = try await bid.load()
            Issue.record("expected invalidated(.expired)")
        } catch VideoAdError.invalidated(.expired) {}
        #expect(bid.invalidationReason == .expired)
        #expect(pages.served.isEmpty)
        harness.serve(Fixtures.ad(id: "img-b8"))
        _ = try await ads.pause.fetch()
    }

    @Test func aTargetingChangeDiscardsAPendingBid() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b9"))
        let bid = try await ads.pause.fetch()
        KontextVideo.shared.variantId = "b"
        #expect(bid.invalidationReason == .targetingChanged)
        do {
            _ = try await bid.load()
            Issue.record("expected invalidated(.targetingChanged)")
        } catch VideoAdError.invalidated(.targetingChanged) {}
        harness.serve(Fixtures.ad(id: "img-b10"))
        _ = try await ads.pause.fetch()
    }

    @Test func destroyDiscardsAPendingBid() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b11"))
        let bid = try await ads.pause.fetch()
        ads.destroy()
        #expect(bid.invalidationReason == .destroyed)
        do {
            _ = try await bid.load()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }

    @Test func deallocatingTheVideoAdsDiscardsAPendingBid() async throws {
        var ads: VideoAds? = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b12"))
        let bid = try await ads!.pause.fetch()
        ads = nil
        #expect(bid.invalidationReason == .destroyed)
        do {
            _ = try await bid.load()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }

    @Test func aCreativeFailureSurfacesAtLoadNotAtFetch() async throws {
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "err-b13"))
        let bid = try await ads.pause.fetch()
        do {
            _ = try await bid.load()
            Issue.record("expected creativeFailed")
        } catch VideoAdError.creativeFailed(let code) {
            #expect(code == 502, "the page's own code")
        }
        #expect(await waitUntil { self.harness.server.beacons.map(\.event).contains("error") })
        #expect(bid.invalidationReason == .creativeFailed(code: 502))
        #expect(bid.isPending == false)
        do {
            _ = try await bid.load()
            Issue.record("expected invalidated(.creativeFailed)")
        } catch VideoAdError.invalidated(.creativeFailed(let code)) {
            #expect(code == 502, "the bid is done; it is not rendered a second time")
        }
        #expect(pages.served == ["err-b13"], "one page load, not two")
        harness.serve(Fixtures.ad(id: "img-b14"))
        _ = try await ads.pause.fetch()
    }

    @Test func fetchThrowsTheRequestSideErrors() async throws {
        let ads = await makeAds()
        harness.server.on("/v2/video/ads", .json(Fixtures.noFill("noAdMatch", format: "overlay")))
        do {
            _ = try await ads.overlay.fetch()
            Issue.record("expected noFill")
        } catch VideoAdError.noFill(let reason) {
            #expect(reason == "noAdMatch")
        }
        ads.destroy()
        do {
            _ = try await ads.overlay.fetch()
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }

    @Test func loadingTwiceAtOnceIsAProgrammerError() async throws {
        var messages: [String] = []
        Environment.assertionFailure = { messages.append($0) }
        let ads = await makeAds()
        harness.serve(Fixtures.ad(id: "img-b15"))
        let bid = try await ads.pause.fetch()
        let first = Task { try await bid.load() }
        await sleepMs(20)
        do {
            _ = try await bid.load()
            Issue.record("expected formatBusy")
        } catch VideoAdError.formatBusy {}
        #expect(messages.count == 1)
        _ = try await first.value
    }
}
}
