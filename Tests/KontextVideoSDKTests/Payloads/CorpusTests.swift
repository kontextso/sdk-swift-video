import Foundation
@testable import KontextVideoSDK
import Testing

/// The shared corpus of malformed server answers (`Corpus/`, a copy of the `video-sdk-corpus` repo; its README
/// has the format): every case through the decoder production uses, against the outcome both SDKs must
/// produce. The Kotlin SDK runs the same files. A case is a JSON file; nothing here changes to add one.
struct CorpusTests {
    @Test func theCorpusIsHere() throws {
        let version = try String(contentsOf: CorpusCase.root.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(!version.isEmpty)
        #expect(CorpusCase.load("ads").count > 1 && CorpusCase.load("config").count > 1, "the corpus copy is missing or empty")
    }

    @Test(arguments: CorpusCase.load("ads"))
    func adsAnswer(_ corpusCase: CorpusCase) throws {
        try corpusCase.check { try Self.outcome(of: APIClient.decode(AdsResponse.self, from: $0)) }
    }

    @Test(arguments: CorpusCase.load("config"))
    func configAnswer(_ corpusCase: CorpusCase) throws {
        try corpusCase.check { data in
            switch try APIClient.decode(ConfigResponse.self, from: data) {
            case .enabled(let reporting): return ["result": "enabled", "reportDebug": reporting.reportDebug, "reportErrors": reporting.reportErrors]
            case .disabled(let reason): return ["result": "disabled", "disabledReason": reason]
            }
        }
    }

    /// The answer as `VideoAds` takes it: each format's first ad, its no-fill reason (`apply`), or nothing,
    /// and the error report's detail for each dropped ad (`reportDroppedAds`). Every format the SDK knows,
    /// `pauseFullscreen` included; a case compares only the formats its `expect` names.
    private static func outcome(of response: AdsResponse) -> [String: Any] {
        guard case .formats(let results) = response else {
            guard case .disabled(let reason) = response else { return [:] }
            return ["result": "disabled", "disabledReason": reason]
        }
        var formats: [String: Any] = [:]
        var ads: [String: Any] = [:]
        for format in AdFormat.allCases {
            guard let result = response.result(for: format) else {
                formats[format.rawValue] = "absent"
                continue
            }
            guard let ad = result.ads.first else {
                formats[format.rawValue] = "noFill:\(result.noFillReason ?? .unknown)"
                continue
            }
            formats[format.rawValue] = "ad:\(ad.id)"
            var facts: [String: Any] = ["trackingCount": ad.tracking.count, "durationMillis": NSNull(), "skipOffsetMillis": NSNull(), "sizesCount": 0]
            switch ad.details {
            case .overlay(_, let sizes, let duration):
                facts["sizesCount"] = sizes.count
                facts["durationMillis"] = duration ?? NSNull()
            case .pause(_, let sizes):
                facts["sizesCount"] = sizes.count
            case .pauseFullscreen:
                break
            case .linear(let duration, let skipOffset):
                facts["durationMillis"] = duration
                facts["skipOffsetMillis"] = skipOffset ?? NSNull()
            }
            ads[format.rawValue] = facts
        }
        let reports = results.flatMap { result in result.dropped.map { "\(result.format.rawValue):\($0)" } }
        return ["result": "formats", "formats": formats, "decodeReports": reports, "ads": ads]
    }
}

/// One corpus file: the server's answer (inline, from a raw file, plus the generated parts) and what must come of it.
struct CorpusCase: Sendable, CustomTestStringConvertible {
    let name: String
    let file: URL

    var testDescription: String { name }

    static let root: URL = Bundle.module.resourceURL!.appendingPathComponent("Corpus")

    /// The cases of one route's folder (`Ads/`, `Config/`), named by route (`ads/…`); `*.raw.json` are answers a
    /// case points to, not cases.
    static func load(_ route: String) -> [CorpusCase] {
        let folder = root.appendingPathComponent(route.capitalized)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".raw.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { CorpusCase(name: "\(route)/\($0.deletingPathExtension().lastPathComponent)", file: $0) }
    }

    /// Decodes the answer with `decode` (a throw is `malformed`) and compares with `expect`: every key it
    /// names, `ads` per format and per fact listed, `decodeReports` in any order. A known difference between
    /// the SDKs is not compared here: the corpus README says who decides it.
    func check(_ decode: (Data) throws -> [String: Any]) throws {
        let spec = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], "\(name) is not a JSON object")
        let expect = try #require(spec["expect"] as? [String: Any], "\(name) has no expect")
        if let difference = spec["knownDifference"] as? String {
            withKnownIssue("\(name) skipped, a known difference between the SDKs: \(difference)") {
                Issue.record("not compared")
            }
            return
        }
        let actual: [String: Any]
        do {
            actual = try decode(try answer(spec))
        } catch is DecodingError {
            actual = ["result": "malformed"]
        }
        if #unavailable(iOS 17), Self.olderDecoderDifferences.contains(name) {
            withKnownIssue("\(name): the decoder before iOS 17 differs", isIntermittent: true) { compare(expect, actual) }
            return
        }
        compare(expect, actual)
    }

    /// Cases the platform's decoder before iOS 17 answers differently, a malformed answer either way: a number
    /// past `Double`'s range fails the whole answer, not only its field, and a missing or mistyped field in a
    /// nested object is reported by its own key only (`to`, not `trigger.to`).
    private static let olderDecoderDifferences: Set<String> = [
        "ads/price-overflow", "ads/tracking-offset-1e400", "ads/trigger-window-without-to", "ads/url-number",
    ]

    private func answer(_ spec: [String: Any]) throws -> Data {
        if let raw = spec["responseFile"] as? String {
            return try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(raw))
        }
        var response = try #require(spec["response"], "\(name) has no response")
        for step in spec["generate"] as? [[String: Any]] ?? [] {
            let path = try #require(step["path"] as? [Any], "\(name): a generate step has no path")
            let count = try #require(step["count"] as? Int, "\(name): a generate step has no count")
            let value: Any = (step["repeat"] as? String).map { String(repeating: $0, count: count) } ?? Array(repeating: step["repeat"] ?? NSNull(), count: count)
            response = Self.setting(value, at: path[...], in: response)
        }
        return try JSONSerialization.data(withJSONObject: response, options: .fragmentsAllowed)
    }

    /// `root` with `value` at `path` (object keys and array indexes).
    private static func setting(_ value: Any, at path: ArraySlice<Any>, in root: Any) -> Any {
        guard let step = path.first else { return value }
        if let key = step as? String, var object = root as? [String: Any] {
            object[key] = setting(value, at: path.dropFirst(), in: object[key] ?? NSNull())
            return object
        }
        if let index = step as? Int, var array = root as? [Any], array.indices.contains(index) {
            array[index] = setting(value, at: path.dropFirst(), in: array[index])
            return array
        }
        return root
    }

    private func compare(_ expect: [String: Any], _ actual: [String: Any]) {
        for (key, expected) in expect {
            switch key {
            case "decodeReports":
                let wanted = (expected as? [String] ?? []).sorted()
                let got = (actual[key] as? [String] ?? []).sorted()
                #expect(wanted == got, "\(name): decodeReports")
            case "formats":
                for (format, outcome) in expected as? [String: String] ?? [:] {
                    let got = (actual["formats"] as? [String: Any])?[format] as? String
                    // `ad` alone: an ad, whatever its id (a generated one).
                    let matches = outcome == "ad" ? got?.hasPrefix("ad:") == true : got == outcome
                    #expect(matches, "\(name): \(format) is \(got ?? "nil"), expected \(outcome)")
                }
            case "ads":
                for (format, facts) in expected as? [String: [String: Any]] ?? [:] {
                    let got = (actual["ads"] as? [String: [String: Any]])?[format]
                    for (fact, value) in facts {
                        let gotValue = got?[fact]
                        #expect(Self.same(value, gotValue), "\(name): \(format).\(fact) is \(String(describing: gotValue)), expected \(value)")
                    }
                }
            default:
                #expect(Self.same(expected, actual[key]), "\(name): \(key) is \(String(describing: actual[key])), expected \(expected)")
            }
        }
    }

    /// JSON scalars compared as JSON compares them: numbers by value, `null` as `NSNull`.
    private static func same(_ lhs: Any, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (is NSNull, is NSNull), (is NSNull, nil): return true
        case (let lhs as Bool, let rhs as Bool): return lhs == rhs
        case (let lhs as String, let rhs as String): return lhs == rhs
        case (let lhs as NSNumber, let rhs as NSNumber): return lhs == rhs
        default: return false
        }
    }
}
