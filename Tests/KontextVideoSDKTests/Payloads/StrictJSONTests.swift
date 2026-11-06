import Foundation
@testable import KontextVideoSDK
import Testing

/// `StrictJSON.check`: a key twice in one object refuses the whole text, escapes read, at any depth; equal keys in
/// different objects are fine. The platform's parser would keep one of the two silently.
@Suite
struct StrictJSONTests {
    private func refuses(_ text: String) -> Bool {
        (try? StrictJSON.check(Data(text.utf8))) == nil
    }

    @Test func aKeyTwiceInOneObjectIsRefused() {
        for text in [
            #"{"enabled": false, "enabled": true}"#,
            #"{"a":"x","\u0061":"y"}"#,
            #"{"o": {"k": 1, "k": 2}}"#,
            #"[{"k": 1}, {"k": 1, "k": 1}]"#,
            #"{"a": {"b": [1, {"c": 2}]}, "a": 2}"#,
            #"{"\"q": 1, "\u0022q": 2}"#,
        ] {
            #expect(refuses(text), "\(text)")
        }
    }

    @Test func equalKeysInDifferentObjectsAreFine() {
        for text in [
            #"[{"k": 1}, {"k": 2}]"#,
            #"{"a": {"k": 1}, "b": {"k": 2}, "k": 3}"#,
            #"{"a": "a", "b": ["a", "a"]}"#,
            #"{"\u00e9": 1, "e\u0301": 2}"#,   // canonically equal, yet two keys: compared code unit by code unit
            #"{"k": "{\"k\": 1, \"k\": 2}"}"#,   // an object written inside a string is text
            #"{}"#, #"[]"#, #""k""#,
        ] {
            #expect(!refuses(text), "\(text)")
        }
    }

    @Test func everyBareTokenIsJSONs() {
        for token in ["TRUE", "True", "NaN", "Infinity", "-Infinity", "01", "-01", "0320", "+1", ".5", "1.", "1e", "1e+", "--1", "abc", "nul", "1x"] {
            #expect(refuses(#"{"a": \#(token)}"#), "\(token)")
        }
        for token in ["true", "false", "null", "0", "-0", "7", "-12", "1.5", "0.25", "1e3", "1E-3", "2.5e+10", "-0.0"] {
            #expect(!refuses(#"{"a": \#(token)}"#), "\(token)")
            #expect(!refuses("[\(token),\(token)]"), "\(token) in an array")
        }
        #expect(!refuses(#"{"a": "TRUE NaN 01 abc"}"#), "text is not a token")
    }

    @Test func answersAndPageMessagesGoThroughIt() throws {
        let twice = Data(#"{"enabled": false, "enabled": true}"#.utf8)
        #expect(throws: (any Error).self) { try APIClient.decode(ConfigResponse.self, from: twice) }
        let message = #"{"adId": "ad-1", "type": "ad.loaded", "type": "ad.close"}"#
        #expect(FrameMessage.parse(message, adId: "ad-1", playheadLimitMs: 1000) == nil, "a page message too")
    }
}
