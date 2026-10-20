import AppKit
import CoreGraphics

/// Straight RGBA8 pixel buffer used for colour-keying artwork and for looking
/// up the hit zones encoded in a skin's mapping images.
public struct Bitmap {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(cgImage: CGImage) {
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard drawn else { return nil }

        width = pixelWidth
        height = pixelHeight
        pixels = buffer
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always)
    public func rgba(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }

    public func isOpaque(x: Int, y: Int, minimumAlpha: Int = 16) -> Bool {
        rgba(x: x, y: y).a >= minimumAlpha
    }

    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

public struct RGB: Equatable {
    public let r: Int, g: Int, b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parses `#rrggbb`. Returns nil for `none`, empty values and junk.
    public init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !s.isEmpty, s != "none", s != "transparent" else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        r = Int((value >> 16) & 0xFF)
        g = Int((value >> 8) & 0xFF)
        b = Int(value & 0xFF)
    }

    public func matches(_ other: (r: Int, g: Int, b: Int), tolerance: Int = 22) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }

    public var color: CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// Loads and caches the artwork that lives next to a `.wms` file.
public final class SkinAssets {
    public let root: URL

    private var files: [String: URL]?
    private var imageCache: [String: CGImage?] = [:]
    private var bitmapCache: [String: Bitmap?] = [:]
    private var keyedCache: [String: CGImage] = [:]
    private var sizeCache: [String: CGSize] = [:]
    private var slicedCache: [String: CGImage] = [:]

    public init(root: URL) {
        self.root = root
    }

    public func url(for name: String) -> URL? {
        let normalised = name
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return nil }
        if files == nil { indexFiles() }
        return files?[normalised.lowercased()]
    }

    private func indexFiles() {
        var map: [String: URL] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            files = map
            return
        }
        for case let file as URL in enumerator {
            let relative = file.path
                .replacingOccurrences(of: root.path + "/", with: "")
                .lowercased()
            map[relative] = file
            // Also allow bare file names ("logo.png") for skins that use them.
            if map[file.lastPathComponent.lowercased()] == nil {
                map[file.lastPathComponent.lowercased()] = file
            }
        }
        files = map
    }

    public func image(named name: String?) -> CGImage? {
        guard let name, !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let cached = imageCache[key] { return cached }

        var image: CGImage?
        if let url = url(for: name), let encoded = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: encoded.size)
            image = encoded.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        imageCache[key] = image
        return image
    }

    public func size(named name: String?) -> CGSize? {
        guard let name, !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let cached = sizeCache[key] { return cached }
        guard let image = image(named: name) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        sizeCache[key] = size
        return size
    }

    public func bitmap(named name: String?) -> Bitmap? {
        guard let name, !name.isEmpty else { return nil }
        let key = name.lowercased()
        if let cached = bitmapCache[key] { return cached }
        let bitmap = image(named: name).flatMap { Bitmap(cgImage: $0) }
        bitmapCache[key] = bitmap
        return bitmap
    }

    /// An image with a key colour turned into transparency — the WMP trick that
    /// gives these skins their non-rectangular windows. When several colours are
    /// declared, the first one actually present in the pixels wins.
    public func keyed(named name: String?, colours: [RGB]) -> CGImage? {
        guard let name else { return nil }
        guard !colours.isEmpty else { return image(named: name) }
        let colourKey = colours.map { "\($0.r),\($0.g),\($0.b)" }.joined(separator: ";")
        let key = "\(name.lowercased())|\(colourKey)"
        if let cached = keyedCache[key] { return cached }
        guard let bitmap = bitmap(named: name) else { return nil }

        // Key every declared colour that actually occurs: old artwork sometimes
        // uses a different key per region (red surround, magenta cut-outs).
        let active = colours.filter { count(of: $0, in: bitmap) >= 8 }
        if active.isEmpty {
            let plain = image(named: name)
            if let plain { keyedCache[key] = plain }
            return plain
        }

        var pixels = bitmap.pixels
        let total = bitmap.width * bitmap.height
        for index in 0..<total {
            let offset = index * 4
            guard pixels[offset + 3] != 0 else { continue }
            let pixel = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            guard active.contains(where: { $0.matches(pixel) }) else { continue }
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }
        let image = Bitmap(width: bitmap.width, height: bitmap.height, pixels: pixels).cgImage()
        if let image { keyedCache[key] = image }
        return image
    }

    private func count(of colour: RGB, in bitmap: Bitmap) -> Int {
        var matches = 0
        for index in 0..<(bitmap.width * bitmap.height) {
            let offset = index * 4
            guard bitmap.pixels[offset + 3] > 0 else { continue }
            if colour.matches((Int(bitmap.pixels[offset]), Int(bitmap.pixels[offset + 1]), Int(bitmap.pixels[offset + 2]))) {
                matches += 1
                if matches >= 64 { return matches }
            }
        }
        return matches
    }

    /// A horizontal strip of frames, e.g. `seek.png` holding 17 states of a slider.
    public func frame(named name: String?, frameWidth: Int, index: Int, frameCount: Int,
                      colours: [RGB] = []) -> CGImage? {
        guard let name, frameWidth > 0, frameCount > 0,
              let image = keyed(named: name, colours: colours) else { return nil }
        let clamped = min(max(index, 0), frameCount - 1)
        guard image.width / frameWidth > 1 else { return image }
        let colourKey = colours.map { "\($0.r),\($0.g),\($0.b)" }.joined(separator: ";")
        let key = "\(name.lowercased())|\(frameWidth)|\(clamped)|\(frameCount)|\(colourKey)"
        if let cached = slicedCache[key] { return cached }
        let rect = CGRect(x: frameWidth * clamped, y: 0, width: frameWidth, height: image.height)
        guard let slice = image.cropping(to: rect) else { return image }
        slicedCache[key] = slice
        return slice
    }
}
