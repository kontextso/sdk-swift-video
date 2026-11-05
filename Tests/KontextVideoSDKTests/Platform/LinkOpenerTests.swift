import Foundation
@testable import KontextVideoSDK
import Testing

/// Which links an ad may open, and opening them: the refused schemes, a usable link, the fallback when the first
/// cannot open, and a refused link never handed to the system.
extension SerialSuites {
@Suite
@MainActor
struct LinkOpenerTests {
    private let harness = SDKHarness()

    @Test func refusedSchemesAndTheRest() {
        let refused = ["tel:+15555550100", "TEL:1", "sms:1", "facetime:1", "itms-services://?action=x", "intent://x",
                       "javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "about:blank", "app-prefs:root"]
        for raw in refused {
            #expect(!LinkOpener.isAllowed(URL(string: raw)!), "\(raw)")
        }
        for raw in ["https://brand.test", "http://brand.test", "itms-apps://apps.apple.com/app/id1", "brandapp://offer", "hostapp://premium"] {
            #expect(LinkOpener.isAllowed(URL(string: raw)!), "\(raw)")
        }
        #expect(!LinkOpener.isAllowed(URL(string: "no-scheme")!), "a link without a scheme leads nowhere")
    }

    @Test func aUsableLink() {
        #expect(LinkOpener.url("https://brand.test/offer")?.host == "brand.test")
        #expect(LinkOpener.url("https://ads.test/r?fid=[KONTEXT_FIREID]")?.absoluteString == "https://ads.test/r?fid=%5BKONTEXT_FIREID%5D",
                "a macro's brackets are encoded, not refused")
        for raw in ["https://brand.test/a b", "https://brand.test/\n", "https:///path", "http://", ""] {
            #expect(LinkOpener.url(raw) == nil, "\(raw.debugDescription)")
        }
    }

    @Test func theFallbackOpensWhenTheDeepLinkCannot() async {
        var opened: [String] = []
        Environment.openURL = { url, completion in opened.append(url.absoluteString); completion(url.scheme == "https") }
        var result: Bool?
        LinkOpener.open(URL(string: "brandapp://offer")!, fallback: URL(string: "https://brand.test/offer")) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(opened == ["brandapp://offer", "https://brand.test/offer"] && result == true)
        opened = []
        result = nil
        LinkOpener.open(URL(string: "https://brand.test/direct")!, fallback: URL(string: "https://brand.test/offer")) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(opened == ["https://brand.test/direct"], "the first opened: no fallback")
    }

    @Test func aRefusedLinkIsNeverHandedToTheSystem() async {
        var opened: [String] = []
        Environment.openURL = { url, completion in opened.append(url.absoluteString); completion(true) }
        var warnings: [String] = []
        Logger.level = .warning
        Logger.sink = { level, message in if level == .warning { warnings.append(message) } }
        defer { Logger.sink = nil }
        var result: Bool?
        LinkOpener.open(URL(string: "tel:+15555550100")!, fallback: URL(string: "https://brand.test/offer")) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(opened == ["https://brand.test/offer"], "a call is never placed from an ad")
        #expect(warnings.contains("the link tel:+15555550100 is not allowed to open"))
    }
}
}
