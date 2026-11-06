import Foundation
@testable import KontextVideoSDK
import Testing

/// `ReportFormat`, pure: the byte cap on every string a report keeps, a state value as JSON and as text, the timestamp.
@Suite
struct ReportFormatTests {
    @Test func theCapIsInBytesAtAScalarBoundary() {
        let limit = ReportFormat.maxFieldLength
        #expect(ReportFormat.capped("").isEmpty)
        #expect(ReportFormat.capped(String(repeating: "a", count: limit)) == String(repeating: "a", count: limit), "exactly the limit stays")
        #expect(ReportFormat.capped(String(repeating: "a", count: limit + 1)) == String(repeating: "a", count: limit))
        // A two-byte é straddling the limit is left out whole, never cut into an invalid byte.
        let straddling = String(repeating: "a", count: limit - 1) + "é"
        #expect(ReportFormat.capped(straddling) == String(repeating: "a", count: limit - 1))
        // Four-byte scalars: 16 fit in 64 bytes, the 17th does not.
        let emoji = String(repeating: "😀", count: 20)
        #expect(ReportFormat.capped(emoji) == String(repeating: "😀", count: 16))
        #expect(ReportFormat.capped("abc", to: 0).isEmpty && ReportFormat.capped("abc", to: 2) == "ab")
    }

    @Test func aNonFiniteNumberEncodesAsText() throws {
        let data = try JSONEncoder().encode(["n": ReportFormat.Value.number(.nan), "i": .number(.infinity), "x": .number(2)])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["n"] as? String == "nan" && object["i"] as? String == "inf" && object["x"] as? Double == 2)
        let negative = try JSONEncoder().encode([ReportFormat.Value.number(-.infinity)])
        #expect(String(data: negative, encoding: .utf8) == #"["-inf"]"#)
    }

    @Test func everyValueKindAsJSONAndAsText() throws {
        let rows: [(ReportFormat.Value, String, String)] = [
            ("text", #"["text"]"#, "text"),
            ("", #"[""]"#, ""),
            (true, "[true]", "true"),
            (false, "[false]", "false"),
            (42, "[42]", "42"),
            (.number(-0.0), "[-0]", "0"),
            (.number(1.5), "[1.5]", "1.5"),
            (.number(1e30), "[1e+30]", "1e+30"),
            (.number(.nan), #"["nan"]"#, "nan"),
        ]
        for (value, json, text) in rows {
            let encoded = String(data: try JSONEncoder().encode([value]), encoding: .utf8)
            #expect(value.description == text, "\(value)")
            // The encoder's spelling of a number may differ; what it reads back as must not.
            let decoded = try JSONSerialization.jsonObject(with: Data((encoded ?? "").utf8)) as? [Any]
            let expected = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any]
            #expect("\(decoded ?? [])" == "\(expected ?? [])", "\(value): \(encoded ?? "nil")")
        }
    }

    @Test func theTimestampIsUTCWithMilliseconds() {
        let stamp = ReportFormat.timestamp()
        #expect(stamp.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"#, options: .regularExpression) != nil, "\(stamp)")
    }
}
