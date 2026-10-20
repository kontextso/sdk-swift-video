import AdSupport
import AppTrackingTransparency
import Foundation

/// The advertising identifier, as the request carries it. Sent only when the IDFA is real: with ATT
/// `authorized` the OS gives the id, in every other state it gives all zeros. Zeros are not sent as an
/// empty id with a flag, the object is omitted, which is what the IAB's iOS 14 guidance and every
/// exchange expect (buyers key on the absence of `ifa`); `attStatus` carries the reason, and the server
/// derives OpenRTB `device.ext.atts` and `lmt` (1 unless authorized) from it, never from this object.
struct IFA: Encodable, Sendable {
    let id: String
    let type = "idfa"
    /// Never `true` on iOS: since iOS 10 an opted-out device returns no id at all, so an id is always one
    /// that may be used. Kept because the shared `IFA` type serves platforms that hand out an id together
    /// with a limit flag (Android before 12, Roku, Fire TV, Samsung and LG TVs), where the id still works
    /// for frequency capping and fraud but not for targeting.
    let limitAdTracking = false
}

/// What the request says about tracking: the ATT status and, when authorized, the IDFA.
struct TrackingInfo: Sendable {
    let ifa: IFA?
    /// `authorized`, `denied`, `notDetermined`, `restricted`; `device.ext.atts` on the demand side.
    let attStatus: String
    /// The status as the OS reports it, for the SDK's own change detection.
    let status: ATTrackingManager.AuthorizationStatus

    init(ifa: IFA?, status: ATTrackingManager.AuthorizationStatus) {
        self.ifa = ifa
        self.status = status
        attStatus = Self.name(of: status)
    }

    /// Reads the current state. With `requestAuthorization`, shows the App Tracking Transparency dialog
    /// first when the user has not answered yet (the app's Info.plist needs `NSUserTrackingUsageDescription`).
    @MainActor
    static func current(requestAuthorization: Bool) async -> TrackingInfo {
        var status = ATTrackingManager.trackingAuthorizationStatus
        if requestAuthorization, status == .notDetermined {
            status = await ATTrackingManager.requestTrackingAuthorization()
            Logger.info("ATT: \(name(of: status))")
        }
        var ifa: IFA?
        if status == .authorized {
            let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            if id != "00000000-0000-0000-0000-000000000000" {
                ifa = IFA(id: id)
            }
        }
        return TrackingInfo(ifa: ifa, status: status)
    }

    private static func name(of status: ATTrackingManager.AuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }
}

/// The consent signals a consent management platform writes to `UserDefaults` under the IAB's shared
/// keys (TCF v2, GPP, US Privacy). What the publisher set on `KontextVideo.shared.regulatory` wins per
/// field; `coppa` can only come from the publisher.
enum ConsentStorage {
    @MainActor
    static func read(merging explicit: KontextVideo.Regulatory?, defaults: UserDefaults? = nil) -> KontextVideo.Regulatory? {
        let defaults = defaults ?? Environment.consentDefaults
        let gdprApplies: Bool? = defaults.object(forKey: "IABTCF_gdprApplies").flatMap { ($0 as? NSNumber)?.intValue }.map { $0 == 1 }
        let gppSid: [Int]? = (defaults.string(forKey: "IABGPP_GppSID") ?? "")
            .split(whereSeparator: { $0 == "_" || $0 == "," })
            .compactMap { Int($0) }
            .nonEmpty
        let stored = KontextVideo.Regulatory(
            gdpr: gdprApplies,
            gdprConsent: defaults.string(forKey: "IABTCF_TCString").nonEmpty,
            coppa: nil,
            gpp: defaults.string(forKey: "IABGPP_HDR_GppString").nonEmpty,
            gppSid: gppSid,
            usPrivacy: defaults.string(forKey: "IABUSPrivacy_String").nonEmpty
        )
        let merged = KontextVideo.Regulatory(
            gdpr: explicit?.gdpr ?? stored.gdpr,
            gdprConsent: explicit?.gdprConsent ?? stored.gdprConsent,
            coppa: explicit?.coppa,
            gpp: explicit?.gpp ?? stored.gpp,
            gppSid: explicit?.gppSid ?? stored.gppSid,
            usPrivacy: explicit?.usPrivacy ?? stored.usPrivacy
        )
        let isEmpty = merged.gdpr == nil && merged.gdprConsent == nil && merged.coppa == nil && merged.gpp == nil && merged.gppSid == nil && merged.usPrivacy == nil
        return isEmpty ? nil : merged
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

private extension Array where Element == Int {
    var nonEmpty: [Int]? { isEmpty ? nil : self }
}
