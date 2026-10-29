import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The on-screen clock on its own: it counts only active time, and tells about an elapsed duration once.
extension SerialSuites {
@Suite
@MainActor
struct ActiveTimeClockTests {
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
        let clock = ActiveTimeClock(duration: 0.01, adId: "clock-1") { elapsed += 1 }
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

    @Test func aStoppedClockNeverReportsAndKeepsItsTime() async {
        var elapsed = 0
        let clock = ActiveTimeClock(duration: 0.05, adId: "clock-2") { elapsed += 1 }
        clock.start(in: nil)
        await sleepMs(20)
        let counted = clock.stop()
        #expect(counted > 0 && clock.observers.isEmpty && clock.timer == nil)
        post(UIApplication.didBecomeActiveNotification)
        await sleepMs(100)
        #expect(elapsed == 0, "stopped before the duration ran out")
        #expect(clock.stop() == counted, "a second stop changes nothing")
    }

    @Test func inAWindowTheClockFollowsThatWindowsSceneNotTheApp() async throws {
        let host = TestWindow()
        defer { host.tearDown() }
        let scene = try #require(host.window.windowScene, "the test host has a window scene")
        let clock = ActiveTimeClock(duration: 60, adId: "clock-3") {}
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
