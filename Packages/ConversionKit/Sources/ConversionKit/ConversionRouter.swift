import Foundation

/// Picks the conversion tier: fast on-device native for what it does well
/// (text, images, PDFs with text layers), the Docling server for office
/// formats and anything native can't take. Falls back gracefully.
public struct ConversionRouter: Sendable {
    public struct Routing: Sendable {
        public let service: any ConversionService
        public let reason: String
    }

    let native: NativeConverter
    let doclingServe: DoclingServeConverter?

    public init(doclingServeURL: URL?) {
        native = NativeConverter()
        doclingServe = doclingServeURL.map { DoclingServeConverter(baseURL: $0) }
    }

    /// nil when nothing can take this file (message explains what would).
    public func route(fileExtension ext: String, serverReachable: Bool) -> Routing? {
        let nativeCan = native.canConvert(fileExtension: ext)
        let doclingCan = doclingServe?.canConvert(fileExtension: ext) ?? false

        // Native-first for what it handles: instant, offline, private.
        if nativeCan {
            return Routing(service: native, reason: "on-device")
        }
        if doclingCan, serverReachable, let doclingServe {
            return Routing(service: doclingServe, reason: "docling-serve")
        }
        return nil
    }

    /// End-to-end: probe once, route, convert.
    public func convert(_ url: URL) async throws -> ConversionResult {
        let ext = url.pathExtension.lowercased()
        let reachable: Bool = if let doclingServe, !native.canConvert(fileExtension: ext) {
            await doclingServe.isReachable()
        } else {
            false
        }
        guard let routing = route(fileExtension: ext, serverReachable: reachable) else {
            if doclingServe == nil, DoclingServeConverter.extensions.contains(ext) {
                throw ConversionError.failed("\(ext) needs a Docling server — set one in Settings")
            }
            if DoclingServeConverter.extensions.contains(ext) {
                throw ConversionError.failed("\(ext) needs the Docling server, which is unreachable")
            }
            throw ConversionError.unsupportedType(ext)
        }
        return try await routing.service.convert(url)
    }
}
