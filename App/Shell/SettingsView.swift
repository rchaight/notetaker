import ConversionKit
import SwiftUI

/// App settings; sections fill in as their milestones land (vault location,
/// AI providers, appearance, security).
struct SettingsView: View {
    @AppStorage("doclingServeURL") private var doclingServeURL = ""
    @State private var probeResult: String?

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section("General") {
                        LabeledContent("Version", value: "0.1.0 (pre-alpha)")
                    }
                    Section("Document conversion") {
                        TextField("Docling server URL", text: $doclingServeURL, prompt: Text("http://homelab:5001"))
                            .autocorrectionDisabled()
                        HStack {
                            Button("Test Connection") {
                                probeResult = "testing…"
                                Task {
                                    guard let url = URL(string: doclingServeURL), !doclingServeURL.isEmpty else {
                                        probeResult = "enter a URL first"
                                        return
                                    }
                                    let reachable = await DoclingServeConverter(baseURL: url).isReachable()
                                    probeResult = reachable
                                        ? "✓ docling-serve reachable"
                                        : "✗ not reachable — check the URL and that the container is running"
                                }
                            }
                            if let probeResult {
                                Text(probeResult)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(
                            "Converts DOCX, PPTX, XLSX and complex PDFs with full layout analysis. Run docling-serve on your homelab: docker run -p 5001:5001 quay.io/docling-project/docling-serve"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Tab("Vault", systemImage: "icloud") {
                VaultDebugView()
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

#Preview {
    SettingsView()
}
