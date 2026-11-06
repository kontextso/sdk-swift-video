import Foundation
@testable import KontextVideoSDK
import Testing

/// What an ads answer does to what a `VideoAds` holds, as `AdStore.plan` decides it over plain ids: the table of
/// the type's doc, row by row, for the pause format.
@Suite
struct AdStoreTests {
    private func response(pause entry: [String: Any]?) throws -> AdsResponse {
        let formats: [[String: Any]] = entry.map { [$0] } ?? []
        let object: [String: Any] = ["enabled": true, "formats": formats]
        return try JSONDecoder().decode(AdsResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func ad(_ id: String) -> [String: Any] {
        Fixtures.filledEntry(Fixtures.ad(id: id))
    }

    /// The pause format's steps, written short: `replace:Y`, `keep`, `drop`, `noFill:R`, `leftOut`, `ignoreUsed:Y`.
    private func pauseSteps(_ response: AdsResponse, held: String?, spent: Set<String> = []) -> [String] {
        let held = held.map { [AdFormat.pause: $0] } ?? [:]
        return AdStore.plan(response, held: held, spent: spent).compactMap { step -> String? in
            switch step {
            case .keep(.pause): "keep"
            case .replace(.pause, let payload): "replace:\(payload.id)"
            case .drop(.pause): "drop"
            case .noFill(.pause, let reason): "noFill:\(reason)"
            case .leftOut(.pause): "leftOut"
            case .ignoreUsed(.pause, let id): "ignoreUsed:\(id)"
            default: nil
            }
        }
    }

    @Test func theTable() throws {
        #expect(pauseSteps(try response(pause: ad("X")), held: nil) == ["replace:X"], "none + X")
        #expect(pauseSteps(try response(pause: ad("X")), held: "X") == ["keep"], "X + X: the re-served payload is ignored")
        #expect(pauseSteps(try response(pause: ad("Y")), held: "X") == ["drop", "replace:Y"], "X + Y")
        #expect(pauseSteps(try response(pause: Fixtures.noFillEntry("noAdMatch")), held: "X") == ["drop", "noFill:noAdMatch"], "X + no-fill")
        #expect(pauseSteps(try response(pause: ad("Y")), held: "X", spent: ["Y"]) == ["drop", "ignoreUsed:Y"], "X + Y already used: a no-fill alreadyUsed")
        #expect(pauseSteps(try response(pause: nil), held: nil) == ["leftOut"], "none + left out: a no-fill, reason unknown")
        #expect(pauseSteps(try response(pause: nil), held: "X") == ["keep"], "X + left out")
        #expect(pauseSteps(try response(pause: Fixtures.noFillEntry("frequencyCap")), held: nil) == ["noFill:frequencyCap"], "none + no-fill")
        #expect(pauseSteps(try response(pause: ad("Y")), held: nil, spent: ["Y"]) == ["ignoreUsed:Y"], "none + Y already used")
        let two: [String: Any] = ["format": "pause", "ads": [Fixtures.ad(id: "X1"), Fixtures.ad(id: "X2")]]
        #expect(pauseSteps(try response(pause: two), held: nil) == ["replace:X1"], "two valid ads: the first only")
        var broken = Fixtures.ad(id: "Z")
        broken["id"] = nil
        let allDropped: [String: Any] = ["format": "pause", "ads": [broken]]
        #expect(pauseSteps(try response(pause: allDropped), held: "X") == ["drop", "noFill:unknown"], "X + every ad malformed")
    }

    @Test func everyFormatIsPlannedOnItsOwnInFormatOrder() throws {
        let object: [String: Any] = ["enabled": true, "formats": [
            Fixtures.filledEntry(Fixtures.ad(id: "P2")),
            Fixtures.filledEntry(Fixtures.overlayAd(id: "O1")),
        ]]
        let answer = try JSONDecoder().decode(AdsResponse.self, from: JSONSerialization.data(withJSONObject: object))
        let steps = AdStore.plan(answer, held: [.overlay: "O1", .pause: "P1"], spent: []).map { step -> String in
            switch step {
            case .keep(let format): "keep:\(format)"
            case .replace(let format, let payload): "replace:\(format):\(payload.id)"
            case .drop(let format): "drop:\(format)"
            case .noFill(let format, let reason): "noFill:\(format):\(reason)"
            case .leftOut(let format): "leftOut:\(format)"
            case .ignoreUsed(let format, let id): "ignoreUsed:\(format):\(id)"
            }
        }
        #expect(steps == AdFormat.allCases.flatMap { format -> [String] in
            switch format {
            case .overlay: ["keep:overlay"]
            case .pause: ["drop:pause", "replace:pause:P2"]
            case .linear: ["leftOut:linear"]
            }
        }, "\(steps)")
    }
}
