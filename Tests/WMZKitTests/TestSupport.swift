import AppKit
import CoreGraphics
import XCTest
@testable import WMZKit

/// A synthetic bitmap written as a PNG into a test skin's directory. Pixels are
/// built directly, so artwork has exactly the colours a test asks for — no
/// drawing, no anti-aliasing, no colour-key rounding.
struct TestImage: Sendable {
    struct EncodingFailed: Error {}

    let width: Int
    let height: Int
    let pixel: @Sendable (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    init(width: Int, height: Int,
         pixel: @escaping @Sendable (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) {
        self.width = width
        self.height = height
        self.pixel = pixel
    }

    static func solid(width: Int, height: Int, colour: (UInt8, UInt8, UInt8)) -> TestImage {
        TestImage(width: width, height: height) { _, _ in (colour.0, colour.1, colour.2, 255) }
    }

    func write(to url: URL) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let index = (y * width + x) * 4
                pixels[index] = value.r
                pixels[index + 1] = value.g
                pixels[index + 2] = value.b
                pixels[index + 3] = value.a
            }
        }

        guard let image = Bitmap(width: width, height: height, pixels: pixels).cgImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw EncodingFailed() }
        try data.write(to: url)
    }
}

/// Base class for tests that need a scene: `makeSkin` builds one in a per-run
/// temporary directory and the directory is removed in `tearDown`. No archive,
/// no network, no window.
class SyntheticSkinTestCase: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
    }

    func makeSkin(wms: String, images: [String: TestImage] = [:]) throws -> Scene {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WMZKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)

        for (name, image) in images {
            try image.write(to: directory.appendingPathComponent(name))
        }

        let definitionURL = directory.appendingPathComponent("test.wms")
        try wms.write(to: definitionURL, atomically: true, encoding: .utf8)
        let theme = try WMLParser.parse(url: definitionURL)
        let document = SkinDocument(
            sourceURL: definitionURL,
            rootURL: directory,
            theme: theme,
            views: theme.children(named: "view")
        )
        return try SceneBuilder.build(document: document)
    }
}
