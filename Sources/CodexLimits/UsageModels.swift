import Foundation

struct UsageWindow: Codable, Equatable, Sendable {
    let remainingPercent: Double
    let resetsAt: Date
    let durationMinutes: Int

    var startsAt: Date {
        resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
    }
}

struct UsageSample: Codable, Equatable, Sendable {
    let date: Date
    let remainingPercent: Double
    let resetsAt: Date
}

struct TokenDay: Codable, Equatable, Sendable {
    let date: Date
    let tokens: Int64
}

struct LimitReading: Codable, Equatable, Identifiable, Sendable {
    let limitId: String
    let name: String
    let window: UsageWindow

    var id: String { "\(limitId)-\(window.durationMinutes)" }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let mainLimit: LimitReading
    let otherLimits: [LimitReading]
    let tokenHistory: [TokenDay]
    let emergencyResetCount: Int
    let fetchedAt: Date
}

enum PaceStatus: String, Codable, Equatable, Sendable {
    case slowDown
    case onTrack
    case roomToUseMore
}

struct Forecast: Equatable, Sendable {
    let status: PaceStatus
    let expectedRemainingAtReset: Double
    let safetyRemainingAtReset: Double
    let historicalRemainingAtReset: Double
    let recommendedPercentPerDay: Double
    let currentPercentPerDay: Double
    let historicalPercentPerDay: Double
    let safetyPercentPerDay: Double
}
