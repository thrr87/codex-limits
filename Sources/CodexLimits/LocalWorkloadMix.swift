import Foundation

struct LocalEventTimestampParser {
    private let fractional: ISO8601DateFormatter
    private let standard: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        standard = ISO8601DateFormatter()
    }

    func date(from value: String) -> Date? {
        fractional.date(from: value) ?? standard.date(from: value)
    }
}

enum LocalWorkloadMixAnalyzer {
    static func detectsChange(
        facts: [LocalActivityFact],
        observation: LocalActivityObservation,
        window: UsageWindow
    ) -> Bool {
        guard observation.coverage == .high else { return false }
        let parser = LocalEventTimestampParser()
        let models = facts.compactMap { fact -> (Date, String)? in
            guard fact.key == .effectiveModel,
                  case let .text(model)? = fact.value,
                  let timestamp = fact.eventTimestamp,
                  let date = parser.date(from: timestamp) else {
                return nil
            }
            return (date, model)
        }
        let current = DateInterval(
            start: window.startsAt,
            end: window.resetsAt
        )
        let previous = DateInterval(
            start: current.start.addingTimeInterval(-current.duration),
            end: current.start
        )
        guard let currentModel = dominantModel(
            observations: models,
            interval: current
        ),
        let previousModel = dominantModel(
            observations: models,
            interval: previous
        ) else {
            return false
        }
        return currentModel != previousModel
    }

    private static func dominantModel(
        observations: [(Date, String)],
        interval: DateInterval
    ) -> String? {
        let models = observations.compactMap { date, model in
            interval.contains(date) ? model : nil
        }
        guard models.count >= 10 else { return nil }
        let counts = Dictionary(grouping: models, by: { $0 })
            .mapValues(\.count)
        guard let dominant = counts.max(by: { $0.value < $1.value }),
              Double(dominant.value) / Double(models.count) >= 0.8 else {
            return nil
        }
        return dominant.key
    }
}
