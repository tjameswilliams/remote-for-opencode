import Foundation
import Testing

@testable import RemoteKit

/// A JSON file sent as a file part failed a thread for good; these pin
/// the rule that decides what goes inline, what goes as a file, and what
/// never leaves the phone.
@Suite("Attachment delivery")
struct AttachmentDeliveryTests {
    @Test("Images and PDFs stay file parts")
    func binaryDocuments() {
        #expect(AttachmentDelivery.classify(mime: "image/jpeg", name: "a.jpg", bytes: Data([0xFF, 0xD8])) == .image)
        #expect(AttachmentDelivery.classify(mime: "image/png; charset=binary", name: "a", bytes: Data([0x89])) == .image)
        #expect(AttachmentDelivery.classify(mime: "application/pdf", name: "a.pdf", bytes: Data("%PDF".utf8)) == .pdf)
    }

    @Test("Text-like files go inline, whether by type, by extension, or by content")
    func textual() {
        let json = Data("{\"a\": 1}".utf8)
        #expect(AttachmentDelivery.classify(mime: "application/json", name: "x.json", bytes: json) == .text("{\"a\": 1}"))
        #expect(AttachmentDelivery.classify(mime: "application/octet-stream", name: "main.py", bytes: Data("print(1)".utf8)) == .text("print(1)"))
        #expect(AttachmentDelivery.classify(mime: "application/octet-stream", name: "notes", bytes: Data("hello\n".utf8)) == .text("hello\n"))
        #expect(AttachmentDelivery.classify(mime: "application/vnd.api+json", name: "r", bytes: json) == .text("{\"a\": 1}"))
    }

    @Test("Binary blobs and oversized text are refused")
    func refused() {
        let blob = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        #expect(AttachmentDelivery.classify(mime: "application/octet-stream", name: "a.bin", bytes: blob) == .unreadable)
        #expect(AttachmentDelivery.classify(mime: "application/zip", name: "a.zip", bytes: Data("PK".utf8)) == .unreadable)
        // Declared text that is not UTF-8 is not text.
        #expect(AttachmentDelivery.classify(mime: "text/plain", name: "a.txt", bytes: Data([0xFF, 0xFE, 0x00, 0x41])) == .unreadable)
        let big = Data(repeating: UInt8(ascii: "a"), count: AttachmentDelivery.textLimit + 1)
        #expect(AttachmentDelivery.classify(mime: "text/plain", name: "big.txt", bytes: big) == .tooLarge)
    }

    @Test("Base64 attachments classify the same way")
    func fromAttachment() {
        let attachment = Attachment(name: "cfg.yaml", mime: "application/x-yaml", data: Data("a: 1\n".utf8).base64EncodedString())
        #expect(AttachmentDelivery.classify(attachment) == .text("a: 1\n"))
    }

    @Test("Inlined text is named, fenced, and cannot break its own fence")
    func inlining() {
        let plain = AttachmentDelivery.inlined(name: "x.json", text: "{}")
        #expect(plain == "Attached file: x.json\n```json\n{}\n```")
        let tricky = AttachmentDelivery.inlined(name: "README.md", text: "```swift\nlet a = 1\n```\n")
        #expect(tricky.hasPrefix("Attached file: README.md\n````md\n"))
        #expect(tricky.hasSuffix("\n````"))
    }
}
