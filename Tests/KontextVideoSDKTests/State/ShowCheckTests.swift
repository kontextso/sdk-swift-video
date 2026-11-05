@testable import KontextVideoSDK
import Testing

/// The show checks' order, as a table: each row makes one more check fail than the row below it, so the first
/// failing check wins.
@Suite
struct ShowCheckTests {
    @Test func theFirstFailingCheckWins() {
        typealias Facts = ShowCheck.Facts
        let rows: [(Facts, ShowCheck.Refusal?)] = [
            (Facts(wasShown: true, isOwnerGone: true, disabledReason: "off", invalidationReason: .rejected, isExpired: true,
                   playsAnotherEpisode: { true }, isSlotTaken: true, isLoaded: false, isContentPaused: true), .alreadyShown),
            (Facts(isOwnerGone: true, disabledReason: "off", invalidationReason: .rejected, isExpired: true,
                   playsAnotherEpisode: { true }, isSlotTaken: true, isLoaded: false, isContentPaused: true), .destroyed),
            (Facts(disabledReason: "off", invalidationReason: .rejected, isExpired: true,
                   playsAnotherEpisode: { true }, isSlotTaken: true, isLoaded: false, isContentPaused: true), .disabled(reason: "off")),
            (Facts(invalidationReason: .rejected, isExpired: true, playsAnotherEpisode: { true }, isSlotTaken: true, isLoaded: false,
                   isContentPaused: true), .invalidated(.rejected)),
            (Facts(isExpired: true, playsAnotherEpisode: { true }, isSlotTaken: true, isLoaded: false, isContentPaused: true), .expired),
            (Facts(playsAnotherEpisode: { true }, isSlotTaken: true, isLoaded: false, isContentPaused: true), .contentChanged),
            (Facts(isSlotTaken: true, isLoaded: false, isContentPaused: true), .anotherAdShowing),
            (Facts(isLoaded: false, isContentPaused: true), .notLoaded),
            (Facts(isContentPaused: true), .contentPaused),
            (Facts(), nil),
        ]
        for (index, (facts, expected)) in rows.enumerated() {
            #expect(ShowCheck.refusal(facts) == expected, "row \(index + 1)")
        }
    }

    @Test func thePlayerIsAskedOnlyWhenEveryCheckBeforeItPassed() {
        var asked = 0
        _ = ShowCheck.refusal(ShowCheck.Facts(wasShown: true, playsAnotherEpisode: { asked += 1; return false }))
        _ = ShowCheck.refusal(ShowCheck.Facts(isExpired: true, playsAnotherEpisode: { asked += 1; return false }))
        #expect(asked == 0)
        _ = ShowCheck.refusal(ShowCheck.Facts(playsAnotherEpisode: { asked += 1; return false }))
        #expect(asked == 1)
    }
}
