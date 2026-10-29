import Foundation

/// One served ad as the wire sends it: everything the SDK needs to place, show, time and track it.
/// `VideoAd` is the public object built from it.
struct AdPayload: Decodable, Sendable {
    /// When the server meant the ad to be shown. Decoded so a timed-mode answer is still a valid ad; not
    /// acted on: the SDK has no timed mode yet, and the app picks every moment.
    enum Trigger: Sendable, Equatable {
        /// The app decides the moment.
        case manual
        /// Timed mode: meant for `from`…`to`, milliseconds in content time.
        case window(from: Int, to: Int)
    }

    /// What the page renders. The viewability clock (1 s for an image or HTML, 2 s for a video), when the
    /// impression counts (at `show`, or at a video's first frame), the video events and the `complete`
    /// beacon depend on it.
    enum Creative: String, Decodable, Sendable {
        case image
        case video
        /// Third-party markup (an HTML or MRAID banner) the page inserts on `ad.show`; counts like an image.
        case html
    }

    enum Rendering: Sendable, Equatable {
        /// The page to show in a WebView.
        case frame(URL)
    }

    struct Price: Decodable, Sendable, Equatable {
        enum Precision: String, Decodable, Sendable {
            /// A DSP's clearing price.
            case exact
            /// Our own or house demand, a forecast.
            case estimated
        }

        /// Per 1,000 impressions.
        let value: Double
        /// ISO 4217.
        let currency: String
        let precision: Precision
    }

    /// One beacon of the ad. The SDK fires every entry once, when its moment happens, except `click`,
    /// `pause`, `resume`, `mute` and `unmute`, which fire on every occurrence; the page never fires any.
    struct TrackingEvent: Decodable, Sendable, Equatable {
        /// A VAST event name: `impression`, `creativeView`, `start`, `complete`, `close`, ... The SDK ignores names it does not know.
        let event: String
        let url: String
        /// `progress` only: milliseconds into the ad video at which to fire.
        let offset: Int?
        /// `endCard` for the linear ad's end card; `nil` for the main creative.
        let part: String?
    }

    /// The nominal box the creative was built for, in points; the VAST NonLinear attributes. Both sides
    /// positive, or the geometry at `show` is nonsense. `scalable: false` (VAST) means built for exactly
    /// this size: the SDK never shrinks it. `maintainAspectRatio` is not read: the SDK always keeps the
    /// ratio, and `false` only permits stretching, it never requires it.
    struct Size: Decodable, Sendable, Equatable {
        let width: Int
        let height: Int
        /// May be shown smaller; absent is `true`.
        let scalable: Bool

        init(width: Int, height: Int, scalable: Bool = true) {
            self.width = width
            self.height = height
            self.scalable = scalable
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decode(Int.self, forKey: .width)
            height = try container.decode(Int.self, forKey: .height)
            scalable = try container.decodeIfPresent(Bool.self, forKey: .scalable) ?? true
            guard width > 0, height > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .width, in: container, debugDescription: "a size must be positive")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case width, height, scalable
        }
    }

    /// Schemes a frame page never comes from: local files and inline content.
    private static let refusedFrameSchemes: Set<String> = ["file", "javascript", "data", "blob", "about"]

    /// An optional count of milliseconds, refused when negative (a negative overlay duration would end the
    /// overlay the moment it shows).
    private static func nonNegative(_ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) throws -> Int? {
        let value = try container.decodeIfPresent(Int.self, forKey: key)
        if let value, value < 0 { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\(key.stringValue) must not be negative") }
        return value
    }

    /// `sizes`, at least one entry, the first built for the request's player.
    private static func sizes(from container: KeyedDecodingContainer<CodingKeys>) throws -> [Size] {
        let sizes = try container.decode([Size].self, forKey: .sizes)
        guard !sizes.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sizes, in: container, debugDescription: "sizes must have at least one entry")
        }
        return sizes
    }

    /// Where an overlay sits; never full screen.
    enum OverlayPosition: String, Decodable, Sendable {
        case top, bottom
    }

    /// Where a pause ad sits.
    enum PausePosition: String, Decodable, Sendable {
        case top, bottom, fullscreen
    }

    /// What each format adds to the common fields.
    enum Details: Sendable, Equatable {
        /// `duration`: milliseconds to keep it on screen; absent, the overlay stays until the app ends it.
        /// `sizes`: every variant the creative carries
        /// assets for, at least one, the first built for the request's player; the SDK picks the best fit
        /// for the real box at show.
        case overlay(position: OverlayPosition, sizes: [Size], duration: Int?)
        /// `sizes` is empty for the fullscreen variant.
        case pause(position: PausePosition, sizes: [Size])
        /// `skipOffset`: milliseconds until the Close may appear; `nil` means no Close before complete.
        case linear(duration: Int, skipOffset: Int?)
    }

    let id: String
    let format: AdFormat
    let creative: Creative
    let trigger: Trigger
    let price: Price
    /// Milliseconds from receipt.
    let expires: Int
    let rendering: Rendering
    let tracking: [TrackingEvent]
    let details: Details
    /// Apple's install attribution; only an app-install ad carries it.
    let attribution: Attribution?
    // Not read: `vastUrl` (for players that render VAST themselves) and, in the response, `nextRequestAt`.

    private enum CodingKeys: String, CodingKey {
        case id, format, creative, trigger, price, expires, rendering, tracking, attribution
        case position, sizes, duration, skipOffset
    }

    private enum TriggerKeys: String, CodingKey {
        case kind, from, to
    }

    private enum RenderingKeys: String, CodingKey {
        case kind, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "the ad id is empty") }
        format = try container.decode(AdFormat.self, forKey: .format)
        creative = try container.decode(Creative.self, forKey: .creative)
        price = try container.decode(Price.self, forKey: .price)
        expires = try container.decode(Int.self, forKey: .expires)
        // An ad that is expired on arrival is not an ad the server meant to give.
        guard expires > 0 else { throw DecodingError.dataCorruptedError(forKey: .expires, in: container, debugDescription: "expires must be positive") }
        tracking = try container.decode([TrackingEvent].self, forKey: .tracking)
        attribution = try? container.decodeIfPresent(Attribution.self, forKey: .attribution)   // best effort: never fails the ad

        let trigger = try container.nestedContainer(keyedBy: TriggerKeys.self, forKey: .trigger)
        switch try trigger.decode(String.self, forKey: .kind) {
        case "manual":
            self.trigger = .manual
        case "window":
            self.trigger = .window(from: try trigger.decode(Int.self, forKey: .from), to: try trigger.decode(Int.self, forKey: .to))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: trigger, debugDescription: "unknown trigger kind \(kind)")
        }

        let rendering = try container.nestedContainer(keyedBy: RenderingKeys.self, forKey: .rendering)
        switch try rendering.decode(String.self, forKey: .kind) {
        case "frame":
            // A page to load: absolute, with a scheme and a host, and not a scheme that loads something
            // local or inline (`file://localhost/...` has a host, so the host alone does not rule it out).
            let url = try rendering.decode(URL.self, forKey: .url)
            guard let scheme = url.scheme?.lowercased(), !Self.refusedFrameSchemes.contains(scheme), let host = url.host, !host.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: rendering, debugDescription: "the frame URL must be absolute with a host")
            }
            self.rendering = .frame(url)
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: rendering, debugDescription: "unknown rendering kind \(kind)")
        }

        switch format {
        case .overlay:
            details = .overlay(
                position: try container.decode(OverlayPosition.self, forKey: .position),
                sizes: try Self.sizes(from: container),
                duration: try Self.nonNegative(.duration, in: container)
            )
        case .pause:
            let position = try container.decode(PausePosition.self, forKey: .position)
            details = .pause(position: position, sizes: position == .fullscreen ? [] : try Self.sizes(from: container))
        case .linear:
            details = .linear(
                duration: try container.decode(Int.self, forKey: .duration),
                skipOffset: try Self.nonNegative(.skipOffset, in: container)
            )
        }
    }
}
