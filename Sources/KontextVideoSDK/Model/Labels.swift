/// The checks behind `VideoAds.labels`: what the SDK sends, and what it drops with a warning. The labels
/// describe where the ads play, never the viewer; the server's configuration decides what they change.
enum Labels {
    /// At most this many pairs: the first in key order are kept.
    static let maxCount = 20
    /// A key or a value of more UTF-8 bytes is dropped, not cut: a cut value would match another rule.
    static let maxBytes = 64

    /// `labels` less what breaks the rules: keys of `a-z`, `0-9` and `_`, values not empty, both at most
    /// `maxBytes`, at most `maxCount` pairs. Every dropped key is named once in a warning.
    static func checked(_ labels: [String: String], for videoId: String) -> [String: String] {
        var kept: [String: String] = [:]
        var dropped: [String] = []
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if !isValidKey(key) {
                dropped.append("key \"\(key.prefix(maxBytes))\" (only a-z, 0-9 and _, at most \(maxBytes) bytes)")
            } else if value.isEmpty || value.utf8.count > maxBytes {
                dropped.append("\(key) (the value must be 1 to \(maxBytes) bytes)")
            } else if kept.count == maxCount {
                dropped.append("\(key) (more than \(maxCount) labels)")
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
        !key.isEmpty && key.utf8.count <= maxBytes
            && key.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }
}
