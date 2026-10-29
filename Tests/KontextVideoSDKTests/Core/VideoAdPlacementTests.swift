import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// Where an overlay or pause ad lands in a player that runs under the notch and the home indicator: cards
/// and strips stay inside the view's safe area, a full-screen pause ad fills the view; a view the viewer
/// cannot see is refused; a shown ad follows its view when it resizes.
extension SerialSuites {
@Suite
@MainActor
struct VideoAdPlacementTests {
    private let harness = SDKHarness()
    private let window = TestWindow()
    private let sender = FrameBridge.Sender(isMainFrame: true, scheme: "kontext-test", host: "frames", port: 0)
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
        try ad.dismiss()
    }

    @Test func aTopPauseCardStaysBelowTheNotch() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6s"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player)
        let frame = try #require(adFrame(in: player))
        #expect(frame == CGRect(x: 45, y: 59, width: 300, height: 300), "the card starts where the notch's safe area ends")
        try ad.dismiss()
    }

    @Test func anAdFitsBetweenTheSideInsetsInLandscape() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o2l"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 844, height: 390), insets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59))
        window.add(player)
        try ad.show(in: player)
        let frame = try #require(adFrame(in: player))
        #expect(frame == CGRect(x: 262, y: 390 - 21 - 90, width: 320, height: 90), "centred between the side insets, above the bottom one")
        try ad.dismiss()
    }

    @Test func showRefusesAViewTheViewerCannotSee() async throws {
        let refused = { (ad: VideoAd, view: UIView, label: String) in
            do {
                try ad.show(in: view)
                Issue.record("\(label): expected presenterUnavailable")
            } catch VideoAdError.presenterUnavailable {
                #expect(ad.isReady && !ad.wasShown, "\(label): the ad stays ready")
            } catch {
                Issue.record("\(label): expected presenterUnavailable, got \(error)")
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
            Issue.record("expected presenterUnavailable")
        } catch VideoAdError.presenterUnavailable {
            #expect(linear.isReady, "a controller in a hidden window cannot present it")
        }
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

    @Test func aFullscreenPauseAdFollowsAResizedPlayer() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6r", position: "fullscreen", size: nil))
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.add(player)
        try ad.show(in: player)
        player.frame.size = CGSize(width: 390, height: 220)
        player.layoutIfNeeded()
        #expect(adFrame(in: player) == player.bounds)
        try ad.dismiss()
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
        try ad.dismiss()
    }

    @Test func aFullscreenPauseAdFillsThePlayerEvenUnderTheSafeArea() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6f", position: "fullscreen", size: nil))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player)
        #expect(try #require(adFrame(in: player)) == player.bounds)
        try ad.dismiss()
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
