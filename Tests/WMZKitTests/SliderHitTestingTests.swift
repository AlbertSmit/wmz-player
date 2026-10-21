import CoreGraphics
import XCTest
@testable import WMZKit

/// A `<customslider>` whose 20×40 position map has a horizontal track band in
/// the middle, and a matching four-frame sprite strip. The map's principal axis
/// is horizontal, so the fraction along the frame should follow the mouse.
final class SliderHitTestingTests: SyntheticSkinTestCase {
    private var scene: Scene!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scene = try makeSkin(wms: Self.definition, images: [
            "slider_strip.png": Self.sprite,
            "slider_map.png": Self.positionMap
        ])
    }

    private static let definition = """
    <theme title="Slider Test">
      <view id="main" width="120" height="60">
        <customslider id="volume" left="10" top="10" image="slider_strip.png"
                      positionImage="slider_map.png"
                      value="wmpprop:player.settings.volume" tooltip="Volume"/>
      </view>
    </theme>
    """

    /// Four fully opaque 20×40 frames; the frame count comes from the sprite
    /// width divided by the position map's width.
    private static let sprite = TestImage(width: 80, height: 40) { x, _ in
        let shades: [(UInt8, UInt8, UInt8)] = [
            (60, 120, 200), (90, 150, 220), (120, 180, 240), (150, 210, 255)
        ]
        return (shades[x / 20].0, shades[x / 20].1, shades[x / 20].2, 255)
    }

    /// Transparent except for a four-row band whose colour changes from row to
    /// row (a vertical gradient): the band's long axis is horizontal, which is
    /// the slider direction, and its full-width rows keep the centroid on the
    /// horizontal centre line.
    private static let positionMap = TestImage(width: 20, height: 40) { _, y in
        guard (18..<22).contains(y) else { return (0, 0, 0, 0) }
        return (UInt8(80 + (y - 18) * 40), 0, 0, 255)
    }

    func testSliderFrameAndFrameCountComeFromArtwork() throws {
        let node = try XCTUnwrap(scene.nodes["volume"])
        XCTAssertEqual(node.kind, .slider)
        XCTAssertEqual(node.frame, CGRect(x: 10, y: 10, width: 20, height: 40))

        let slider = try XCTUnwrap(node.slider)
        XCTAssertEqual(slider.frameWidth, 20)
        XCTAssertEqual(slider.frameCount, 4)
        XCTAssertEqual(slider.mapSize, CGSize(width: 20, height: 40))
    }

    func testClickNearLeftEdgeIsZero() {
        XCTAssertEqual(fraction(at: CGPoint(x: 10.5, y: 30)), 0, accuracy: 0.01)
    }

    func testClickInTheMiddleIsHalf() {
        XCTAssertEqual(fraction(at: CGPoint(x: 20, y: 30)), 0.5, accuracy: 0.01)
    }

    func testClickNearRightEdgeIsOne() {
        XCTAssertEqual(fraction(at: CGPoint(x: 29.5, y: 30)), 1, accuracy: 0.01)
    }

    func testHitTestReturnsSliderWithTheVolumeTarget() throws {
        guard case .slider(let info, _, let node) =
            scene.hitTest(CGPoint(x: 20, y: 30), state: PlayerState())
        else {
            XCTFail("Expected a slider hit inside the customslider")
            return
        }
        XCTAssertEqual(info.target, .volume)
        XCTAssertEqual(node.id, "volume")
        XCTAssertEqual(try XCTUnwrap(node.slider).image, "slider_strip.png")
    }

    func testArtworkFileNameCanOverrideTheValueBinding() throws {
        // Documents current behaviour: `sliderTarget` searches the value, id,
        // tooltips *and* the artwork file name, with "seek" checked before
        // "volume". A volume slider whose sprite happens to be called seek.png
        // is therefore classified as a seek slider even though its value binds
        // to the volume setting.
        let skin = try makeSkin(wms: """
        <theme title="Slider Naming Test">
          <view id="main" width="120" height="60">
            <customslider id="volume" left="10" top="10" image="seek.png"
                          positionImage="slider_map.png"
                          value="wmpprop:player.settings.volume"/>
          </view>
        </theme>
        """, images: [
            "seek.png": Self.sprite,
            "slider_map.png": Self.positionMap
        ])

        guard case .slider(let info, _, _) =
            skin.hitTest(CGPoint(x: 20, y: 30), state: PlayerState())
        else {
            XCTFail("Expected a slider hit")
            return
        }
        XCTAssertEqual(info.target, .seek)
    }

    // MARK: - Helpers

    private func fraction(at point: CGPoint) -> Double {
        guard case .slider(_, let fraction, _) = scene.hitTest(point, state: PlayerState()) else {
            XCTFail("Expected a slider hit at \(point)")
            return .nan
        }
        return fraction
    }
}
