import CoreGraphics
import XCTest
@testable import WMZKit

/// Clicks inside a `<playlist>` are translated from a y offset to an absolute
/// playlist index. The list is a window: `playlistStart` is the index of the
/// first loaded row, `playlistOffset` the scroll position inside that window.
final class PlaylistHitTestingTests: SyntheticSkinTestCase {
    private var scene: Scene!

    /// 11pt rows are `ceil(11 * 1.5)` = 17pt tall.
    private static let rowHeight: CGFloat = 17
    private static let playlistTop: CGFloat = 20

    override func setUpWithError() throws {
        try super.setUpWithError()
        scene = try makeSkin(wms: """
        <theme title="Playlist Test">
          <view id="main" width="200" height="200">
            <playlist id="queue" left="0" top="20" width="200" height="180"
                      columns="name=Title;artist=Artist" fontSize="11"/>
          </view>
        </theme>
        """)
    }

    func testPlaylistGeometryUsesColumnsAndFontSize() throws {
        let node = try XCTUnwrap(scene.nodes["queue"])
        XCTAssertEqual(node.kind, .playlist)

        let info = try XCTUnwrap(node.playlist)
        XCTAssertEqual(info.columns.map(\.key), ["name", "artist"])
        XCTAssertEqual(info.columns.map(\.label), ["Title", "Artist"])
        XCTAssertEqual(info.rowHeight, Self.rowHeight)
        XCTAssertFalse(info.columnsVisible)
    }

    func testClickOnFirstRowResolvesToPlaylistStart() {
        // A few points into the first row.
        XCTAssertEqual(rowIndex(at: y(0)), 100)
    }

    func testClickOnFourthRowAddsThreeToTheStart() {
        XCTAssertEqual(rowIndex(at: y(3)), 103)
    }

    func testClickOnLastLoadedRowResolvesToItsAbsoluteIndex() {
        XCTAssertEqual(rowIndex(at: y(9)), 109)
    }

    func testClickBelowTheLastRowDoesNotResolveToARow() {
        // Row 10 of 10 loaded rows: inside the playlist frame, past its content.
        guard case .background = scene.hitTest(CGPoint(x: 20, y: y(10)), state: state()) else {
            XCTFail("A click past the last loaded row should fall through to the background")
            return
        }
    }

    func testPlaylistOffsetIsAddedToTheClickedLine() {
        // Scrolled by two rows, the first visible line is rows[2] (index 102) and
        // the second visible line is rows[3] (index 103), matching the renderer.
        var state = state()
        state.playlistOffset = 2
        guard case .playlistRow(let index, _) =
            scene.hitTest(CGPoint(x: 20, y: y(1)), state: state)
        else {
            XCTFail("Expected a playlist row")
            return
        }
        XCTAssertEqual(index, 103)
    }

    func testColumnHeaderIsNotExcludedFromRowHitTesting() throws {
        // Documents current behaviour, not an assumption: the renderer shifts the
        // rows down by one `rowHeight` when `columnsVisible="true"`, but hit
        // testing does not, so a click in the header band already resolves to the
        // first row and every row below it is off by one.
        let headerScene = try makeSkin(wms: """
        <theme title="Playlist Header Test">
          <view id="main" width="200" height="200">
            <playlist id="queue" left="0" top="20" width="200" height="180"
                      columns="name=Title;artist=Artist" fontSize="11"
                      columnsVisible="true"/>
          </view>
        </theme>
        """)

        guard case .playlistRow(let headerIndex, _) =
            headerScene.hitTest(CGPoint(x: 20, y: Self.playlistTop + 4), state: state())
        else {
            XCTFail("Expected the header band to be treated as a row (current behaviour)")
            return
        }
        XCTAssertEqual(headerIndex, 100)

        // The renderer draws rows[0] at y 37...54, but that click lands on rows[1].
        guard case .playlistRow(let firstDrawnRow, _) =
            headerScene.hitTest(CGPoint(x: 20, y: Self.playlistTop + Self.rowHeight + 4), state: state())
        else {
            XCTFail("Expected a row hit one line below the header")
            return
        }
        XCTAssertEqual(firstDrawnRow, 101)
    }

    // MARK: - Helpers

    private func state() -> PlayerState {
        var state = PlayerState()
        state.playlistStart = 100
        state.playlistTotal = 10
        state.playlistRows = (100..<110).map { index in
            PlaylistRow(index: index, title: "Track \(index)", artist: "Artist \(index)",
                        album: "Album", duration: 180)
        }
        return state
    }

    /// Midpoint of the row at `line`, inside the playlist frame.
    private func y(_ line: Int) -> CGFloat {
        Self.playlistTop + CGFloat(line) * Self.rowHeight + Self.rowHeight / 2
    }

    private func rowIndex(at point: CGFloat) -> Int? {
        guard case .playlistRow(let index, _) =
            scene.hitTest(CGPoint(x: 20, y: point), state: state())
        else { return nil }
        return index
    }
}
