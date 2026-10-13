import KontextVideoSDK
import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var demo: Demo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                row("SDK", KontextVideo.version)
                Spacer()
                row("State", demo.state)
            }

            // The player: the content plays here; the SDK places overlay and pause ads inside it.
            PlayerView(view: demo.playerView)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)

            HStack {
                Button("Load pause") { demo.loadPauseAd() }
                Button("Pause") { demo.viewerPaused() }
                Button("Resume") { demo.viewerResumed() }
            }
            HStack {
                Button("Load overlay") { demo.loadOverlay() }
                Button("Show") { demo.showOverlay() }
                Button("Dismiss") { demo.dismissOverlay() }
            }
            HStack {
                Button("Load linear") { demo.loadLinear() }
                Button("Show") { demo.showLinear() }
                Spacer()
                Button("Destroy") { demo.destroy() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(demo.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced))
        }
    }
}

/// Hosts the demo player's UIView in SwiftUI; the SDK adds ad views into it.
struct PlayerView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view.backgroundColor = .black
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
