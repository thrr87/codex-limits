import Foundation

struct LocalActivityFactIndex {
    private let entries: [(date: Date, index: Int)]
    private let turnEntries: [
        (start: Date, end: Date, index: Int)
    ]
    private let boundaryEntries: [
        (
            date: Date,
            affectedStart: Date?,
            affectedEnd: Date?,
            index: Int
        )
    ]

    init(_ facts: [LocalActivityFact]) {
        let parser = LocalEventTimestampParser()
        entries = facts.enumerated().compactMap { index, fact in
            guard let timestamp = fact.eventTimestamp,
                  let date = parser.date(from: timestamp) else {
                return nil
            }
            return (date, index)
        }
        .sorted { $0.date < $1.date }
        turnEntries = facts.enumerated().compactMap { index, fact in
            guard case let .turnTiming(timing) = fact.value,
                  let start = timing.startedAt,
                  let end = timing.completedAt,
                  start < end else {
                return nil
            }
            return (start, end, index)
        }
        .sorted { $0.start < $1.start }
        boundaryEntries = facts.enumerated().compactMap { index, fact in
            guard case let .turnTiming(timing) = fact.value else {
                return nil
            }
            let start = timing.startedAt
            let end = timing.completedAt
            if let start, let end, start < end {
                return nil
            }
            let date = start
                ?? end
                ?? fact.eventTimestamp.flatMap(parser.date)
            guard let date else { return nil }
            if let start, let end {
                return (
                    date,
                    min(start, end),
                    max(start, end),
                    index
                )
            }
            return (date, start, end, index)
        }
    }

    func facts(
        in interval: DateInterval,
        from facts: [LocalActivityFact]
    ) -> [LocalActivityFact] {
        let start = lowerBound(for: interval.start)
        let end = lowerBound(for: interval.end)
        return entries[start ..< end].compactMap {
            facts.indices.contains($0.index) ? facts[$0.index] : nil
        }
    }

    func activityFacts(
        in interval: DateInterval,
        from facts: [LocalActivityFact]
    ) -> [LocalActivityFact] {
        var result = self.facts(in: interval, from: facts).filter { fact in
            if case .turnTiming = fact.value { return false }
            return true
        }
        let candidateEnd = turnLowerBound(for: interval.end)
        result += turnEntries[..<candidateEnd]
            .lazy
            .filter { $0.end > interval.start }
            .compactMap {
                facts.indices.contains($0.index) ? facts[$0.index] : nil
            }
        result += boundaryEntries
            .lazy
            .filter { entry in
                switch (entry.affectedStart, entry.affectedEnd) {
                case let (start?, end?):
                    return start < interval.end && end > interval.start
                case let (start?, nil):
                    return start < interval.end
                case let (nil, end?):
                    return end > interval.start
                case (nil, nil):
                    return interval.contains(entry.date)
                }
            }
            .compactMap {
                facts.indices.contains($0.index) ? facts[$0.index] : nil
            }
        return result
    }

    private func lowerBound(for date: Date) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func turnLowerBound(for date: Date) -> Int {
        var lower = 0
        var upper = turnEntries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if turnEntries[middle].start < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
