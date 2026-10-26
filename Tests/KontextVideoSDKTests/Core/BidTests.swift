import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// `VideoAd.Bid`: the facts before anything is rendered, `load()` (shared, never rendered twice),
/// `reject()` at every stage, expiry before and during a load, a creative that fails or dies, and the
/// conflicting calls on one bid. Pages are real: the in-process frame server answers the WebView.
extension SerialSuites {
@Suite
@MainActor
struct BidTests {
    private let harness = SDKHarness()
    private let pages = FramePageServer()
    private let window = TestWindow()
    /// The `VideoAds` behind each bid: releasing it would destroy the bid.
    private let owners = Owners()

    final class Owners {
        var all: [VideoAds] = []
    }

    init() {
        pages.install()
        window.add(harness.player.view)
    }

    private func bid(_ ad: [String: Any]) async throws -> (VideoAd.Bid, VideoAds) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        harness.serve(ad)
        let format = AdFormat(rawValue: ad["format"] as? String ?? "pause")!
        return (try await ads.format(format), ads)
    }

    private func error(_ work: () async throws -> Any) async -> VideoAdError? {
        do {
            _ = try await work()
            Issue.record("expected a throw")
            return nil
        } catch let error as VideoAdError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    private func beacons(_ event: String) async -> [[String: String]] {
        await sleepMs(80)
        return harness.server.beacons.filter { $0.event == event }.map(\.query)
    }

    // MARK: Facts and load

    @Test func aBidGivesTheFactsAndRendersNothing() async throws {
        let (bid, ads) = try await bid(Fixtures.ad(id: "img-1", moreSizes: [["width": 200, "height": 200, "scalable": true, "maintainAspectRatio": true]]))
        #expect(bid.id == "img-1")
        #expect(bid.format == .pause)
        #expect(bid.price == VideoAd.Price(value: 7.5, currency: "USD", precision: .exact))
        #expect(bid.data.position == .top)
        #expect(bid.data.size == VideoAd.Size(width: 300, height: 300))
        #expect(bid.data.sizes.count == 2)
        #expect(bid.duration == nil)
        #expect(bid.invalidationReason == nil)
        await sleepMs(50)
        #expect(pages.served.isEmpty, "nothing rendered before load()")
        _ = ads
    }

    @Test func linearFactsAreInSeconds() async throws {
        let (bid, _) = try await bid(Fixtures.linearAd(id: "vid-1", duration: 15_000, skipOffset: 5_000))
        #expect(bid.duration == 15)
        #expect(bid.data.skipOffset == 5)
        #expect(bid.data.position == nil)
        #expect(bid.data.size == nil)
    }

    @Test func loadReturnsAReadyAdWithTheSameFactsAndFiresLoaded() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-2"))
        let ad = try await bid.load()
        #expect(ad.isReady)
        #expect(ad.id == bid.id && ad.price == bid.price && ad.data.size == bid.data.size)
        #expect(await beacons("loaded").count == 1)
        #expect(await beacons("impression").isEmpty, "loading fires nothing billable")
    }

    @Test func aSecondLoadReturnsTheSameAd() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-3"))
        let first = try await bid.load()
        #expect(try await bid.load() === first)
        #expect(pages.served == ["img-3"])
    }

    @Test func loadsAtOnceShareOneRender() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "slow-4"))
        async let one = bid.load()
        async let two = bid.load()
        let (a, b) = try await (one, two)
        #expect(a === b, "the second call awaits the first")
        #expect(pages.served == ["slow-4"], "rendered once")
    }

    @Test func loadsAtOnceShareTheSameError() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "err-5"))
        let one = Task { try await bid.load() }
        let two = Task { try await bid.load() }
        for result in [await one.result, await two.result] {
            guard case .failure(VideoAdError.creativeFailed(let code)) = result else { Issue.record("expected creativeFailed, got \(result)"); continue }
            #expect(code == 502)
        }
        #expect(pages.served == ["err-5"])
    }

    @Test func cancellingALoadStopsOnlyItsWaitingTheLoadContinues() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "slow-6", frameURL: "\(Fixtures.frameOrigin)/frame/slow-6?step=300"))
        let first = Task { try await bid.load() }
        await sleepMs(50)
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {}
        let ad = try await bid.load()
        #expect(ad.isReady)
        #expect(pages.served == ["slow-6"], "the cancelled load went on; nothing rendered again")
    }

    // MARK: A creative that fails

    @Test func aFailingCreativeThrowsItsCodeFiresErrorAndDropsTheBid() async throws {
        let (bid, ads) = try await bid(Fixtures.ad(id: "err-7"))
        let failure = await error { try await bid.load() }
        guard case .creativeFailed(let code) = failure else { Issue.record("expected creativeFailed, got \(String(describing: failure))"); return }
        #expect(code == 502)
        #expect(await beacons("error").map { $0["code"] } == ["502"])
        #expect(bid.invalidationReason == .creativeFailed(code: 502))
        harness.serve(Fixtures.ad(id: "img-8"))
        _ = try await ads.format(.pause)
        #expect(harness.adsRequests.last?.body?["held"] as? [String] == [], "a failed bid is not held")
    }

    @Test func aCreativeThatNeverLoadsThrowsTheGeneralCode() async throws {
        FrameBridge.loadTimeout = 0.3
        let (bid, _) = try await bid(Fixtures.ad(id: "dead-9"))
        let failure = await error { try await bid.load() }
        guard case .creativeFailed(let code) = failure else { Issue.record("expected creativeFailed, got \(String(describing: failure))"); return }
        #expect(code == 500)
    }

    @Test func theLoadTimeoutCountsOnlyActiveTime() async throws {
        FrameBridge.loadTimeout = 0.3
        Environment.isApplicationActive = { false }
        let (bid, _) = try await bid(Fixtures.ad(id: "dead-10"))
        let load = Task { try await bid.load() }
        await sleepMs(600)
        #expect(bid.invalidationReason == nil, "in the background the timeout does not run")
        Environment.isApplicationActive = { true }
        do {
            _ = try await load.value
            Issue.record("expected creativeFailed")
        } catch VideoAdError.creativeFailed {}
    }

    @Test func aCreativeThatDiesAfterLoadingMakesShowThrowWithoutADelegateCall() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-11"))
        let ad = try await bid.load()
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        _ = try? await ad.bridge.webView.evaluateJavaScript("fail(405)")
        #expect(await waitUntil { bid.invalidationReason != nil })
        #expect(bid.invalidationReason == .creativeFailed(code: 405))
        #expect(delegate.events.isEmpty, "nothing is delivered before show")
        do {
            try ad.show(in: harness.player.view)
            Issue.record("expected a throw")
        } catch VideoAdError.invalidated(let reason) {
            #expect(reason == .creativeFailed(code: 405))
        }
    }

    // MARK: Expiry

    @Test func expiryCountsFromTheFirstReceiptOnTheSDKsClock() async throws {
        let fresh = try Fixtures.adData(Fixtures.ad(expires: 1000))
        #expect(fresh.isExpired == false)
        advanceClock(by: 0.999)
        #expect(fresh.isExpired == false)
        advanceClock(by: 0.002)
        #expect(fresh.isExpired)
        // The real clock is CLOCK_MONOTONIC, which keeps counting while the device sleeps; a test cannot
        // sleep the device, so it checks what it can: the clock advances and never goes backwards.
        Environment.reset()
        let before = Environment.now()
        await sleepMs(50)
        let elapsed = Environment.now() - before
        #expect(elapsed >= 0.05 && elapsed < 5)
    }

    @Test func anExpiredBidThrowsAtLoad() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-12", expires: 30_000))
        advanceClock(by: 31)
        let failure = await error { try await bid.load() }
        guard case .invalidated(.expired) = failure else { Issue.record("expected invalidated(.expired), got \(String(describing: failure))"); return }
        #expect(pages.served.isEmpty)
        #expect(await beacons("error").isEmpty, "expiry is not a creative error")
    }

    @Test func aBidThatExpiresDuringTheLoadDropsTheResult() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "slow-13", expires: 30_000, frameURL: "\(Fixtures.frameOrigin)/frame/slow-13?step=300"))
        let load = Task { try await bid.load() }
        await sleepMs(50)
        advanceClock(by: 31)
        do {
            _ = try await load.value
            Issue.record("expected invalidated(.expired)")
        } catch VideoAdError.invalidated(let reason) {
            #expect(reason == .expired)
        }
        #expect(await beacons("error").isEmpty)
    }

    @Test func aLoadedAdThatExpiredThrowsAtShow() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-14", expires: 30_000))
        let ad = try await bid.load()
        advanceClock(by: 31)
        do {
            try ad.show(in: harness.player.view)
            Issue.record("expected a throw")
        } catch VideoAdError.invalidated(let reason) {
            #expect(reason == .expired)
        }
        #expect(bid.invalidationReason == .expired)
    }

    // MARK: Reject

    @Test func rejectBeforeLoadFiresNotUsedAndLoadThrows() async throws {
        let (bid, ads) = try await bid(Fixtures.ad(id: "img-15"))
        try bid.reject()
        #expect(await beacons("notUsed").map { $0["reason"] } == ["notUsed"])
        let failure = await error { try await bid.load() }
        guard case .invalidated(.rejected) = failure else { Issue.record("expected invalidated(.rejected), got \(String(describing: failure))"); return }
        harness.serve(Fixtures.ad(id: "img-16"))
        _ = try await ads.format(.pause)
        #expect(harness.adsRequests.last?.body?["held"] as? [String] == [], "a rejected bid is not held")
    }

    @Test func rejectOutbidCarriesTheWinningPriceAndTheWinner() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-17"))
        try bid.reject(.outbid(winningPrice: 2.4, winner: "AppLovin MAX"))
        let beacon = await beacons("notUsed").first
        #expect(beacon?["reason"] == "outbid")
        #expect(beacon?["wp"] == "2.4")
        #expect(beacon?["winner"] == "AppLovin MAX", "percent-encoded on the wire, decoded here")
        let (other, _) = try await self.bid(Fixtures.ad(id: "img-17b"))
        try other.reject(.outbid())
        let bare = await beacons("notUsed").last
        #expect(bare?["wp"]?.isEmpty == true && bare?["winner"]?.isEmpty == true, "both optional")
    }

    @Test func rejectDuringTheLoadCancelsItAndReleasesTheWebView() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "dead-18"))
        let load = Task { try await bid.load() }
        await sleepMs(100)
        try bid.reject()
        do {
            _ = try await load.value
            Issue.record("expected invalidated(.rejected)")
        } catch VideoAdError.invalidated(let reason) {
            #expect(reason == .rejected)
        }
        #expect(await beacons("notUsed").count == 1)
    }

    @Test func rejectAfterLoadMakesShowThrowAndTheAdRejectIsTheSame() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-19"))
        let ad = try await bid.load()
        try ad.reject()
        #expect(bid.invalidationReason == .rejected)
        #expect(ad.isReady == false)
        do {
            try ad.show(in: harness.player.view)
            Issue.record("expected a throw")
        } catch VideoAdError.invalidated(let reason) {
            #expect(reason == .rejected)
        }
        #expect(await beacons("notUsed").count == 1)
    }

    @Test func rejectAfterShowThrowsAlreadyShown() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-20"))
        let ad = try await bid.load()
        try ad.show(in: harness.player.view)
        #expect(throws: VideoAdError.self) { try bid.reject() }
        do { try ad.reject() } catch VideoAdError.alreadyShown {} catch { Issue.record("expected alreadyShown, got \(error)") }
        #expect(await beacons("notUsed").isEmpty)
        try ad.dismiss()
    }

    @Test func rejectTwiceThrowsAndSendsOneNotice() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-21"))
        try bid.reject()
        do { try bid.reject() } catch VideoAdError.invalidated(let reason) { #expect(reason == .rejected) }
        #expect(await beacons("notUsed").count == 1)
    }

    @Test func rejectAnExpiredBidThrowsWithoutANotice() async throws {
        let (bid, _) = try await bid(Fixtures.ad(id: "img-22", expires: 30_000))
        advanceClock(by: 31)
        do { try bid.reject() } catch VideoAdError.invalidated(let reason) { #expect(reason == .expired) }
        #expect(await beacons("notUsed").isEmpty, "the server closes an expired bid itself")
    }

    // MARK: After the VideoAds ended

    @Test func aBidOfADestroyedVideoAdsThrowsDestroyed() async throws {
        let (bid, ads) = try await bid(Fixtures.ad(id: "img-23"))
        ads.destroy()
        let failure = await error { try await bid.load() }
        guard case .destroyed = failure else { Issue.record("expected destroyed, got \(String(describing: failure))"); return }
        do { try bid.reject() } catch VideoAdError.destroyed {} catch { Issue.record("expected destroyed, got \(error)") }
    }

    @Test func destroyDuringTheLoadThrowsDestroyed() async throws {
        let (bid, ads) = try await bid(Fixtures.ad(id: "dead-24"))
        let load = Task { try await bid.load() }
        await sleepMs(100)
        ads.destroy()
        do {
            _ = try await load.value
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
    }
}
}
