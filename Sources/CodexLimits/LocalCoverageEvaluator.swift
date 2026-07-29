import Foundation

enum LocalCoverageUnavailableReason: String, Codable, Equatable, Sendable {
    case tokenDefinitionsNotProvenCompatible
}

struct LocalCoverageEvaluation: Equatable, Sendable {
    let comparable: Bool
    let numericPercent: Double?
    let reason: LocalCoverageUnavailableReason?

    static let unavailable = LocalCoverageEvaluation(
        comparable: false,
        numericPercent: nil,
        reason: .tokenDefinitionsNotProvenCompatible
    )
}
