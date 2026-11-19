import Foundation
@testable import KontextVideoSDK
import StoreKit
import Testing
import UIKit

/// An overlay or pause ad under another screen of the app: a view controller presented over the one holding
/// the player ends it `.interrupted`, and refuses a show, as another Activity covering the player's does on
/// Android; an alert, a popover and the store sheet of a click leave it up.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdCoverTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps every `VideoAds` a test created alive for the test's duration: the ad holds its owner weakly.
    private let owners = Owners()

    init() {
        harness.player.view.frame.origin.y = 120
        window.add(harness.player.view)
    }

    /// A loaded ad, owned by a `VideoAds`, with a recording delegate.
    private func makeAd(_ payload: [String: Any]) async throws -> (VideoAd, RecordingDelegate, VideoAds) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        ad.bridge.receive(["bidId": ad.id, "type": "ad.loaded"], from: sender)
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        return (ad, delegate, ads)
    }

    private func beacons() async -> [String] {
        await beaconsSettled()
        return harness.server.beacons.map(\.event)
    }

    /// A player view in a window of its own, for a test that presents over it: the runner never finishes a
    /// dismissal, so the suite's window would stay covered.
    private func playerInFreshWindow() -> (TestWindow, UIView) {
        let screen = TestWindow()
        let player = UIView(frame: CGRect(x: 0, y: 120, width: 390, height: 300))
        screen.add(player)
        return (screen, player)
    }

    /// Another screen of the app presented over the player's controller ends an overlay or pause ad
    /// `.interrupted`, as another Activity covering the player's does on Android: a sheet (the presenter's view
    /// stays in the window, so nothing else would notice), a form sheet, a full-screen cover.
    @Test(arguments: [UIModalPresentationStyle.pageSheet, .formSheet, .fullScreen, .overFullScreen])
    func aScreenPresentedOverTheInlineAdsControllerEndsItInterrupted(_ style: UIModalPresentationStyle) async throws {
        for payload in [Fixtures.overlayAd(id: "o-sheet-\(style.rawValue)"), Fixtures.ad(id: "p-sheet-\(style.rawValue)")] {
            // A window each: the runner never finishes a dismissal.
            let (screen, player) = playerInFreshWindow()
            defer { screen.tearDown() }
            let (ad, delegate, _) = try await makeAd(payload)
            try ad.show(in: player)
            #expect(await waitUntil { delegate.events.contains("impression") })
            let sheet = UIViewController()
            sheet.modalPresentationStyle = style
            screen.root.present(sheet, animated: false)
            #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "\(ad.format), style \(style.rawValue): \(delegate.events)")
            #expect(KontextVideo.shared.adOnScreen == nil && !player.subviews.contains { $0 is InlineAdView }, "the slot is free")
            await sleepMs(100)
            #expect(delegate.endReasons == [.interrupted], "once")
        }
    }

    /// The player's controller inside a container (a navigation or tab controller): a screen the container
    /// presents covers it too.
    @Test func aScreenPresentedOverAParentOfThePlayersControllerEndsTheAd() async throws {
        let player = UIViewController()
        window.root.addChild(player)
        window.add(player.view)
        player.view.frame = CGRect(x: 0, y: 120, width: 390, height: 300)
        player.didMove(toParent: window.root)
        let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-parent"))
        try ad.show(in: player.view)
        window.root.present(UIViewController(), animated: false)
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "\(delegate.events)")
    }

    /// An alert, a popover or the App Store sheet of a click leave the ad up: the player stays in view around
    /// the first two, as around a dialog on Android; the sheet is the ad's own click, which on Android leaves the
    /// app and only freezes the ad.
    @Test func anAlertAPopoverOrTheStoreSheetOverThePlayerLeaveTheAdUp() async throws {
        // The rule itself, on every OS: the iOS 15 runner does not always complete one of these presentations.
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .pageSheet
        let lightPopover = UIViewController()
        lightPopover.modalPresentationStyle = .popover
        #expect(InlineScreen.hidesThePlayer(sheet) && InlineScreen.hidesThePlayer(UIViewController()))
        #expect(!InlineScreen.hidesThePlayer(UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)))
        #expect(!InlineScreen.hidesThePlayer(lightPopover) && !InlineScreen.hidesThePlayer(SKStoreProductViewController()))
        // And on screen, where the runner presents them.
        let alert = UIAlertController(title: "Alert", message: nil, preferredStyle: .alert)
        let popover = UIViewController()
        popover.modalPresentationStyle = .popover
        var shownOver = 0
        for (index, (cover, label)) in [(alert as UIViewController, "an alert"), (popover, "a popover"), (SKStoreProductViewController(), "the store sheet")].enumerated() {
            let (screen, player) = playerInFreshWindow()
            defer { screen.tearDown() }
            popover.popoverPresentationController?.sourceView = screen.root.view
            popover.popoverPresentationController?.sourceRect = CGRect(x: 0, y: 0, width: 10, height: 10)
            let (ad, delegate, _) = try await makeAd(Fixtures.ad(id: "p-light-\(index)"))
            try ad.show(in: player)
            screen.root.present(cover, animated: false)
            guard await waitUntil(2, { screen.root.presentedViewController === cover }) else {
                ad.dismiss()
                continue
            }
            await sleepMs(Int(ViewabilityMeter.interval * 1000) * 3)
            #expect(!ad.hasEnded && delegate.endReasons.isEmpty, "\(label): the ad stays up")
            shownOver += 1
            ad.dismiss()
        }
        #expect(shownOver >= 1, "the runner presented one at least")
    }

    /// A show under a screen the app presented over the player's: refused, as a show into a stopped Activity is on
    /// Android; nothing fired, the ad ready for the player's return.
    @Test func showUnderAScreenPresentedOverThePlayerThrowsAndKeepsTheAd() async throws {
        let (ad, delegate, _) = try await makeAd(Fixtures.overlayAd(id: "o-under"))
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .pageSheet
        window.root.present(sheet, animated: false)
        #expect(await waitUntil { self.window.root.presentedViewController === sheet })
        do { try ad.show(in: harness.player.view) } catch VideoAdError.cannotShowNow {} catch { Issue.record("expected cannotShowNow, got \(error)") }
        #expect(ad.isReady && !ad.wasShown && KontextVideo.shared.adOnScreen == nil && delegate.events.isEmpty)
        #expect(!(await beacons()).contains { $0 != "loaded" }, "nothing fired")
        // Not spent: it shows where nothing covers the player (another window: the runner never finishes a dismissal).
        let (screen, player) = playerInFreshWindow()
        defer { screen.tearDown() }
        try ad.show(in: player)
        #expect(ad.wasShown && !ad.hasEnded)
        ad.dismiss()
    }
}
}
