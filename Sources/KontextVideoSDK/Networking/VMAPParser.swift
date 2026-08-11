import Foundation

/// Parses the ad server's VMAP 1.0 response into `InstreamAd`s.
///
/// Reads only what the SDK needs: `vmap:AdBreak@timeOffset`, the
/// `kontext:Overlay` extension (sessionId, index, position, endMs, and the
/// AdJson creative URL), and the `NonLinear` geometry. The bidId is derived
/// from the AdJson URL path (`/api/frame/{bidId}`).
enum VMAPParser {
    static func parse(_ data: Data) -> [InstreamAd] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.ads
    }

    /// "HH:MM:SS.mmm" → milliseconds.
    static func milliseconds(fromTimeOffset offset: String) -> Int? {
        let parts = offset.split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return Int((Double(hours * 3600 + minutes * 60) + seconds) * 1000)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var ads: [InstreamAd] = []

        private var breakStartMs: Int?
        private var overlayAttributes: [String: String] = [:]
        private var nonLinearAttributes: [String: String] = [:]
        private var adJsonText = ""
        private var isInsideAdJson = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "vmap:AdBreak":
                breakStartMs = attributes["timeOffset"].flatMap(VMAPParser.milliseconds(fromTimeOffset:))
                overlayAttributes = [:]
                nonLinearAttributes = [:]
                adJsonText = ""
            case "kontext:Overlay":
                overlayAttributes = attributes
            case "kontext:AdJson":
                isInsideAdJson = true
                adJsonText = ""
            case "NonLinear":
                nonLinearAttributes = attributes
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideAdJson { adJsonText += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if isInsideAdJson, let text = String(data: CDATABlock, encoding: .utf8) {
                adJsonText += text
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch elementName {
            case "kontext:AdJson":
                isInsideAdJson = false
            case "vmap:AdBreak":
                appendAd()
            default:
                break
            }
        }

        private func appendAd() {
            let adJsonURL = URL(string: adJsonText.trimmingCharacters(in: .whitespacesAndNewlines))
            // ".../api/frame/{bidId}?format=json" → "{bidId}"
            let bidId = adJsonURL?.lastPathComponent ?? ""
            ads.append(InstreamAd(
                index: overlayAttributes["index"].flatMap(Int.init) ?? ads.count,
                startMs: breakStartMs ?? 0,
                endMs: overlayAttributes["endMs"].flatMap(Int.init),
                position: overlayAttributes["position"],
                bidId: bidId,
                adJsonURL: adJsonURL,
                width: nonLinearAttributes["width"].flatMap(Int.init),
                height: nonLinearAttributes["height"].flatMap(Int.init),
                sessionId: overlayAttributes["sessionId"]
            ))
        }
    }
}
