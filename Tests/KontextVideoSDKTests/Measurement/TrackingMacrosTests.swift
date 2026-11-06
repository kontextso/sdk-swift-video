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
                                              fireId: "f", viewDurationMs: nil, notUsed: nil)
        #expect(reads == 0 && plain == "https://t.test/?u=%5BUNKNOWN%5D", "an unknown macro stays, encoded")
        let both = TrackingMacros.substitute("https://t.test/?m=[MEDIAPLAYHEAD]&c=[CONTENTPLAYHEAD]&f=[KONTEXT_FIREID]", contentPlayhead: read,
                                             adPlayheadMs: 0, errorCode: nil, fireId: "f", viewDurationMs: nil, notUsed: nil)
        #expect(reads == 1, "its two names are one read")
        #expect(both == "https://t.test/?m=00%3A00%3A01.500&c=00%3A00%3A01.500&f=f")
    }

    @Test func aWinningPriceThatIsNotAPriceIsLeftEmpty() {
        let price = { (value: Double) in
            TrackingMacros.substitute("https://t.test/?p=[KONTEXT_WINNINGPRICE]", contentPlayhead: { 0 }, adPlayheadMs: 0, errorCode: nil,
                                      fireId: "f", viewDurationMs: nil, notUsed: .outbid(winningPrice: value, winner: nil))
        }
        for nonsense in [Double.nan, .infinity, -.infinity, -1] {
            #expect(price(nonsense) == "https://t.test/?p=", "\(nonsense)")
        }
        #expect(price(2.5) == "https://t.test/?p=2.5" && price(0) == "https://t.test/?p=0.0")
    }

    @Test func anIPv6HostKeepsItsBracketsAndStillParses() {
        let template = "https://[2001:db8::1]:8080/t?e=[KONTEXT_FIREID]&u=[UNKNOWN]#[x]"
        let filled = TrackingMacros.substitute(template, contentPlayhead: { 0 }, adPlayheadMs: 0, errorCode: nil, fireId: "f",
                                               viewDurationMs: nil, notUsed: nil)
        #expect(filled == "https://[2001:db8::1]:8080/t?e=f&u=%5BUNKNOWN%5D#%5Bx%5D")
        #expect(URL(string: filled)?.host == "2001:db8::1" && URL(string: filled)?.port == 8080)
        #expect(TrackingMacros.encodingBrackets("http://[::1]") == "http://[::1]", "a host alone")
        #expect(TrackingMacros.encodingBrackets("[X]?a=[Y]") == "%5BX%5D?a=%5BY%5D", "no authority: every bracket")
        #expect(LinkOpener.url("https://[2001:db8::1]/offer?f=[KONTEXT_FIREID]")?.host == "2001:db8::1", "a click-through to an IPv6 host")
    }
}
