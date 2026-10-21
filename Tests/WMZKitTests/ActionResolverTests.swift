import XCTest
@testable import WMZKit

final class ActionResolverTests: XCTestCase {
    private func element(_ name: String, _ attributes: [String: String] = [:]) -> Element {
        Element(name: name, attrs: attributes)
    }

    private func button(onClick script: String) -> Element {
        element("button", ["onclick": script])
    }

    // MARK: - Element names

    func testPlayElementMapsToPlay() {
        XCTAssertEqual(ActionResolver.action(for: element("playelement")), .play)
    }

    func testPauseElementMapsToPause() {
        XCTAssertEqual(ActionResolver.action(for: element("pauseelement")), .pause)
    }

    func testNextElementMapsToNext() {
        XCTAssertEqual(ActionResolver.action(for: element("nextelement")), .next)
    }

    // MARK: - Scripts

    func testControlsPlayScriptMapsToPlay() {
        XCTAssertEqual(ActionResolver.action(for: button(onClick: "player.controls.play()")), .play)
    }

    func testOpenViewScriptMapsToOpenViewWithViewID() {
        XCTAssertEqual(ActionResolver.action(for: button(onClick: "theme.openView('plView')")), .openView("plView"))
    }

    func testOnViewCloseScriptMapsToClosePanelWithID() {
        XCTAssertEqual(ActionResolver.action(for: button(onClick: "onViewClose('plViewer')")), .closePanel("plViewer"))
    }

    func testSavePreferenceScriptMapsToOpenPanelToken() {
        let script = "theme.savePreference('remoteCallPl','true')"
        XCTAssertEqual(ActionResolver.action(for: button(onClick: script)), .openPanel("pl"))
    }

    func testRateSongScriptMapsToRating() {
        XCTAssertEqual(ActionResolver.action(for: button(onClick: "rateSong('80')")), .setRating(80))
    }

    // MARK: - Sound

    func testSoundIsExtractedFromCheckSoundPref() {
        let script = "checkSoundPref('button.wav');player.controls.play()"
        XCTAssertEqual(ActionResolver.sound(for: button(onClick: script)), "button.wav")
    }

    func testElementWithoutClickScriptHasNoSound() {
        XCTAssertNil(ActionResolver.sound(for: button(onClick: "")))
    }

    // MARK: - Visibility

    func testVisibleFalseHidesElement() {
        let element = self.element("button", ["visible": "false"])
        XCTAssertFalse(ActionResolver.isVisible(element, state: PlayerState()))
    }

    func testPauseEnabledFollowsPlayingStateWhenPlaying() {
        let element = self.element("button", ["visible": "wmpenabled:player.controls.pause"])
        var state = PlayerState()
        state.isPlaying = true
        XCTAssertTrue(ActionResolver.isVisible(element, state: state))
    }

    func testPauseEnabledFollowsPlayingStateWhenPaused() {
        let element = self.element("button", ["visible": "wmpenabled:player.controls.pause"])
        var state = PlayerState()
        state.isPlaying = false
        XCTAssertFalse(ActionResolver.isVisible(element, state: state))
    }

    func testFilledStarIsVisibleAtItsRating() {
        var state = PlayerState()
        state.rating = 60 // three of five stars
        XCTAssertTrue(ActionResolver.isVisible(element("button", ["id": "rate3"]), state: state))
    }

    func testBlankStarForAFilledSlotIsHidden() {
        var state = PlayerState()
        state.rating = 60
        XCTAssertFalse(ActionResolver.isVisible(element("button", ["id": "blankRate3"]), state: state))
    }

    func testEmptyRatingOverlayIsHiddenOnceRated() {
        var state = PlayerState()
        state.rating = 60
        XCTAssertFalse(ActionResolver.isVisible(element("button", ["id": "emptyRate"]), state: state))
    }
}
