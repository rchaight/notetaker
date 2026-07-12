@testable import ConversionKit
import Foundation
import Testing

/// URLProtocol stub so the Docling tier is tested without a real server.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct DoclingServeConverterTests {
    private func makeConverter() -> DoclingServeConverter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DoclingServeConverter(
            baseURL: URL(string: "http://homelab.test:5001")!,
            session: URLSession(configuration: configuration)
        )
    }

    @Test func convertsViaServer() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/health") == true {
                return (200, Data())
            }
            #expect(request.url?.path.hasSuffix("/v1alpha/convert/file") == true)
            let json = ##"{"status":"success","document":{"md_content":"# Converted\n\nA table survived."}}"##
            return (200, Data(json.utf8))
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).docx")
        try Data("fake docx".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = try await makeConverter().convert(temp)
        #expect(result.markdown.contains("# Converted"))
        #expect(result.provenance == "Docling (server)")
    }

    @Test func serverErrorSurfaces() async throws {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("err-\(UUID()).docx")
        try Data("x".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        await #expect(throws: ConversionError.failed("docling-serve HTTP 500")) {
            _ = try await makeConverter().convert(temp)
        }
    }

    @Test func healthProbe() async {
        StubURLProtocol.handler = { _ in (200, Data()) }
        #expect(await makeConverter().isReachable())
        StubURLProtocol.handler = { _ in (503, Data()) }
        #expect(await !(makeConverter().isReachable()))
    }

    @Test func tolerantResponseParsing() {
        let nested = ##"{"document":{"md_content":"# A"}}"##
        let flat = ##"{"md_content":"# B"}"##
        let list = ##"{"documents":[{"md_content":"# C"}]}"##
        #expect(DoclingServeConverter.extractMarkdown(from: Data(nested.utf8)) == "# A")
        #expect(DoclingServeConverter.extractMarkdown(from: Data(flat.utf8)) == "# B")
        #expect(DoclingServeConverter.extractMarkdown(from: Data(list.utf8)) == "# C")
        #expect(DoclingServeConverter.extractMarkdown(from: Data("not json".utf8)) == nil)
    }
}

struct ConversionRouterTests {
    @Test func nativeFirstForItsFormats() {
        let router = ConversionRouter(doclingServeURL: URL(string: "http://homelab.test:5001"), useLocalEngine: false)
        for ext in ["pdf", "txt", "png", "rtf"] {
            #expect(router.route(fileExtension: ext, serverReachable: true)?.reason == "on-device")
        }
    }

    @Test func officeFormatsGoToDocling() {
        let router = ConversionRouter(doclingServeURL: URL(string: "http://homelab.test:5001"), useLocalEngine: false)
        for ext in ["docx", "pptx", "xlsx", "csv"] {
            #expect(router.route(fileExtension: ext, serverReachable: true)?.reason == "docling-serve")
        }
    }

    @Test func officeWithoutServerRoutesNowhere() {
        let noServer = ConversionRouter(doclingServeURL: nil, useLocalEngine: false)
        #expect(noServer.route(fileExtension: "docx", serverReachable: false) == nil)
        let unreachable = ConversionRouter(
            doclingServeURL: URL(string: "http://homelab.test:5001"),
            useLocalEngine: false
        )
        #expect(unreachable.route(fileExtension: "docx", serverReachable: false) == nil)
    }

    @Test func unknownTypesRouteNowhere() {
        let router = ConversionRouter(doclingServeURL: URL(string: "http://homelab.test:5001"), useLocalEngine: false)
        #expect(router.route(fileExtension: "zip", serverReachable: true) == nil)
    }
}

struct ServerURLTests {
    @Test func normalizesBareHostPort() {
        #expect(ServerURL.normalize("localhost:11434")?.absoluteString == "http://localhost:11434")
        #expect(ServerURL.normalize("10.0.5.100:5001")?.absoluteString == "http://10.0.5.100:5001")
        #expect(ServerURL.normalize("https://secure.host:9443")?.absoluteString == "https://secure.host:9443")
        #expect(ServerURL.normalize("  http://x:1 ") != nil)
        #expect(ServerURL.normalize("") == nil)
        #expect(ServerURL.normalize("   ") == nil)
    }
}

#if os(macOS)
    struct LocalEngineRoutingTests {
        @Test(.enabled(if: PythonEngineConverter.resolveEngineDirectory() != nil))
        func officeFormatsPreferTheOnboardEngine() {
            let router = ConversionRouter(doclingServeURL: nil)
            #expect(router.route(fileExtension: "docx", serverReachable: false)?.reason == "file-parser-engine")
        }
    }

    /// Live test against the REAL File-Parser engine when installed.
    struct PythonEngineLiveTests {
        static var engineInstalled: Bool {
            PythonEngineConverter.resolveEngineDirectory() != nil
        }

        @Test(.enabled(if: engineInstalled), .timeLimit(.minutes(5)))
        func convertsCSVThroughRealEngine() async throws {
            let csv = FileManager.default.temporaryDirectory
                .appendingPathComponent("engine-live-\(UUID().uuidString).csv")
            try "course,enrollment\nPHAR 7315,94\nPHAR 7420,88\n"
                .write(to: csv, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: csv) }

            let engine = try PythonEngineConverter(
                engineDirectory: #require(PythonEngineConverter.resolveEngineDirectory())
            )
            let result = try await engine.convert(csv)
            #expect(result.markdown.contains("PHAR 7315"))
            #expect(result.provenance.contains("File-Parser"))
        }
    }
#endif
