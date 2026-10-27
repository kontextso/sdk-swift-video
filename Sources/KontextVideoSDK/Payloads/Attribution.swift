/// `attribution` of an ad: what an app-install ad carries for Apple's install attribution. iOS and tvOS
/// only; absent for every other ad. A malformed payload drops the attribution, never the ad: it still
/// serves and renders, only the install would not be attributed.
struct Attribution: Decodable, Sendable, Equatable {
    /// The SKAdNetwork payload, signed by the ad network.
    let skan: Skan?
    /// The AdAttributionKit compact JWS. Decoded for the record; the SDK does not act on it yet.
    let aakJWS: String?

    private enum CodingKeys: String, CodingKey {
        case skan, aak
    }

    private enum AAKKeys: String, CodingKey {
        case jws
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skan = try? container.decodeIfPresent(Skan.self, forKey: .skan)
        aakJWS = try? container.nestedContainer(keyedBy: AAKKeys.self, forKey: .aak).decode(String.self, forKey: .jws)
    }
}

/// The SKAdNetwork payload of an app-install ad, as the ad network signed it. Passed through to Apple's
/// APIs: the fidelity-0 entry registers the view-through impression (`SKAdImpression`), the fidelity-1
/// entry signs the App Store product sheet a click opens. The names and types are the Video API's; the
/// decoder coerces a numeric id the server sent as a number, so `42` and `"42"` both pass.
struct Skan: Decodable, Sendable, Equatable {
    struct Fidelity: Decodable, Sendable, Equatable {
        /// 0 for a view-through impression, 1 for a StoreKit-rendered surface.
        let fidelity: Int
        let nonce: String
        /// Milliseconds since the epoch, when the network signed it.
        let timestamp: String
        let signature: String

        private enum CodingKeys: String, CodingKey {
            case fidelity, nonce, timestamp, signature
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fidelity = try container.requireIntCoercing(forKey: .fidelity)
            nonce = try container.requireStringCoercing(forKey: .nonce)
            timestamp = try container.requireStringCoercing(forKey: .timestamp)
            signature = try container.requireStringCoercing(forKey: .signature)
        }
    }

    /// The SKAdNetwork version, `"4.0"`.
    let version: String
    /// The ad network's id, as listed in the app's `SKAdNetworkItems`.
    let network: String
    /// The advertised app's App Store id.
    let itunesItem: String
    /// The publisher app's App Store id; `"0"` when unknown.
    let sourceApp: String
    /// SKAdNetwork 4: the hierarchical source id; replaces `campaign`.
    let sourceIdentifier: String?
    /// SKAdNetwork 3 and earlier: the campaign id.
    let campaign: String?
    /// At least one entry; which fidelities the network signed. Only 0 and 1 exist; an entry with another
    /// value is dropped.
    let fidelities: [Fidelity]

    private enum CodingKeys: String, CodingKey {
        case version, network, itunesItem, sourceApp, sourceIdentifier, campaign, fidelities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.requireStringCoercing(forKey: .version)
        network = try container.requireStringCoercing(forKey: .network)
        itunesItem = try container.requireStringCoercing(forKey: .itunesItem)
        sourceApp = try container.requireStringCoercing(forKey: .sourceApp)
        sourceIdentifier = container.decodeStringCoercing(forKey: .sourceIdentifier)
        campaign = container.decodeStringCoercing(forKey: .campaign)
        fidelities = try container.decode([Fidelity].self, forKey: .fidelities).filter { (0...1).contains($0.fidelity) }
        guard !fidelities.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .fidelities, in: container, debugDescription: "fidelities must have at least one entry of fidelity 0 or 1")
        }
    }

    /// The network signed the view-through impression: an `SKAdImpression` can be registered.
    var hasFidelity0: Bool {
        fidelities.contains { $0.fidelity == 0 }
    }

    /// The network signed the click: a StoreKit product sheet can carry the attribution.
    var hasFidelity1: Bool {
        fidelities.contains { $0.fidelity == 1 }
    }

    /// The shape KontextKit's StoreKit helpers take; values stay strings, KontextKit converts at Apple's API.
    func rawDictionary() -> [String: Any] {
        var dictionary: [String: Any] = [
            "version": version,
            "network": network,
            "itunesItem": itunesItem,
            "sourceApp": sourceApp,
            "fidelities": fidelities.map { entry -> [String: Any] in
                ["fidelity": entry.fidelity, "nonce": entry.nonce, "timestamp": entry.timestamp, "signature": entry.signature]
            },
        ]
        if let sourceIdentifier { dictionary["sourceIdentifier"] = sourceIdentifier }
        if let campaign { dictionary["campaign"] = campaign }
        return dictionary
    }
}

/// Per-field decoding that takes the expected JSON type first and coerces between a number and a string
/// otherwise, so a numeric id the server sent as `42` instead of `"42"` does not fail the ad. An empty
/// string is missing: an empty signature, nonce or id attributes nothing.
private extension KeyedDecodingContainer {
    func decodeStringCoercing(forKey key: Key) -> String? {
        if let string = try? decode(String.self, forKey: key) { return string.isEmpty ? nil : string }
        if let int = try? decode(Int.self, forKey: key) { return String(int) }
        if let double = try? decode(Double.self, forKey: key) { return String(double) }
        return nil
    }

    func requireStringCoercing(forKey key: Key) throws -> String {
        guard let value = decodeStringCoercing(forKey: key) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "missing or unparseable \(key.stringValue)")
        }
        return value
    }

    func requireIntCoercing(forKey key: Key) throws -> Int {
        if let int = try? decode(Int.self, forKey: key) { return int }
        if let string = try? decode(String.self, forKey: key), let int = Int(string) { return int }
        // `Int(exactly:)`: a huge or fractional number is unparseable, not a trap.
        if let double = try? decode(Double.self, forKey: key), let int = Int(exactly: double) { return int }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "missing or unparseable \(key.stringValue)")
    }
}
