import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The on-screen clock on its own: it counts only active time, and tells about an elapsed duration once.
extension SerialSuites {
@Suite
@MainActor
struct OnScreenTimeClockTests {
    init() {
        SDKHarness.reset()
        Environment.isApplicationActive = { true }
        Environment.isWindowActive = { _ in true }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    @Test func anElapsedDurationIsReportedOnceWhateverTheActivityDoesAfter() async {
        var elapsed = 0
        let clock = OnScreenTimeClock(duration: 0.01, bidId: "clock-1") { elapsed += 1 }
        defer { clock.stop() }
        clock.start(in: nil)
        #expect(await waitUntil { elapsed == 1 })
        // The app leaves and comes back after the duration ran out: the rest of the duration is zero.
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didBecomeActiveNotification)
        post(UIApplication.willResignActiveNotification)
        post(UIApplication.didBecomeActiveNotification)
        await sleepMs(100)
        #expect(elapsed == 1, "once, not again on every return")
        #expect(clock.timer == nil, "no timer waits for a second expiry")
    }

    @Test func aDurationLongerThanTheLongestWaitWaitsAgainForTheRest() async {
        OnScreenTimeClock.longestWait = 0.05   // a day, shortened
        defer { OnScreenTimeClock.longestWait = 86_400 }
        var elapsed = 0
        let clock = OnScreenTimeClock(duration: 0.3, bidId: "clock-long") { elapsed += 1 }
        defer { clock.stop() }
        clock.start(in: nil)
        #expect(await waitUntil { elapsed == 1 })
        #expect(clock.elapsed >= 0.3, "the whole duration, not one capped wait: \(clock.elapsed)")
    }

    @Test func itCountsOnlyWhileTheMeterSaysTheAdIsSeen() {
        let clock = OnScreenTimeClock(duration: nil, bidId: "clock-seen") {}
        defer { clock.stop() }
        clock.start(in: nil)
        #expect(clock.isCounting)
        clock.setSeen(false)
        #expect(!clock.isCounting && clock.isSceneActive, "out of sight in an active app: nothing counts")
        clock.setSeen(true)
        #expect(clock.isCounting)
    }

    @Test func aStoppedClockNeverReportsAndKeepsItsTime() async {
        var elapsed = 0
        // A duration no runner's delay reaches: a 50 ms one could run out during a 20 ms sleep on a busy runner.
        let clock = OnScreenTimeClock(duration: 60, bidId: "clock-2") { elapsed += 1 }
        clock.start(in: nil)
        await sleepMs(20)
        let counted = clock.stop()
        #expect(counted > 0 && clock.observers.isEmpty && clock.timer == nil)
        post(UIApplication.didBecomeActiveNotification)
        await sleepMs(100)
        #expect(elapsed == 0, "stopped before the duration ran out")
        #expect(clock.stop() == counted, "a second stop changes nothing")
    }

    @Test func aDurationOfZeroOrLessElapsesAtOnce() async {
        for duration in [0, -5, -.infinity] as [TimeInterval] {
            var elapsed = 0
            let clock = OnScreenTimeClock(duration: duration, bidId: "clock-zero") { elapsed += 1 }
            clock.start(in: nil)
            #expect(await waitUntil { elapsed == 1 }, "\(duration)")
            clock.stop()
        }
    }

    @Test func nothingCountsBeforeTheStartOrInAnInactiveApp() async {
        let clock = OnScreenTimeClock(duration: 0.01, bidId: "clock-idle") {}
        defer { clock.stop() }
        await sleepMs(20)
        #expect(clock.elapsed == 0 && !clock.isCounting && clock.timer == nil, "not started")
        Environment.isApplicationActive = { false }
        var elapsed = 0
        let inactive = OnScreenTimeClock(duration: 0.01, bidId: "clock-inactive") { elapsed += 1 }
        defer { inactive.stop() }
        inactive.start(in: nil)
        await sleepMs(50)
        #expect(!inactive.isCounting && !inactive.isSceneActive && inactive.elapsed == 0 && elapsed == 0, "the app was not in front")
        post(UIApplication.didBecomeActiveNotification)
        #expect(await waitUntil { elapsed == 1 }, "counted from the return")
    }

    @Test func aSecondStartAndAStartAfterStopDoNothing() {
        var resumes = 0
        let clock = OnScreenTimeClock(duration: nil, bidId: "clock-twice") {}
        clock.onResume = { resumes += 1 }
        clock.start(in: nil)
        let observers = clock.observers.count
        clock.start(in: nil)
        #expect(clock.observers.count == observers && resumes == 1, "one set of observers, one resume")
        clock.stop()
        clock.start(in: nil)
        #expect(clock.observers.isEmpty && !clock.isCounting && resumes == 1, "stopped for good")
        clock.setSeen(true)
        #expect(!clock.isCounting)
    }

    @Test func onResumeIsCalledOnEveryReturnToCounting() {
        var resumes = 0
        let clock = OnScreenTimeClock(duration: nil, bidId: "clock-resume") {}
        defer { clock.stop() }
        clock.onResume = { resumes += 1 }
        clock.start(in: nil)
        clock.setSeen(false)
        clock.setSeen(true)
        clock.setSeen(true)
        post(UIApplication.willResignActiveNotification)
        clock.setSeen(false)
        post(UIApplication.didBecomeActiveNotification)
        #expect(resumes == 2 && !clock.isCounting, "start, back into sight; not while still unseen")
        clock.setSeen(true)
        #expect(resumes == 3 && clock.isCounting)
    }

    @Test func inAWindowTheClockFollowsThatWindowsSceneNotTheApp() async throws {
        let host = TestWindow()
        defer { host.tearDown() }
        let scene = try #require(host.window.windowScene, "the test host has a window scene")
        let clock = OnScreenTimeClock(duration: 60, bidId: "clock-3") {}
        defer { clock.stop() }
        clock.start(in: host.window)
        #expect(clock.timer != nil, "counting: the scene is active")
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
        #expect(clock.timer != nil, "another scene of the app went inactive: this one still has the screen")
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        #expect(clock.timer == nil, "frozen with its own scene")
        let frozen = clock.elapsed
        await sleepMs(30)
        #expect(clock.elapsed == frozen)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        #expect(clock.timer != nil, "counting again when the scene is back")
    }
}
}
