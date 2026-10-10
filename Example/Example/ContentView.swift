import KontextVideoSDK
import SwiftUI

struct ContentView: View {
    @ObservedObject var status: SDKStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("SDK version", KontextVideo.version)
            row("Install id", KontextVideo.installId)
            row("Publisher token", KontextVideo.shared.configuration?.publisherToken ?? "not initialised")
            row("State", status.state)
            ForEach(Array(status.loads.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}
