import Foundation
@testable import ProofKit
import Testing

// MARK: - AnnotatedText

struct AnnotatedTextTests {
    @Test func noExclusionsYieldsOneTextSegment() {
        let segments = AnnotatedText.build(text: "Hello world.", excluding: [])
        #expect(segments == [AnnotatedText.Segment(text: "Hello world.")])
    }

    @Test func emptyTextYieldsNoSegments() {
        #expect(AnnotatedText.build(text: "", excluding: []) == [])
    }

    @Test func excludedTokenBecomesMarkup() {
        let text = "See #project for details."
        let tagRange = (text as NSString).range(of: "#project")
        let segments = AnnotatedText.build(text: text, excluding: [tagRange])
        #expect(segments == [
            AnnotatedText.Segment(text: "See "),
            AnnotatedText.Segment(markup: "#project"),
            AnnotatedText.Segment(text: " for details."),
        ])
    }

    @Test func reconstructionRoundTripsPlainText() {
        let text = "Meet @dean tomorrow about the #budget line item."
        let ns = text as NSString
        let excluding = [ns.range(of: "@dean"), ns.range(of: "#budget")]
        let segments = AnnotatedText.build(text: text, excluding: excluding)
        #expect(AnnotatedText.reconstruct(segments) == text)
    }

    /// The unit-verification test the spec calls for: an emoji is one
    /// Unicode scalar but a UTF-16 SURROGATE PAIR (two code units). The
    /// builder must carry it through a markup boundary without splitting
    /// the pair or miscounting length — otherwise every offset after it
    /// would be off by one.
    @Test func reconstructionRoundTripsThroughEmojiSurrogatePair() {
        let text = "🎉 great #work today"
        let ns = text as NSString
        #expect(ns.length == "🎉 great #work today".utf16.count)
        let excluding = [ns.range(of: "#work")]
        let segments = AnnotatedText.build(text: text, excluding: excluding)
        #expect(AnnotatedText.reconstruct(segments) == text)
        // The emoji's surrogate pair must stay intact inside its segment,
        // not get sliced across a segment boundary.
        let firstSegment = segments.first?.text ?? ""
        #expect(firstSegment.hasPrefix("🎉"))
    }

    @Test func reconstructionRoundTripsThroughCRLF() {
        let text = "Line one.\r\nSee #tag\r\nLine three."
        let ns = text as NSString
        let excluding = [ns.range(of: "#tag")]
        let segments = AnnotatedText.build(text: text, excluding: excluding)
        #expect(AnnotatedText.reconstruct(segments) == text)
    }

    @Test func adjacentExclusionsMergeWithoutEmptyGap() {
        let text = "ab#tag@personcd"
        let ns = text as NSString
        let excluding = [ns.range(of: "#tag"), ns.range(of: "@person")]
        let segments = AnnotatedText.build(text: text, excluding: excluding)
        // #tag and @person are adjacent with nothing between them — no
        // zero-length "text" segment should appear.
        #expect(segments == [
            AnnotatedText.Segment(text: "ab"),
            AnnotatedText.Segment(markup: "#tag@person"),
            AnnotatedText.Segment(text: "cd"),
        ])
        #expect(AnnotatedText.reconstruct(segments) == text)
    }

    @Test func overlappingExclusionsMerge() {
        let text = "0123456789"
        let segments = AnnotatedText.build(
            text: text,
            excluding: [NSRange(location: 2, length: 4), NSRange(location: 4, length: 4)]
        )
        #expect(segments == [
            AnnotatedText.Segment(text: "01"),
            AnnotatedText.Segment(markup: "234567"),
            AnnotatedText.Segment(text: "89"),
        ])
    }

    @Test func outOfBoundsRangeIsClampedNotCrashing() {
        let text = "short"
        let segments = AnnotatedText.build(text: text, excluding: [NSRange(location: 3, length: 50)])
        #expect(AnnotatedText.reconstruct(segments) == text)
    }

    @Test func jsonEncodesAlternatingAnnotationArray() throws {
        let text = "Hi #tag."
        let segments = AnnotatedText.build(text: text, excluding: [(text as NSString).range(of: "#tag")])
        let json = AnnotatedText.json(for: segments)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let annotation = decoded?["annotation"] as? [[String: String]]
        #expect(annotation == [["text": "Hi "], ["markup": "#tag"], ["text": "."]])
    }
}

// MARK: - Response decoding

struct LanguageToolDecodingTests {
    /// A real LanguageTool `/v2/check` response shape (trimmed to the
    /// fields ProofKit reads).
    static let fixture = ##"""
    {
      "software": {"name": "LanguageTool", "version": "6.4"},
      "language": {"name": "English (US)", "code": "en-US"},
      "matches": [
        {
          "message": "Possible spelling mistake found.",
          "shortMessage": "Spelling mistake",
          "replacements": [{"value": "world"}, {"value": "word"}],
          "offset": 6,
          "length": 5,
          "context": {"text": "Hello wrold today", "offset": 6, "length": 5},
          "rule": {
            "id": "MORFOLOGIK_RULE_EN_US",
            "description": "Possible spelling mistake",
            "issueType": "misspelling",
            "category": {"id": "TYPOS", "name": "Possible Typo"}
          }
        }
      ]
    }
    """##

    @Test func decodesRealShapeFixture() throws {
        let matches = try LanguageToolProvider.decodeMatches(
            Data(Self.fixture.utf8), textLength: ("Hello wrold today" as NSString).length
        )
        #expect(matches.count == 1)
        let match = matches[0]
        #expect(match.range == NSRange(location: 6, length: 5))
        #expect(match.message == "Possible spelling mistake found.")
        #expect(match.shortMessage == "Spelling mistake")
        #expect(match.replacements == ["world", "word"])
        #expect(match.ruleId == "MORFOLOGIK_RULE_EN_US")
        #expect(match.category == "TYPOS")
        // Confirms the range lands on the intended word in the original
        // text, with the offset used as-is (no unit conversion).
        let original = "Hello wrold today"
        #expect((original as NSString).substring(with: match.range) == "wrold")
    }

    @Test func decodeDropsMatchWhoseRangeIsOutOfBounds() throws {
        let json = ##"{"matches":[{"message":"x","shortMessage":"","replacements":[],"offset":900,"length":5,"rule":{"id":"R","category":{"id":"C"}}}]}"##
        let matches = try LanguageToolProvider.decodeMatches(Data(json.utf8), textLength: 20)
        #expect(matches.isEmpty)
    }

    @Test func decodeThrowsBadResponseOnMalformedJSON() {
        #expect(throws: GrammarError.badResponse("unexpected LanguageTool response shape")) {
            _ = try LanguageToolProvider.decodeMatches(Data("not json".utf8), textLength: 10)
        }
    }

    /// Verifies the offset UNIT: LanguageTool is a Java tool (Java `char`
    /// == one UTF-16 code unit), so an offset counted past a leading
    /// emoji's surrogate pair must land two UTF-16 units in — exactly
    /// where NSString/NSRange already expect it, with no rescaling.
    @Test func offsetUnitMatchesUTF16AfterEmoji() throws {
        let text = "🎉 wrold"
        let wroldOffset = (text as NSString).range(of: "wrold").location
        #expect(wroldOffset == 3) // 2 (surrogate pair) + 1 (space)
        let json = """
        {"matches":[{"message":"typo","shortMessage":"","replacements":[{"value":"world"}],"offset":\(
            wroldOffset
        ),"length":5,"rule":{"id":"R","category":{"id":"C"}}}]}
        """
        let matches = try LanguageToolProvider.decodeMatches(Data(json.utf8), textLength: (text as NSString).length)
        #expect(matches.count == 1)
        #expect((text as NSString).substring(with: matches[0].range) == "wrold")
    }
}

// MARK: - GrammarMatch.shifted (post-Apply range bookkeeping)

struct GrammarMatchShiftedTests {
    static func match(_ location: Int, _ length: Int, ruleId: String = "R") -> GrammarMatch {
        GrammarMatch(
            range: NSRange(location: location, length: length),
            message: "m", shortMessage: "s", replacements: [], ruleId: ruleId, category: "C"
        )
    }

    @Test func appliedMatchIsDropped() {
        let applied = Self.match(0, 3)
        let result = GrammarMatch.shifted([applied], afterApplying: applied, newLength: 5)
        #expect(result.isEmpty)
    }

    @Test func laterMatchesShiftByLengthDelta() {
        let applied = Self.match(0, 3) // "foo" -> "food" grows by 1
        let later = Self.match(10, 4)
        let result = GrammarMatch.shifted([applied, later], afterApplying: applied, newLength: 4)
        #expect(result.count == 1)
        #expect(result[0].range == NSRange(location: 11, length: 4))
        #expect(result[0].id == later.id) // identity preserved for stable list rows
    }

    @Test func earlierMatchesAreUntouched() {
        let earlier = Self.match(0, 3)
        let applied = Self.match(10, 3)
        let result = GrammarMatch.shifted([earlier, applied], afterApplying: applied, newLength: 10)
        #expect(result == [earlier])
    }

    @Test func overlappingMatchIsDroppedAsStale() {
        let applied = Self.match(5, 5)
        let overlapping = Self.match(7, 5) // starts inside the edited span
        let result = GrammarMatch.shifted([applied, overlapping], afterApplying: applied, newLength: 2)
        #expect(result.isEmpty)
    }

    @Test func shrinkingReplacementShiftsLaterMatchesNegatively() {
        let applied = Self.match(0, 10) // shrinks to length 2
        let later = Self.match(20, 3)
        let result = GrammarMatch.shifted([applied, later], afterApplying: applied, newLength: 2)
        #expect(result[0].range == NSRange(location: 12, length: 3))
    }
}

// MARK: - LanguageToolProvider over the network (stubbed)

/// URLProtocol stub — the same pattern ConversionKitTests uses for
/// DoclingServeConverter, so the provider is tested end-to-end (request
/// building, response decoding, error mapping) without a real server.
final class ProofStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequestBody = request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                }
            }
            return data
        } ?? request.httpBody

        guard let handler = Self.handler, let url = request.url else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct LanguageToolProviderTests {
    private func makeProvider() -> LanguageToolProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProofStubURLProtocol.self]
        return LanguageToolProvider(
            baseURL: URL(string: "http://homelab.test:8010")!,
            session: URLSession(configuration: configuration)
        )
    }

    @Test func checkPostsAnnotatedTextWithExclusionsAsMarkup() async throws {
        let text = "I has a #project note, she go now."
        let tagRange = (text as NSString).range(of: "#project")
        // "go" (offset in the ORIGINAL text) sits after the excluded tag —
        // the stub reports it exactly where a real LanguageTool server
        // would, because the annotation tiles the original text exactly
        // (see AnnotatedText's doc comment) and LT offsets are UTF-16
        // code units, same as NSRange.
        let goRange = (text as NSString).range(
            of: "go",
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        ProofStubURLProtocol.handler = { request in
            #expect(request.url?.path.hasSuffix("/v2/check") == true)
            let json = """
            {"matches":[{"message":"Subject-verb agreement","shortMessage":"","replacements":[{"value":"goes"}],"offset":\(goRange
                .location),"length":\(goRange.length),"rule":{"id":"AGREEMENT","category":{"id":"GRAMMAR"}}}]}
            """
            return (200, Data(json.utf8))
        }

        let matches = try await makeProvider().check(text, excluding: [tagRange], language: "en-US")
        #expect(matches.count == 1)
        #expect((text as NSString).substring(with: matches[0].range) == "go")

        // The tag was sent as markup, not as checkable text.
        let body = ProofStubURLProtocol.lastRequestBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(body.removingPercentEncoding?.contains(##""markup":"#project""##) == true)
    }

    @Test func checkReturnsEmptyForEmptyText() async throws {
        ProofStubURLProtocol.handler = { _ in (200, Data("{\"matches\":[]}".utf8)) }
        let matches = try await makeProvider().check("", excluding: [], language: nil)
        #expect(matches.isEmpty)
    }

    @Test func checkMapsNon200ToBadResponse() async throws {
        ProofStubURLProtocol.handler = { _ in (404, Data()) }
        await #expect(throws: GrammarError.badResponse("HTTP 404")) {
            _ = try await makeProvider().check("some text", excluding: [], language: nil)
        }
    }

    @Test func checkMapsMalformedBodyToBadResponse() async throws {
        ProofStubURLProtocol.handler = { _ in (200, Data("<not json>".utf8)) }
        await #expect(throws: GrammarError.badResponse("unexpected LanguageTool response shape")) {
            _ = try await makeProvider().check("some text", excluding: [], language: nil)
        }
    }

    @Test func unreachableHostMapsToUnreachableError() async throws {
        // A closed local port fails fast (connection refused) without
        // waiting for the 8s timeout, and never leaves the machine.
        let provider = try LanguageToolProvider(baseURL: #require(URL(string: "http://127.0.0.1:1")))
        do {
            _ = try await provider.check("text", excluding: [], language: nil)
            Issue.record("expected an error")
        } catch let error as GrammarError {
            guard case .unreachable = error else {
                Issue.record("expected .unreachable, got \(error)")
                return
            }
        }
    }

    @Test func withTimeoutThrowsTimeoutWhenOperationOutlivesDeadline() async throws {
        await #expect(throws: GrammarError.timeout) {
            _ = try await LanguageToolProvider.withTimeout(0.05) {
                try await Task.sleep(for: .seconds(2))
                return 1
            }
        }
    }

    @Test func withTimeoutPropagatesTheOperationsOwnErrorWhenItFailsFirst() async throws {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            _ = try await LanguageToolProvider.withTimeout(5) {
                throw Boom()
            } as Int
        }
    }

    @Test func listLanguagesDecodesAndFallsBackToShortCode() async throws {
        ProofStubURLProtocol.handler = { _ in
            (
                200,
                Data(##"[{"name":"English (US)","code":"en-US","longCode":"en-US"},{"name":"German","code":"de"}]"##
                    .utf8)
            )
        }
        let languages = try await makeProvider().listLanguages()
        #expect(languages.map(\.id) == ["en-US", "de"])
        #expect(languages.map(\.name) == ["English (US)", "German"])
    }
}
