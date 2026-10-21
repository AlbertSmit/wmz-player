import CoreGraphics
import XCTest
@testable import WMZKit

/// `transparencyColor` makes pixels of that colour click-through, which is how
/// these skins get an irregular outline from a rectangular bitmap.
final class KeyColourHitTestingTests: SyntheticSkinTestCase {
    private var scene: Scene!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scene = try makeSkin(wms: """
        <theme title="Key Colour Test">
          <view id="main" width="60" height="60">
            <button id="playBtn" left="10" top="10" image="keyed.png"
                    transparencyColor="#ff00ff" onClick="player.controls.play()"/>
          </view>
        </theme>
        """, images: [
            "keyed.png": TestImage(width: 40, height: 40) { x, y in
                let border = 8
                let inside = x >= border && x < 40 - border && y >= border && y < 40 - border
                return inside ? (200, 0, 0, 255) : (255, 0, 255, 255)
            }
        ])
    }

    func testKeyColourIsReadFromTransparencyColor() throws {
        // `Scene.nodes` is keyed by lower-cased id.
        let node = try XCTUnwrap(scene.nodes["playbtn"])
        XCTAssertEqual(node.frame, CGRect(x: 10, y: 10, width: 40, height: 40))
        XCTAssertEqual(node.keyColours, [RGB(r: 255, g: 0, b: 255)])
    }

    func testClickOnTheTransparentBorderFallsThroughToBackground() throws {
        // (13, 30) is inside the magenta border, three pixels from the left edge.
        guard case .background = scene.hitTest(CGPoint(x: 13, y: 30), state: PlayerState()) else {
            XCTFail("A click on the key-coloured border should not hit the button")
            return
        }
        // The node geometry still contains the point; only opacity rejects it.
        let node = try XCTUnwrap(scene.nodes["playbtn"])
        XCTAssertTrue(node.frame.contains(CGPoint(x: 13, y: 30)))
    }

    func testClickOnTheRedCentreHitsTheButton() throws {
        guard case .action(let action, let node) =
            scene.hitTest(CGPoint(x: 30, y: 30), state: PlayerState())
        else {
            XCTFail("A click on the opaque centre should hit the button")
            return
        }
        XCTAssertEqual(action, .play)
        XCTAssertEqual(scene.node(at: CGPoint(x: 30, y: 30), state: PlayerState())?.id, "playBtn")
        XCTAssertEqual(node.id, "playBtn")
    }
}
