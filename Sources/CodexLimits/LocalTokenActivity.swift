import Foundation

enum LocalActivityObservation: Equatable, Sendable {
    case continuous(sourceVersion: String, observedAt: Date)
    case gap(sourceVersion: String, observedAt: Date, reason: String)
    case unavailable(String)

    var coverage: CoverageLevel {
        switch self {
        case .continuous: .high
        case .gap: .low
        case .unavailable: .unavailable
        }
    }

    var reason: String? {
        switch self {
        case .continuous:
            nil
        case let .gap(_, _, reason), let .unavailable(reason):
            reason
        }
    }
}

struct LocalTokenActivityPoint: Equatable, Identifiable, Sendable {
    let date: Date
    let tokens: Int64

    var id: Date { date }
}

struct LocalTokenActivitySlice: Equatable, Sendable {
    let tokens: Int64
    let points: [LocalTokenActivityPoint]
    let coverage: CoverageLevel
    let reason: String?
}

struct LocalTokenActivitySnapshot: Equatable, Sendable {
    let tokens: Int64?
    let interval: DateInterval
    let coverage: CoverageLevel
    let reason: String?
    let sourceVersion: String?
    let observedAt: Date?
    let points: [LocalTokenActivityPoint]
    let accountComparison: LocalCoverageEvaluation

    static func unavailable(
        _ reason: String,
        interval: DateInterval
    ) -> LocalTokenActivitySnapshot {
        LocalTokenActivitySnapshot(
            tokens: nil,
            interval: interval,
            coverage: .unavailable,
            reason: reason,
            sourceVersion: nil,
            observedAt: nil,
            points: [],
            accountComparison: .unavailable
        )
    }

    func slice(in selectedInterval: DateInterval) -> LocalTokenActivitySlice {
        let baseline = points.last {
            $0.date < selectedInterval.start
        }?.tokens ?? 0
        let selectedPoints = points
            .filter {
                $0.date >= selectedInterval.start
                    && $0.date < selectedInterval.end
            }
            .map {
                LocalTokenActivityPoint(
                    date: $0.date,
                    tokens: $0.tokens - baseline
                )
            }
        let selectedCoverage: CoverageLevel
        let selectedReason: String?
        if coverage == .low || coverage == .unavailable {
            selectedCoverage = coverage
            selectedReason = reason
        } else if selectedPoints.isEmpty {
            selectedCoverage = .notApplicable
            selectedReason = "No local token activity was observed"
        } else {
            selectedCoverage = coverage
            selectedReason = reason
        }
        return LocalTokenActivitySlice(
            tokens: selectedPoints.last?.tokens ?? 0,
            points: selectedPoints,
            coverage: selectedCoverage,
            reason: selectedReason
        )
    }
}

enum LocalTokenActivityAggregator {
    static func evaluate(
        facts: [LocalActivityFact],
        interval: DateInterval,
        observation: LocalActivityObservation
    ) -> LocalTokenActivitySnapshot {
        if case let .unavailable(reason) = observation {
            return .unavailable(reason, interval: interval)
        }
        return observedActivity(
            facts: facts,
            interval: interval,
            observation: observation
        )
    }

    private static func observedActivity(
        facts: [LocalActivityFact],
        interval: DateInterval,
        observation: LocalActivityObservation
    ) -> LocalTokenActivitySnapshot {
        let timestampParser = LocalEventTimestampParser()
        var seen = Set<String>()
        var hasUnboundedCounter = false
        let values = facts.compactMap { fact -> (Date, Int64)? in
            guard fact.key == .token,
                  fact.availability == .available,
                  let eventID = fact.eventID,
                  seen.insert(eventID).inserted,
                  let timestamp = fact.eventTimestamp,
                  let date = timestampParser.date(from: timestamp),
                  date >= interval.start,
                  date < interval.end else {
                return nil
            }
            guard let delta = fact.numericDelta, delta >= 0 else {
                hasUnboundedCounter = [
                    "segment-baseline",
                    "source-discontinuity",
                    "cumulative-counter-decreased"
                ].contains(fact.reason) || hasUnboundedCounter
                return nil
            }
            return (date, delta)
        }
        .sorted { $0.0 < $1.0 }

        var total: Int64 = 0
        var points: [LocalTokenActivityPoint] = []
        for (date, delta) in values {
            let addition = total.addingReportingOverflow(delta)
            guard !addition.overflow else {
                return LocalTokenActivitySnapshot(
                    tokens: nil,
                    interval: interval,
                    coverage: .unavailable,
                    reason: "Local token total is invalid",
                    sourceVersion: sourceVersion(observation),
                    observedAt: observedAt(observation),
                    points: [],
                    accountComparison: .unavailable
                )
            }
            total = addition.partialValue
            if points.last?.date == date {
                points[points.count - 1] = LocalTokenActivityPoint(
                    date: date,
                    tokens: total
                )
            } else {
                points.append(
                    LocalTokenActivityPoint(date: date, tokens: total)
                )
            }
        }

        let coverage: CoverageLevel
        let reason: String?
        switch observation {
        case .continuous:
            if hasUnboundedCounter {
                coverage = .low
                reason = "Local token activity starts from an unbounded counter"
            } else {
                coverage = values.isEmpty ? .notApplicable : .high
                reason = values.isEmpty
                    ? "No local token activity was observed"
                    : "Only local activity on this Mac is observed"
            }
        case let .gap(_, _, message):
            coverage = .low
            reason = message
        case let .unavailable(message):
            coverage = .unavailable
            reason = message
        }
        return LocalTokenActivitySnapshot(
            tokens: total,
            interval: interval,
            coverage: coverage,
            reason: reason,
            sourceVersion: sourceVersion(observation),
            observedAt: observedAt(observation),
            points: points,
            accountComparison: .unavailable
        )
    }

    private static func sourceVersion(
        _ observation: LocalActivityObservation
    ) -> String? {
        switch observation {
        case let .continuous(sourceVersion, _),
             let .gap(sourceVersion, _, _):
            sourceVersion
        case .unavailable:
            nil
        }
    }

    private static func observedAt(
        _ observation: LocalActivityObservation
    ) -> Date? {
        switch observation {
        case let .continuous(_, observedAt),
             let .gap(_, observedAt, _):
            observedAt
        case .unavailable:
            nil
        }
    }
}
