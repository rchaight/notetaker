@testable import ConversionKit
import Foundation
import PDFKit
import Testing

#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

struct NativeConverterTests {
    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversionTests-\(UUID().uuidString)-\(name)")
    }

    @Test func plainTextPassesThrough() async throws {
        let url = tempFile("note.txt")
        try "# Already markdown\n\n- [ ] task\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await NativeConverter().convert(url)
        #expect(result.markdown == "# Already markdown\n\n- [ ] task\n")
        #expect(result.provenance == "plain text")
        #expect(result.suggestedName.hasSuffix("note"))
    }

    @Test func pdfWithTextLayerExtracts() async throws {
        // Build a real PDF with a text layer via PDFKit annotations-free path:
        // draw into a PDF context.
        let url = tempFile("doc.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: "Provost budget meeting notes for accreditation.",
            attributes: [.font: ConversionFont.systemFont(ofSize: 24)]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let result = try await NativeConverter().convert(url)
        #expect(result.markdown.contains("accreditation"))
        #expect(result.provenance == "PDFKit text")
    }

    @Test func imageOCRReadsRenderedText() throws {
        // Render large black-on-white text and OCR it back.
        let width = 900, height = 220
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(
            string: "NOTETAKER 2026",
            attributes: [
                .font: ConversionFont.boldSystemFont(ofSize: 96),
                .foregroundColor: ConversionFont.self is AnyClass ? CGColor(gray: 0, alpha: 1) : CGColor(
                    gray: 0,
                    alpha: 1
                ),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, context)
        let image = try #require(context.makeImage())

        let text = try NativeConverter.ocr(cgImage: image)
        #expect(text.uppercased().contains("NOTETAKER"), "OCR read: \(text)")
    }

    @Test func rtfConvertsWithEmphasis() async throws {
        let rtf = NSAttributedString(
            string: "Bold words matter",
            attributes: [.font: ConversionFont.boldSystemFont(ofSize: 12)]
        )
        let data = try rtf.data(
            from: NSRange(location: 0, length: rtf.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = tempFile("styled.rtf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await NativeConverter().convert(url)
        #expect(result.markdown.contains("**Bold words matter**"))
        #expect(result.provenance == "RTF import")
    }

    @Test func unsupportedTypeThrows() async {
        let url = tempFile("archive.zip")
        await #expect(throws: ConversionError.unsupportedType("zip")) {
            _ = try await NativeConverter().convert(url)
        }
    }

    @Test func capabilityMatrix() {
        let converter = NativeConverter()
        for ext in ["pdf", "txt", "md", "png", "jpg", "rtf", "html"] {
            #expect(converter.canConvert(fileExtension: ext), Comment(rawValue: ext))
        }
        for ext in ["docx", "pptx", "xlsx", "zip", "mp3"] {
            #expect(!converter.canConvert(fileExtension: ext), "\(ext) belongs to Docling/audio tiers")
        }
    }
}

struct AttributedMarkdownTests {
    @Test func headingsByFontSize() {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: "Big Title\n",
            attributes: [.font: ConversionFont.systemFont(ofSize: 24)]
        ))
        attributed.append(NSAttributedString(
            string: "Body text here.\n",
            attributes: [.font: ConversionFont.systemFont(ofSize: 12)]
        ))
        let markdown = AttributedMarkdown.markdown(from: attributed)
        #expect(markdown.contains("# Big Title"))
        #expect(markdown.contains("Body text here."))
    }

    @Test func italicRuns() throws {
        #if canImport(AppKit)
            let italic = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        #else
            let descriptor = try #require(UIFont.systemFont(ofSize: 12).fontDescriptor.withSymbolicTraits(.traitItalic))
            let italic = UIFont(descriptor: descriptor, size: 12)
        #endif
        let attributed = NSAttributedString(string: "lean in", attributes: [.font: italic])
        #expect(AttributedMarkdown.markdown(from: attributed).contains("*lean in*"))
    }

    @Test func emptyInputYieldsEmpty() {
        #expect(AttributedMarkdown.markdown(from: NSAttributedString()) == "")
    }
}
