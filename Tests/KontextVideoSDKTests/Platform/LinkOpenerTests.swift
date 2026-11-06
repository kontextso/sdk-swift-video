import Foundation
@testable import KontextVideoSDK
import Testing
import UIKit

/// Which links an ad may open, and opening them: the refused schemes, a usable link, the fallback when the first
/// cannot open, a refused link never handed to the system, and where each route opens (an app, the App Store, a
/// universal link, the in-app browser).
extension SerialSuites {
@Suite
@MainActor
struct LinkOpenerTests {
    private let harness = SDKHarness()
    private let browser = InAppBrowser { nil }

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
        LinkOpener.open(URL(string: "brandapp://offer")!, fallback: URL(string: "https://brand.test/offer"), browser: browser) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(opened == ["brandapp://offer", "https://brand.test/offer"] && result == true)
        opened = []
        result = nil
        LinkOpener.open(URL(string: "https://brand.test/direct")!, fallback: URL(string: "https://brand.test/offer"), browser: browser) { result = $0 }
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
        LinkOpener.open(URL(string: "tel:+15555550100")!, fallback: URL(string: "https://brand.test/offer"), browser: browser) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(opened == ["https://brand.test/offer"], "a call is never placed from an ad")
        #expect(warnings.contains("the link tel:+15555550100 is not allowed to open"))
    }

    /// What a test world answers: which links an installed app claims, whether the in-app browser can appear,
    /// whether `UIApplication.open` opens. Every call is recorded in order, `open:`, `universal:` or `browser:`.
    private func world(claimed: Set<String> = [], browserAppears: Bool = true, opens: Bool = true) -> () -> [String] {
        var calls: [String] = []
        let shown = UIViewController()
        Environment.openURL = { url, completion in calls.append("open:\(url.absoluteString)"); completion(opens) }
        Environment.openUniversalLink = { url, completion in
            calls.append("universal:\(url.absoluteString)")
            completion(claimed.contains(url.absoluteString))
        }
        Environment.presentInAppBrowser = { url, _, _ in
            calls.append("browser:\(url.absoluteString)")
            return browserAppears ? shown : nil
        }
        return { _ = shown; return calls }
    }

    /// Opens `raw` (with `fallback`) and returns what it did and whether something opened.
    private func open(_ raw: String, fallback: String? = nil, in calls: () -> [String]) async -> ([String], Bool?) {
        var result: Bool?
        LinkOpener.open(URL(string: raw)!, fallback: fallback.flatMap(URL.init(string:)), browser: browser) { result = $0 }
        _ = await waitUntil { result != nil }
        return (calls(), result)
    }

    @Test func anAppsOwnLinkOpensThatAppAndNeverTheBrowser() async {
        let (calls, result) = await open("brandapp://offer", in: world())
        #expect(calls == ["open:brandapp://offer"] && result == true)
        #expect(!browser.isOpen)
    }

    @Test func aStoreLinkOpensTheAppStoreAppAndNeverTheBrowser() async {
        for raw in ["https://apps.apple.com/app/id1", "https://itunes.apple.com/app/id1", "itms-apps://apps.apple.com/app/id1"] {
            let (calls, result) = await open(raw, in: world())
            #expect(calls == ["open:\(raw)"] && result == true, "\(raw): \(calls)")
        }
        #expect(!browser.isOpen)
    }

    @Test func aWebLinkAnInstalledAppClaimsOpensInThatApp() async {
        let (calls, result) = await open("https://brand.test/offer", in: world(claimed: ["https://brand.test/offer"]))
        #expect(calls == ["universal:https://brand.test/offer"] && result == true, "\(calls)")
        #expect(!browser.isOpen, "the app stays in front of nothing of ours")
    }

    @Test func aWebLinkNoAppClaimsOpensInTheInAppBrowser() async {
        let (calls, result) = await open("https://brand.test/offer", in: world())
        #expect(calls == ["universal:https://brand.test/offer", "browser:https://brand.test/offer"] && result == true, "\(calls)")
        #expect(browser.isOpen)
    }

    @Test func aWebLinkOpensInSafariWhenTheBrowserCannotAppear() async {
        let (calls, result) = await open("https://brand.test/offer", in: world(browserAppears: false))
        #expect(calls == ["universal:https://brand.test/offer", "browser:https://brand.test/offer", "open:https://brand.test/offer"] && result == true, "\(calls)")
        #expect(!browser.isOpen)
    }

    @Test func aRefusedLinkGoesNowhereAndItsWebFallbackToTheBrowser() async {
        let (calls, result) = await open("tel:+15555550100", fallback: "https://brand.test/offer", in: world())
        #expect(calls == ["universal:https://brand.test/offer", "browser:https://brand.test/offer"] && result == true, "\(calls)")
    }

    @Test func theFallbackGoesTheSameWayWhenNothingOpenedTheFirst() async {
        // The app is not installed: its link opens nothing, the web fallback opens in the browser.
        Environment.openURL = { _, completion in completion(false) }
        var calls: [String] = []
        let shown = UIViewController()
        Environment.presentInAppBrowser = { url, _, _ in calls.append("browser:\(url.absoluteString)"); return shown }
        var result: Bool?
        LinkOpener.open(URL(string: "brandapp://offer")!, fallback: URL(string: "https://brand.test/offer"), browser: browser) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(calls == ["browser:https://brand.test/offer"] && result == true)
        // Nothing opens at all: the completion says so.
        Environment.presentInAppBrowser = { _, _, _ in nil }
        result = nil
        LinkOpener.open(URL(string: "brandapp://offer")!, fallback: URL(string: "https://brand.test/offer"), browser: InAppBrowser { nil }) { result = $0 }
        #expect(await waitUntil { result != nil })
        #expect(result == false)
    }
}
}
