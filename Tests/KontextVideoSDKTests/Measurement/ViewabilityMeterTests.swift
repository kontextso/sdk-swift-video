import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The viewability meter against real views in a real window: exposure geometry, the dwell for
/// `viewable`, the verdicts when the ad ends first or the view is gone.
extension SerialSuites {
@Suite
@MainActor
struct ViewabilityMeterTests {
    private let window = TestWindow(size: CGSize(width: 400, height: 800))

    init() {
        SDKHarness.reset()
        ViewabilityMeter.interval = 0.02
    }

    private func makeView(_ frame: CGRect) -> UIView {
        let view = UIView(frame: frame)
        window.add(view)
        return view
    }

    final class Sink {
        var exposures: [Double] = []
        var verdict: ViewabilityMeter.Verdict?
    }

    private func attach(_ meter: ViewabilityMeter) -> Sink {
        let sink = Sink()
        meter.onExposure = { percentage, _ in sink.exposures.append(percentage) }
        meter.onVerdict = { sink.verdict = $0 }
        return sink
    }

    @Test func fullyVisibleViewBecomesViewableAfterTheDwell() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 0.1)
        let sink = attach(meter)
        meter.start()
        #expect(await waitUntil { sink.verdict != nil })
        #expect(sink.verdict == .viewable)
        #expect(sink.exposures.first == 1)
        #expect(meter.verdict == .viewable)
    }

    @Test func aViewInAnInactiveAppIsExposedZeroSoThePagePausesItsVideo() async {
        defer { window.tearDown(); Environment.isApplicationActive = { true } }
        Environment.isApplicationActive = { false }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 0.1)
        let sink = attach(meter)
        meter.start()
        #expect(await waitUntil { !sink.exposures.isEmpty })
        await sleepMs(150)
        #expect(sink.exposures.allSatisfy { $0 == 0 }, "in the background the page hears exposure 0")
        #expect(sink.verdict == nil, "and no viewability clock runs")
        Environment.isApplicationActive = { true }
        #expect(await waitUntil { sink.verdict == .viewable }, "on return the ad counts again")
    }

    @Test func measuringGoesOnAfterTheVerdictAndTheViewLeavingTheWindowIsReported() async {
        defer { window.tearDown() }
        let view = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let meter = ViewabilityMeter(view: view, requiredSeconds: 0.1)
        let sink = attach(meter)
        var detached = 0
        meter.onDetached = { detached += 1 }
        meter.start()
        #expect(await waitUntil { sink.verdict == .viewable })
        view.removeFromSuperview()
        #expect(await waitUntil { sink.exposures.last == 0 }, "the page still hears exposure after the verdict")
        #expect(await waitUntil { detached >= 1 })
        #expect(await waitUntil { detached >= 3 }, "reported on every tick while it stays out")
        meter.stop()
    }

    @Test func viewHalfOffScreenReportsHalfExposure() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 300, y: 0, width: 200, height: 100)), requiredSeconds: 0.1)
        let sink = attach(meter)
        meter.start()
        #expect(await waitUntil { sink.verdict != nil })
        #expect(sink.exposures.first == 0.5)
        #expect(sink.verdict == .viewable, "50 % counts")
    }

    @Test func viewMostlyOffScreenNeverBecomesViewable() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 350, y: 0, width: 200, height: 100)), requiredSeconds: 0.05)
        let sink = attach(meter)
        meter.start()
        await sleepMs(200)
        #expect(sink.verdict == nil)
        #expect(sink.exposures.first == 0.25)
        meter.stop()
        #expect(sink.verdict == .notViewable)
    }

    @Test func stoppingBeforeTheDwellIsNotViewable() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 5)
        let sink = attach(meter)
        meter.start()
        await sleepMs(60)
        meter.stop()
        #expect(sink.verdict == .notViewable)
    }

    @Test func anAncestorThatClipsCutsTheExposure() async {
        defer { window.tearDown() }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))   // clipsToBounds by default
        window.add(scroll)
        let view = UIView(frame: CGRect(x: 0, y: 50, width: 200, height: 100))           // its lower half is outside the scroll view
        scroll.addSubview(view)
        let meter = ViewabilityMeter(view: view, requiredSeconds: 5)
        let sink = attach(meter)
        meter.start()
        await sleepMs(80)
        #expect(sink.exposures.first == 0.5, "the window would say 1: the scroll view clips half")
        scroll.isHidden = true
        await sleepMs(80)
        #expect(sink.exposures.last == 0, "a hidden ancestor hides the ad")
        meter.stop()
    }

    @Test func aViewInAScrolledParentIsMeasuredWhereItShows() {
        defer { window.tearDown() }
        // A scroll view at (0, 100), 320×300, holding the ad 320×80 at (40, 300).
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 320, height: 300))   // clipsToBounds by default
        scroll.contentSize = CGSize(width: 320, height: 2_000)
        window.add(scroll)
        let view = UIView(frame: CGRect(x: 40, y: 300, width: 320, height: 80))
        scroll.addSubview(view)
        // Scrolled down by 200: the ad sits at y 100–180 in the scroll view, whole in height; the scroll view
        // cuts the 40 pt it sticks out on the right.
        scroll.contentOffset = CGPoint(x: 0, y: 200)
        #expect(abs(ViewExposure.visibleShare(of: view) - 0.875) < 0.001, "280×80 of 320×80")
        // Scrolled by 350: the ad sits at y −50 to 30, only its bottom 30 rows show.
        scroll.contentOffset = CGPoint(x: 0, y: 350)
        #expect(abs(ViewExposure.visibleShare(of: view) - 0.328) < 0.001, "280×30 of 320×80")
    }

    @Test func aParentThatDoesNotClipLetsTheAdShowBeyondIt() {
        defer { window.tearDown() }
        // The ad, 120×80 at x 100 in a 160×200 parent, sticks out 60 pt; UIKit does not clip by default.
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 200))
        window.add(parent)
        let view = UIView(frame: CGRect(x: 100, y: 0, width: 120, height: 80))
        parent.addSubview(view)
        #expect(abs(ViewExposure.visibleShare(of: view) - 1) < 0.001, "all of it inside the window")
        parent.clipsToBounds = true
        #expect(abs(ViewExposure.visibleShare(of: view) - 0.5) < 0.001, "cut at the parent's edge: 60 of 120")
    }

    @Test func aScaledAncestorDoesNotShrinkTheShare() async {
        defer { window.tearDown() }
        let player = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        player.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)   // a mini player: on screen in full, at half size
        window.add(player)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        player.addSubview(view)
        let meter = ViewabilityMeter(view: view, requiredSeconds: 5)
        let sink = attach(meter)
        meter.start()
        await sleepMs(80)
        #expect(sink.exposures.first == 1, "the whole ad is visible, however small it is drawn")
        meter.stop()
    }

    @Test func stopIsFinalAndStartDoesNotRestart() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 0.05)
        let sink = attach(meter)
        meter.start()
        meter.stop()
        #expect(sink.verdict == .notViewable)
        meter.start()
        await sleepMs(120)
        #expect(sink.exposures.count == 1, "no tick after stop: \(sink.exposures)")
    }

    @Test func aGapBetweenTicksRestartsTheDwell() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 0.5)
        let sink = attach(meter)
        meter.start()
        await sleepMs(60)
        advanceClock(by: 3)   // the main thread stalled, or the app was suspended: nothing was measured meanwhile
        await sleepMs(60)
        #expect(sink.verdict == nil, "three seconds passed on the clock, but not continuously on screen")
        meter.stop()
        #expect(sink.verdict == .notViewable)
    }

    @Test func exposureIsReportedWhenThePlaceChangesAtTheSamePercentage() async {
        defer { window.tearDown() }
        let view = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let meter = ViewabilityMeter(view: view, requiredSeconds: 5)
        var rectangles: [CGRect] = []
        meter.onExposure = { _, rect in rectangles.append(rect) }
        meter.start()
        await sleepMs(80)
        view.frame.origin.x = 300          // the right half is off screen: 50 %
        await sleepMs(80)
        view.frame.origin.x = -100         // the left half is off screen: still 50 %, another rectangle
        await sleepMs(80)
        #expect(rectangles.count == 3 && rectangles[1] != rectangles[2], "the page hears where the visible part is: \(rectangles)")
        meter.stop()
    }

    @Test func exposureIsReportedOnlyWhenItChanges() async {
        defer { window.tearDown() }
        let view = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let meter = ViewabilityMeter(view: view, requiredSeconds: 5)
        let sink = attach(meter)
        meter.start()
        await sleepMs(120)
        #expect(sink.exposures == [1])
        view.frame.origin.x = 300
        await sleepMs(80)
        #expect(sink.exposures == [1, 0.5])
        meter.stop()
    }

    @Test func hiddenViewCountsAsNotExposed() async {
        defer { window.tearDown() }
        let view = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        view.isHidden = true
        let meter = ViewabilityMeter(view: view, requiredSeconds: 0.05)
        let sink = attach(meter)
        meter.start()
        await sleepMs(150)
        #expect(sink.exposures == [0])
        #expect(sink.verdict == nil)
        meter.stop()
    }

    @Test func leavingTheScreenResetsTheDwell() async {
        defer { window.tearDown() }
        let view = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let meter = ViewabilityMeter(view: view, requiredSeconds: 0.15)
        let sink = attach(meter)
        meter.start()
        await sleepMs(80)
        view.frame.origin.x = 1000
        await sleepMs(60)
        view.frame.origin.x = 0
        await sleepMs(100)
        #expect(sink.verdict == nil, "the dwell starts over after leaving the screen")
        #expect(await waitUntil { sink.verdict != nil })
        #expect(sink.verdict == .viewable)
    }

    @Test func viewGoneIsUndetermined() async {
        defer { window.tearDown() }
        var view: UIView? = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let meter = ViewabilityMeter(view: view!, requiredSeconds: 5)
        let sink = attach(meter)
        meter.start()
        view = nil
        await sleepMs(50)
        meter.stop()
        #expect(sink.verdict == .viewUndetermined)
    }

    @Test func verdictIsFinal() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 0.05)
        let sink = attach(meter)
        meter.start()
        #expect(await waitUntil { sink.verdict != nil })
        meter.stop()
        meter.start()
        await sleepMs(50)
        #expect(sink.verdict == .viewable)
    }

    // MARK: Controlled sampling: a frozen clock and ticks driven by hand

    /// A clock the test moves; the meter's timer is set so far apart that only the test's ticks count.
    final class Clock {
        var now: TimeInterval = 1000
    }

    private func frozen() -> Clock {
        let clock = Clock()
        Environment.now = { clock.now }
        ViewabilityMeter.interval = 10_000
        return clock
    }

    @Test func aViewOutOfSightInAnActiveSceneIsUnseenThenOffScreenAfterTheGrace() async {
        defer { window.tearDown() }
        let clock = frozen()
        let view = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let meter = ViewabilityMeter(view: view, requiredSeconds: 1)
        defer { meter.stop() }
        var seen: [Bool] = []
        var offScreen = 0
        meter.onSeen = { seen.append($0) }
        meter.onOffScreen = { offScreen += 1 }
        meter.start()   // seen, at 1000
        view.frame.origin.x = 10_000   // a feed cell swiped away: still in the window, nothing of it on screen
        clock.now = 1000.5
        meter.tick()
        clock.now = 1001.25
        meter.tick()
        #expect(seen == [true, false] && offScreen == 0, "unseen, within the grace")
        clock.now = 1001.5
        meter.tick()
        #expect(offScreen == 1, "a second out of sight")
        view.frame.origin.x = 0
        meter.tick()
        #expect(seen == [true, false, true] && offScreen == 1)
    }

    @Test func theDwellCountsToTheBoundaryExactly() async {
        defer { window.tearDown() }
        let clock = frozen()
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()   // the first tick, at 1000
        clock.now = 1000.999
        meter.tick()
        #expect(sink.verdict == nil, "just before")
        clock.now = 1001
        meter.tick()
        #expect(sink.verdict == .viewable, "exactly at the dwell")
    }

    @Test func aPauseBetweenTwoTicksRestartsTheDwell() async {
        defer { window.tearDown() }
        let clock = frozen()
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 2)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()            // playing from 1000
        clock.now = 1001.05
        meter.countsTime = false  // paused...
        clock.now = 1001.10
        meter.countsTime = true   // ...and playing again before any tick saw the pause
        clock.now = 1002
        meter.tick()
        #expect(sink.verdict == nil, "two seconds since the start, but not two continuous seconds of playback")
        clock.now = 1003.999
        meter.tick()
        #expect(sink.verdict == nil)
        clock.now = 1004
        meter.tick()
        #expect(sink.verdict == .viewable, "two seconds from the first tick after the pause")
    }

    @Test func aRotatedViewHalfOffTheWindowIsMeasuredOnItsShape() async {
        defer { window.tearDown() }
        let clock = frozen()
        // A 100×100 square turned 45°, its center 20 points beyond the window's left edge: a quarter of it
        // (25.7 %) is on screen. Its bounding box would claim three quarters.
        let view = makeView(CGRect(x: 0, y: 0, width: 100, height: 100))
        view.center = CGPoint(x: -20, y: 400)
        view.transform = CGAffineTransform(rotationAngle: .pi / 4)
        let meter = ViewabilityMeter(view: view, requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()
        let share = sink.exposures.last ?? -1
        #expect(share >= 0.25 && share <= 0.27, "\(share)")
        clock.now += 5
        meter.tick()
        #expect(sink.verdict == nil, "never viewable at a quarter")
    }

    @Test func aRotatedAncestorThatClipsIsMeasuredOnItsShape() async {
        defer { window.tearDown() }
        _ = frozen()
        // A clipping container turned 45°, holding a view twice its size: what shows is the container's
        // diamond, a quarter of the view.
        let container = UIView(frame: CGRect(x: 150, y: 350, width: 100, height: 100))
        container.clipsToBounds = true
        container.transform = CGAffineTransform(rotationAngle: .pi / 4)
        window.add(container)
        let view = UIView(frame: CGRect(x: -50, y: -50, width: 200, height: 200))
        container.addSubview(view)
        let meter = ViewabilityMeter(view: view, requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()
        let share = sink.exposures.last ?? -1
        #expect(share >= 0.24 && share <= 0.26, "\(share)")
    }

    @Test func justUnderHalfRoundsToHalfForThePageButNeverQualifies() async {
        defer { window.tearDown() }
        let clock = frozen()
        // 99.2 of 200 points wide on screen: 49.6 %.
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 300.8, y: 0, width: 200, height: 100)), requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()
        #expect(sink.exposures.last == 0.5, "reported rounded")
        clock.now += 10
        meter.tick()
        #expect(sink.verdict == nil, "the rule compares the real share")
    }

    @Test func anInactiveAdWindowInAnActiveAppIsNotExposed() async {
        defer { window.tearDown() }
        _ = frozen()
        Environment.isApplicationActive = { true }
        Environment.isWindowActive = { _ in false }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()
        #expect(sink.exposures.last == 0)
    }

    @Test func aViewCollapsedToZeroSizeOrATransparentWindowIsNotExposed() async {
        defer { window.tearDown() }
        _ = frozen()
        let collapsing = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let empty = ViewabilityMeter(view: collapsing, requiredSeconds: 1)
        defer { empty.stop() }
        let emptySink = attach(empty)
        empty.start()
        collapsing.frame = .zero
        empty.tick()
        #expect(emptySink.exposures == [1, 0])
        window.window.alpha = 0
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 0, y: 0, width: 200, height: 100)), requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()
        #expect(sink.exposures.last == 0)
        window.window.alpha = 1
    }

    @Test func transparencyMultipliesAlongTheAncestors() async {
        defer { window.tearDown() }
        _ = frozen()
        // Three ancestors at 0.1 each: 0.001 on screen, though none of them alone is below the cutoff.
        let outer = makeView(CGRect(x: 0, y: 0, width: 200, height: 100))
        let middle = UIView(frame: outer.bounds), inner = UIView(frame: outer.bounds), view = UIView(frame: outer.bounds)
        outer.addSubview(middle)
        middle.addSubview(inner)
        inner.addSubview(view)
        [outer, middle, inner].forEach { $0.alpha = 0.1 }
        let meter = ViewabilityMeter(view: view, requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()
        #expect(sink.exposures.last == 0, "\(sink.exposures)")
        #expect(!ViewExposure.canBeSeen(view), "show refuses it by the same rule")
        outer.alpha = 1
        middle.alpha = 1
        meter.tick()
        #expect(sink.exposures.last == 1, "one ancestor at 0.1 is still seen: \(sink.exposures)")
        #expect(ViewExposure.canBeSeen(view))
    }

    @Test func nothingIsReportedBeforeTheViewIsLaidOutInAWindowThenARealZeroIs() async {
        defer { window.tearDown() }
        _ = frozen()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let meter = ViewabilityMeter(view: view, requiredSeconds: 1)
        defer { meter.stop() }
        let sink = attach(meter)
        meter.start()   // not in a window yet: a linear ad's controller still on its way to the screen
        meter.tick()
        #expect(sink.exposures.isEmpty, "a 0 now would make the page pause the video it has just started")
        view.frame = .zero
        window.add(view)   // in the window, not laid out yet
        meter.tick()
        #expect(sink.exposures.isEmpty, "a view without a size has not been measured")
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        meter.tick()
        #expect(sink.exposures == [1], "the first real measurement")
        view.isHidden = true   // covered
        meter.tick()
        #expect(sink.exposures == [1, 0])
        view.isHidden = false
        meter.tick()
        view.removeFromSuperview()   // detached
        meter.tick()
        #expect(sink.exposures == [1, 0, 1, 0], "a real 0 after the first measurement goes out")
    }
}
}
