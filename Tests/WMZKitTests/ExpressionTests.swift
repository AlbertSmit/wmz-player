import XCTest
@testable import WMZKit

final class ExpressionTests: XCTestCase {
    private func number(_ raw: String?, lookup: @escaping (String) -> Double = { _ in 0 }) -> Double? {
        Expression.number(raw, lookup: lookup)
    }

    func testPlainNumberEvaluatesToItsValue() {
        XCTAssertEqual(number("42"), 42)
    }

    func testNumberWithWhitespaceIsTrimmed() {
        XCTAssertEqual(number("  7.5 "), 7.5)
    }

    func testJScriptIdentifierMinusConstantUsesLookup() {
        XCTAssertEqual(number("jscript:view.width-43", lookup: { $0 == "view.width" ? 200 : 0 }), 157)
    }

    func testDivisionReturnsFractionalValue() {
        XCTAssertEqual(number("10/4"), 2.5)
    }

    func testMultiplicationBindsTighterThanAddition() {
        XCTAssertEqual(number("2+3*4"), 14)
    }

    func testParenthesesOverridePrecedence() {
        XCTAssertEqual(number("(2+3)*4"), 20)
    }

    func testUnaryMinusIsSupported() {
        XCTAssertEqual(number("-view.height/2", lookup: { $0 == "view.height" ? 100 : 0 }), -50)
    }

    func testTrailingSemicolonIsIgnored() {
        XCTAssertEqual(number("42;"), 42)
    }

    func testStatementWithSemicolonReturnsNil() {
        XCTAssertNil(number("foo();"))
    }

    func testAssignmentReturnsNil() {
        XCTAssertNil(number("x = 5"))
    }

    func testDivisionByZeroReturnsNil() {
        XCTAssertNil(number("1/0"))
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(number("   "))
    }
}
