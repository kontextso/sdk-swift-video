@testable import KontextVideoSDK
import Testing

/// What a linear ad does once UIKit confirmed its presentation, as a table: the runner never completes a modal
/// transition, so the re-dismissal of an ad ended mid-presentation is checked here as a rule.
@Suite
@MainActor
struct LinearPresentationTests {
    @Test func afterPresentedTable() {
        typealias Rule = LinearPresentation
        #expect(Rule.afterPresented(phase: .reserved, isBeingDismissed: false) == .reachScreen)
        #expect(Rule.afterPresented(phase: .ending(.destroyed), isBeingDismissed: false) == .dismissAgain,
                "ended mid-presentation: UIKit dropped the dismissal, ask again")
        #expect(Rule.afterPresented(phase: .ending(.destroyed), isBeingDismissed: true) == .nothing, "already on its way out")
        #expect(Rule.afterPresented(phase: .ended(.destroyed), isBeingDismissed: false) == .nothing)
        #expect(Rule.afterPresented(phase: .onScreen, isBeingDismissed: false) == .nothing, "the watchdog's second confirmation")
        #expect(Rule.afterPresented(phase: nil, isBeingDismissed: false) == .nothing, "the ad is gone")
    }
}
