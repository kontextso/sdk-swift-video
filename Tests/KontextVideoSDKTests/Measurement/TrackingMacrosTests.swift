import Foundation
@testable import KontextVideoSDK
import Testing

/// How a tracking URL's macros are written, without firing anything: the playhead format, the brackets, the
/// content playhead's two names. What fires, and when, is TrackerTests'.
@Suite
@MainActor
struct TrackingMacrosTests {
    @Test func aNonsensePlayheadIsClampedNotCrashed() {
        #expect(TrackingMacros.playhead(seconds: .infinity) == "00:00:00.000")
        #expect(TrackingMacros.playhead(seconds: .nan) == "00:00:00.000")
        #expect(TrackingMacros.playhead(seconds: -5) == "00:00:00.000")
        #expect(TrackingMacros.playhead(seconds: TimeInterval(Int.max) / 1000) == "87600:00:00.000", "ten years, not a trap")
        #expect(TrackingMacros.playhead(seconds: 1e300) == "87600:00:00.000")
        #expect(TrackingMacros.playhead(seconds: 3661.25) == "01:01:01.250")
    }

    @Test func bracketsAreMatchedEncodedOrNotAndLeftEncoded() {
        #expect(TrackingMacros.decodingBrackets("a%5bX%5D[Y]") == "a[X][Y]")
        #expect(TrackingMacros.encodingBrackets("a[X]") == "a%5BX%5D")
        #expect(TrackingMacros.asksForContentPlayhead("https://t.test/?c=%5BCONTENTPLAYHEAD]"))
        #expect(TrackingMacros.asksForContentPlayhead("https://t.test/?c=[MEDIAPLAYHEAD]"))
        #expect(!TrackingMacros.asksForContentPlayhead("https://t.test/?a=[ADPLAYHEAD]"))
    }

    @Test func theContentPlayheadIsReadOnlyWhenTheURLAsksForIt() {
        var reads = 0
        let read = { () -> TimeInterval in reads += 1; return 1.5 }
        let plain = TrackingMacros.substitute("https://t.test/?u=[UNKNOWN]", contentPlayhead: read, adPlayheadMs: 0, errorCode: nil,
                                              fireID: "f", viewDurationMs: nil, notUsed: nil)
        #expect(reads == 0 && plain == "https://t.test/?u=%5BUNKNOWN%5D", "an unknown macro stays, encoded")
        let both = TrackingMacros.substitute("https://t.test/?m=[MEDIAPLAYHEAD]&c=[CONTENTPLAYHEAD]&f=[KONTEXT_FIREID]", contentPlayhead: read,
                                             adPlayheadMs: 0, errorCode: nil, fireID: "f", viewDurationMs: nil, notUsed: nil)
        #expect(reads == 1, "its two names are one read")
        #expect(both == "https://t.test/?m=00%3A00%3A01.500&c=00%3A00%3A01.500&f=f")
    }

    @Test func aWinningPriceThatIsNotAPriceIsLeftEmpty() {
        let price = { (value: Double) in
            TrackingMacros.substitute("https://t.test/?p=[KONTEXT_WINNINGPRICE]", contentPlayhead: { 0 }, adPlayheadMs: 0, errorCode: nil,
                                      fireID: "f", viewDurationMs: nil, notUsed: .outbid(winningPrice: value, winner: nil))
        }
        for nonsense in [Double.nan, .infinity, -.infinity, -1] {
            #expect(price(nonsense) == "https://t.test/?p=", "\(nonsense)")
        }
        #expect(price(2.5) == "https://t.test/?p=2.5" && price(0) == "https://t.test/?p=0.0")
    }

    @Test func anIPv6HostKeepsItsBracketsAndStillParses() {
        let template = "https://[2001:db8::1]:8080/t?e=[KONTEXT_FIREID]&u=[UNKNOWN]#[x]"
        let filled = TrackingMacros.substitute(template, contentPlayhead: { 0 }, adPlayheadMs: 0, errorCode: nil, fireID: "f",
                                               viewDurationMs: nil, notUsed: nil)
        #expect(filled == "https://[2001:db8::1]:8080/t?e=f&u=%5BUNKNOWN%5D#%5Bx%5D")
        #expect(URL(string: filled)?.host == "2001:db8::1" && URL(string: filled)?.port == 8080)
        #expect(TrackingMacros.encodingBrackets("http://[::1]") == "http://[::1]", "a host alone")
        #expect(TrackingMacros.encodingBrackets("[X]?a=[Y]") == "%5BX%5D?a=%5BY%5D", "no authority: every bracket")
        #expect(LinkOpener.url("https://[2001:db8::1]/offer?f=[KONTEXT_FIREID]")?.host == "2001:db8::1", "a click-through to an IPv6 host")
    }

    private func fill(_ template: String, adPlayheadMs: Int = 0, errorCode: Int? = nil, viewDurationMs: Int? = nil,
                      notUsed: Tracker.NotUsed? = nil, contentPlayhead: TimeInterval = 0) -> String {
        TrackingMacros.substitute(template, contentPlayhead: { contentPlayhead }, adPlayheadMs: adPlayheadMs, errorCode: errorCode,
                                  fireID: "f", viewDurationMs: viewDurationMs, notUsed: notUsed)
    }

    @Test func everyMacroWithoutAValueIsEmpty() {
        let template = "https://t.test/?e=[ERRORCODE]&v=[KONTEXT_VIEWDURATION]&r=[KONTEXT_REASON]&p=[KONTEXT_WINNINGPRICE]&w=[KONTEXT_WINNER]"
        #expect(fill(template) == "https://t.test/?e=&v=&r=&p=&w=")
        #expect(fill(template, notUsed: .outbid(winningPrice: nil, winner: nil)) == "https://t.test/?e=&v=&r=outbid&p=&w=")
        #expect(fill(template, notUsed: .outbid(winningPrice: nil, winner: "")) == "https://t.test/?e=&v=&r=outbid&p=&w=")
        #expect(fill("https://t.test/?a=[ADPLAYHEAD]&m=[MEDIAPLAYHEAD]") == "https://t.test/?a=00%3A00%3A00.000&m=00%3A00%3A00.000", "a playhead is 0, never empty")
    }

    @Test func everyMacroWithAValue() {
        let template = "https://t.test/?e=[ERRORCODE]&v=[KONTEXT_VIEWDURATION]&r=[KONTEXT_REASON]&a=[ADPLAYHEAD]&f=[KONTEXT_FIREID]"
        #expect(fill(template, adPlayheadMs: 61_001, errorCode: 405, viewDurationMs: 9_876, notUsed: .notUsed)
                == "https://t.test/?e=405&v=9876&r=notUsed&a=00%3A01%3A01.001&f=f")
        #expect(fill("https://t.test/?r=[KONTEXT_REASON]&w=[KONTEXT_WINNER]", notUsed: .destroyed) == "https://t.test/?r=destroyed&w=")
        #expect(fill("https://t.test/?v=[KONTEXT_VIEWDURATION]&e=[ERRORCODE]", errorCode: 0, viewDurationMs: 0) == "https://t.test/?v=0&e=0", "0 is a value")
    }

    @Test func aMacroTwiceIsFilledTwiceAndOnlyItsExactSpellingIsOne() {
        #expect(fill("https://t.test/?a=[ERRORCODE]&b=[ERRORCODE]", errorCode: 402) == "https://t.test/?a=402&b=402")
        #expect(fill("https://t.test/?a=[errorcode]&b=[ErrorCode]&c=[ ERRORCODE ]", errorCode: 402)
                == "https://t.test/?a=%5Berrorcode%5D&b=%5BErrorCode%5D&c=%5B ERRORCODE %5D", "macros are upper case, as the IAB writes them")
        #expect(fill("https://t.test/?a=[[ERRORCODE]]", errorCode: 402) == "https://t.test/?a=%5B402%5D")
        #expect(fill("https://t.test/?a=ERRORCODE", errorCode: 402) == "https://t.test/?a=ERRORCODE", "no brackets, no macro")
    }

    @Test func playheadBoundaries() {
        let rows: [(TimeInterval, String)] = [
            (0, "00:00:00.000"), (-0.0, "00:00:00.000"), (0.0004, "00:00:00.000"), (0.0006, "00:00:00.001"), (59.9996, "00:01:00.000"),
            (3599.999, "00:59:59.999"), (3600, "01:00:00.000"), (86_400, "24:00:00.000"), (-.infinity, "00:00:00.000"),
            (TrackingMacros.maxPlayhead, "87600:00:00.000"), (TrackingMacros.maxPlayhead + 1, "87600:00:00.000"),
        ]
        for (seconds, expected) in rows {
            #expect(TrackingMacros.playhead(seconds: seconds) == expected, "\(seconds)")
        }
        #expect(fill("https://t.test/?a=[ADPLAYHEAD]", adPlayheadMs: -500) == "https://t.test/?a=00%3A00%3A00.000", "a negative ad playhead")
        #expect(fill("https://t.test/?a=[ADPLAYHEAD]", adPlayheadMs: Int.min) == "https://t.test/?a=00%3A00%3A00.000")
    }

    @Test func onlyUnreservedCharactersStayInAValue() {
        let unreserved = "AZaz09-._~"
        let filled = fill("https://t.test/?w=[KONTEXT_WINNER]", notUsed: .outbid(winningPrice: nil, winner: unreserved + " !*'();:@&=+$,/?#[]%é"))
        #expect(filled == "https://t.test/?w=AZaz09-._~%20%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%2F%3F%23%5B%5D%25%C3%A9")
        #expect(fill("https://t.test/?p=[KONTEXT_WINNINGPRICE]", notUsed: .outbid(winningPrice: -0.0, winner: nil)) == "https://t.test/?p=-0.0",
                "-0 is no negative price")
        #expect(fill("https://t.test/?p=[KONTEXT_WINNINGPRICE]", notUsed: .outbid(winningPrice: .greatestFiniteMagnitude, winner: nil))
                == "https://t.test/?p=1.7976931348623157e%2B308")
    }

    @Test func theCacheBusterAndTheTimestampHaveTheirShape() {
        let filled = fill("https://t.test/?c=[CACHEBUSTING]&t=[TIMESTAMP]")
        let query = URLComponents(string: filled)?.queryItems ?? []
        let buster = query.first { $0.name == "c" }?.value ?? ""
        #expect(buster.count == 8 && buster.allSatisfy(\.isNumber), "\(buster)")
        let stamp = query.first { $0.name == "t" }?.value ?? ""
        #expect(stamp.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}(Z|[+-]\d\d:\d\d)$"#, options: .regularExpression) != nil, "\(stamp)")
    }
}
