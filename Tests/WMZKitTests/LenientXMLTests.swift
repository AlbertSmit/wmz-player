import XCTest
@testable import WMZKit

final class LenientXMLTests: XCTestCase {
    private func parse(_ text: String) -> Element? {
        LenientXML.parse(text)
    }

    func testAttributeWithoutPrecedingSpaceIsRead() {
        let element = parse("<button cursor=\"hand\"onClick=\"x\"/>")
        XCTAssertEqual(element?["cursor"], "hand")
    }

    func testAttributeFollowingUnspacedAttributeIsRead() {
        let element = parse("<button cursor=\"hand\"onClick=\"x\"/>")
        XCTAssertEqual(element?["onclick"], "x")
    }

    func testDuplicateAttributeKeepsFirstValue() {
        let element = parse("<button image=\"first.png\" image=\"second.png\"/>")
        XCTAssertEqual(element?["image"], "first.png")
    }

    func testUnquotedAttributeValuesAreRead() {
        let element = parse("<view width=100 height=50/>")
        XCTAssertEqual(element?["width"], "100")
    }

    func testUnquotedHeightIsRead() {
        let element = parse("<view width=100 height=50/>")
        XCTAssertEqual(element?["height"], "50")
    }

    func testUppercaseTagsAreLowercased() {
        let element = parse("<VIEW ID=\"main\"><BUTTON/></VIEW>")
        XCTAssertEqual(element?.name, "view")
    }

    func testUppercaseChildTagIsLowercased() {
        let element = parse("<VIEW><BUTTON/></VIEW>")
        XCTAssertEqual(element?.children.first?.name, "button")
    }

    func testAttributeNamesAreLowercased() {
        let element = parse("<view ID=\"main\"/>")
        XCTAssertEqual(element?["id"], "main")
    }

    func testBareAmpersandInAttributeIsPreserved() {
        let element = parse("<text value=\"rock & roll\"/>")
        XCTAssertEqual(element?["value"], "rock & roll")
    }

    func testKnownEntitiesAreDecoded() {
        let element = parse("<text value=\"Tom &amp; Jerry\"/>")
        XCTAssertEqual(element?["value"], "Tom & Jerry")
    }

    func testSelfClosingElementHasNoChildren() {
        let element = parse("<view><button image=\"btn.png\"/></view>")
        XCTAssertEqual(element?.children.first?.children.count, 0)
    }

    func testSiblingAfterSelfClosingElementIsStillParsed() {
        let element = parse("<view><button/><text/></view>")
        XCTAssertEqual(element?.children.count, 2)
    }

    func testTextContentIsTrimmedAndDecoded() {
        let element = parse("<text>  Hello &amp; goodbye  </text>")
        XCTAssertEqual(element?.text, "Hello & goodbye")
    }
}
