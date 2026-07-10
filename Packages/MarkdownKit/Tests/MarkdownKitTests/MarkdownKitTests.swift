@testable import MarkdownKit
import Testing

@Test func moduleName() {
    #expect(MarkdownKitInfo.name == "MarkdownKit")
}

@Test func parsesMarkdownBlocks() {
    #expect(MarkdownKitInfo.blockCount(of: "# Title\n\nA paragraph.") == 2)
}
