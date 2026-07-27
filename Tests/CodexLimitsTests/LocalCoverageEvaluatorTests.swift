import XCTest
@testable import CodexLimits

final class LocalCoverageEvaluatorTests: XCTestCase {
    func testUnprovenTokenDefinitionsRemainNonComparable() {
        let result = LocalCoverageEvaluator().evaluate()

        XCTAssertFalse(result.comparable)
        XCTAssertNil(result.numericPercent)
        XCTAssertEqual(result.reason, .tokenDefinitionsNotProvenCompatible)
    }
}
