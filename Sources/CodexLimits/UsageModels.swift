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
    let lifetimeTokens: Int64?
    let comparisonBreak: Bool

    private enum CodingKeys: String, CodingKey {
        case observedAt
        case date
        case remainingPercent
        case resetsAt
        case lifetimeTokens
        case comparisonBreak
    }

    init(
        observedAt: Date,
        remainingPercent: Double,
        resetsAt: Date,
        lifetimeTokens: Int64? = nil,
        comparisonBreak: Bool = false
    ) {
        self.observedAt = observedAt
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.lifetimeTokens = lifetimeTokens
        self.comparisonBreak = comparisonBreak
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
            ?? container.decode(Date.self, forKey: .date)
        remainingPercent = try container.decode(Double.self, forKey: .remainingPercent)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
        lifetimeTokens = try container.decodeIfPresent(Int64.self, forKey: .lifetimeTokens)
        comparisonBreak = try container.decodeIfPresent(
            Bool.self,
            forKey: .comparisonBreak
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(lifetimeTokens, forKey: .lifetimeTokens)
        if comparisonBreak {
            try container.encode(true, forKey: .comparisonBreak)
        }
    }

    static func == (lhs: UsageSample, rhs: UsageSample) -> Bool {
        lhs.observedAt == rhs.observedAt
            && lhs.remainingPercent == rhs.remainingPercent
            && lhs.resetsAt == rhs.resetsAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(observedAt)
        hasher.combine(remainingPercent)
        hasher.combine(resetsAt)
    }
}

enum UsageHistoryPolicy {
    static let weeklyDurationMinutes = 10_080
    static let correctionTolerance = 0.1
    static let tightBoundary: TimeInterval = 15 * 60
    static let maximumComparableGap: TimeInterval = 30 * 60

    static func segments(
        _ samples: [UsageSample]
    ) -> [[UsageSample]] {
        samples.sorted { $0.observedAt < $1.observedAt }
            .reduce(into: []) { intervals, sample in
                if let previous = intervals.last?.last,
                   sample.remainingPercent
                    > previous.remainingPercent + correctionTolerance {
                    intervals.append([sample])
                } else if intervals.isEmpty {
                    intervals.append([sample])
                } else {
                    intervals[intervals.count - 1].append(sample)
                }
            }
    }
}

enum TokenDayCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

struct TokenDay: Codable, Equatable, Sendable {
    let date: Date
    let tokens: Int64
    let completeness: TokenDayCompleteness?

    init(
        date: Date,
        tokens: Int64,
        completeness: TokenDayCompleteness? = nil
    ) {
        self.date = date
        self.tokens = tokens
        self.completeness = completeness
    }
}

struct LimitReading: Codable, Equatable, Identifiable, Sendable {
    let limitId: String
    let name: String
    let window: UsageWindow

    var id: String { "\(limitId)-\(window.durationMinutes)" }
}

struct BankedResetDetail: Codable, Equatable, Sendable {
    let id: String
    let resetType: String?
    let status: String
    let grantedAt: Date?
    let expiresAt: Date
    let title: String?
    let description: String?
}

struct AccountCreditFacts: Codable, Equatable, Sendable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool

    func fillingMissingValues(from previous: AccountCreditFacts) -> AccountCreditFacts {
        AccountCreditFacts(
            balance: balance ?? previous.balance,
            hasCredits: hasCredits,
            unlimited: unlimited
        )
    }
}

struct AccountSpendControlFacts: Codable, Equatable, Sendable {
    let limit: String
    let used: String
    let remainingPercent: Double
    let resetsAt: Date
    let reached: Bool?

    func fillingMissingValues(
        from previous: AccountSpendControlFacts
    ) -> AccountSpendControlFacts {
        AccountSpendControlFacts(
            limit: limit,
            used: used,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            reached: reached ?? previous.reached
        )
    }
}

struct AccountFacts: Codable, Equatable, Sendable {
    let lifetimeTokens: Int64?
    let lifetimeTokensObservedAt: Date?
    let peakDailyTokens: Int64?
    let peakDailyTokensObservedAt: Date?
    let longestRunningTurnSeconds: Int64?
    let longestRunningTurnObservedAt: Date?
    let currentStreakDays: Int64?
    let currentStreakObservedAt: Date?
    let longestStreakDays: Int64?
    let longestStreakObservedAt: Date?
    let credits: AccountCreditFacts?
    let creditsObservedAt: Date?
    let creditBalanceObservedAt: Date?
    let spendControl: AccountSpendControlFacts?
    let spendControlObservedAt: Date?
    let spendControlReachedObservedAt: Date?

    init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?,
        credits: AccountCreditFacts?,
        spendControl: AccountSpendControlFacts?,
        lifetimeTokensObservedAt: Date? = nil,
        peakDailyTokensObservedAt: Date? = nil,
        longestRunningTurnObservedAt: Date? = nil,
        currentStreakObservedAt: Date? = nil,
        longestStreakObservedAt: Date? = nil,
        creditsObservedAt: Date? = nil,
        creditBalanceObservedAt: Date? = nil,
        spendControlObservedAt: Date? = nil,
        spendControlReachedObservedAt: Date? = nil
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.lifetimeTokensObservedAt = lifetimeTokensObservedAt
        self.peakDailyTokens = peakDailyTokens
        self.peakDailyTokensObservedAt = peakDailyTokensObservedAt
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
        self.longestRunningTurnObservedAt = longestRunningTurnObservedAt
        self.currentStreakDays = currentStreakDays
        self.currentStreakObservedAt = currentStreakObservedAt
        self.longestStreakDays = longestStreakDays
        self.longestStreakObservedAt = longestStreakObservedAt
        self.credits = credits
        self.creditsObservedAt = creditsObservedAt
        self.creditBalanceObservedAt = creditBalanceObservedAt
        self.spendControl = spendControl
        self.spendControlObservedAt = spendControlObservedAt
        self.spendControlReachedObservedAt = spendControlReachedObservedAt
    }

    var isEmpty: Bool {
        lifetimeTokens == nil
            && peakDailyTokens == nil
            && longestRunningTurnSeconds == nil
            && currentStreakDays == nil
            && longestStreakDays == nil
            && credits == nil
            && spendControl == nil
    }

    func fillingMissingValues(from previous: AccountFacts) -> AccountFacts {
        AccountFacts(
            lifetimeTokens: lifetimeTokens ?? previous.lifetimeTokens,
            peakDailyTokens: peakDailyTokens ?? previous.peakDailyTokens,
            longestRunningTurnSeconds: longestRunningTurnSeconds
                ?? previous.longestRunningTurnSeconds,
            currentStreakDays: currentStreakDays ?? previous.currentStreakDays,
            longestStreakDays: longestStreakDays ?? previous.longestStreakDays,
            credits: credits.map {
                guard let previousCredits = previous.credits else { return $0 }
                return $0.fillingMissingValues(from: previousCredits)
            } ?? previous.credits,
            spendControl: spendControl.map {
                guard let previousSpendControl = previous.spendControl else { return $0 }
                return $0.fillingMissingValues(from: previousSpendControl)
            } ?? previous.spendControl,
            lifetimeTokensObservedAt: lifetimeTokens != nil
                ? lifetimeTokensObservedAt
                : previous.lifetimeTokensObservedAt,
            peakDailyTokensObservedAt: peakDailyTokens != nil
                ? peakDailyTokensObservedAt
                : previous.peakDailyTokensObservedAt,
            longestRunningTurnObservedAt: longestRunningTurnSeconds != nil
                ? longestRunningTurnObservedAt
                : previous.longestRunningTurnObservedAt,
            currentStreakObservedAt: currentStreakDays != nil
                ? currentStreakObservedAt
                : previous.currentStreakObservedAt,
            longestStreakObservedAt: longestStreakDays != nil
                ? longestStreakObservedAt
                : previous.longestStreakObservedAt,
            creditsObservedAt: credits != nil
                ? creditsObservedAt
                : previous.creditsObservedAt,
            creditBalanceObservedAt: credits?.balance != nil
                ? creditBalanceObservedAt
                : previous.creditBalanceObservedAt,
            spendControlObservedAt: spendControl != nil
                ? spendControlObservedAt
                : previous.spendControlObservedAt,
            spendControlReachedObservedAt: spendControl?.reached != nil
                ? spendControlReachedObservedAt
                : previous.spendControlReachedObservedAt
        )
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let mainLimit: LimitReading?
    let otherLimits: [LimitReading]
    let tokenHistory: [TokenDay]
    let emergencyResetCount: Int
    let bankedResetCountAvailable: Bool?
    let bankedResetDetails: [BankedResetDetail]?
    let fetchedAt: Date
    let accountFacts: AccountFacts?

    init(
        mainLimit: LimitReading?,
        otherLimits: [LimitReading],
        tokenHistory: [TokenDay],
        emergencyResetCount: Int,
        bankedResetCountAvailable: Bool? = true,
        bankedResetDetails: [BankedResetDetail]? = nil,
        fetchedAt: Date,
        accountFacts: AccountFacts? = nil
    ) {
        self.mainLimit = mainLimit
        self.otherLimits = otherLimits
        self.tokenHistory = tokenHistory
        self.emergencyResetCount = emergencyResetCount
        self.bankedResetCountAvailable = bankedResetCountAvailable
        self.bankedResetDetails = bankedResetDetails
        self.fetchedAt = fetchedAt
        self.accountFacts = accountFacts
    }
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
    let recommendedPercentPerDay: Double
    let currentPercentPerDay: Double
    let safetyPercentPerDay: Double
    let historicalReference: UsageForecastReference?

    var historicalRemainingAtReset: Double {
        historicalReference?.remainingAtReset ?? expectedRemainingAtReset
    }

    var historicalPercentPerDay: Double {
        historicalReference?.percentPerDay ?? currentPercentPerDay
    }

    var historicalReferenceSource: UsageForecastReferenceSource? {
        historicalReference?.source
    }
}

enum UsageForecastReferenceSource: String, Equatable, Sendable {
    case accountHistory = "Account history"
    case tokenEstimate = "Token activity estimate"
}

struct UsageForecastReference: Equatable, Sendable {
    let source: UsageForecastReferenceSource
    let percentPerDay: Double
    let remainingAtReset: Double
}
