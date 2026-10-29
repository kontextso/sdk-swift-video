import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// An app-install ad's SKAdNetwork side, through the ad: the impression registered at presentation and
/// ended with the ad, one app-wide queue, and the App Store sheet a signed click opens. Apple's APIs are
/// replaced by the harness's recorders.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdSKAdNetworkTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps every `VideoAds` a test created alive for the test's duration: the ad holds its owner weakly.
    private let owners = Owners()

    final class Owners {
        var all: [VideoAds] = []
    }

    init() {
        harness.player.view.frame.origin.y = 120
        window.add(harness.player.view)
    }

    private func makeAd(_ payload: [String: Any]) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        send(ad, "ad.loaded")
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate, ads)
    }

    private func send(_ ad: VideoAd, _ type: String, _ extra: [String: Any] = [:]) {
        var body: [String: Any] = ["adId": ad.id, "type": type]
        extra.forEach { body[$0.key] = $0.value }
        ad.bridge.receive(body, from: sender)
    }

    private func beacons() async -> [String] {
        await sleepMs(80)
        return harness.server.beacons.map { beacon in beacon.query["part"].map { "\(beacon.event)(\($0))" } ?? beacon.event }
    }

    /// Lets a test hold `initImpression` open until it says so.
    final class Gate {
        var open = false
    }

    private var skanCalls: [String] { harness.skAdNetwork.calls }

    @Test func anAppInstallAdRegistersItsImpressionWhenShownAndEndsItWhenItLeaves() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s1"), itunesItem: "s1"))
        await sleepMs(30)
        #expect(skanCalls.isEmpty, "nothing before show")
        try ad.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls == ["init s1", "start"] })
        try ad.dismiss()
        #expect(await waitUntil { skanCalls == ["init s1", "start", "end", "dispose"] })
    }

    @Test func anAdWithoutAttributionNeverTouchesSKAdNetwork() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "s2"))
        try ad.show(in: harness.player.view)
        try ad.dismiss()
        await sleepMs(50)
        #expect(skanCalls.isEmpty && ad.skAdNetwork == nil)
    }

    @Test func aLinearAdRegistersItsImpressionOnceUIKitPresentedIt() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.linearAd(id: "s3"), itunesItem: "s3"))
        try ad.show(from: window.root)
        await sleepMs(50)
        #expect(skanCalls.isEmpty, "reserved, not on screen yet")
        ad.linearController?.loadViewIfNeeded()
        window.add(ad.bridge.webView)
        ad.presented()
        #expect(await waitUntil { skanCalls == ["init s3", "start"] })
        ad.end(.interrupted)
        #expect(await waitUntil { skanCalls == ["init s3", "start", "end", "dispose"] })
    }

    @Test func aLinearAdThatNeverGotOnScreenRegistersNoImpression() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.installAd(Fixtures.linearAd(id: "s4"), itunesItem: "s4"))
        try ad.show(from: window.root)
        ad.end(.interrupted)
        await sleepMs(50)
        #expect(skanCalls.isEmpty && delegate.endReasons == [.interrupted])
    }

    @Test func theEndWaitsForAStartStillInFlight() async throws {
        let gate = Gate()
        harness.skAdNetwork.onStart = { while !gate.open { await sleepMs(5) } }
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s5"), itunesItem: "s5"))
        try ad.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls == ["init s5", "start"] })
        try ad.dismiss()
        await sleepMs(60)
        #expect(skanCalls == ["init s5", "start"], "end waits until Apple answered the start")
        gate.open = true
        #expect(await waitUntil { skanCalls == ["init s5", "start", "end", "dispose"] })
    }

    @Test func theNextAdsImpressionStartsAfterThePreviousOneEnded() async throws {
        let gate = Gate()
        harness.skAdNetwork.onEnd = { while !gate.open { await sleepMs(5) } }
        let (first, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s6a"), itunesItem: "s6a"))
        let (second, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s6b"), itunesItem: "s6b"))
        try first.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls.count == 2 })
        try first.dismiss()
        try second.show(in: harness.player.view)
        await sleepMs(60)
        #expect(skanCalls == ["init s6a", "start", "end"], "the next ad's init waits for the end in flight")
        gate.open = true
        #expect(await waitUntil { skanCalls.count == 6 })
        #expect(skanCalls == ["init s6a", "start", "end", "dispose", "init s6b", "start"], "one impression at a time, in order")
        try second.dismiss()
    }

    @Test func aFailedRegistrationIsLoggedAndTheAdGoesOn() async throws {
        harness.skAdNetwork.onInit = { throw TestFailure() }
        let (ad, delegate, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s7"), itunesItem: "s7"))
        try ad.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls == ["init s7"] })
        try ad.dismiss()
        await sleepMs(60)
        #expect(skanCalls == ["init s7"], "nothing to end when Apple refused the impression")
        #expect(delegate.events == ["impression", "end:dismissed"])
        #expect(await beacons().contains("impression"))
    }

    @Test func aFailedEndStillReleasesTheImpressionBeforeTheNextAd() async throws {
        harness.skAdNetwork.onEnd = { throw TestFailure() }
        let (first, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s11a"), itunesItem: "s11a"))
        let (second, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s11b"), itunesItem: "s11b"))
        try first.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls.count == 2 })
        try first.dismiss()
        try second.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls.count == 6 })
        #expect(skanCalls == ["init s11a", "start", "end", "dispose", "init s11b", "start"], "dispose runs whatever the end did")
        try second.dismiss()
    }

    @Test func anAdThatEndedWhileAppleRegisteredItIsNeverStarted() async throws {
        let gate = Gate()
        harness.skAdNetwork.onInit = { while !gate.open { await sleepMs(5) } }
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s12"), itunesItem: "s12"))
        try ad.show(in: harness.player.view)
        try ad.dismiss()
        gate.open = true
        #expect(await waitUntil { skanCalls.count == 3 })
        await sleepMs(30)
        #expect(skanCalls == ["init s12", "end", "dispose"], "no start for an ad already gone; the end releases it")
    }

    @Test func anAdThatEndsOnceRegistrationIsUnderwayIsNeverStarted() async throws {
        // The same, with registration proven to be inside the manager before the ad ends.
        let gate = Gate()
        var entered = false
        harness.skAdNetwork.onInit = { entered = true; while !gate.open { await sleepMs(5) } }
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s12b"), itunesItem: "s12b"))
        try ad.show(in: harness.player.view)
        #expect(await waitUntil { entered })
        try ad.dismiss()
        gate.open = true
        #expect(await waitUntil { skanCalls.count == 3 })
        await sleepMs(30)
        #expect(skanCalls == ["init s12b", "end", "dispose"])
    }

    @Test func everyFailureIsReportedWithItsStepAndAd() async throws {
        harness.server.on("/v2/config", .json(Fixtures.initEnabled(reportDebug: true)))
        harness.skAdNetwork.onStart = { throw TestFailure() }
        harness.skAdNetwork.onEnd = { throw TestFailure() }
        harness.skAdNetwork.onDispose = { throw TestFailure() }
        let (first, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s16a"), itunesItem: "s16a"))
        try first.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls.count == 2 })
        try first.dismiss()
        #expect(await waitUntil { skanCalls.count == 4 })
        // A failed dispose does not block the next ad.
        harness.skAdNetwork.onStart = nil
        let (second, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s16b"), itunesItem: "s16b"))
        try second.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls == ["init s16a", "start", "end", "dispose", "init s16b", "start"] })
        let failures = {
            self.harness.server.requests(to: "/v2/debug").compactMap { $0.body?["events"] as? [[String: Any]] }.flatMap { $0 }
                .filter { $0["name"] as? String == "ad.skanFailed" }
        }
        #expect(await waitUntil(5) { failures().count == 3 })
        #expect(failures().compactMap { ($0["state"] as? [String: Any])?["step"] as? String } == ["start", "end", "dispose"], "each failure once, with its step")
        #expect(failures().compactMap { $0["adId"] as? String } == ["s16a", "s16a", "s16a"], "and the ad it belongs to")
        try second.dismiss()
    }

    @Test func aClickWhoseSheetIsLoadingWhenTheAdEndsIsStillHonored() async throws {
        let gate = Gate()
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        harness.storeProduct.onPresent = { while !gate.open { await sleepMs(5) } }
        harness.storeProduct.result = .success(false)
        var ad: VideoAd? = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s17"), itunesItem: "s17")).0
        weak var released = ad
        try ad?.show(in: harness.player.view)
        ad?.bridge.noteTouch()
        if let ad { send(ad, "ad.click", ["url": "https://apps.apple.com/app/id17"]) }
        #expect(await waitUntil { harness.storeProduct.presented.count == 1 })
        try ad?.dismiss()   // the ad ends while the sheet is still loading, and is released
        ad = nil
        #expect(await waitUntil { released == nil }, "the ad is gone")
        gate.open = true
        #expect(await waitUntil { opened.count == 1 }, "the sheet failed: the viewer's tap still opens the URL")
        #expect(opened.first?.absoluteString == "https://apps.apple.com/app/id17")
    }

    @Test func aFailedStartStillGetsItsEnd() async throws {
        harness.skAdNetwork.onStart = { throw TestFailure() }
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s13"), itunesItem: "s13"))
        try ad.show(in: harness.player.view)
        #expect(await waitUntil { skanCalls.count == 2 })
        try ad.dismiss()
        #expect(await waitUntil { skanCalls == ["init s13", "start", "end", "dispose"] }, "Apple asks for the end even after a failed start")
    }

    @Test func repeatedStartAndEndAreOneLifecycle() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s14"), itunesItem: "s14"))
        try ad.show(in: harness.player.view)
        let impression = try #require(ad.skAdNetwork)
        impression.start()
        impression.start()
        #expect(await waitUntil { skanCalls.count == 2 })
        try ad.dismiss()
        impression.end()
        impression.end()
        await sleepMs(60)
        #expect(skanCalls == ["init s14", "start", "end", "dispose"])
    }

    @Test func aClickOnAnAdWhoseNetworkSignedTheClickOpensTheStoreSheetNotTheURL() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s8"), itunesItem: "s8"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://apps.apple.com/app/id1521454264"])
        #expect(await waitUntil { harness.storeProduct.presented.count == 1 })
        #expect(harness.storeProduct.presented.first?.itunesItem == "s8")
        #expect(await beacons().contains("click"), "the click beacon fires as for any click")
        #expect(opened.isEmpty, "the sheet replaces the URL")
        #expect(delegate.clicks.count == 1 && !ad.hasEnded)
    }

    @Test func aStoreSheetThatCouldNotBePresentedOpensTheURL() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s9"), itunesItem: "s9"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        harness.storeProduct.result = .success(false)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://apps.apple.com/app/id1"])
        #expect(await waitUntil { opened.count == 1 })
        harness.storeProduct.result = .failure(TestFailure())
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://apps.apple.com/app/id2"])
        #expect(await waitUntil { opened.count == 2 })
        #expect(opened.map(\.absoluteString) == ["https://apps.apple.com/app/id1", "https://apps.apple.com/app/id2"])
        #expect(harness.storeProduct.presented.count == 2, "the sheet was tried each time")
    }

    @Test func anAdSignedForTheClickOnlyRegistersNoImpressionAndStillOpensTheSheet() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s15"), itunesItem: "s15", fidelities: [1]))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://apps.apple.com/app/id1"])
        #expect(await waitUntil { harness.storeProduct.presented.count == 1 })
        try ad.dismiss()
        await sleepMs(60)
        #expect(skanCalls.isEmpty && opened.isEmpty, "nothing to register, nothing to log; the sheet carries the attribution")
    }

    @Test func aClickOnAnAdWithOnlyAViewThroughSignatureOpensTheURL() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.installAd(Fixtures.ad(id: "s10"), itunesItem: "s10", fidelities: [0]))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://apps.apple.com/app/id1"])
        #expect(opened.map(\.absoluteString) == ["https://apps.apple.com/app/id1"])
        await sleepMs(30)
        #expect(harness.storeProduct.presented.isEmpty, "no signature for the click, no sheet")
        #expect(await waitUntil { skanCalls == ["init s10", "start"] }, "the view-through impression still counts")
    }
}
}
