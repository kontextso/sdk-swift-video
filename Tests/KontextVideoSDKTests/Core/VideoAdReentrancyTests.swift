import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The app's own code running inside the SDK's calls: a player view's UIKit hook while `show` adds the ad,
/// the playhead provider inside a beacon. Whatever it does (show another ad, destroy, take the player
/// away), one ad holds the slot, nothing is left behind, and `didEnd` stays the last delegate call.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdReentrancyTests {
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

    /// A loaded ad, owned by its own `VideoAds`, with a recording delegate.
    private func makeAd(_ payload: [String: Any]) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
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
        return harness.server.beacons.map(\.event)
    }

    /// The usual tracking, with the content playhead macro only in `event`'s URL: the app's provider then
    /// runs inside that one beacon and no other.
    private func tracking(readingThePlayheadOnlyIn event: String, adId: String) -> [[String: Any]] {
        Fixtures.tracking(video: false, adId: adId).map { entry in
            var entry = entry
            let url = entry["url"] as? String ?? ""
            entry["url"] = entry["event"] as? String == event ? url : url.replacingOccurrences(of: "&cph=[MEDIAPLAYHEAD]", with: "")
            return entry
        }
    }

    @Test func aPlayheadProviderThatDestroysDuringShowGetsNoImpressionAfterDidEnd() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.ad(id: "p10p"))
        var reads = 0
        // The first beacon at show reads the playhead; the app's provider destroys the VideoAds there.
        ads.playheadProvider = { [weak ads] in
            reads += 1
            if reads == 1 { ads?.destroy() }
            return 0
        }
        try ad.show(in: harness.player.view)
        #expect(reads >= 1, "the show's beacons read the app's provider")
        #expect(delegate.events == ["end:destroyed"], "didEnd is the last and only call: \(delegate.events)")
        #expect(KontextVideo.shared.adOnScreen == nil && ad.loadedBridge == nil)
        #expect(!(await beacons()).contains("impression"), "nothing after the end")
    }

    @Test func aShowFromInsideTheContainersAddHookFindsTheSlotTaken() async throws {
        let (first, firstDelegate, _) = try await makeAd(Fixtures.overlayAd(id: "o10r"))
        let (second, secondDelegate, _) = try await makeAd(Fixtures.ad(id: "p10r"))
        let reentrant = ReentrantView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let other = UIView(frame: CGRect(x: 0, y: 300, width: 390, height: 220))
        window.add(reentrant)
        window.add(other)
        var nested: Error?
        reentrant.onAdd = { do { try second.show(in: other) } catch { nested = error } }
        try first.show(in: reentrant)
        guard case .anotherAdShowing? = nested as? VideoAdError else { Issue.record("expected anotherAdShowing, got \(String(describing: nested))"); return }
        #expect(first.wasShown && !second.wasShown && second.isReady, "one ad on screen; the other stays ready")
        #expect(firstDelegate.events == ["impression"] && secondDelegate.events.isEmpty)
        #expect(other.subviews.isEmpty, "the refused show left nothing behind")
        #expect(KontextVideo.shared.adOnScreen === first)
        try first.dismiss()
    }

    @Test func aDestroyFromInsideTheContainersAddHookEndsTheAdWithNothingLeft() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o10d"))
        let reentrant = ReentrantView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        window.add(reentrant)
        reentrant.onAdd = { ads.destroy() }
        try ad.show(in: reentrant)
        #expect(ad.wasShown && ad.hasEnded)
        #expect(delegate.events == ["end:destroyed"], "no impression for an ad that ended before it was on screen")
        #expect(reentrant.subviews.isEmpty && KontextVideo.shared.adOnScreen == nil)
        #expect(!(await beacons()).contains("impression"))
    }

    @Test func aHookThatTakesThePlayerOffScreenEndsTheAdWithoutAnImpression() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o11o"))
        let reentrant = ReentrantView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        window.add(reentrant)
        reentrant.onAdd = { reentrant.removeFromSuperview() }
        try ad.show(in: reentrant)
        #expect(ad.wasShown && ad.hasEnded)
        #expect(delegate.events == ["end:interrupted"], "committed, then ended at once, never seen")
        #expect(reentrant.subviews.isEmpty && KontextVideo.shared.adOnScreen == nil)
        #expect(!(await beacons()).contains("impression"))
    }

    @Test func aProviderThatDestroysDuringTheImpressionBeaconKeepsDidEndLast() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.ad(id: "p11i", extra: ["tracking": tracking(readingThePlayheadOnlyIn: "impression", adId: "p11i")]))
        var reads = 0
        ads.playheadProvider = { [weak ads] in
            reads += 1
            ads?.destroy()
            return 0
        }
        try ad.show(in: harness.player.view)
        #expect(reads == 1, "read inside the impression beacon only")
        #expect(delegate.events == ["end:destroyed"], "no impression callback after the end: \(delegate.events)")
        #expect(KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aProviderThatDestroysDuringTheClickBeaconStillOpensTheClickAndKeepsDidEndLast() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.ad(id: "p11c", extra: ["tracking": tracking(readingThePlayheadOnlyIn: "click", adId: "p11c")]))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ads.playheadProvider = { [weak ads] in
            ads?.destroy()
            return 0
        }
        ad.bridge.noteTouch()   // a click counts only right after the viewer's touch
        send(ad, "ad.click", ["url": "https://brand.test/offer"])
        #expect(delegate.events == ["impression", "end:destroyed"], "no click callback after the end: \(delegate.events)")
        #expect(await waitUntil { opened.map(\.absoluteString) == ["https://brand.test/offer"] }, "the viewer's tap still opens")
    }
}
}

/// A player view that runs the app's code when the SDK adds its host, as an overridable UIKit hook can.
@MainActor
private final class ReentrantView: UIView {
    var onAdd: (() -> Void)?

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        let action = onAdd
        onAdd = nil
        action?()
    }
}
