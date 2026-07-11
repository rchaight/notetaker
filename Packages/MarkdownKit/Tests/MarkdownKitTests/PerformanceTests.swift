import Foundation
@testable import MarkdownKit
import Testing

struct PerformanceTests {
    /// ~50k words with realistic markdown density. Guards against styling
    /// regressions that would make large notes unusable; the bound is loose
    /// (debug builds, CI machines) — the point is catching order-of-magnitude
    /// slowdowns, not micro-benchmarks.
    @Test func fiftyThousandWordNoteParsesQuickly() {
        let paragraph = "Some **bold** and *italic* prose with `code`, a [link](https://example.com), and plain filler words to pad the paragraph out to a realistic length.\n\n- [ ] a task >2026-07-15\n- [x] a done task\n\n"
        let body = "# Big Note\n\n" + String(repeating: paragraph, count: 1200) // ~50k words
        let start = ContinuousClock.now
        let ranges = MarkdownStyler.styleRanges(in: body)
        let elapsed = ContinuousClock.now - start
        #expect(!ranges.isEmpty)
        #expect(elapsed < .seconds(3), "styling 50k words took \(elapsed)")
    }
}
