#if canImport(FoundationModels, _version: 2.1)
import Foundation
import FoundationModels
import UniformTypeIdentifiers

/// An MP4 clip for a prompt: `Attachment(SCXVideo(mp4: data))`. Apple's data attachments need
/// iOS 27.2, and a model that takes video needs `SCXLanguageModel.load` to report it.
@available(iOS 27.2, macOS 27.2, visionOS 27.2, watchOS 27.2, *)
public struct SCXVideo: DataAttachmentRepresentable {
    public var transcriptRepresentation: Transcript.DataAttachment

    public init(_ attachment: Transcript.DataAttachment) {
        transcriptRepresentation = attachment
    }

    public init(mp4 data: Data) {
        transcriptRepresentation = Transcript.DataAttachment(contentType: .mpeg4Movie, content: data)
    }
}
#endif
