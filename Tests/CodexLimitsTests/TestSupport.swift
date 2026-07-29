import Foundation
import XCTest
@testable import CodexLimits

extension XCTestCase {
    func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

extension CodexAssistedHistory {
    func recordResult(
        _ result: CodexAssistedAnalysisResult,
        scope: CodexAssistedAnalysisScope
    ) async throws {
        try recordAnalysis(
            result: result,
            overhead: result.overhead,
            outcome: .succeeded,
            scope: scope,
            observedAt: result.observedAt
        )
    }
}
