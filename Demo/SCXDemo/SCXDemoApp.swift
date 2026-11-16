import AVFoundation
import FoundationModels
import PhotosUI
import SCXSwiftKit
import SwiftUI

@main
struct SCXDemoApp: App {
    var body: some Scene {
        WindowGroup { ChatView() }
    }
}

/// A picked image or video, ready to send.
enum Media {
    case image(URL, thumbnail: UIImage?)
    case video(Data)
}

struct ConversionFailed: Error, CustomStringConvertible {
    var description: String { "This device cannot convert video to MP4. The iOS 27.0 simulator has no video export, so use a real iPhone." }
}

/// A picked video, copied out of the picker's temporary location.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = URL.temporaryDirectory.appending(path: "picked.mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }

    /// SCX takes MP4 up to 300 KB, and iPhone videos are usually HEVC in a MOV. The export keeps the
    /// first 15 seconds of the picture and drops the sound, which leaves the 300 KB for the picture.
    /// It aims at 270 KB, because `fileLengthLimit` is only a target for the encoder.
    func convertedToMP4() async throws -> Data {
        let output = URL.temporaryDirectory.appending(path: "picked.mp4")
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: url)
        let fifteenSeconds = CMTime(seconds: 15, preferredTimescale: 600)
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(try await asset.load(.duration), fifteenSeconds))
        let picture = AVMutableComposition()
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let track = picture.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ConversionFailed() }
        try track.insertTimeRange(range, of: video, at: .zero)
        track.preferredTransform = try await video.load(.preferredTransform)
        guard let export = AVAssetExportSession(asset: picture, presetName: AVAssetExportPresetMediumQuality) else { throw ConversionFailed() }
        export.fileLengthLimit = 270_000
        try await export.export(to: output, as: .mp4)
        return try Data(contentsOf: output)
    }
}

/// One screen: pick an SCX model, ask, optionally attach a photo or video, watch the answer stream
/// through Apple's `LanguageModelSession`.
struct ChatView: View {
    @State private var apiKey = ProcessInfo.processInfo.environment["SCX_API_KEY"] ?? ""
    @State private var modelID = "MAGPiE"
    @State private var prompt = "Which Australian regulator supervises banks, and what does it do? Two sentences."
    @State private var pickerItem: PhotosPickerItem?
    @State private var media: Media?
    @State private var answer = ""
    @State private var reasoning = ""
    @State private var status = "Ready"
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: $modelID) {
                    Text("MAGPiE").tag("MAGPiE")
                    Text("GLM-5.3").tag("GLM-5.3")
                    Text("Qwen3-32B").tag("Qwen3-32B")
                    Text("GLM-5.3-Flash (image)").tag("GLM-5.3-Flash")
                    Text("gemma-4-31B-it (image, video)").tag("gemma-4-31B-it")
                    Text("Kimi-K3.1-Pro (image, video)").tag("Kimi-K3.1-Pro")
                }
                .pickerStyle(.menu)

                SecureField("SCX API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Ask something", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack {
                    // `.current` hands over the stored file. The app converts video itself, so the picker need not.
                    PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Label("Image or video", systemImage: "paperclip")
                    }
                    switch media {
                    case .image(_, let thumbnail?):
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6))
                    case .video(let data):
                        Label(Int64(data.count).formatted(.byteCount(style: .file)), systemImage: "video")
                            .font(.caption)
                    default:
                        EmptyView()
                    }
                    if media != nil {
                        Button("Remove", systemImage: "xmark.circle.fill") { pickerItem = nil }
                            .labelStyle(.iconOnly)
                    }
                }
                .onChange(of: pickerItem) { Task { await preparePicked() } }

                Button(isBusy ? "Working…" : "Send") { Task { await send() } }
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

    private func preparePicked() async {
        media = nil
        guard let pickerItem else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Preparing attachment…"
        do {
            if pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try await pickerItem.loadTransferable(type: Movie.self) {
                    media = .video(try await movie.convertedToMP4())
                }
            } else if let data = try await pickerItem.loadTransferable(type: Data.self) {
                // A file keeps the EXIF rotation, which `Attachment(imageURL:)` reads.
                let url = URL.temporaryDirectory.appending(path: "picked-image")
                try data.write(to: url)
                media = .image(url, thumbnail: UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 132, height: 132)))
            }
            status = media == nil ? "Could not read that file" : "Ready"
        } catch {
            status = "Error: \(error)"
        }
    }

    /// The text with the picked file, or nil for a video on a system older than iOS 27.2.
    private func fullPrompt() -> Prompt? {
        switch media {
        case .image(let url, _):
            return Prompt { prompt; FoundationModels.Attachment(imageURL: url) }
        case .video(let mp4):
            #if canImport(FoundationModels, _version: 2.1)
            if #available(iOS 27.2, *) {
                return Prompt { prompt; FoundationModels.Attachment(SCXVideo(mp4: mp4)) }
            }
            #endif
            return nil
        case nil:
            return Prompt(prompt)
        }
    }

    private func send() async {
        guard let input = fullPrompt() else {
            status = "Video needs iOS 27.2 or later"
            return
        }
        isBusy = true
        answer = ""
        reasoning = ""
        status = "Streaming from api.scx.ai · \(modelID)"
        let started = Date()
        do {
            let model = try await SCXLanguageModel.load(model: modelID, apiKey: apiKey)
            let session = LanguageModelSession(
                model: model,
                instructions: Instructions("You are a sovereign Australian AI assistant hosted by SCX.ai. Be concise."))
            for try await snapshot in session.streamResponse(to: input) {
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
