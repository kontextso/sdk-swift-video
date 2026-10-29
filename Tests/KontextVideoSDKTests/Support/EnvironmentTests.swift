import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// The OS decisions behind `Environment`: which window is the key one, and when a window counts as active.
/// Serialized: it swaps the process-wide seams.
extension SerialSuites {
@Suite
@MainActor
struct EnvironmentTests {
    @Test func anAppWithoutScenesFindsItsWindowOnTheAppDelegate() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(Environment.keyWindow(scenes: [], delegateWindow: window) === window)
        #expect(Environment.keyWindow(scenes: [], delegateWindow: nil) == nil)
    }

    @Test func theKeyWindowComesFromTheActiveSceneThenAnInactiveOneNeverABackgroundOne() {
        let make = { UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let (active, inactive, background, delegate, plain) = (make(), make(), make(), make(), make())
        let keys: Set<ObjectIdentifier> = [ObjectIdentifier(active), ObjectIdentifier(inactive), ObjectIdentifier(background)]
        let isKey = { (window: UIWindow) in keys.contains(ObjectIdentifier(window)) }
        // Listed in an order that puts the wrong answers first.
        let all: [(state: UIScene.ActivationState, windows: [UIWindow])] = [(.background, [background]), (.foregroundInactive, [plain, inactive]), (.foregroundActive, [active])]
        #expect(Environment.keyWindow(scenes: all, delegateWindow: delegate, isKey: isKey) === active, "the scene receiving events first")
        #expect(Environment.keyWindow(scenes: Array(all.dropLast()), delegateWindow: delegate, isKey: isKey) === inactive, "then a foreground inactive one, its key window")
        #expect(Environment.keyWindow(scenes: [(.background, [background])], delegateWindow: delegate, isKey: isKey) == nil, "never a background scene, and not the delegate's while scenes exist")
        #expect(Environment.keyWindow(scenes: [(.foregroundActive, [plain])], delegateWindow: delegate, isKey: isKey) == nil, "an active scene without a key window gives none")
    }

    @Test func aWindowIsActiveOnlyWhenTheAppAndItsOwnSceneAre() {
        let cases: [(app: Bool, scene: UIScene.ActivationState?, active: Bool, why: String)] = [
            (true, .foregroundActive, true, "both active"),
            (true, .foregroundInactive, false, "the ad's scene inactive while the app is active (iPad)"),
            (true, .background, false, "the ad's scene in the background"),
            (false, .foregroundActive, false, "an inactive app shows nothing"),
            (true, nil, true, "a window without a scene follows the app"),
            (false, nil, false, "and so when the app is not active"),
        ]
        for item in cases {
            let active = Environment.isWindowActive(appActive: item.app, sceneState: item.scene)
            #expect(active == item.active, "\(item.why)")
        }
        // The hook uses the same rule with the live values.
        let window = TestWindow().window
        defer { Environment.reset() }
        Environment.isApplicationActive = { false }
        #expect(!Environment.isWindowActive(window))
    }
}
}
