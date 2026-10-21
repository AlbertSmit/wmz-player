import AppKit
import CoreGraphics
import XCTest
@testable import WMZKit

/// Builds a tiny synthetic skin in a temporary directory, then exercises the
/// scene layout and hit testing against it. No archive, no network, no window.
final class SceneBuilderTests: XCTestCase {
    private var directory: URL!
    private var scene: Scene!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WMZKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try PNG.write(width: 100, height: 80, colour: (51, 102, 153),
                      to: directory.appendingPathComponent("bg.png"))
        try PNG.write(width: 20, height: 20, colour: (230, 120, 20),
                      to: directory.appendingPathComponent("btn.png"))

        let definition = """
        <theme title="Test Skin">
          <view id="main" width="100" height="80">
            <subview backgroundImage="bg.png"/>
            <button id="playBtn" left="10" top="10" image="btn.png" onClick="player.controls.play()"/>
            <text id="title" left="40" top="10" value="Hello"/>
          </view>
        </theme>
        """

        let definitionURL = directory.appendingPathComponent("test.wms")
        try definition.write(to: definitionURL, atomically: true, encoding: .utf8)
        let theme = try WMLParser.parse(url: definitionURL)
        let document = SkinDocument(
            sourceURL: definitionURL,
            rootURL: directory,
            theme: theme,
            views: theme.children(named: "view")
        )
        scene = try SceneBuilder.build(document: document)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSceneSizeComesFromViewAttributes() {
        XCTAssertEqual(scene.size, CGSize(width: 100, height: 80))
    }

    func testButtonFrameUsesLeftTopAndNaturalImageSize() {
        XCTAssertEqual(buttonNode?.frame, CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testClickInsideButtonResolvesToItsAction() {
        XCTAssertEqual(action(at: CGPoint(x: 15, y: 15)), .play)
    }

    func testClickInsideButtonResolvesToThatNode() {
        XCTAssertEqual(scene.node(at: CGPoint(x: 15, y: 15), state: PlayerState())?.id, "playBtn")
    }

    func testClickOutsideInteractiveControlsIsBackground() {
        if case .background = scene.hitTest(CGPoint(x: 80, y: 70), state: PlayerState()) {
            // Expected.
        } else {
            XCTFail("Expected a click away from the button to miss every control")
        }
    }

    // MARK: - Helpers

    private var buttonNode: SceneNode? {
        scene.root.children.first { $0.kind == .button }
    }

    private func action(at point: CGPoint) -> MediaAction? {
        guard case .action(let action, _) = scene.hitTest(point, state: PlayerState()) else { return nil }
        return action
    }
}

private enum PNG {
    struct EncodingFailed: Error {}

    static func write(width: Int, height: Int,
                      colour: (red: UInt8, green: UInt8, blue: UInt8),
                      to url: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw EncodingFailed() }

        context.setFillColor(CGColor(
            red: CGFloat(colour.red) / 255,
            green: CGFloat(colour.green) / 255,
            blue: CGFloat(colour.blue) / 255,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw EncodingFailed() }
        try data.write(to: url)
    }
}
