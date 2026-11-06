import Foundation
@testable import KontextVideoSDK
import Testing

/// `FrameNavigation` as tables over plain values: what a top-level navigation may do in each phase, and a
/// navigation out as a click after a touch.
@Suite
@MainActor
struct FrameNavigationTests {
    private static let page = URL(string: "https://server.kontext.so/frame/ad-1")!
    private let navigation = FrameNavigation(pageURL: Self.page)

    @Test func navigationsBeforeAndAfterThePageIsReady() {
        let anchored = URL(string: "https://server.kontext.so/frame/ad-1#endcard")!
        // target, main frame, reload, submission, loading, shown
        let rows: [(String, Bool, Bool, Bool, FrameNavigation.Decision, FrameNavigation.Decision)] = [
            ("https://server.kontext.so/frame/ad-1/v2", true, false, false, .allow, .cancel),
            ("https://server.kontext.so:443/next", true, false, false, .allow, .cancel),
            ("about:blank", true, false, false, .allow, .cancel),
            ("https://brand.test/", true, false, false, .failLoad, .external),
            ("https://server.kontext.so/frame/ad-1#endcard", true, false, false, .allow, .allow),
            ("https://server.kontext.so/frame/ad-1", true, true, false, .allow, .cancel),
            ("https://server.kontext.so/frame/ad-1#submitted", true, false, true, .allow, .cancel),
            ("https://anything.test/creative", false, false, false, .allow, .allow),
        ]
        for (target, isMainFrame, isReload, isSubmission, loading, shown) in rows {
            for (phase, expected) in [(FramePhase.loading, loading), (.shown, shown)] {
                let decision = navigation.decision(to: URL(string: target)!, isMainFrame: isMainFrame, isReload: isReload,
                                                   isSubmission: isSubmission, current: Self.page, phase: phase)
                #expect(decision == expected, "\(target) in \(phase)")
            }
        }
        #expect(navigation.decision(to: anchored, isMainFrame: true, current: anchored, phase: .shown) == .allow, "the same fragment again")
    }

    @Test func aNavigationOutIsAClickOnlyWhenShownAllowedAndTouched() {
        let target = URL(string: "https://brand.test")!
        var touch = TouchGate()
        touch.note(now: 10)
        let loading = FrameNavigation.click(to: target, phase: .loaded, touch: &touch, now: 10)
        #expect(loading == nil, "not shown yet")
        let refused = FrameNavigation.click(to: URL(string: "tel:+15555550100")!, phase: .shown, touch: &touch, now: 10)
        #expect(refused == nil, "a refused scheme")
        let click = FrameNavigation.click(to: target, phase: .shown, touch: &touch, now: 10)
        guard case .click(let url, let fallback, let area)? = click else { Issue.record("expected a click, the touch was left for this"); return }
        #expect(url == target && fallback == nil && area == .creative)
        let again = FrameNavigation.click(to: target, phase: .shown, touch: &touch, now: 10)
        #expect(again == nil, "the touch was spent")
    }
}
