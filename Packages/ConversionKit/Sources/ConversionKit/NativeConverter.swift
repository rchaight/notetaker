import Foundation
import PDFKit
import Vision

/// The always-available tier: on-device conversion with system frameworks
/// on both platforms. PDFs via PDFKit text extraction (OCR fallback for
/// scanned pages), images via Vision OCR, RTF/HTML via attributed-string
/// import, plain text passthrough. Docling tiers cover the hard layouts.
public struct NativeConverter: ConversionService {
    public let name = "On-device"

    public init() {}

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "bmp", "gif", "webp"]
    static let attributedExtensions: Set<String> = ["rtf", "rtfd", "html", "htm"]

    public func canConvert(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return ext == "pdf"
            || Self.textExtensions.contains(ext)
            || Self.imageExtensions.contains(ext)
            || Self.attributedExtensions.contains(ext)
    }

    public func convert(_ url: URL) async throws -> ConversionResult {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent

        if Self.textExtensions.contains(ext) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ConversionError.failed("unreadable text file")
            }
            return ConversionResult(markdown: text, provenance: "plain text", suggestedName: name)
        }
        if ext == "pdf" {
            return try await convertPDF(url, name: name)
        }
        if Self.imageExtensions.contains(ext) {
            let markdown = try await Self.ocr(imageURL: url)
            return ConversionResult(markdown: markdown, provenance: "Vision OCR", suggestedName: name)
        }
        if Self.attributedExtensions.contains(ext) {
            return try await convertAttributed(url, extension: ext, name: name)
        }
        throw ConversionError.unsupportedType(ext)
    }

    // MARK: - PDF

    private func convertPDF(_ url: URL, name: String) async throws -> ConversionResult {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.failed("unreadable PDF")
        }
        var pages: [String] = []
        var ocrPages = 0
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                pages.append(text)
            } else if let image = Self.render(page: page) {
                // Scanned page: no text layer — OCR the rendered bitmap.
                if let recognized = try? Self.ocr(cgImage: image), !recognized.isEmpty {
                    pages.append(recognized)
                    ocrPages += 1
                }
            }
        }
        let body = pages.joined(separator: "\n\n---\n\n")
        guard !body.isEmpty else { throw ConversionError.emptyResult }
        let provenance = ocrPages > 0 ? "PDFKit text + Vision OCR (\(ocrPages) scanned pages)" : "PDFKit text"
        return ConversionResult(markdown: body + "\n", provenance: provenance, suggestedName: name)
    }

    private static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - OCR

    static func ocr(imageURL: URL) async throws -> String {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ConversionError.failed("unreadable image") }
        let text = try ocr(cgImage: image)
        guard !text.isEmpty else { throw ConversionError.emptyResult }
        return text
    }

    static func ocr(cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - Attributed (RTF/HTML)

    private func convertAttributed(
        _ url: URL, extension ext: String, name: String
    ) async throws -> ConversionResult {
        let data = try Data(contentsOf: url)
        let documentType: NSAttributedString.DocumentType = (ext == "html" || ext == "htm") ? .html : .rtf
        // The HTML importer runs WebKit machinery — main thread required.
        // Convert to markdown inside the hop: NSAttributedString isn't
        // Sendable, but the resulting String is.
        let markdown = try await MainActor.run { () -> String in
            let attributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: documentType,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
            return AttributedMarkdown.markdown(from: attributed)
        }
        guard !markdown.isEmpty else { throw ConversionError.emptyResult }
        return ConversionResult(
            markdown: markdown,
            provenance: documentType == .html ? "HTML import" : "RTF import",
            suggestedName: name
        )
    }
}
