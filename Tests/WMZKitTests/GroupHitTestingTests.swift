import CoreGraphics
import XCTest
@testable import WMZKit

/// A `<buttongroup>` is one control with a colour map: each child
/// `<buttonelement>` names its zone with `mappingColor`, and the click is
/// resolved by sampling `mappingImage` at the click position.
final class GroupHitTestingTests: SyntheticSkinTestCase {
    private var scene: Scene!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scene = try makeSkin(wms: """
        <theme title="Group Test">
          <view id="main" width="60" height="40">
            <buttongroup id="transport" left="10" top="10" width="40" height="20"
                         image="mode.png" mappingImage="mode_map.png">
              <buttonelement mappingColor="#ff0000" onClick="player.controls.play()"/>
              <buttonelement mappingColor="#00ff00" onClick="player.controls.pause()"/>
            </buttongroup>
          </view>
        </theme>
        """, images: [
            "mode.png": TestImage.solid(width: 40, height: 20, colour: (40, 40, 40)),
            "mode_map.png": TestImage(width: 40, height: 20) { x, _ in
                x < 20 ? (255, 0, 0, 255) : (0, 255, 0, 255)
            }
        ])
    }

    func testGroupBuildsOneZonePerMappedChild() throws {
        let node = try XCTUnwrap(scene.nodes["transport"])
        XCTAssertEqual(node.kind, .group)
        XCTAssertEqual(node.frame, CGRect(x: 10, y: 10, width: 40, height: 20))
        XCTAssertEqual(node.zones.count, 2)
    }

    func testClickInLeftHalfPlays() throws {
        guard case .action(let action, let node) =
            scene.hitTest(CGPoint(x: 15, y: 20), state: PlayerState())
        else {
            XCTFail("Expected the left map half to resolve to an action")
            return
        }
        XCTAssertEqual(action, .play)
        XCTAssertEqual(node.id, "transport")
    }

    func testClickInRightHalfPauses() throws {
        guard case .action(let action, _) =
            scene.hitTest(CGPoint(x: 45, y: 20), state: PlayerState())
        else {
            XCTFail("Expected the right map half to resolve to an action")
            return
        }
        XCTAssertEqual(action, .pause)
    }

    func testClicksOutsideTheGroupFrameAreBackground() {
        // The group is 40×20 at (10, 10), so this is one pixel below its frame.
        guard case .background = scene.hitTest(CGPoint(x: 30, y: 30.5), state: PlayerState()) else {
            XCTFail("Expected a click outside the group frame to miss it")
            return
        }
    }
}
