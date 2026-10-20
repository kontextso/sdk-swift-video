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
        #expect(await waitUntil(1) { sink.verdict != nil })
        #expect(sink.verdict == .viewable)
        #expect(sink.exposures.first == 1)
        #expect(meter.verdict == .viewable)
    }

    @Test func viewHalfOffScreenReportsHalfExposure() async {
        defer { window.tearDown() }
        let meter = ViewabilityMeter(view: makeView(CGRect(x: 300, y: 0, width: 200, height: 100)), requiredSeconds: 0.1)
        let sink = attach(meter)
        meter.start()
        #expect(await waitUntil(1) { sink.verdict != nil })
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
        #expect(await waitUntil(1) { sink.verdict != nil })
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
        #expect(await waitUntil(1) { sink.verdict != nil })
        meter.stop()
        meter.start()
        await sleepMs(50)
        #expect(sink.verdict == .viewable)
    }
}
}
