import Foundation

/// The checks every JSON text from outside passes before the platform parses it: how deep it nests, every bare
/// token in JSON's own grammar, and no key twice in one object. The server's answers (`APIClient.decode`, error bodies included) and the ad page's
/// string messages (`FrameMessage`) go through it.
///
/// Why the depth: the decoder is recursive, one call per level. A text like `[[[[…]]]]` nested 100 000 deep
/// would overflow the stack and crash the app from an ad request, which no `catch` stops; the platform's decoder
/// has its own limit only from iOS 17. A real answer nests about 6 deep.
///
/// Why the keys: the platform's parsers take a key twice in one object and keep one of the two silently
/// (`{"enabled": false, "enabled": true}` reads as `false` here and, before its own check, as `true` on
/// Android), so one answer would mean two things. A key twice refuses the whole text, as the Kotlin SDK does:
///
/// ```
///   {"enabled": false, "enabled": true}     refused: a key twice in one object
///   {"a": "x", "\u0061": "y"}          refused: escapes are read, "a" both times
///   [{"k": 1}, {"k": 2}]                    fine: two objects
///   {"\u00e9": 1, "e\u0301": 2}         fine: keys compare code unit by code unit
/// ```
///
/// Why the tokens: the platform's parsers differ by OS version on what they let through outside strings (a
/// number such as `0320` was read on one), and the Kotlin SDK refuses them all. A bare token is
/// `true | false | null | -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`: `TRUE`, `True`, `NaN`, `01`, `+1`,
/// `.5` and unquoted words refuse the text.
///
/// How: one pass over the bytes, no recursion. Brackets and quotes inside strings (text such as
/// `"Watch [Episode 2]"`, escaped quotes included) are text, not structure. The structure itself (commas,
/// colons, brackets that match) is left to the platform's parser after it.
enum StrictJSON {
    /// The deepest arrays and objects may nest, as the Kotlin SDK and the platform's decoder from iOS 17 read it.
    static let maxNestingDepth = 512

    /// One open object or array: an object's keys so far, and whether its next string is a key.
    private struct Level {
        /// `nil` for an array.
        var keys: Set<[UInt16]>?
        var expectsKey: Bool
    }

    /// Throws `DecodingError.dataCorrupted` for a text nested deeper than `maxNestingDepth`, with a bare token
    /// JSON does not have, or with a key twice in one object.
    static func check(_ data: Data) throws {
        let bytes = [UInt8](data)
        var levels: [Level] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                let end = stringEnd(bytes, from: index)
                if let last = levels.indices.last, levels[last].expectsKey {
                    levels[last].expectsKey = false
                    let key = try self.key(bytes[index...min(end, bytes.count - 1)])
                    if levels[last].keys?.insert(key).inserted == false {
                        throw refused("the key \"\(String(utf16CodeUnits: key, count: min(key.count, 40)))\" twice in one object")
                    }
                }
                index = end + 1
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let isObject = bytes[index] == UInt8(ascii: "{")
                levels.append(Level(keys: isObject ? [] : nil, expectsKey: isObject))
                if levels.count > maxNestingDepth { throw refused("nested deeper than \(maxNestingDepth) levels") }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                _ = levels.popLast()
            case UInt8(ascii: ","):
                if let last = levels.indices.last { levels[last].expectsKey = levels[last].keys != nil }
            case UInt8(ascii: ":"), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                break
            default:
                var end = index
                while end < bytes.count, !tokenEnds.contains(bytes[end]) { end += 1 }
                let token = bytes[index..<end]
                guard isBareToken(token) else { throw refused("not JSON: \(String(bytes: token.prefix(40), encoding: .utf8) ?? "a token that is not UTF-8")") }
                index = end
                continue
            }
            index += 1
        }
    }

    /// What ends a bare token: a structural character, white space or a quote.
    private static let tokenEnds: Set<UInt8> = Set("{}[],: \t\n\r\"".utf8)

    /// `true`, `false`, `null`, or a number in JSON's grammar: `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`.
    private static func isBareToken(_ token: ArraySlice<UInt8>) -> Bool {
        if ["true", "false", "null"].contains(where: { token.elementsEqual($0.utf8) }) { return true }
        var rest = token[...]
        func digits() -> Int {
            let count = rest.prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }.count
            rest = rest.dropFirst(count)
            return count
        }
        if rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
        let leading = rest.first
        let whole = digits()
        guard whole == 1 || (whole > 1 && leading != UInt8(ascii: "0")) else { return false }
        if rest.first == UInt8(ascii: ".") {
            rest = rest.dropFirst()
            guard digits() > 0 else { return false }
        }
        if rest.first == UInt8(ascii: "e") || rest.first == UInt8(ascii: "E") {
            rest = rest.dropFirst()
            if rest.first == UInt8(ascii: "+") || rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
            guard digits() > 0 else { return false }
        }
        return rest.isEmpty
    }

    /// The index of the quote that closes the string opened at `start`; the text's end for one never closed (the
    /// parser refuses it).
    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 1
            case UInt8(ascii: "\""): return index
            default: break
            }
            index += 1
        }
        return bytes.count
    }

    /// A key, quotes included, as UTF-16 code units with its escapes read, so `"a"` and `"\u0061"` are one key.
    private static func key(_ quoted: ArraySlice<UInt8>) throws -> [UInt16] {
        guard quoted.contains(UInt8(ascii: "\\")) else {
            guard let text = String(bytes: quoted.dropFirst().dropLast(), encoding: .utf8) else { throw refused("a key that is not UTF-8") }
            return Array(text.utf16)
        }
        guard let text = try? JSONSerialization.jsonObject(with: Data(quoted), options: .fragmentsAllowed) as? String else {
            throw refused("a key that is not a JSON string")
        }
        return Array(text.utf16)
    }

    private static func refused(_ reason: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: reason))
    }
}
