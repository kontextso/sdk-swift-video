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

    @Test func aProviderThatDestroysAtShowMeansNothingIsShown() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.ad(id: "p10p"))
        var reads = 0
        ads.playheadProvider = { [weak ads] in
            reads += 1
            ads?.destroy()
            return 0
        }
        do {
            try ad.show(in: harness.player.view)
            Issue.record("expected destroyed")
        } catch VideoAdError.destroyed {}
        #expect(reads == 1, "read once, before the show changed anything")
        #expect(!ad.wasShown && delegate.events.isEmpty)
        #expect(KontextVideo.shared.adOnScreen == nil && harness.player.view.subviews.isEmpty)
        #expect(!(await beacons()).contains("impression"))
    }

    @Test func aShowReadsTheProviderOnceAndEveryBeaconOfItUsesThatValue() async throws {
        let (ad, _, ads) = try await makeAd(Fixtures.ad(id: "p11i"))
        var reads = 0
        ads.playheadProvider = {
            reads += 1
            return TimeInterval(reads)   // advances on every read
        }
        try ad.show(in: harness.player.view)
        #expect(reads == 1)
        let shows = { self.harness.server.beacons.filter { $0.adId == "p11i" && ["creativeView", "iconView", "impression"].contains($0.event) } }
        #expect(await waitUntil { shows().count == 3 })
        let playheads = Set(shows().compactMap { $0.query["cph"] })
        #expect(playheads == ["00:00:01.000"], "creativeView, iconView and the impression: one moment, \(playheads)")
        try ad.dismiss()
    }

    @Test func aProviderThatDestroysAtAClickDropsTheClickAndKeepsDidEndLast() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.ad(id: "p11c"))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        try ad.show(in: harness.player.view)
        ads.playheadProvider = { [weak ads] in
            ads?.destroy()
            return 0
        }
        ad.bridge.noteTouch()   // a click counts only right after the viewer's touch
        send(ad, "ad.click", ["url": "https://brand.test/offer"])
        #expect(delegate.events == ["impression", "end:destroyed"], "the ad ended before the click was handled: \(delegate.events)")
        await sleepMs(50)
        #expect(opened.isEmpty, "a click on an ad the app destroyed first opens nothing")
    }

    @Test func aProviderThatEndsTheAdOnEveryReadIsReadOnce() async throws {
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o11r"))
        try ad.show(in: harness.player.view)
        var reads = 0
        ads.playheadProvider = { [weak ad] in
            reads += 1
            if reads < 20 { try? ad?.dismiss() }   // bounded only so a regression fails instead of overflowing the stack
            return 0
        }
        try ad.dismiss()
        #expect(reads == 1, "the provider's own dismiss reads nothing more: \(reads) reads")
        #expect(delegate.events == ["impression", "end:dismissed"], "ended once: \(delegate.events)")
    }

    @Test func aClickWhoseURLsAloneAskForThePlayheadReadsItOnce() async throws {
        let tracking = Fixtures.tracking(video: false, adId: "p11u").map { entry -> [String: Any] in
            var entry = entry
            entry["url"] = (entry["url"] as? String ?? "").replacingOccurrences(of: "&cph=[MEDIAPLAYHEAD]", with: "")
            return entry
        }
        let (ad, _, ads) = try await makeAd(Fixtures.ad(id: "p11u", extra: ["tracking": tracking]))
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(false) }   // the first fails: the fallback opens too
        try ad.show(in: harness.player.view)
        var reads = 0
        ads.playheadProvider = {
            reads += 1
            return TimeInterval(reads)   // advances on every read
        }
        ad.bridge.noteTouch()
        send(ad, "ad.click", ["url": "https://brand.test/a?cph=[MEDIAPLAYHEAD]", "fallbackUrl": "https://brand.test/b?cph=[MEDIAPLAYHEAD]"])
        #expect(await waitUntil { opened.count == 2 })
        let playheads = opened.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cph" }?.value }
        #expect(reads == 1 && playheads == ["00:00:01.000", "00:00:01.000"], "one read for the click and its fallback: \(reads), \(playheads)")
    }

    // MARK: Unparking

    @Test func aDestroyFromTheParkingWindowsHookWhileShowingEndsTheAdWithNothingShown() async throws {
        let hook = HookWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        Environment.parkingWindow = { hook }
        let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "o12d"))
        hook.onRemove = { ads.destroy() }
        try ad.show(in: harness.player.view)
        #expect(ad.wasShown && ad.hasEnded)
        #expect(delegate.events == ["end:destroyed"], "no impression for an ad that ended before it was on screen")
        #expect(harness.player.view.subviews.isEmpty && KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aShowFromTheParkingWindowsHookFindsTheSlotTaken() async throws {
        let hook = HookWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        Environment.parkingWindow = { hook }
        let (first, firstDelegate, _) = try await makeAd(Fixtures.overlayAd(id: "o12s"))
        let (second, secondDelegate, _) = try await makeAd(Fixtures.ad(id: "p12s"))
        let other = UIView(frame: CGRect(x: 0, y: 400, width: 390, height: 220))
        window.add(other)
        var nested: Error?
        hook.onRemove = { do { try second.show(in: other) } catch { nested = error } }
        try first.show(in: harness.player.view)
        guard case .anotherAdShowing? = nested as? VideoAdError else { Issue.record("expected anotherAdShowing, got \(String(describing: nested))"); return }
        #expect(first.wasShown && !second.wasShown && second.isReady)
        #expect(firstDelegate.events == ["impression"] && secondDelegate.events.isEmpty)
        #expect(other.subviews.isEmpty && KontextVideo.shared.adOnScreen === first)
        try first.dismiss()
    }

    @Test func aDestroyFromTheParkingWindowsHookEndsALinearAdBeforeUIKitPresentsIt() async throws {
        let hook = HookWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        Environment.parkingWindow = { hook }
        let (ad, delegate, ads) = try await makeAd(Fixtures.linearAd(id: "v12d"))
        hook.onRemove = { ads.destroy() }
        try ad.show(from: window.root)
        #expect(ad.wasShown && ad.hasEnded && ad.linearController == nil)
        #expect(window.root.presentedViewController == nil, "nothing was presented")
        #expect(delegate.events == ["end:destroyed"] && KontextVideo.shared.adOnScreen == nil)
    }

    // MARK: Hostile app code through every operation

    enum Hostile: String, CaseIterable {
        case destroyOwner, showThisAd, showAnotherAd, dismissThisAd
    }

    enum Operation: String, CaseIterable {
        case show, reject, dismiss, errorBeforeShow, errorAfterShow, click, videoStart, destroy
        var needsShown: Bool { ![.show, .reject, .errorBeforeShow].contains(self) }
    }

    /// Every operation, with a playhead provider that does something hostile the first time the SDK reads it.
    /// Whatever it does: at most one ad on screen, `didEnd` last and once, no impression for an ad that was not
    /// shown, a rejected or failed ad never shown, and no host left behind.
    @Test func hostileProviderThroughEveryOperationKeepsTheGuarantees() async throws {
        var opened: [URL] = []
        Environment.openURL = { url, completion in opened.append(url); completion(true) }
        let other = UIView(frame: CGRect(x: 0, y: 400, width: 390, height: 220))
        window.add(other)
        for hostile in Hostile.allCases {
            for operation in Operation.allCases {
                let label = "\(hostile.rawValue) during \(operation.rawValue)"
                let (ad, delegate, ads) = try await makeAd(Fixtures.overlayAd(id: "x-\(hostile.rawValue)-\(operation.rawValue)", creative: "video"))
                let (another, anotherDelegate, otherAds) = try await makeAd(Fixtures.ad(id: "y-\(hostile.rawValue)-\(operation.rawValue)"))
                if operation.needsShown {
                    try ad.show(in: harness.player.view)
                    if operation != .videoStart { send(ad, "video.start", ["playhead": 0]) }
                }
                var armed = true
                ads.playheadProvider = { [weak ads, weak ad, weak another] in
                    guard armed else { return 0 }
                    armed = false
                    switch hostile {
                    case .destroyOwner: ads?.destroy()
                    case .showThisAd: try? ad?.show(in: harness.player.view)
                    case .showAnotherAd: try? another?.show(in: other)
                    case .dismissThisAd: try? ad?.dismiss()
                    }
                    return 0
                }
                switch operation {
                case .show: try? ad.show(in: harness.player.view)
                case .reject: try? ad.reject()
                case .dismiss: try? ad.dismiss()
                case .errorBeforeShow, .errorAfterShow: send(ad, "ad.error", ["code": 405])
                case .click:
                    ad.bridge.noteTouch()
                    send(ad, "ad.click", ["url": "https://brand.test/\(label)"])
                case .videoStart: send(ad, "video.start", ["playhead": 0])
                case .destroy: ads.destroy()
                }
                check([(ad, delegate, harness.player.view), (another, anotherDelegate, other)], label)
                ads.playheadProvider = nil
                for shown in [ad, another] where shown.wasShown && !shown.hasEnded { try? shown.dismiss() }
                ads.destroy()
                otherAds.destroy()
                #expect(KontextVideo.shared.adOnScreen == nil, "\(label): the slot is free afterwards")
            }
        }
    }

    private func check(_ ads: [(ad: VideoAd, delegate: RecordingDelegate, view: UIView)], _ label: String) {
        let onScreen = ads.filter { $0.ad.wasShown && !$0.ad.hasEnded }
        #expect(onScreen.count <= 1, "\(label): at most one ad on screen")
        if let slot = KontextVideo.shared.adOnScreen {
            #expect(onScreen.contains { $0.ad === slot }, "\(label): the slot holds the ad on screen")
        }
        for (ad, delegate, view) in ads {
            let ends = delegate.events.filter { $0.hasPrefix("end:") }
            #expect(ends.count == (ad.wasShown && ad.hasEnded ? 1 : 0), "\(label): \(ad.id) ends once if shown: \(delegate.events)")
            if let last = delegate.events.last, !ends.isEmpty { #expect(last.hasPrefix("end:"), "\(label): didEnd is last: \(delegate.events)") }
            if delegate.events.contains("impression") { #expect(ad.wasShown, "\(label): an impression only for a shown ad") }
            if ad.invalidationReason != nil { #expect(!ad.wasShown, "\(label): an invalidated ad is never shown") }
            let hosts = view.subviews.filter { $0 is AdHostView }.count   // each view holds only its own ad
            #expect(hosts == (ad.wasShown && !ad.hasEnded ? 1 : 0), "\(label): \(ad.id) leaves no host behind")
        }
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

/// A parking window that runs the app's code when the SDK takes a WebView out of it, as an overridable
/// UIKit hook can.
@MainActor
private final class HookWindow: UIWindow {
    var onRemove: (() -> Void)?

    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        let action = onRemove
        onRemove = nil
        action?()
    }
}
