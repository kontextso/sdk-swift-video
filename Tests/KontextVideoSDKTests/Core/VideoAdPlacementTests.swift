import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// Where an overlay or pause ad lands in a player that runs under the notch and the home indicator: cards
/// and strips stay inside the view's safe area, a full-screen pause ad fills the view; a view the viewer
/// cannot see is refused; a shown ad follows its view when it resizes; the page hears no exposure before
/// the ad's view is laid out in a window.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdPlacementTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameProtocol.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
    /// Keeps the `VideoAds` alive for the test: the ad holds its owner weakly.
    private let owners = Owners()

    final class Owners {
        var all: [VideoAds] = []
    }

    /// A loaded ad, owned by a `VideoAds`.
    private func makeAd(_ payload: [String: Any]) async throws -> (VideoAd, VideoAds, VideoAds?) {
        _ = await harness.initialize()
        let ads = harness.player.ads(for: .init(id: "ep", language: "en"))
        owners.all.append(ads)
        let ad = VideoAd(descriptor: try Fixtures.descriptor(payload), owner: ads)
        ad.bridge.load()
        ad.bridge.receive(["adId": ad.id, "type": "ad.loaded"], from: sender)
        return (ad, ads, nil)
    }

    @Test func aBottomOverlayStaysAboveTheHomeIndicator() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o2s"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player)
        let frame = try #require(adFrame(in: player))
        #expect(frame == CGRect(x: 35, y: 844 - 34 - 90, width: 320, height: 90), "the strip ends where the home indicator begins")
        ad.dismiss()
    }

    @Test func anAdWhollyClippedWhereItIsPlacedIsNeverCounted() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-clip", position: "top"))
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        // A feed's viewport 100 high, scrolled so the 800 high player's middle shows and its top does not.
        let viewport = UIView(frame: CGRect(x: 0, y: 100, width: 390, height: 100))
        viewport.clipsToBounds = true
        window.add(viewport)
        let player = UIView(frame: CGRect(x: 0, y: -350, width: 390, height: 800))
        viewport.addSubview(player)
        try ad.show(in: player)
        #expect(delegate.endReasons == [.interrupted] && !delegate.events.contains("impression"), "\(delegate.events)")
        await sleepMs(80)
        #expect(!harness.server.beacons.contains { $0.adId == "o-clip" && $0.event == "impression" })
        #expect(KontextVideo.shared.adOnScreen == nil)
    }

    @Test func aPauseCardOutOfSightEndsAndFreesTheSlot() async throws {
        ViewabilityMeter.offScreenGrace = 0.2
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p-away"))
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.add(player)
        try ad.show(in: player)
        player.frame.origin.x = 10_000   // the feed moved on; the cell stays in the window
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "\(delegate.events)")
        #expect(KontextVideo.shared.adOnScreen == nil, "the next episode's ad can show")
    }

    @Test func aTopPauseCardStaysBelowTheNotch() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6s"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player)
        let frame = try #require(adFrame(in: player))
        #expect(frame == CGRect(x: 45, y: 59, width: 300, height: 300), "the card starts where the notch's safe area ends")
        ad.dismiss()
    }

    @Test func anAdFitsBetweenTheSideInsetsInLandscape() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o2l"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 844, height: 390), insets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59))
        window.add(player)
        try ad.show(in: player)
        let frame = try #require(adFrame(in: player))
        #expect(frame == CGRect(x: 262, y: 390 - 21 - 90, width: 320, height: 90), "centred between the side insets, above the bottom one")
        ad.dismiss()
    }

    @Test func aLinearAdSendsNoExposureBeforeItsViewIsLaidOutInAWindow() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.linearAd(id: "i30a"))
        var exposures: [Double] = []
        ad.bridge.onSend = { type, payload in if type == "ad.exposure", let value = payload["exposedPercentage"] as? Double { exposures.append(value) } }
        try ad.show(from: window.root)
        ad.linearController?.loadViewIfNeeded()
        // Presented before the WebView reached a window: the meter's first tick, run at once, has nothing
        // to measure (a second one would take the view as gone).
        ad.reachedScreen()
        ad.bridge.receive(["adId": ad.id, "type": "video.start", "playhead": 0], from: sender)
        #expect(exposures.isEmpty, "no exposure 0 before the first layout: \(exposures)")
        window.add(ad.bridge.webView)
        #expect(await waitUntil { exposures.first.map { $0 > 0 } == true }, "the first real measurement: \(exposures)")
        ad.bridge.webView.removeFromSuperview()
        #expect(await waitUntil { exposures.count >= 2 && exposures.last == 0 }, "a real 0 later still goes out: \(exposures)")
        ad.bridge.receive(["adId": ad.id, "type": "video.skip", "playhead": 1000], from: sender)
    }

    @Test func showRefusesAViewTheViewerCannotSee() async throws {
        let refused = { (ad: VideoAd, view: UIView, label: String) in
            do {
                try ad.show(in: view)
                Issue.record("\(label): expected cannotShowNow")
            } catch VideoAdError.cannotShowNow {
                #expect(ad.isReady && !ad.wasShown, "\(label): the ad stays ready")
            } catch {
                Issue.record("\(label): expected cannotShowNow, got \(error)")
            }
        }
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p10h"))
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        let hidden = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        hidden.isHidden = true
        window.add(hidden)
        refused(ad, hidden, "a hidden view")
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let child = UIView(frame: parent.bounds)
        parent.addSubview(child)
        parent.alpha = 0
        window.add(parent)
        refused(ad, child, "inside a transparent ancestor")
        let hiddenWindow = TestWindow()
        defer { hiddenWindow.tearDown() }
        let inHiddenWindow = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        hiddenWindow.add(inHiddenWindow)
        hiddenWindow.window.isHidden = true
        refused(ad, inHiddenWindow, "in a hidden window")
        let (fullscreen, _, _) = try await makeAd(Fixtures.ad(id: "p10z", position: "fullscreen", size: nil))
        let empty = UIView(frame: .zero)
        window.add(empty)
        refused(fullscreen, empty, "a view without an area, for an ad that fills it")
        #expect(delegate.events.isEmpty, "no impression")

        let (linear, _, _) = try await makeAd(Fixtures.linearAd(id: "v10h"))
        do {
            try linear.show(from: hiddenWindow.root)
            Issue.record("expected cannotShowNow")
        } catch VideoAdError.cannotShowNow {
            #expect(linear.isReady, "a controller in a hidden window cannot present it")
        }
    }

    @Test func aWindowItselfCanBeTheContainer() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p-win"))
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        // A window has no `window` of its own: it is its own, on screen while visible and its scene in front.
        try ad.show(in: window.window)
        #expect(ad.wasShown && window.window.subviews.contains { $0 is InlineAdView })
        ad.dismiss()
        #expect(delegate.endReasons == [.dismissed])
        let hiddenWindow = TestWindow()
        defer { hiddenWindow.tearDown() }
        hiddenWindow.window.isHidden = true
        let (hidden, _, _) = try await makeAd(Fixtures.ad(id: "p-win-h"))
        let refused = { (container: UIWindow, label: String) in
            do {
                try hidden.show(in: container)
                Issue.record("\(label): expected cannotShowNow")
            } catch VideoAdError.cannotShowNow {
            } catch {
                Issue.record("\(label): expected cannotShowNow, got \(error)")
            }
        }
        refused(hiddenWindow.window, "a hidden window is not on screen")
        Environment.isWindowActive = { _ in false }
        refused(window.window, "nor one whose scene is not in front")
        #expect(hidden.isReady && !hidden.wasShown)
    }

    @Test func showRefusesWhileTheAppOrTheViewsSceneIsNotInFront() async throws {
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        window.add(player)
        let (pause, _, _) = try await makeAd(Fixtures.ad(id: "p-front"))
        let (linear, _, _) = try await makeAd(Fixtures.linearAd(id: "v-front"))
        let delegate = RecordingDelegate()
        pause.delegate = delegate
        linear.delegate = delegate
        Environment.keyWindow = { self.window.window }
        let attempts: [(String, () throws -> Void)] = [
            ("show(in:)", { try pause.show(in: player) }),
            ("show(from:)", { try linear.show(from: self.window.root) }),
            ("show()", { try linear.show() }),
        ]
        // The app in the background or inactive (PiP only, background audio, the lock screen), then the app
        // active but the window's own scene not (Control Center pulled over it, an iPad scene behind).
        let states: [(String, () -> Void)] = [
            ("app not active", { Environment.isApplicationActive = { false } }),
            ("scene not active", {
                Environment.isApplicationActive = { true }
                Environment.isWindowActive = { _ in false }
            }),
        ]
        for (state, apply) in states {
            apply()
            for (call, show) in attempts {
                do {
                    try show()
                    Issue.record("\(state), \(call): expected cannotShowNow")
                } catch VideoAdError.cannotShowNow {
                } catch {
                    Issue.record("\(state), \(call): expected cannotShowNow, got \(error)")
                }
            }
        }
        #expect(pause.isReady && linear.isReady && !pause.wasShown && !linear.wasShown, "nothing spent: both stay ready")
        #expect(KontextVideo.shared.adOnScreen == nil && player.subviews.isEmpty && window.root.presentedViewController == nil)
        #expect(delegate.events.isEmpty)
        await sleepMs(100)
        let fired = harness.server.beacons.filter { ["p-front", "v-front"].contains($0.adId) }.map(\.event)
        #expect(!fired.contains("impression") && !fired.contains("creativeView"), "no impression for an ad nobody sees")
        // Back in front: the same ad shows.
        Environment.isWindowActive = { _ in true }
        try pause.show(in: player)
        #expect(pause.wasShown)
        pause.dismiss()
    }

    @Test func aShownAdFollowsTheViewWhenItResizesAndEndsWhenItNoLongerFits() async throws {
        let wide: [String: Any] = ["width": 728, "height": 90, "scalable": true, "maintainAspectRatio": true]
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "o2r", format: "overlay", position: "bottom", size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true], moreSizes: [wide], duration: 6000))
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.add(player)
        try ad.show(in: player)
        #expect(adFrame(in: player) == CGRect(x: 58, y: 300, width: 728, height: 90))
        #expect(player.hitTest(CGPoint(x: 10, y: 10), with: nil) === player, "touches outside the ad reach the player")
        player.frame.size = CGSize(width: 390, height: 220)
        player.layoutIfNeeded()
        #expect(adFrame(in: player) == CGRect(x: 0, y: 220 - 48, width: 390, height: 48), "the same variant, scaled to the narrower view")
        #expect(ad.chosenSize == VideoAd.Size(width: 728, height: 90), "the page was told that variant")
        player.frame.size = CGSize(width: 300, height: 220)
        player.layoutIfNeeded()
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "below 50 % it ends")
        #expect(player.subviews.isEmpty)
    }

    @Test func aContainerThatShrinksForAMomentAndGrowsBackKeepsTheAd() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "o2g", format: "overlay", position: "bottom",
                                                      size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true], duration: 6000))
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        window.add(player)
        try ad.show(in: player)
        let placed = adFrame(in: player)
        // A transition passes through a size the ad does not fit, then lands on a bigger one.
        player.frame.size = CGSize(width: 100, height: 20)
        player.layoutIfNeeded()
        await sleepMs(50)
        player.frame.size = CGSize(width: 390, height: 220)
        player.layoutIfNeeded()
        await sleepMs(Int(InlineScreen.unfitGrace * 1000) + 300)
        #expect(!ad.hasEnded && delegate.endReasons.isEmpty, "back to a fitting size within the grace: \(delegate.events)")
        #expect(adFrame(in: player) == placed)
        // A second misfit is watched for the same way: staying too small ends it.
        player.frame.size = CGSize(width: 100, height: 20)
        player.layoutIfNeeded()
        #expect(await waitUntil { delegate.endReasons == [.interrupted] }, "still too small after the grace: \(delegate.events)")
    }

    @Test func aFullscreenPauseAdFollowsAResizedPlayer() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6r", position: "fullscreen", size: nil))
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.add(player)
        try ad.show(in: player)
        player.frame.size = CGSize(width: 390, height: 220)
        player.layoutIfNeeded()
        #expect(adFrame(in: player) == player.bounds.inset(by: player.safeAreaInsets), "the resized player less its safe area")
        ad.dismiss()
    }

    @Test func theMinimumOfContainerTooSmallIncludesTheSafeArea() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6m"))   // 300×300, may shrink to 150×150
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        var minimum: CGSize?
        do {
            try ad.show(in: player)
            Issue.record("expected containerTooSmall")
        } catch VideoAdError.containerTooSmall(let size) {
            minimum = size
        }
        #expect(minimum == CGSize(width: 150, height: 150 + 59 + 34))
        player.frame.size = try #require(minimum)
        try ad.show(in: player)
        #expect(adFrame(in: player) == CGRect(x: 0, y: 59, width: 150, height: 150), "a view of the minimum holds it")
        ad.dismiss()
    }

    // MARK: The app's insets

    @Test func insetsAddToTheSafeAreaForAStripAndACard() async throws {
        let notch = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let (strip, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-in-b"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: notch)
        window.add(player)
        try strip.show(in: player, insets: UIEdgeInsets(top: 0, left: 0, bottom: 80, right: 0))
        #expect(adFrame(in: player) == CGRect(x: 35, y: 844 - 34 - 80 - 90, width: 320, height: 90), "80 points above the safe area's bottom")
        strip.dismiss()
        let (card, _, _) = try await makeAd(Fixtures.ad(id: "p-in-t"))
        try card.show(in: player, insets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
        #expect(adFrame(in: player) == CGRect(x: 45, y: 59 + 20, width: 300, height: 300), "20 points below the safe area's top")
        card.dismiss()
    }

    @Test func aFullscreenPauseAdIgnoresTheInsets() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p-in-f", position: "fullscreen", size: nil))
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.add(player)
        try ad.show(in: player, insets: UIEdgeInsets(top: 40, left: 10, bottom: 80, right: 10))
        #expect(adFrame(in: player) == player.bounds.inset(by: player.safeAreaInsets), "the safe area only, not the app's insets")
        ad.dismiss()
    }

    @Test func theInsetsStayThroughAResize() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-in-r"))
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.add(player)
        try ad.show(in: player, insets: UIEdgeInsets(top: 0, left: 0, bottom: 50, right: 0))
        #expect(adFrame(in: player) == CGRect(x: 262, y: 390 - 50 - 90, width: 320, height: 90))
        player.frame.size = CGSize(width: 390, height: 220)
        player.layoutIfNeeded()
        #expect(adFrame(in: player) == CGRect(x: 35, y: 220 - 50 - 90, width: 320, height: 90), "still 50 points above the bottom")
        ad.dismiss()
    }

    @Test func theMinimumOfContainerTooSmallIncludesTheInsets() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p-in-m"))   // 300×300, may shrink to 150×150
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        do {
            try ad.show(in: player, insets: insets)
            Issue.record("expected containerTooSmall")
        } catch VideoAdError.containerTooSmall(let minimum) {
            #expect(minimum == CGSize(width: 150, height: 150 + 59 + 34 + 20))
        }
    }

    @Test func insetsThatLeaveNoWidthOrNoHeightAreTooSmall() async throws {
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.add(player)
        // 390 − 600 and 844 − 1000: inverted rectangles, whose `CGRect.width`/`height` read 210 and 156.
        for (id, insets) in [("o-in-w", UIEdgeInsets(top: 0, left: 300, bottom: 0, right: 300)),
                             ("o-in-h", UIEdgeInsets(top: 500, left: 0, bottom: 500, right: 0))] {
            let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: id))
            do {
                try ad.show(in: player, insets: insets)
                Issue.record("\(id): expected containerTooSmall")
            } catch VideoAdError.containerTooSmall {}
            #expect(ad.isReady && player.subviews.isEmpty, "\(id): nothing shown, the ad stays ready")
        }
    }

    @Test func hugeFiniteInsetsAreTooSmallAndNeverTrap() async throws {
        let wide: [String: Any] = ["width": 728, "height": 90, "scalable": true, "maintainAspectRatio": true]
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "o-in-x", format: "overlay", position: "bottom", size: ["width": 320, "height": 90, "scalable": true, "maintainAspectRatio": true], moreSizes: [wide], duration: 6000))
        Logger.level = .debug   // after initialize, which sets its own: the size and dimension logs are built
        defer { Logger.level = .warning }
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.add(player)
        for insets in [UIEdgeInsets(top: 0, left: 1e20, bottom: 0, right: 0), UIEdgeInsets(top: 1e20, left: 0, bottom: 0, right: 0),
                       UIEdgeInsets(top: 0, left: 0, bottom: .greatestFiniteMagnitude, right: .greatestFiniteMagnitude)] {
            do {
                try ad.show(in: player, insets: insets)
                Issue.record("expected containerTooSmall for \(insets)")
            } catch VideoAdError.containerTooSmall(let minimum) {
                #expect(minimum.width.isFinite && minimum.height.isFinite, "a minimum the app can act on: \(minimum)")
            }
        }
        #expect(ad.isReady)
    }

    @Test func aHugeFiniteContainerNeverTraps() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "o-in-h", format: "overlay", position: "bottom",
                                                      size: ["width": 320, "height": 90, "scalable": false], duration: 6000))
        Logger.level = .debug   // after initialize: the size and dimension logs are built
        defer { Logger.level = .warning }
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 1e20, height: 10))   // far wider than an Int, too low
        window.add(player)
        do {
            try ad.show(in: player)
            Issue.record("expected containerTooSmall")
        } catch VideoAdError.containerTooSmall {}
        #expect(ad.isReady)
    }

    @Test func resizingUntilTheInsetsLeaveNoRoomEndsTheAd() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-in-z"))   // 320×90, may shrink to 160×45
        let delegate = RecordingDelegate()
        ad.delegate = delegate
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.add(player)
        try ad.show(in: player, insets: UIEdgeInsets(top: 0, left: 300, bottom: 0, right: 300))
        #expect(adFrame(in: player)?.width == 244, "the 244 points between the insets")
        player.frame.size = CGSize(width: 100, height: 390)   // 100 − 600: an inverted 500-point rectangle
        player.layoutIfNeeded()
        #expect(await waitUntil { delegate.endReasons == [.interrupted] })
        #expect(player.subviews.isEmpty)
    }

    @Test func aNegativeOrNonFiniteInsetCountsAsZero() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o-in-n"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player, insets: UIEdgeInsets(top: -10, left: .nan, bottom: .infinity, right: -5))
        #expect(adFrame(in: player) == CGRect(x: 35, y: 844 - 34 - 90, width: 320, height: 90))
        ad.dismiss()
    }

    @Test func aFullscreenPauseAdKeepsItsPageInsideTheSafeAreaOnBlack() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6f", position: "fullscreen", size: nil))
        // A landscape iPhone: the island's cutout on the left, the home indicator at the bottom.
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 844, height: 390), insets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59))
        window.add(player)
        try ad.show(in: player)
        #expect(try #require(adFrame(in: player)) == CGRect(x: 59, y: 0, width: 726, height: 369), "the page stays clear of the cutout")
        let host = try #require(player.subviews.compactMap { $0 as? InlineAdView }.first)
        #expect(host.frame == player.bounds && host.backgroundColor == .black, "the host fills the player in black")
        #expect(host.hitTest(CGPoint(x: 20, y: 200), with: nil) === host, "a touch by the cutout stays with the ad, not the player")
        ad.dismiss()
    }
}
}

/// A view with fixed safe-area insets, as a full-screen player on a notched iPhone has.
final class SafeAreaView: UIView {
    let insets: UIEdgeInsets
    init(frame: CGRect, insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: frame)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var safeAreaInsets: UIEdgeInsets { insets }
}
