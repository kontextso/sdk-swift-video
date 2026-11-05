@testable import KontextVideoSDK
import Testing
import UIKit

/// Where an overlay or pause ad goes, as plain arithmetic: the room the safe area and insets leave, the scale,
/// the smallest scale, the rectangle, the app's insets cleaned.
@Suite @MainActor
struct AdGeometryTests {
    private let strip = VideoAd.Size(width: 320, height: 80)
    private let view = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func theRoomIsTheViewLessTheSafeAreaOrNothing() {
        #expect(AdGeometry.room(in: view, safeArea: UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 40))
            == CGRect(x: 20, y: 10, width: 340, height: 260))
        // Insets wider or taller than the view leave nothing, however large: an inverted rectangle is no room.
        #expect(AdGeometry.room(in: view, safeArea: UIEdgeInsets(top: 0, left: 200, bottom: 0, right: 200)) == nil)
        #expect(AdGeometry.room(in: view, safeArea: UIEdgeInsets(top: 0, left: 0, bottom: .greatestFiniteMagnitude, right: 0)) == nil)
        #expect(AdGeometry.room(in: view, safeArea: UIEdgeInsets(top: .infinity, left: 0, bottom: 0, right: 0)) == nil)
        #expect(AdGeometry.room(in: .zero, safeArea: .zero) == nil)
    }

    @Test func theScaleNeverEnlargesAndFollowsTheTighterSide() {
        #expect(AdGeometry.scale(toFit: strip, in: view) == 1, "room to spare: full size, never more")
        #expect(AdGeometry.scale(toFit: strip, in: CGRect(x: 0, y: 0, width: 160, height: 300)) == 0.5, "the width decides")
        #expect(AdGeometry.scale(toFit: strip, in: CGRect(x: 0, y: 0, width: 400, height: 20)) == 0.25, "the height decides")
        #expect(AdGeometry.smallestScale(of: strip) == 0.5)
        #expect(AdGeometry.smallestScale(of: VideoAd.Size(width: 320, height: 80, isScalable: false)) == 1)
    }

    @Test func theFrameIsCentredAtTheBottomByDefaultOrAtTheTop() {
        let bottom = AdGeometry.frame(of: strip, at: nil, in: view, safeArea: UIEdgeInsets(top: 0, left: 0, bottom: 44, right: 0))
        #expect(bottom == CGRect(x: 40, y: 300 - 44 - 80, width: 320, height: 80))
        #expect(AdGeometry.frame(of: strip, at: .bottom, in: view, safeArea: .zero) == CGRect(x: 40, y: 220, width: 320, height: 80))
        #expect(AdGeometry.frame(of: strip, at: .top, in: view, safeArea: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0))
            == CGRect(x: 40, y: 20, width: 320, height: 80))
    }

    @Test func aScalableAdShrinksToHalfAndNoFurtherAFixedOneNotAtAll() {
        // 200 wide: 62.5 %, allowed for a scalable ad, centred, rounded to whole points.
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 300)
        #expect(AdGeometry.frame(of: strip, at: .bottom, in: narrow, safeArea: .zero) == CGRect(x: 0, y: 250, width: 200, height: 50))
        #expect(AdGeometry.frame(of: VideoAd.Size(width: 320, height: 80, isScalable: false), at: .bottom, in: narrow, safeArea: .zero) == nil)
        // 159 wide is below half of 320: nothing.
        #expect(AdGeometry.frame(of: strip, at: .bottom, in: CGRect(x: 0, y: 0, width: 159, height: 300), safeArea: .zero) == nil)
        #expect(AdGeometry.frame(of: strip, at: .bottom, in: CGRect(x: 0, y: 0, width: 160, height: 300), safeArea: .zero) != nil, "exactly half fits")
    }

    @Test func theAppsInsetsAreCleanedAndAddedOnEverySide() {
        let cleaned = AdGeometry.cleaned(UIEdgeInsets(top: -5, left: .nan, bottom: 80, right: .infinity))
        #expect(cleaned == UIEdgeInsets(top: 0, left: 0, bottom: 80, right: 0), "negative and non-finite count as zero")
        let sum = AdGeometry.adding(UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4), to: UIEdgeInsets(top: 10, left: 20, bottom: 30, right: 40))
        #expect(sum == UIEdgeInsets(top: 11, left: 22, bottom: 33, right: 44))
    }
}
