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

    @Test func tapsOutsideTheAdGoThroughToThePlayer() {
        let slot = slot()
        #expect(slot.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)
    }
}
}
