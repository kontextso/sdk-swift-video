import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// Where an overlay or pause ad lands in a player that runs under the notch and the home indicator: cards
/// and strips stay inside the view's safe area, a full-screen pause ad fills the view.
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
        let host = try #require(player.subviews.last)
        #expect(host.frame == CGRect(x: 35, y: 844 - 34 - 90, width: 320, height: 90), "the strip ends where the home indicator begins")
        try ad.dismiss()
    }

    @Test func aTopPauseCardStaysBelowTheNotch() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6s"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player)
        let host = try #require(player.subviews.last)
        #expect(host.frame == CGRect(x: 45, y: 59, width: 300, height: 300), "the card starts where the notch's safe area ends")
        try ad.dismiss()
    }

    @Test func anAdFitsBetweenTheSideInsetsInLandscape() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.overlayAd(id: "o2l"))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 844, height: 390), insets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59))
        window.add(player)
        try ad.show(in: player)
        let host = try #require(player.subviews.last)
        #expect(host.frame == CGRect(x: 262, y: 390 - 21 - 90, width: 320, height: 90), "centred between the side insets, above the bottom one")
        try ad.dismiss()
    }

    @Test func aFullscreenPauseAdFillsThePlayerEvenUnderTheSafeArea() async throws {
        let (ad, _, _) = try await makeAd(Fixtures.ad(id: "p6f", position: "fullscreen", size: nil))
        let player = SafeAreaView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
        window.add(player)
        try ad.show(in: player)
        #expect(try #require(player.subviews.last).frame == player.bounds)
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
