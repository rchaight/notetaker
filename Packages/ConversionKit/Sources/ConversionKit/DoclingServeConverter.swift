import Foundation

/// HTTP tier: converts via a docling-serve instance (e.g. a container on
/// the user's homelab). Handles the formats native frameworks can't —
/// DOCX/PPTX/XLSX with real layout analysis — and works from iOS too.
public struct DoclingServeConverter: ConversionService {
    public let name = "Docling (server)"

    let baseURL: URL
    let session: URLSession

    /// docling-serve's import coverage beyond the native tier.
    static let extensions: Set<String> = [
        "pdf", "docx", "pptx", "xlsx", "csv", "html", "htm", "adoc", "asciidoc", "md",
        "png", "jpg", "jpeg", "tiff", "bmp", "webp",
    ]

    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 600 // big PDFs take a while
            self.session = URLSession(configuration: configuration)
        }
    }

    public func canConvert(fileExtension: String) -> Bool {
        Self.extensions.contains(fileExtension.lowercased())
    }

    /// GET /health — cheap reachability probe for the router and Settings.
    public func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func convert(_ url: URL) async throws -> ConversionResult {
        let data = try Data(contentsOf: url)
        let boundary = "notetaker-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("v1alpha/convert/file"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body
                .append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
                        .utf8))
        }
        appendField("to_formats", "md")
        body
            .append(
                Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                    .utf8)
            )
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ConversionError.failed("docling-serve HTTP \(code)")
        }
        guard let markdown = Self.extractMarkdown(from: responseData), !markdown.isEmpty else {
            throw ConversionError.emptyResult
        }
        return ConversionResult(
            markdown: markdown.hasSuffix("\n") ? markdown : markdown + "\n",
            provenance: "Docling (server)",
            suggestedName: url.deletingPathExtension().lastPathComponent
        )
    }

    /// Tolerant response parsing: docling-serve nests markdown at
    /// document.md_content; accept a couple of shapes so minor server
    /// version drift doesn't break imports.
    static func extractMarkdown(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let document = json["document"] as? [String: Any],
           let markdown = document["md_content"] as? String {
            return markdown
        }
        if let markdown = json["md_content"] as? String {
            return markdown
        }
        if let documents = json["documents"] as? [[String: Any]],
           let markdown = documents.first?["md_content"] as? String {
            return markdown
        }
        return nil
    }
}
