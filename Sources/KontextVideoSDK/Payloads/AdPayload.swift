import Foundation

/// One served ad as the wire sends it: everything the SDK needs to place, show, time and track it.
/// `VideoAd` is the public object built from it.
struct AdPayload: Decodable, Sendable {
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

        init(value: Double, currency: String, precision: Precision) {
            self.value = value
            self.currency = currency
            self.precision = precision
        }

        private enum CodingKeys: String, CodingKey { case value, currency, precision }

        /// A finite, non-negative CPM in a three-letter currency: the publisher's auction compares it.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decodeNumber(Double.self, forKey: .value)
            guard value.isFinite, value >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "the price must be a finite, non-negative CPM")
            }
            currency = try container.decode(String.self, forKey: .currency)
            // Bytes, not Characters: a combining mark or a zero-width joiner hides inside one Character.
            guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
                throw DecodingError.dataCorruptedError(forKey: .currency, in: container, debugDescription: "the currency must be an ISO 4217 code")
            }
            precision = try container.decode(Precision.self, forKey: .precision)
        }
    }

    /// One beacon of the ad. The SDK fires every entry once, when its moment happens, except `click`,
    /// `pause`, `resume`, `mute` and `unmute`, which fire on every occurrence; the page never fires any.
    struct TrackingEvent: Decodable, Sendable, Equatable {
        /// A VAST event name: `impression`, `creativeView`, `start`, `complete`, `close`, ... The SDK ignores names it does not know.
        let event: String
        let url: String
        /// `progress` only: milliseconds into the ad video at which to fire. The wire's `number`: the server
        /// converts a VAST percent (33 % of 15 023 ms is 4957.59), so it is rounded to the nearest millisecond.
        let offset: Int?
        /// `endCard` for the linear ad's end card; `nil` for the main creative.
        let part: String?

        init(event: String, url: String, offset: Int?, part: String?) {
            self.event = event
            self.url = url
            self.offset = offset
            self.part = part
        }

        private enum CodingKeys: String, CodingKey { case event, url, offset, part }

        /// An offset that is not a number, negative or out of range: this entry cannot fire at a meaningful moment.
        struct InvalidOffset: Error {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = try container.decode(String.self, forKey: .event)
            url = try container.decode(String.self, forKey: .url)
            part = try container.decodeIfPresent(String.self, forKey: .part)
            // A string, a boolean or an object is no count of milliseconds either, nor a number no Double holds
            // (`1e400`): the entry goes, not the ad.
            let raw: Double?
            do {
                raw = try container.decodeNumberIfPresent(Double.self, forKey: .offset)
            } catch DecodingError.typeMismatch, DecodingError.dataCorrupted {
                throw InvalidOffset()
            }
            if let raw {
                guard raw >= 0, let offset = AdPayload.milliseconds(raw) else { throw InvalidOffset() }
                self.offset = offset
            } else {
                offset = nil
            }
        }
    }

    /// `tracking`: an entry whose offset is unusable (not a number, negative, out of range) is dropped, the
    /// rest of the ad stays; any other broken entry still fails the ad.
    private struct TrackingEntry: Decodable {
        let event: TrackingEvent?

        init(from decoder: Decoder) throws {
            do {
                event = try TrackingEvent(from: decoder)
            } catch is TrackingEvent.InvalidOffset {
                event = nil
            }
        }
    }

    /// The largest count of milliseconds taken: ten years, the content playhead's cap. Beyond it a value is
    /// nonsense, and near `Int.max` it would trap the conversion.
    static let maxMilliseconds: Double = 315_360_000_000

    /// A wire `number` of milliseconds as whole ones, rounded to the nearest: the contract types durations
    /// and offsets as numbers, and a server converting from VAST or percent sends fractions. `nil` when not
    /// finite or beyond `maxMilliseconds` either way.
    static func milliseconds(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) <= maxMilliseconds else { return nil }
        return Int(value.rounded())
    }

    /// The nominal box the creative was built for, in points; the VAST NonLinear attributes. Both sides
    /// positive, or the geometry at `show` is nonsense. `scalable: false` (VAST) means built for exactly
    /// this size: the SDK never shrinks it. `maintainAspectRatio` is not read: the SDK always keeps the
    /// ratio, and `false` only permits stretching, it never requires it.
    struct Size: Decodable, Sendable, Equatable {
        let width: Int
        let height: Int
        /// May be shown smaller; absent is `true`.
        let isScalable: Bool
        /// The largest side a creative may have, in points.
        static let maxSide = 10_000

        init(width: Int, height: Int, isScalable: Bool = true) {
            self.width = width
            self.height = height
            self.isScalable = isScalable
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decodeNumber(Int.self, forKey: .width)
            height = try container.decodeNumber(Int.self, forKey: .height)
            isScalable = try container.decodeIfPresent(Bool.self, forKey: .isScalable) ?? true
            // Positive, and no larger than any screen could be: an absurd size would only produce absurd geometry.
            guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height) else {
                throw DecodingError.dataCorruptedError(forKey: .width, in: container, debugDescription: "a size must be positive and at most \(Self.maxSide) points")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case width, height
            case isScalable = "scalable"
        }
    }

    /// Where a frame page comes from: the web, or a scheme the tests serve pages over.
    private static let frameSchemes: Set<String> = ["http", "https"]

    /// An optional count of milliseconds, refused when negative (a negative overlay duration would end the
    /// overlay the moment it shows). The sign of the value sent, before rounding: -0.4 is as broken as -1.
    private static func nonNegative(_ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) throws -> Int? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        let raw = try container.decodeNumber(Double.self, forKey: key)
        if raw < 0 { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\(key.stringValue) must not be negative") }
        return try milliseconds(raw, key, in: container)
    }

    /// A required count of milliseconds, a fraction rounded (`milliseconds(_:)`).
    private static func milliseconds<Key: CodingKey>(_ key: Key, in container: KeyedDecodingContainer<Key>) throws -> Int {
        try milliseconds(try container.decodeNumber(Double.self, forKey: key), key, in: container)
    }

    /// `raw`, the value of `key`, as milliseconds, or an error at `key`.
    private static func milliseconds<Key: CodingKey>(_ raw: Double, _ key: Key, in container: KeyedDecodingContainer<Key>) throws -> Int {
        guard let value = milliseconds(raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\(key.stringValue) is not a usable count of milliseconds")
        }
        return value
    }

    /// Whether `text` is a URL as written: the characters of RFC 3986, each `%` starting an escape, brackets only
    /// in the host (an IPv6 literal), and beyond ASCII anything but a space or a control character. Checked on the
    /// string: Foundation's `URL` (iOS 17 and later) percent-encodes what does not belong in a URL, a space
    /// included, and would take a URL the server never meant; the Kotlin SDK's parser refuses the same.
    static func isWellFormedURL(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        // The authority runs from after `//` to the path, the query or the fragment.
        let start = text.range(of: "//").map { text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: $0.upperBound) } ?? 0
        let end = scalars[start...].firstIndex { "/?#".unicodeScalars.contains($0) } ?? scalars.count
        for (index, scalar) in scalars.enumerated() {
            guard scalar.isASCII else {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) { return false }
                continue
            }
            guard urlCharacters.contains(scalar) else { return false }
            if scalar == "[" || scalar == "]", !(start..<end).contains(index) { return false }
            if scalar == "%" {
                guard index + 2 < scalars.count, scalars[index + 1].properties.isASCIIHexDigit, scalars[index + 2].properties.isASCIIHexDigit else { return false }
            }
        }
        return true
    }

    /// RFC 3986's unreserved and reserved characters, and `%`.
    private static let urlCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")

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
        case kind
    }

    private enum RenderingKeys: String, CodingKey {
        case kind, url
    }

    /// The fields in a fixed order, so a broken ad fails at the same field whatever else is wrong with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.id(from: container)
        format = try container.decode(AdFormat.self, forKey: .format)
        creative = try container.decode(Creative.self, forKey: .creative)
        price = try container.decode(Price.self, forKey: .price)
        expires = try Self.expires(from: container)
        tracking = try container.decode([TrackingEntry].self, forKey: .tracking).compactMap(\.event)
        attribution = try? container.decodeIfPresent(Attribution.self, forKey: .attribution)   // best effort: never fails the ad
        try Self.checkTrigger(in: container)
        rendering = try Self.rendering(from: container)
        details = try Self.details(of: format, from: container)
    }

    // MARK: Readers, one per group of fields

    private static func id(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        let id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "the ad id is empty") }
        return id
    }

    private static func expires(from container: KeyedDecodingContainer<CodingKeys>) throws -> Int {
        let expires = try milliseconds(.expires, in: container)
        // An ad that is expired on arrival is not an ad the server meant to give.
        guard expires > 0 else { throw DecodingError.dataCorruptedError(forKey: .expires, in: container, debugDescription: "expires must be positive") }
        return expires
    }

    /// The SDK does not act on a trigger yet: the app picks every moment. Only `manual` says that; a `window`
    /// (timed mode, `from`…`to` in content time) is refused rather than shown at any time, and the ad is dropped
    /// and reported at `trigger.kind`, as an unknown kind is.
    private static func checkTrigger(in container: KeyedDecodingContainer<CodingKeys>) throws {
        let trigger = try container.nestedContainer(keyedBy: TriggerKeys.self, forKey: .trigger)
        switch try trigger.decode(String.self, forKey: .kind) {
        case "manual":
            return
        case "window":
            throw DecodingError.dataCorruptedError(forKey: .kind, in: trigger, debugDescription: "trigger kind window is not supported yet")
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: trigger, debugDescription: "unknown trigger kind \(kind)")
        }
    }

    private static func rendering(from container: KeyedDecodingContainer<CodingKeys>) throws -> Rendering {
        let rendering = try container.nestedContainer(keyedBy: RenderingKeys.self, forKey: .rendering)
        switch try rendering.decode(String.self, forKey: .kind) {
        case "frame":
            // A web page to load: http or https, with a host and a valid port. Anything else (a local file,
            // inline content, another app's scheme) is not a frame page.
            let text = try rendering.decode(String.self, forKey: .url)
            guard isWellFormedURL(text), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  frameSchemes.contains(scheme) || Environment.testFrameSchemes.contains(scheme),
                  let host = url.host, !host.isEmpty, (url.port.map { (1...65_535).contains($0) } ?? true) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: rendering, debugDescription: "the frame URL must be an http or https page with a host")
            }
            return .frame(url)
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: rendering, debugDescription: "unknown rendering kind \(kind)")
        }
    }

    /// What `format` adds to the common fields.
    private static func details(of format: AdFormat, from container: KeyedDecodingContainer<CodingKeys>) throws -> Details {
        switch format {
        case .overlay:
            return .overlay(
                position: try container.decode(OverlayPosition.self, forKey: .position),
                sizes: try sizes(from: container),
                duration: try nonNegative(.duration, in: container)
            )
        case .pause:
            let position = try container.decode(PausePosition.self, forKey: .position)
            return .pause(position: position, sizes: position == .fullscreen ? [] : try sizes(from: container))
        case .linear:
            let duration = try milliseconds(.duration, in: container)
            // A video of no length has nothing to play, and its progress beacons no moment to fire at.
            guard duration > 0 else { throw DecodingError.dataCorruptedError(forKey: .duration, in: container, debugDescription: "duration must be positive") }
            return .linear(duration: duration, skipOffset: try nonNegative(.skipOffset, in: container))
        }
    }
}

/// Reading the answers' values: a format by its wire name, and numbers reported at their own field.
extension KeyedDecodingContainer {
    /// A format from its wire name, for an ad and for an entry of the answer. `AdFormat` is not `Decodable`: this
    /// keeps the call sites' spelling, and an unknown name fails as the raw-value decoding did.
    func decode(_ type: AdFormat.Type, forKey key: Key) throws -> AdFormat {
        let name = try decode(String.self, forKey: key)
        guard let format = AdFormat(rawValue: name) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "unknown format \(name)")
        }
        return format
    }

    /// `decode(_:forKey:)` for a number, a number the type cannot hold (`1e400`, or `320.5` read as an `Int`)
    /// reported at `key`: the iOS decoder throws its own error for it, not a `DecodingError`, and it reaches the
    /// caller as corrupted data with no coding path, while the error report must name the field (`price.value`),
    /// as the Kotlin SDK does.
    func decodeNumber<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try atKey(key) { try decode(type, forKey: key) }
    }

    /// `decodeIfPresent(_:forKey:)` for a number, as `decodeNumber(_:forKey:)`.
    func decodeNumberIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try atKey(key) { try decodeIfPresent(type, forKey: key) }
    }

    private func atKey<T>(_ key: Key, _ decode: () throws -> T) throws -> T {
        do {
            return try decode()
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.count <= codingPath.count {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: context.debugDescription)
        } catch let error where !(error is DecodingError) {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(error)")
        }
    }
}
