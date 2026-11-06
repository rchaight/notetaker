@testable import EditorKit
import Foundation
import Testing

struct EditorModeShortTitleTests {
    @Test func shortTitlesFitTheSegmentedPicker() {
        #expect(EditorMode.allCases.map(\.shortTitle) == ["Source", "Live", "Reading"])
        // The long form stays for Settings.
        #expect(EditorMode.live.title == "Live Preview")
    }
}

#if canImport(AppKit)
    import AppKit

    @MainActor
    struct TextColumnTests {
        @Test func horizontalInsetCentresWideViews() {
            #expect(MarkdownTextView.horizontalInset(viewWidth: 1400, maxTextWidth: 780) == 310)
            #expect(MarkdownTextView.horizontalInset(viewWidth: 796, maxTextWidth: 780) == 16)
            #expect(MarkdownTextView.horizontalInset(viewWidth: 600, maxTextWidth: 780) == 16)
            #expect(MarkdownTextView.horizontalInset(viewWidth: 1400, maxTextWidth: nil) == 16)
            // Odd leftovers round down so the column is never squeezed.
            #expect(MarkdownTextView.horizontalInset(viewWidth: 1401, maxTextWidth: 780) == 310)
        }

        @Test func textViewAppliesInsetOnResize() {
            let view = MarkdownTextView.makeTextKit2()
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.maxTextWidth = 780
            view.setFrameSize(NSSize(width: 1400, height: 600))
            #expect(view.textContainerInset.width == 310)
            #expect(view.textContainerInset.height == 16, "only the sides grow")
            #expect(view.textContainer?.size.width == 780)

            // Narrowing the window gives the gutters back down to the floor.
            view.setFrameSize(NSSize(width: 700, height: 600))
            #expect(view.textContainerInset.width == 16)
            #expect(view.textContainer?.size.width == 668)
        }

        @Test func changingTheCapRecomputesWithoutAResize() {
            let view = MarkdownTextView.makeTextKit2()
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.setFrameSize(NSSize(width: 1400, height: 600))
            #expect(view.textContainerInset.width == 16, "no cap: the owner's inset is untouched")
            view.maxTextWidth = 780
            #expect(view.textContainerInset.width == 310)
            view.maxTextWidth = nil
            #expect(view.textContainerInset.width == 16)
        }
    }
#endif
