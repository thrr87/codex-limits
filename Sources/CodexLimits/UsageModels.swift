import Foundation

struct UsageWindow: Codable, Equatable, Sendable {
    let remainingPercent: Double
    let resetsAt: Date
    let durationMinutes: Int

    var startsAt: Date {
        resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
    }
}

struct UsageSample: Codable, Equatable, Hashable, Sendable {
    let observedAt: Date
    let remainingPercent: Double
    let resetsAt: Date

    private enum CodingKeys: String, CodingKey {
        case observedAt
        case date
        case remainingPercent
        case resetsAt
    }

    init(observedAt: Date, remainingPercent: Double, resetsAt: Date) {
        self.observedAt = observedAt
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
            ?? container.decode(Date.self, forKey: .date)
        remainingPercent = try container.decode(Double.self, forKey: .remainingPercent)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
    }
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
