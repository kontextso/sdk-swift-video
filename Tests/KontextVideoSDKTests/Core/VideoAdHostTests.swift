import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The view behind SwiftUI's `VideoAdHost`: the ad it is given is shown, replaced or dismissed.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdHostTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)

    final class Heard {
        var ends: [VideoAd.EndReason] = []
        var failures: [VideoAdError] = []
        /// The ads' owners: a released `VideoAds` destroys its ads.
        var owners: [VideoAds] = []
    }

    private let heard = Heard()

    private func loaded(_ payload: [String: Any]) async throws -> VideoAd {
        _ = await harness.initialize()
        let owner = VideoAds(content: .init(id: "ep-h", language: "en"))
        heard.owners.append(owner)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: owner)
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
        return ad
    }

    /// A slot in the window, sized, hearing its ads.
    private func slot() -> VideoAdSlotView {
        let slot = VideoAdSlotView()
        slot.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        window.add(slot)
        let heard = heard
        slot.onEnd = { _, reason in heard.ends.append(reason) }
        slot.onShowFailed = { _, error in heard.failures.append(error) }
        return slot
    }

    @Test func anAdGivenIsShownAndItsEndHeard() async throws {
        let slot = slot()
        let ad = try await loaded(Fixtures.ad(id: "p-h-1"))
        slot.set(ad)
        #expect(ad.wasShown)
        #expect(slot.ad === ad)
        ad.dismiss()
        #expect(heard.ends == [.dismissed])
        #expect(slot.ad == nil, "an ended ad leaves the slot")
    }

    @Test func nilDismissesTheAdShown() async throws {
        let slot = slot()
        let ad = try await loaded(Fixtures.ad(id: "p-h-2"))
        slot.set(ad)
        slot.set(nil)
        #expect(heard.ends == [.dismissed])
        #expect(KontextVideo.shared.adOnScreen == nil)
    }

    @Test func anotherAdReplacesTheOneShown() async throws {
        let slot = slot()
        let first = try await loaded(Fixtures.ad(id: "p-h-3"))
        let second = try await loaded(Fixtures.ad(id: "p-h-4"))
        slot.set(first)
        slot.set(second)
        #expect(heard.ends == [.dismissed], "the first was dismissed")
        #expect(second.wasShown && slot.ad === second)
    }

    @Test func anAdWaitsUntilTheSlotIsInAWindowWithASize() async throws {
        let slot = VideoAdSlotView()
        let ad = try await loaded(Fixtures.ad(id: "p-h-5"))
        slot.set(ad)
        #expect(!ad.wasShown, "no window yet")
        slot.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        window.add(slot)
        slot.layoutIfNeeded()
        #expect(ad.wasShown)
        slot.set(nil)
    }

    @Test func anAdTakenAwayBeforeItShowedIsGivenBack() async throws {
        let slot = VideoAdSlotView()
        let ad = try await loaded(Fixtures.ad(id: "p-h-6"))
        slot.set(ad)
        slot.set(nil)
        #expect(!ad.wasShown)
        #expect(ad.delegate == nil, "the slot is no longer its delegate")
    }

    @Test func anAdThatCannotBeShownIsReportedAndNotHeld() async throws {
        let elsewhere = try await loaded(Fixtures.ad(id: "p-h-7"))
        let other = UIView(frame: CGRect(x: 0, y: 300, width: 390, height: 220))
        window.add(other)
        try elsewhere.show(in: other) // the app's one slot is taken
        let slot = slot()
        let ad = try await loaded(Fixtures.ad(id: "p-h-8"))
        slot.set(ad)
        #expect(heard.failures.count == 1)
        #expect(slot.ad == nil && !ad.wasShown)
        elsewhere.dismiss()
    }

    @Test func anAdShownElsewhereIsLeftAlone() async throws {
        let ad = try await loaded(Fixtures.ad(id: "p-h-9"))
        let other = UIView(frame: CGRect(x: 0, y: 300, width: 390, height: 220))
        window.add(other)
        try ad.show(in: other)
        let slot = slot()
        slot.set(ad)
        slot.set(nil)
        #expect(!ad.hasEnded, "not dismissed by a slot that did not show it")
        ad.dismiss()
    }

    /// Lets every block queued on the main queue so far run: SwiftUI's deferred updates.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func aHostDismantledBeforeItsDeferredUpdateNeverAdoptsTheAd() async throws {
        let slot = slot()
        let ad = try await loaded(Fixtures.ad(id: "p-h-10"))
        slot.request(ad)
        slot.dismantle()   // SwiftUI removed the host, still in its window, before the update was applied
        await drainMainQueue()
        #expect(!ad.wasShown && ad.delegate == nil && slot.ad == nil && ad.isReady, "never adopted, never shown")
    }

    @Test func theLatestUpdateWinsAfterABurst() async throws {
        let slot = slot()
        let first = try await loaded(Fixtures.ad(id: "p-h-11"))
        let second = try await loaded(Fixtures.ad(id: "p-h-12"))
        slot.request(first)
        slot.request(second)
        slot.request(nil)
        await drainMainQueue()
        #expect(!first.wasShown && !second.wasShown && first.delegate == nil && second.delegate == nil)
        slot.request(second)
        await drainMainQueue()
        #expect(second.wasShown && !first.wasShown, "one apply, of the latest wish")
        slot.request(nil)
        await drainMainQueue()
    }

    @Test func aDismantledHostFreesTheSlotAtOnceAndReportsTheEndAfterTheUpdate() async throws {
        let slot = slot()
        let ad = try await loaded(Fixtures.ad(id: "p-h-13"))
        slot.set(ad)
        #expect(ad.wasShown)
        slot.dismantle()
        #expect(KontextVideo.shared.adOnScreen == nil, "the app's one slot is free before SwiftUI goes on")
        #expect(heard.ends.isEmpty, "not inside SwiftUI's update")
        await drainMainQueue()
        #expect(heard.ends == [.dismissed])
    }

    @Test func aLinearAdInAHostPresentsFromTheHostsWindowNotTheKeyWindow() async throws {
        let other = TestWindow()
        defer { other.tearDown() }
        let key = window.window
        Environment.keyWindow = { key }
        let slot = VideoAdSlotView()
        slot.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        other.add(slot)
        let ad = try await loaded(Fixtures.linearAd(id: "l-h-14"))
        slot.set(ad)
        #expect(ad.wasShown, "\(heard.failures)")
        #expect(other.root.presentedViewController is LinearAdViewController || ad.linearController?.presentingViewController === other.root,
                "presented from the host's own window")
        #expect(window.root.presentedViewController == nil, "not from the key window")
        heard.owners.forEach { $0.destroy() }
    }

    @Test func aLinearAdBeingDismissedWhenTheHostLeavesStillReportsItsEnd() async throws {
        LinearScreen.dismissalTimeout = 0.05
        let ad = try await loaded(Fixtures.linearAd(id: "l-h-15"))
        do {
            let slot = slot()
            slot.set(ad)
            #expect(ad.wasShown)
            heard.owners.forEach { $0.destroy() }   // the ad ends: its dismissal starts, didEnd waits for it
            #expect(ad.hasEnded && heard.ends.isEmpty, "being dismissed")
            slot.dismantle()
            slot.removeFromSuperview()
        }
        #expect(await waitUntil { self.heard.ends == [.destroyed] }, "the end is still heard after the host left")
    }

    @Test func theImpressionAndAClickReachTheAppsHandlers() async throws {
        let slot = slot()
        var impressions: [String] = []
        var clicks: [VideoAd.Click] = []
        slot.onImpression = { impressions.append($0.id) }
        slot.onClick = { _, click in clicks.append(click) }
        Environment.openURL = { _, completion in completion(true) }
        let ad = try await loaded(Fixtures.ad(id: "p-h-click"))
        slot.set(ad)
        #expect(await waitUntil { impressions == ["p-h-click"] }, "an image ad's impression at show")
        ad.bridge.noteTouch()
        ad.bridge.receive(["adId": ad.id, "type": "ad.click", "url": "https://brand.test", "area": "endCard"], from: sender)
        #expect(clicks == [VideoAd.Click(area: .endCard)])
        slot.onClick = nil
        ad.bridge.noteTouch()
        ad.bridge.receive(["adId": ad.id, "type": "ad.click", "url": "https://brand.test"], from: sender)
        #expect(clicks.count == 1 && ad.wasShown && !ad.hasEnded, "no handler: the click is still the ad's, nothing breaks")
    }

    @Test func dismantlingThroughSwiftUIsHookDismissesTheAd() async throws {
        let slot = slot()
        let ad = try await loaded(Fixtures.ad(id: "p-h-dismantle"))
        slot.set(ad)
        VideoAdHost.dismantleUIView(slot, coordinator: ())
        #expect(slot.isDismantled && slot.ad == nil && KontextVideo.shared.adOnScreen == nil)
        #expect(await waitUntil { self.heard.ends == [.dismissed] }, "the end after SwiftUI's update")
        VideoAdHost.dismantleUIView(UIView(), coordinator: ())   // a view that is no slot: nothing to do
    }

    @Test func tapsOutsideTheAdGoThroughToThePlayer() {
        let slot = slot()
        #expect(slot.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)
    }
}
}
