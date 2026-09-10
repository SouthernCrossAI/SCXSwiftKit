import FoundationModels
import SCXSwiftKit
import SwiftUI

@main
struct SCXDemoApp: App {
    var body: some Scene {
        WindowGroup { ChatView() }
    }
}

/// One screen: pick an SCX model, ask, watch the answer stream through Apple's `LanguageModelSession`.
struct ChatView: View {
    @State private var apiKey = ProcessInfo.processInfo.environment["SCX_API_KEY"] ?? ""
    @State private var modelID = "MAGPiE"
    @State private var prompt = "Which Australian regulator supervises banks, and what does it do? Two sentences."
    @State private var answer = ""
    @State private var reasoning = ""
    @State private var status = "Ready"
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: $modelID) {
                    Text("MAGPiE").tag("MAGPiE")
                    Text("GLM-5.2").tag("GLM-5.2")
                    Text("Qwen3-32B").tag("Qwen3-32B")
                }
                .pickerStyle(.segmented)

                SecureField("SCX API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Ask something", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                Button(isBusy ? "Streaming…" : "Send") { Task { await send() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || prompt.isEmpty || apiKey.isEmpty)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !reasoning.isEmpty {
                            Text("Reasoning").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(reasoning).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(answer).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("SCX × Foundation Models")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Launch with SCX_DEMO_AUTOSEND=1 to send the prefilled prompt immediately (used for recordings).
            if ProcessInfo.processInfo.environment["SCX_DEMO_AUTOSEND"] != nil, !apiKey.isEmpty {
                try? await Task.sleep(for: .seconds(1.5))
                await send()
            }
        }
    }

    private func send() async {
        isBusy = true
        answer = ""
        reasoning = ""
        status = "Streaming from api.scx.ai · \(modelID)"
        let started = Date()
        do {
            let model = SCXLanguageModel(model: modelID, apiKey: apiKey)
            let session = LanguageModelSession(
                model: model,
                instructions: Instructions("You are a sovereign Australian AI assistant hosted by SCX.ai. Be concise."))
            for try await snapshot in session.streamResponse(to: prompt) {
                answer = snapshot.content
            }
            for case .reasoning(let entry) in session.transcript {
                reasoning = entry.segments.compactMap { segment -> String? in
                    if case .text(let text) = segment { return text.content }
                    return nil
                }.joined()
            }
            status = String(format: "Done in %.1f s · %@ via LanguageModelSession", Date().timeIntervalSince(started), modelID)
        } catch {
            status = "Error: \(error)"
        }
        isBusy = false
    }
}
