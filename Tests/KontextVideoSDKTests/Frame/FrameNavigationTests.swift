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

    @Test func theOriginIsSchemeHostAndPortWhateverTheirCase() {
        // target, the page's origin
        let rows: [(String, Bool)] = [
            ("https://server.kontext.so/x", true), ("HTTPS://SERVER.KONTEXT.SO/x", true), ("https://server.kontext.so:443/x", true),
            ("http://server.kontext.so/x", false), ("https://server.kontext.so:444/x", false), ("https://cdn.server.kontext.so/x", false),
            ("https://kontext.so/x", false), ("https://server.kontext.so.evil.test/x", false), ("wss://server.kontext.so/x", false),
        ]
        for (target, ours) in rows {
            #expect(navigation.isSameOrigin(URL(string: target)!) == ours, "\(target)")
        }
        #expect(FrameNavigation.defaultPort(for: "HTTPS") == 443 && FrameNavigation.defaultPort(for: "Http") == 80)
        #expect(FrameNavigation.defaultPort(for: "wss") == 0 && FrameNavigation.defaultPort(for: nil) == 0)
    }

    @Test func schemesThatAreNoPageFailTheLoadAndAreNoClickOnceShown() throws {
        // Plain characters only: iOS 15's URL(string:) refuses `<` and `>`.
        for target in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "myapp://open"] {
            let url = try #require(URL(string: target), "\(target)")
            #expect(navigation.decision(to: url, isMainFrame: true, current: Self.page, phase: .loading) == .failLoad, "\(target) while loading")
            #expect(navigation.decision(to: url, isMainFrame: true, current: Self.page, phase: .shown) == .external, "\(target) once shown")
        }
        var touch = TouchGate()
        touch.note(now: 1)
        for target in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts"] {
            let click = FrameNavigation.click(to: URL(string: target)!, phase: .shown, touch: &touch, now: 1)
            #expect(click == nil, "\(target) is never opened")
        }
        let afterRefusals = FrameNavigation.click(to: URL(string: "https://brand.test")!, phase: .shown, touch: &touch, now: 1)
        #expect(afterRefusals != nil, "a refused navigation out keeps the touch")
    }

    @Test func aFragmentStaysWithinTheDocumentOnlyOnTheCurrentURL() {
        let fragment = URL(string: "https://server.kontext.so/frame/ad-1#endcard")!
        #expect(navigation.decision(to: fragment, isMainFrame: true, current: nil, phase: .shown) == .cancel, "no current document known")
        let elsewhere = URL(string: "https://server.kontext.so/frame/ad-2#endcard")!
        #expect(navigation.decision(to: elsewhere, isMainFrame: true, current: Self.page, phase: .shown) == .cancel, "another path")
        let query = URL(string: "https://server.kontext.so/frame/ad-1?v=2#endcard")!
        #expect(navigation.decision(to: query, isMainFrame: true, current: Self.page, phase: .shown) == .cancel, "another query")
        let empty = URL(string: "https://server.kontext.so/frame/ad-1#")!
        #expect(navigation.decision(to: empty, isMainFrame: true, current: Self.page, phase: .shown) == .allow, "an empty fragment is one")
        for phase in [FramePhase.loaded, .ended] {
            #expect(navigation.decision(to: fragment, isMainFrame: true, current: Self.page, phase: phase) == .allow, "\(phase)")
            #expect(navigation.decision(to: Self.page, isMainFrame: true, current: Self.page, phase: phase) == .cancel, "\(phase)")
        }
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
