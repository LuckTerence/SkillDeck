import AppKit

/// Loads and caches SVG logos bundled under `Resources/<subdirectory>`.
///
/// Template tinting needs a bitmap-backed image; an SVG-backed `_NSSVGImageRep`
/// would tint the whole bounds as a solid square.
final class BundledIconCache: @unchecked Sendable {

    static let shared = BundledIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func image(
        named name: String,
        subdirectory: String,
        isTemplate: Bool,
        pixels: Int = 256
    ) -> NSImage? {
        let key = "\(subdirectory)/\(name)/\(isTemplate)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard
            let url = SkillDeckResources.bundle.url(
                forResource: name,
                withExtension: "svg",
                subdirectory: subdirectory
            ),
            let svg = NSImage(contentsOf: url),
            let image = rasterize(svg, pixels: pixels)
        else {
            return nil
        }

        image.isTemplate = isTemplate
        cache.setObject(image, forKey: key)
        return image
    }

    private func rasterize(_ image: NSImage, pixels: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))

        let rasterized = NSImage(size: NSSize(width: pixels, height: pixels))
        rasterized.addRepresentation(rep)
        return rasterized
    }
}
