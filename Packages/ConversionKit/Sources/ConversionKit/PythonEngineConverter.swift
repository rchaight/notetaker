#if os(macOS)
    import Foundation

    /// The onboard Docling tier: drives the File-Parser Python engine the
    /// user already has installed (github.com/rchaight/File-Parser). Full
    /// layout analysis with zero network. macOS only — and only possible
    /// because the macOS app ships unsandboxed (Developer ID .dmg).
    public struct PythonEngineConverter: ConversionService {
        public let name = "Docling (File-Parser engine)"

        let engineDirectory: URL

        /// Mirrors File-Parser's conversion options (CLI --no-ocr/--no-tables).
        public struct Options: Sendable {
            public var ocr: Bool
            public var tableStructure: Bool

            public init(ocr: Bool = true, tableStructure: Bool = true) {
                self.ocr = ocr
                self.tableStructure = tableStructure
            }

            /// Reads the app's settings keys (default: both enabled).
            public static func fromDefaults() -> Options {
                let defaults = UserDefaults.standard
                return Options(
                    ocr: defaults.object(forKey: "fileParserOCR") as? Bool ?? true,
                    tableStructure: defaults.object(forKey: "fileParserTables") as? Bool ?? true
                )
            }
        }

        let options: Options

        /// Resolution order mirrors File-Parser's own EngineBridge:
        /// explicit setting → canonical install → dev repo.
        public static func resolveEngineDirectory() -> URL? {
            let fm = FileManager.default
            func valid(_ url: URL) -> Bool {
                fm.fileExists(atPath: url.appendingPathComponent(".venv/bin/python").path)
            }
            if let configured = UserDefaults.standard.string(forKey: "fileParserEngineDir"),
               !configured.isEmpty {
                let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
                if valid(url) {
                    return url
                }
            }
            let canonical = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("File-Parser/engine")
            if valid(canonical) {
                return canonical
            }
            let dev = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/AI/Projects/File-Parser/engine")
            if valid(dev) {
                return dev
            }
            return nil
        }

        public init(engineDirectory: URL, options: Options = .fromDefaults()) {
            self.engineDirectory = engineDirectory
            self.options = options
        }

        /// Everything the Docling capability matrix imports (minus audio —
        /// out of scope for Notetaker).
        static let extensions: Set<String> = [
            "pdf", "docx", "pptx", "xlsx", "csv", "html", "htm", "adoc", "asciidoc",
            "md", "markdown", "vtt", "png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp",
        ]

        public func canConvert(fileExtension: String) -> Bool {
            Self.extensions.contains(fileExtension.lowercased())
        }

        public func convert(_ url: URL) async throws -> ConversionResult {
            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("notetaker-engine-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDir) }

            let python = engineDirectory.appendingPathComponent(".venv/bin/python")
            var arguments = [
                "-m", "fileparser.cli", "convert", url.path,
                "--to", "markdown", "--out", outputDir.path,
                "--quiet", "--overwrite",
            ]
            if !options.ocr {
                arguments.append("--no-ocr")
            }
            if !options.tableStructure {
                arguments.append("--no-tables")
            }
            let result = try await Self.run(
                executable: python,
                arguments: arguments,
                workingDirectory: engineDirectory
            )

            // --quiet emits exactly one JSON object: the result.
            guard let lastLine = result.stdout
                .split(separator: "\n").last.map(String.init),
                let json = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any]
            else {
                throw ConversionError.failed("engine emitted no result (stderr: \(result.stderr.suffix(200)))")
            }
            guard json["ok"] as? Bool == true, let outputPath = json["output_path"] as? String else {
                let message = json["error"] as? String ?? "unknown engine error"
                throw ConversionError.failed("engine: \(message)")
            }
            let markdown = try String(contentsOfFile: outputPath, encoding: .utf8)
            guard !markdown.isEmpty else { throw ConversionError.emptyResult }

            var provenance = "Docling (File-Parser engine)"
            if let pages = json["pages"] as? Int {
                provenance += " · \(pages) pages"
            }
            return ConversionResult(
                markdown: markdown.hasSuffix("\n") ? markdown : markdown + "\n",
                provenance: provenance,
                suggestedName: url.deletingPathExtension().lastPathComponent
            )
        }

        // MARK: - Process plumbing

        struct ProcessOutput {
            let stdout: String
            let stderr: String
        }

        static func run(
            executable: URL, arguments: [String], workingDirectory: URL
        ) async throws -> ProcessOutput {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.terminationHandler = { _ in
                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessOutput(stdout: out, stderr: err))
                }
                do {
                    try process.run()
                } catch {
                    continuation
                        .resume(throwing: ConversionError.failed("engine launch: \(error.localizedDescription)"))
                }
            }
        }
    }
#endif
