import Foundation
import MarkdownKit

#if canImport(AppKit)
    import AppKit

    public typealias PlatformImage = NSImage
#else
    import UIKit

    public typealias PlatformImage = UIImage
#endif

/// Standalone `![alt](source)` paragraphs reserve thumbnail room via
/// paragraph spacing (highlighter) and draw the image there. Storage keeps
/// the literal markdown; only local vault files render (remote URLs stay
/// raw text — no network from the layout pass).
public final class ImageLayoutFragment: NSTextLayoutFragment {
    public var source: String?
    public var baseURL: URL?

    private var resolvedImage: (image: PlatformImage, size: CGSize)? {
        guard let source, let url = ImageThumbnails.resolveLocalURL(source, base: baseURL),
              let image = ImageThumbnails.image(at: url) else { return nil }
        return (image, image.size)
    }

    private var imageRect: CGRect {
        guard let (_, size) = resolvedImage, size.width > 0, size.height > 0 else { return .zero }
        let frame = layoutFragmentFrame
        let lineHeight = textLineFragments.first?.typographicBounds.height ?? 17
        let maxHeight = MarkdownTheme.imageThumbnailHeight
        let maxWidth = max(frame.width - 8, 40)
        let scale = min(maxHeight / size.height, maxWidth / size.width, 1)
        return CGRect(
            x: 4, y: lineHeight + 4,
            width: (size.width * scale).rounded(), height: (size.height * scale).rounded()
        )
    }

    override public var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(imageRect)
    }

    override public func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let (image, _) = resolvedImage else { return }
        let rect = imageRect.offsetBy(dx: point.x, dy: point.y)
        guard !rect.isEmpty else { return }
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.clip()
        #if canImport(AppKit)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // The text context is flipped (top-left origin); unflip
                // locally so the bitmap isn't drawn upside down.
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(cg, in: rect)
            }
        #else
            if let cg = image.cgImage {
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(cg, in: rect)
            }
        #endif
        context.restoreGState()
    }
}

public enum ImageThumbnails {
    // NSCache is documented thread-safe; the checker can't see that.
    private nonisolated(unsafe) static let cache = NSCache<NSURL, PlatformImage>()

    /// Local-file resolution only: absolute paths, file: URLs, or paths
    /// relative to the note's folder. http(s) returns nil by design.
    public static func resolveLocalURL(_ source: String, base: URL?) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") { return nil }
        if source.hasPrefix("file://") { return URL(string: source) }
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        guard let base else { return nil }
        // appendingPathComponent, not fileURLWithPath(relativeTo:) — the
        // latter probes the filesystem for directory-ness and drops the
        // base's last component when the folder doesn't exist locally.
        return base
            .appendingPathComponent(source.removingPercentEncoding ?? source)
            .standardizedFileURL
    }

    static func image(at url: URL) -> PlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
              let image = PlatformImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// The image source when a paragraph is exactly one image (Typora only
    /// previews standalone image lines; inline images stay raw text).
    public static func standaloneImageSource(_ paragraph: String) -> String? {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let open = trimmed.range(of: "]("),
              !trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2) ..< open.lowerBound].contains("]"),
              case let source = String(trimmed[open.upperBound ..< trimmed.index(before: trimmed.endIndex)]),
              !source.contains(")"), !source.contains("\n"), !source.isEmpty
        else { return nil }
        return source
    }
}
