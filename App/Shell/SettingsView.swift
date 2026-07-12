import AIKit
import ConversionKit
import SwiftUI

/// App settings; sections fill in as their milestones land (vault location,
/// AI providers, appearance, security).
struct SettingsView: View {
    @AppStorage("doclingServeURL") private var doclingServeURL = ""
    @State private var probeResult: String?
    @AppStorage("ollamaURL") private var ollamaURL = ""
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @State private var ollamaModels: [String] = []
    @State private var ollamaProbe: String?

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
                                    guard let url = ServerURL.normalize(doclingServeURL) else {
                                        probeResult = "enter a URL like http://homelab:5001"
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
                    Section("AI — Ollama (homelab)") {
                        TextField("Ollama server URL", text: $ollamaURL, prompt: Text("http://homelab:11434"))
                            .autocorrectionDisabled()
                        HStack {
                            Button("Test Connection") {
                                ollamaProbe = "testing…"
                                Task {
                                    guard let url = ServerURL.normalize(ollamaURL) else {
                                        ollamaProbe = "enter a URL like http://localhost:11434"
                                        return
                                    }
                                    do {
                                        let models = try await OllamaProvider(baseURL: url, model: "probe").listModels()
                                        ollamaModels = models
                                        if ollamaModel.isEmpty, let first = models.first {
                                            ollamaModel = first
                                        }
                                        ollamaProbe = "✓ \(models.count) model(s) available"
                                    } catch {
                                        ollamaProbe = "✗ not reachable"
                                    }
                                }
                            }
                            if let ollamaProbe {
                                Text(ollamaProbe)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !ollamaModels.isEmpty {
                            Picker("Model", selection: $ollamaModel) {
                                ForEach(ollamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        } else if !ollamaModel.isEmpty {
                            LabeledContent("Model", value: ollamaModel)
                        }
                        Text(
                            "Long notes beyond the on-device model's window route here; content only ever goes to your own server."
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
