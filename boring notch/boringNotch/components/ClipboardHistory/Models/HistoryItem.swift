//
//  HistoryItem.swift
//  boringNotch — ported/adapted from Maccy
//

import AppKit
import Defaults
import SwiftData
import UniformTypeIdentifiers
import Vision

@Model
final class HistoryItem {
    private static let transientTypes: [String] = [
        NSPasteboard.PasteboardType.modified.rawValue,
        NSPasteboard.PasteboardType.fromMaccy.rawValue,
        NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
        NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
        NSPasteboard.PasteboardType.source.rawValue,
        NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
        NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
        NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
        NSPasteboard.PasteboardType.notesRichText.rawValue
    ]

    var application: String?
    var firstCopiedAt: Date = Date.now
    var lastCopiedAt: Date = Date.now
    var numberOfCopies: Int = 1
    var pin: String?
    var title = ""

    @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
    var contents: [HistoryItemContent] = []

    init(contents: [HistoryItemContent] = []) {
        self.contents = contents
    }

    var isPinned: Bool { pin != nil }

    func supersedes(_ item: HistoryItem) -> Bool {
        item.contents
            .filter { content in
                !Self.transientTypes.contains(content.type)
            }
            .allSatisfy { content in
                contents.contains(where: { $0.type == content.type && $0.value == content.value })
            }
    }

    func generateTitle() -> String {
        guard image == nil else {
            Task { @MainActor in
                self.performTextRecognition()
            }
            return ""
        }

        var title = previewableText.shortened(to: 1_000)

        if Defaults[.clipboardShowSpecialSymbols] {
            if let range = title.range(of: "^ +", options: .regularExpression) {
                title = title.replacingOccurrences(of: " ", with: "·", range: range)
            }
            if let range = title.range(of: " +$", options: .regularExpression) {
                title = title.replacingOccurrences(of: " ", with: "·", range: range)
            }
            title = title
                .replacingOccurrences(of: "\n", with: "⏎")
                .replacingOccurrences(of: "\t", with: "⇥")
        } else {
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title
    }

    var previewableText: String {
        if !fileURLs.isEmpty {
            return fileURLs
                .compactMap { $0.absoluteString.removingPercentEncoding }
                .joined(separator: "\n")
        } else if let text = text, !text.isEmpty {
            return text
        } else if let rtf = rtf, !rtf.string.isEmpty {
            return rtf.string
        } else if let html = html, !html.string.isEmpty {
            return html.string
        } else {
            return title
        }
    }

    var fileURLs: [URL] {
        guard !universalClipboardText else {
            return []
        }

        return allContentData([.fileURL])
            .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
    }

    var htmlData: Data? { contentData([.html]) }
    var html: NSAttributedString? {
        guard let data = htmlData else { return nil }
        return NSAttributedString(html: data, documentAttributes: nil)
    }

    var imageData: Data? {
        var data: Data?
        data = contentData([.tiff, .png, .jpeg, .heic, .image])
        if data == nil, universalClipboardImage, let url = fileURLs.first {
            data = try? Data(contentsOf: url)
        }
        return data
    }

    var image: NSImage? {
        if let data = imageData, let image = NSImage(data: data) {
            return image
        }

        // Finder copies image files as file URLs rather than bitmap data.
        // Keep the file URL for paste support, but use the file itself for the visual preview.
        guard let imageURL = imageFileURL else { return nil }
        return NSImage(contentsOf: imageURL)
    }

    var rtfData: Data? { contentData([.rtf]) }
    var rtf: NSAttributedString? {
        guard let data = rtfData else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    var text: String? {
        guard let data = contentData([.string]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var modified: Int? {
        guard let data = contentData([.modified]),
              let modified = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Int(modified)
    }

    var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
    var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

    private var universalClipboardImage: Bool {
        universalClipboard && fileURLs.first?.pathExtension.lowercased() == "jpeg"
    }
    private var universalClipboardText: Bool {
        universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic, .image]) != nil
    }

    private var imageFileURL: URL? {
        fileURLs.first { url in
            guard url.isFileURL else { return false }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }

    /// First file URL that points at a video / movie asset (Finder copy, etc.).
    var videoFileURL: URL? {
        fileURLs.first { url in
            guard url.isFileURL else { return false }
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .video)
        }
    }

    /// URL best suited for QuickLook / thumbnail generation (image file or video).
    var mediaPreviewURL: URL? {
        if let imageFileURL { return imageFileURL }
        return videoFileURL
    }

    var contentKind: ClipboardContentKind {
        if image != nil { return .image }
        if videoFileURL != nil { return .video }
        if !fileURLs.isEmpty { return .file }
        if let text = text, let url = URL(string: text), url.scheme != nil, text.contains("://") {
            return .link
        }
        return .text
    }

    private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
        let content = contents.first(where: { content in
            types.contains(NSPasteboard.PasteboardType(content.type))
        })
        return content?.value
    }

    private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
        contents
            .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
            .compactMap { $0.value }
    }

    private func performTextRecognition() {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let requestHandler = VNImageRequestHandler(cgImage: cgImage)
        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            self?.title = recognizedStrings.joined(separator: "\n")
        }
        request.recognitionLevel = .fast

        do {
            try requestHandler.perform([request])
        } catch {
            print("Unable to perform OCR request: \(error).")
        }
    }
}

enum ClipboardContentKind: String {
    case text
    case image
    case video
    case file
    case link

    var systemImage: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .video: return "video"
        case .file: return "doc"
        case .link: return "link"
        }
    }

    /// Image / video cards render a visual thumbnail instead of text.
    var isVisualMedia: Bool {
        switch self {
        case .image, .video: return true
        default: return false
        }
    }
}
