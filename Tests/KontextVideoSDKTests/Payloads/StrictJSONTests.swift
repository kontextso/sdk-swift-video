import Foundation
@testable import KontextVideoSDK
import Testing

/// `StrictJSON.check`: a key twice in one object refuses the whole text, escapes read, at any depth; equal keys in
/// different objects are fine. The platform's parser would keep one of the two silently. Also the nesting limit,
/// with strings read as the decoder reads them: brackets in text are never nesting, whatever the escapes.
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
        let message = #"{"bidId": "ad-1", "type": "ad.loaded", "type": "ad.close"}"#
        #expect(FrameMessage.parse(message, bidId: "ad-1", playheadLimitMs: 1000) == nil, "a page message too")
    }

    /// A raw control character (U+0000 to U+001F) inside a string, key or value, is not JSON: answers and page
    /// messages with one are refused, as on Android. Escaped (`\n`, `\u0000`) it is text.
    @Test func aRawControlCharacterInAStringIsRefused() throws {
        for text in ["{\"enabled\": false, \"disabledReason\": \"a\nb\"}", "{\"enabled\": false, \"disabled\tReason\": \"x\"}",
                     "{\"enabled\": false, \"disabledReason\": \"a\u{0}b\"}"] {
            #expect(throws: (any Error).self, "\(text.debugDescription)") { try APIClient.decode(ConfigResponse.self, from: Data(text.utf8)) }
        }
        guard case .disabled(let reason) = try APIClient.decode(ConfigResponse.self, from: Data(#"{"enabled": false, "disabledReason": "a\nb\u0000"}"#.utf8)) else {
            Issue.record("expected disabled"); return
        }
        #expect(reason == "a\nb\u{0}", "escaped, it is text")
        #expect(FrameMessage.parse("{\"bidId\": \"ad-1\", \"type\": \"ad.close\", \"reason\": \"a\nb\"}", bidId: "ad-1", playheadLimitMs: 1000) == nil, "a page message too")
        #expect(FrameMessage.parse(#"{"bidId": "ad-1", "type": "ad.close", "reason": "a\nb"}"#, bidId: "ad-1", playheadLimitMs: 1000)?.reason == "a\nb")
    }

    // MARK: Nesting

    struct Reply: Decodable { let b: [Int] }

    private let deep = String(repeating: "[", count: StrictJSON.maxNestingDepth * 2)

    @Test func theNestingLimitForArraysAndObjects() {
        let limit = StrictJSON.maxNestingDepth
        let arrays = { (depth: Int) in String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        let objects = { (depth: Int) in String(repeating: #"{"k":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1) }
        let mixed = { (depth: Int) in String(repeating: #"[{"k":"#, count: depth / 2) + "1" + String(repeating: "}]", count: depth / 2) }
        for (name, make) in [("arrays", arrays), ("objects", objects), ("mixed", mixed)] {
            #expect(!refuses(make(limit)), "\(name) at the limit")
            #expect(refuses(make(limit + 2)), "\(name) past it")
        }
        #expect(refuses(arrays(limit + 1)), "one level past it")
        #expect(refuses(String(repeating: "[", count: limit + 1)), "an unclosed text past the limit too")
        let siblings = "[" + Array(repeating: arrays(limit - 1), count: 3).joined(separator: ",") + "]"
        #expect(!refuses(siblings), "siblings are not depth")
        #expect(!refuses(String(repeating: "[1],", count: 10_000) + "[1]"), "a long flat text")
    }

    @Test func aKeyWithABrokenEscapeIsRefused() {
        for text in [#"{"a\x": 1}"#, #"{"\u12": 1}"#, #"{"\uZZZZ": 1}"#] {
            #expect(refuses(text), "\(text)")
        }
        #expect(!refuses(#"{"a\\x": 1, "a\\\\x": 2}"#), "an escaped backslash is a character: two keys")
    }

    @Test func textThatIsNoJSONValueIsRefusedOrLeftToTheParser() {
        for text in ["NaN", "undefined", "'k'", "{k: 1}", #"{"a": 1}x"#] {
            #expect(refuses(text), "\(text)")
        }
        #expect(!refuses(""), "empty: no token to refuse; the parser after it refuses it")
        #expect(!refuses(" \n\t "))
    }

    @Test func bracketsInTextAreNotNestingWhateverTheEscapes() throws {
        // An escaped quote, an escaped backslash then an escaped quote, a bracket written as a code.
        for text in [#""sfs\"\#(deep)""#, #""a\\\"\#(deep)""#, #""\u005B\#(deep)""#] {
            let data = Data(#"{"a": \#(text), "b": [1]}"#.utf8)
            #expect(try APIClient.decode(Reply.self, from: data).b == [1], "\(text.prefix(12))")
        }
    }

    @Test func anEscapedBackslashThenAQuoteEndsTheString() {
        // `C:\\` ends the string, so the brackets after it are nesting, and one level too many.
        let nesting = String(repeating: "[", count: StrictJSON.maxNestingDepth) + String(repeating: "]", count: StrictJSON.maxNestingDepth)
        let data = Data(#"{"p": "C:\\", "x": \#(nesting)}"#.utf8)
        do {
            _ = try APIClient.decode([String: [Int]].self, from: data)
            Issue.record("decoded an answer nested deeper than the limit")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("nested deeper than"), "refused by the SDK's own check")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
