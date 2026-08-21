import Foundation
import UniformTypeIdentifiers

// The editor's own NSTextView/UITextView subclass: owns paste and (macOS)
// drag-and-drop so browser/Word/Mail pastes come in as clean markdown,
// image pastes/drops land in the vault, and a URL pasted over a selection
// becomes a link. The decision ladder never loses a paste — any
// conversion failure falls back to the platform's default paste.
//
// `MarkdownEditor.makeNSView`/`makeUIView` construct this type in place
// of the stock text view (and it's what `SharedEditorCache` reuses on
// macOS), so paste/drop behavior travels with the cached view.
#if canImport(AppKit)
    import AppKit

    public final class MarkdownTextView: NSTextView {
        /// nil = image import off (the default until the app wires it).
        /// Set by `MarkdownEditor` from its own `importAttachments` param.
        public var importAttachments: (([AttachmentDrop]) async -> [String])?

        override public init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
            super.init(frame: frameRect, textContainer: container)
            // Default NSTextView drag registration already covers plain
            // text; add file URLs and raw image data so Finder image
            // drags and screenshot drags are offered to us at all.
            registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .tiff, .png])
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used by MarkdownEditor")
        }

        /// The TextKit 2 stack this view was built on. The view's public
        /// accessors reach it through weak links (container →
        /// layoutManager → contentManager), so the factory parks a strong
        /// reference here to keep the storage alive.
        private var ownedContentStorage: NSTextContentStorage?

        /// TextKit 2 construction. NSTextView's `usingTextLayoutManager`
        /// convenience initializer is not inherited by subclasses, so this
        /// builds the same stack that initializer does — fresh storage →
        /// layout manager → container — and adopts the container before it
        /// ever belongs to another view. (Adopting a container swapped off
        /// an existing view leaves that view as the render target: notes
        /// opened blank.)
        public static func makeTextKit2() -> MarkdownTextView {
            let contentStorage = NSTextContentStorage()
            let layoutManager = NSTextLayoutManager()
            contentStorage.addTextLayoutManager(layoutManager)
            contentStorage.primaryTextLayoutManager = layoutManager
            let container = NSTextContainer(
                size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            )
            layoutManager.textContainer = container
            let view = MarkdownTextView(frame: .zero, textContainer: container)
            view.ownedContentStorage = contentStorage
            return view
        }

        // MARK: - Paste decision ladder

        override public func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            if handleImagePaste(pasteboard) {
                return
            }

            let selectionRange = selectedRange()
            let plain = pasteboard.string(forType: .string)

            if let plain, !plain.isEmpty, selectionRange.length > 0 {
                let selectedText = (string as NSString).substring(with: selectionRange)
                if let wrapped = RichPaste.linkWrapping(selection: selectedText, pasted: plain) {
                    insertMarkdown(wrapped, replacing: selectionRange)
                    return
                }
            }

            if let plain, !plain.isEmpty, RichPaste.isProbablyMarkdown(plain) {
                super.paste(sender)
                return
            }

            if let converted = convertRichPasteboard(pasteboard) {
                insertMarkdown(converted, replacing: selectionRange)
                return
            }

            // Never lose a paste: no plain string, no convertible rich
            // flavor, and no image — hand it to AppKit's own paste.
            super.paste(sender)
        }

        // "Paste and Match Style" (`pasteAsPlainText:`) is intentionally
        // NOT overridden — the default implementation already inserts the
        // raw plain pasteboard string unmodified, which is the user's
        // escape hatch out of markdown conversion.

        private func convertRichPasteboard(_ pasteboard: NSPasteboard) -> String? {
            let candidates: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [
                (.html, .html), (.rtf, .rtf), (.rtfd, .rtfd),
            ]
            for (type, documentType) in candidates {
                guard let data = pasteboard.data(forType: type) else { continue }
                guard let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
                ) else { continue }
                let markdown = RichPaste.markdown(fromAttributed: attributed)
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return markdown
                }
            }
            return nil
        }

        // MARK: - Image paste

        private func handleImagePaste(_ pasteboard: NSPasteboard) -> Bool {
            guard let importAttachments else { return false }
            let drops = imageAttachmentDrops(from: pasteboard)
            guard !drops.isEmpty else { return false }
            let target = selectedRange()
            Task { [weak self] in
                let paths = await importAttachments(drops)
                await MainActor.run {
                    self?.insertImageMarkdown(paths, drops: drops, replacing: target)
                }
            }
            return true
        }

        private func imageAttachmentDrops(from pasteboard: NSPasteboard) -> [AttachmentDrop] {
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
            ) as? [URL], !urls.isEmpty {
                return urls.map { AttachmentDrop(source: .fileURL($0), suggestedName: $0.lastPathComponent) }
            }
            // Raw bitmap data only counts when no text flavor rides along:
            // Office apps put a TIFF rendition next to their string/RTF/HTML,
            // and importing that would hijack a text paste into an image.
            // A bare screenshot (TIFF only) still imports.
            let hasTextFlavor = pasteboard.string(forType: .string) != nil
                || pasteboard.data(forType: .html) != nil
                || pasteboard.data(forType: .rtf) != nil
            if !hasTextFlavor,
               let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
                return [AttachmentDrop(source: .data(data), suggestedName: "pasted-image.png")]
            }
            return []
        }

        private func containsImportableImage(_ pasteboard: NSPasteboard) -> Bool {
            !imageAttachmentDrops(from: pasteboard).isEmpty
        }

        // MARK: - Drag and drop

        override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if importAttachments != nil, containsImportableImage(sender.draggingPasteboard) {
                return .copy
            }
            return super.draggingEntered(sender)
        }

        override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            if importAttachments != nil, containsImportableImage(sender.draggingPasteboard) {
                return .copy
            }
            return super.draggingUpdated(sender)
        }

        override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pasteboard = sender.draggingPasteboard
            guard let importAttachments else { return super.performDragOperation(sender) }
            let drops = imageAttachmentDrops(from: pasteboard)
            // Non-image files (or no importer wired) fall through to
            // whatever NSTextView already does with a drag.
            guard !drops.isEmpty else { return super.performDragOperation(sender) }
            let dropPoint = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: dropPoint)
            let target = NSRange(location: index, length: 0)
            Task { [weak self] in
                let paths = await importAttachments(drops)
                await MainActor.run {
                    self?.insertImageMarkdown(paths, drops: drops, replacing: target)
                }
            }
            return true
        }

        // MARK: - Shared insertion

        /// One undo group per paste/drop — `insertText(_:replacementRange:)`
        /// is the same entry point normal typing uses, so it fires the
        /// delegate's `textDidChange` and registers exactly one undo step.
        private func insertMarkdown(_ markdown: String, replacing range: NSRange) {
            guard NSMaxRange(range) <= (string as NSString).length else { return }
            insertText(markdown, replacementRange: range)
        }

        /// `paths` is index-aligned with `drops` — `importAttachments`
        /// returns an empty string for any drop it couldn't import, which
        /// this skips rather than mis-pairing a name with the wrong path.
        private func insertImageMarkdown(_ paths: [String], drops: [AttachmentDrop], replacing range: NSRange) {
            let lines = zip(paths, drops).compactMap { path, drop -> String? in
                guard !path.isEmpty else { return nil }
                return "![\((drop.suggestedName as NSString).deletingPathExtension)](\(path))"
            }
            guard !lines.isEmpty else { return }
            insertMarkdown(lines.joined(separator: "\n\n"), replacing: range)
        }
    }

#else
    import UIKit

    public final class MarkdownUITextView: UITextView {
        /// nil = image import off (the default until the app wires it).
        public var importAttachments: (([AttachmentDrop]) async -> [String])?

        // MARK: - Paste decision ladder

        override public func paste(_ sender: Any?) {
            let pasteboard = UIPasteboard.general
            if handleImagePaste(pasteboard) {
                return
            }

            let range = selectedRange
            let plain = pasteboard.string

            if let plain, !plain.isEmpty, range.length > 0 {
                let selectedText = (text as NSString).substring(with: range)
                if let wrapped = RichPaste.linkWrapping(selection: selectedText, pasted: plain) {
                    insertMarkdown(wrapped, replacing: range)
                    return
                }
            }

            if let plain, !plain.isEmpty, RichPaste.isProbablyMarkdown(plain) {
                super.paste(sender)
                return
            }

            if let converted = convertRichPasteboard(pasteboard) {
                insertMarkdown(converted, replacing: range)
                return
            }

            super.paste(sender)
        }

        private func convertRichPasteboard(_ pasteboard: UIPasteboard) -> String? {
            let candidates: [(String, NSAttributedString.DocumentType)] = [
                (UTType.html.identifier, .html),
                (UTType.rtf.identifier, .rtf),
                (UTType.flatRTFD.identifier, .rtfd),
            ]
            for (type, documentType) in candidates {
                guard let data = pasteboard.data(forPasteboardType: type) else { continue }
                guard let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
                ) else { continue }
                let markdown = RichPaste.markdown(fromAttributed: attributed)
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return markdown
                }
            }
            return nil
        }

        // MARK: - Image paste (iOS: paste only — drop stays default per spec)

        private func handleImagePaste(_ pasteboard: UIPasteboard) -> Bool {
            guard let importAttachments else { return false }
            let drops = imageAttachmentDrops(from: pasteboard)
            guard !drops.isEmpty else { return false }
            let target = selectedRange
            Task { [weak self] in
                let paths = await importAttachments(drops)
                await MainActor.run {
                    self?.insertImageMarkdown(paths, drops: drops, replacing: target)
                }
            }
            return true
        }

        private func imageAttachmentDrops(from pasteboard: UIPasteboard) -> [AttachmentDrop] {
            if let data = pasteboard.data(forPasteboardType: UTType.png.identifier) {
                return [AttachmentDrop(source: .data(data), suggestedName: "pasted-image.png")]
            }
            if let data = pasteboard.data(forPasteboardType: UTType.jpeg.identifier) {
                return [AttachmentDrop(source: .data(data), suggestedName: "pasted-image.jpg")]
            }
            if let image = pasteboard.image, let data = image.pngData() {
                return [AttachmentDrop(source: .data(data), suggestedName: "pasted-image.png")]
            }
            return []
        }

        // MARK: - Shared insertion

        /// Direct `textStorage` edits don't fire UITextViewDelegate
        /// automatically (the command-apply path elsewhere in this file
        /// has the same shape) — the manual `textViewDidChange` call is
        /// what re-styles and syncs the text binding.
        private func insertMarkdown(_ markdown: String, replacing range: NSRange) {
            guard NSMaxRange(range) <= textStorage.length else { return }
            let previous = textStorage.attributedSubstring(from: range).string
            let insertedLength = (markdown as NSString).length
            textStorage.replaceCharacters(in: range, with: markdown)
            selectedRange = NSRange(location: range.location + insertedLength, length: 0)
            undoManager?.registerUndo(withTarget: self) { target in
                target.insertMarkdown(previous, replacing: NSRange(location: range.location, length: insertedLength))
            }
            delegate?.textViewDidChange?(self)
        }

        /// `paths` is index-aligned with `drops` — `importAttachments`
        /// returns an empty string for any drop it couldn't import, which
        /// this skips rather than mis-pairing a name with the wrong path.
        private func insertImageMarkdown(_ paths: [String], drops: [AttachmentDrop], replacing range: NSRange) {
            let lines = zip(paths, drops).compactMap { path, drop -> String? in
                guard !path.isEmpty else { return nil }
                return "![\((drop.suggestedName as NSString).deletingPathExtension)](\(path))"
            }
            guard !lines.isEmpty else { return }
            insertMarkdown(lines.joined(separator: "\n\n"), replacing: range)
        }
    }
#endif
