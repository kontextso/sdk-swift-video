import Foundation
@testable import KontextVideoSDK
import Testing

/// The nesting-depth check reads strings as the JSON decoder does: brackets in text are never nesting, whatever
/// the escapes, and a string ends where the decoder ends it.
@Suite
struct NestingDepthTests {
    struct Reply: Decodable { let b: [Int] }

    private let deep = String(repeating: "[", count: APIClient.maxNestingDepth * 2)

    @Test func bracketsInTextAreNotNestingWhateverTheEscapes() throws {
        // An escaped quote, an escaped backslash then an escaped quote, a bracket written as a code.
        for text in [#""sfs\"\#(deep)""#, #""a\\\"\#(deep)""#, #""\u005B\#(deep)""#] {
            let data = Data(#"{"a": \#(text), "b": [1]}"#.utf8)
            #expect(try APIClient.decode(Reply.self, from: data).b == [1], "\(text.prefix(12))")
        }
    }

    @Test func anEscapedBackslashThenAQuoteEndsTheString() {
        // `C:\\` ends the string, so the brackets after it are nesting, and one level too many.
        let nesting = String(repeating: "[", count: APIClient.maxNestingDepth) + String(repeating: "]", count: APIClient.maxNestingDepth)
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
