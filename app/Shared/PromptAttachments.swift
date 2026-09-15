import RemoteKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

#if canImport(UIKit)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

/// Files staged for the next prompt, and the shrinking that makes sending
/// them from a phone reasonable.
///
/// Images are downscaled before they ever reach the wire. A 12MP photo is
/// ~4 MB that takes real time on cellular and buys nothing: vision models
/// see a resized copy anyway, so the long side is capped and the result
/// re-encoded as JPEG. What the user sees on screen is the thumbnail; what
/// travels is the transit copy.
@MainActor
final class PromptAttachments: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published var error: String?

    struct Item: Identifiable {
        let id = UUID().uuidString
        var name: String
        var mime: String
        var data: Data
        /// Rendered for the composer strip; nil for non-images.
        var thumbnail: PlatformImage?
        /// A block of text pasted into the composer and lifted out of the
        /// field. It travels as a text attachment (the Mac inlines it in
        /// the prompt, fenced and named) and the strip draws it as a
        /// "Pasted text" chip rather than a file.
        var pasted = false

        /// For the pasted-text chip.
        var lineCount: Int {
            PromptAttachments.lineCount(of: String(decoding: data, as: UTF8.self))
        }
    }

    /// A paste this long goes into a chip instead of the field. The
    /// vertical text field re-lays out its whole content on every
    /// keystroke, and a few thousand characters of log output is enough to
    /// make typing after it stutter; the same cutoffs the terminal agents
    /// use, where the chip convention comes from.
    nonisolated static let pasteCharacterLimit = 800
    nonisolated static let pasteLineLimit = 10

    nonisolated static func isLargePaste(_ text: String) -> Bool {
        text.count > pasteCharacterLimit || lineCount(of: text) > pasteLineLimit
    }

    /// Every line ending Swift knows as one (CRLF included); a trailing
    /// newline is not a line.
    nonisolated static func lineCount(of text: String) -> Int {
        let body = text.last?.isNewline == true ? text.dropLast() : text[...]
        return body.isEmpty ? 0 : body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    /// Matches the Mac's limit, checked here too so the failure lands
    /// before a long upload rather than after it.
    private static let totalLimit = 20 << 20

    var isEmpty: Bool { items.isEmpty }

    /// Sizing and encoding both live in RemoteKit/ImageShaping — the same
    /// conventions Tomte validated: ImageIO thumbnailing (EXIF-correct, no
    /// full decode), 1024px at 0.7, refuse anything still over 2 MB after.
    func add(imageData raw: Data, name: String = "image.jpg") {
        guard let jpeg = ImageShaping.downscaledJPEG(from: raw) else {
            error = "That file isn't an image this app can read."
            return
        }
        guard jpeg.count <= ImageShaping.maxBytes else {
            error = "That image is too large to send."
            return
        }
        append(Item(
            name: name, mime: "image/jpeg", data: jpeg, thumbnail: PlatformImage(data: jpeg)
        ))
    }

    #if os(iOS)
    /// Camera captures arrive as UIImage rather than file bytes; hand the
    /// same pipeline a JPEG to work from.
    func add(image: UIImage, name: String = "photo.jpg") {
        guard let raw = image.jpegData(compressionQuality: 0.95) else {
            error = "Couldn't prepare that photo."
            return
        }
        add(imageData: raw, name: name)
    }
    #endif

    func add(fileAt url: URL) {
        // Security-scoped: files from the document picker live outside our
        // sandbox and the scope must be opened before reading.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            error = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        if mime.hasPrefix("image/") {
            add(imageData: data, name: url.lastPathComponent)
            return
        }
        stage(name: url.lastPathComponent, mime: mime, data: data)
    }

    /// Text pasted into the composer, lifted out of the field. Numbered
    /// from the second one on, so two pastes in one message stay apart in
    /// the transcript's attachment line and in the prompt the model reads.
    func add(pastedText text: String) {
        let count = items.filter(\.pasted).count
        let name = count == 0 ? "Pasted text.txt" : "Pasted text \(count + 1).txt"
        stage(name: name, mime: "text/plain", data: Data(text.utf8), pasted: true)
    }

    /// Refuse here what the Mac would refuse anyway, so the failure lands
    /// before an upload rather than after it, and never in the thread.
    /// Text and PDFs then ride as-is: they are compressed inside the seal
    /// (Wire.Squeeze), and re-encoding would only lose fidelity the model
    /// may need.
    private func stage(name: String, mime: String, data: Data, pasted: Bool = false) {
        switch AttachmentDelivery.classify(mime: mime, name: name, bytes: data) {
        case .unreadable:
            error = "\(name) isn't something the model can read. Send text files, images, or PDFs."
            return
        case .tooLarge:
            error = pasted
                ? "That paste is too large to send (limit \(AttachmentDelivery.textLimit >> 10) KB)."
                : "\(name) is too large to send as text (limit \(AttachmentDelivery.textLimit >> 10) KB)."
            return
        case .image, .pdf, .text:
            break
        }
        append(Item(name: name, mime: mime, data: data, thumbnail: nil, pasted: pasted))
    }

    #if os(iOS)
    func load(_ selection: [PhotosPickerItem]) async {
        for item in selection {
            guard let data = try? await item.loadTransferable(type: Data.self)
            else { continue }
            // The picker's own filename when it has one; the shaping
            // pipeline transcodes to JPEG either way.
            add(imageData: data, name: item.supportedContentTypes.first?.preferredFilenameExtension
                .map { "image.\($0)" } ?? "image.jpg")
        }
    }
    #endif

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
    }

    /// What goes on the wire.
    func wireAttachments() -> [Attachment] {
        items.map {
            Attachment(
                id: $0.id, name: $0.name, mime: $0.mime,
                data: $0.data.base64EncodedString()
            )
        }
    }

    private func append(_ item: Item) {
        let total = items.reduce(0) { $0 + $1.data.count } + item.data.count
        guard total <= Self.totalLimit else {
            error = "That would exceed the \(Self.totalLimit >> 20) MB limit for one message."
            return
        }
        items.append(item)
    }

}

/// The strip above the field: what's coming along, and a way to change your
/// mind about each one.
struct AttachmentStrip: View {
    @ObservedObject var attachments: PromptAttachments

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments.items) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = item.thumbnail {
                                #if canImport(UIKit)
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                #else
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                #endif
                            } else if item.pasted {
                                // Line count rather than a file name: what
                                // was pasted has no name, and how much of
                                // it there is says what the chip holds.
                                VStack(spacing: 2) {
                                    Image(systemName: "text.alignleft")
                                        .font(.title3)
                                    Text("Pasted text")
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                    Text("\(item.lineCount) lines")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.primary.opacity(0.06))
                            } else {
                                VStack(spacing: 2) {
                                    Image(systemName: "doc")
                                        .font(.title3)
                                    Text(item.name)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                        .padding(.horizontal, 4)
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.primary.opacity(0.06))
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button {
                            attachments.remove(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel(item.pasted ? "Remove pasted text" : "Remove \(item.name)")
                    }
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 6)
        }
        .frame(height: 66)
    }
}
