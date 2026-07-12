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
    #if os(macOS)
        let localEngine: PythonEngineConverter?
    #endif

    /// - Parameter useLocalEngine: tests pass false for determinism (the
    ///   File-Parser engine's presence depends on the machine).
    public init(doclingServeURL: URL?, useLocalEngine: Bool = true) {
        native = NativeConverter()
        doclingServe = doclingServeURL.map { DoclingServeConverter(baseURL: $0) }
        #if os(macOS)
            localEngine = useLocalEngine
                ? PythonEngineConverter.resolveEngineDirectory()
                .map { PythonEngineConverter(engineDirectory: $0) }
                : nil
        #endif
    }

    /// nil when nothing can take this file (message explains what would).
    public func route(fileExtension ext: String, serverReachable: Bool) -> Routing? {
        let nativeCan = native.canConvert(fileExtension: ext)
        let doclingCan = doclingServe?.canConvert(fileExtension: ext) ?? false

        // Native-first for what it handles: instant, offline, private.
        if nativeCan {
            return Routing(service: native, reason: "on-device")
        }
        #if os(macOS)
            // The onboard File-Parser engine beats the network for the rest.
            if let localEngine, localEngine.canConvert(fileExtension: ext) {
                return Routing(service: localEngine, reason: "file-parser-engine")
            }
        #endif
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
            if DoclingServeConverter.extensions.contains(ext) {
                throw ConversionError.failed(
                    "\(ext) needs Docling — install File-Parser's engine or set a docling-serve URL in Settings"
                )
            }
            throw ConversionError.unsupportedType(ext)
        }
        return try await routing.service.convert(url)
    }
}
