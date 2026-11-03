/// The checks behind `VideoAds(content:labels:)`: what the SDK sends, and what it drops with a warning. The labels
/// describe where the ads play, never the viewer; the server's configuration decides what they change.
enum Labels {
    /// `labels` less what breaks the rules: keys of `a-z`, `A-Z`, `0-9` and `_`, values not empty. Every dropped key is
    /// named once in a warning.
    static func checked(_ labels: [String: String], for videoId: String) -> [String: String] {
        var kept: [String: String] = [:]
        var dropped: [String] = []
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if !isValidKey(key) {
                dropped.append("key \"\(key)\" (only a-z, A-Z, 0-9 and _)")
            } else if value.isEmpty {
                dropped.append("\(key) (the value is empty)")
            } else {
                kept[key] = value
            }
        }
        if !dropped.isEmpty {
            Logger.warning("labels of video \(videoId): dropped \(dropped.joined(separator: ", "))")
        }
        return kept
    }

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }
}
