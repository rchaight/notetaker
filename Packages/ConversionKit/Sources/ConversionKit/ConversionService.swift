import Foundation

/// The outcome of converting an external document to vault markdown.
public struct ConversionResult: Equatable, Sendable {
    public let markdown: String
    /// Human-visible engine label, e.g. "PDFKit text" or "Vision OCR" —
    /// provenance is part of the product (on-device basic vs full Docling).
    public let provenance: String
    /// Suggested note filename (no extension).
    public let suggestedName: String

    public init(markdown: String, provenance: String, suggestedName: String) {
        self.markdown = markdown
        self.provenance = provenance
        self.suggestedName = suggestedName
    }
}

public enum ConversionError: Error, Equatable, Sendable {
    case unsupportedType(String)
    case emptyResult
    case failed(String)
}

/// One conversion tier. The router (M5 later pass) picks among
/// NativeConverter | PythonEngineConverter (macOS Docling) |
/// DoclingServeConverter (homelab HTTP) by input type + platform +
/// connectivity.
public protocol ConversionService: Sendable {
    var name: String { get }
    func canConvert(fileExtension: String) -> Bool
    func convert(_ url: URL) async throws -> ConversionResult
}
