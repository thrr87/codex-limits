import Darwin
import Foundation

public struct AllowanceObservation: Codable, Equatable, Hashable, Sendable {
    public let metric: String
    public let observedAt: Date
    public let remainingPercent: Double
    public let resetsAt: Date
    public let startsAt: Date?
    public let source: String?

    public init(
        metric: String,
        observedAt: Date,
        remainingPercent: Double,
        resetsAt: Date,
        startsAt: Date? = nil,
        source: String? = nil
    ) {
        self.metric = metric
        self.observedAt = observedAt
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.startsAt = startsAt
        self.source = source
    }

    public var isValid: Bool {
        hasValidFields && observedAt < resetsAt
    }

    fileprivate var hasValidFields: Bool {
        !metric.isEmpty && metric.utf8.count <= 64
            && metric.utf8.allSatisfy {
                (48 ... 57).contains($0) || (65 ... 90).contains($0)
                    || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
            }
            && Self.validDate(observedAt) && Self.validDate(resetsAt)
            && remainingPercent.isFinite && (0 ... 100).contains(remainingPercent)
            && (startsAt.map { Self.validDate($0) && $0 <= observedAt } ?? true)
            && (source.map {
                !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy {
                    (48 ... 57).contains($0) || (65 ... 90).contains($0)
                        || (97 ... 122).contains($0) || [45, 46, 95].contains($0)
                }
            } ?? true)
    }

    static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (0 ..< 253_402_300_800).contains(seconds)
    }
}

public enum AllowanceHistoryError: Error, Equatable {
    case invalidRecord
    case readLimitExceeded
    case writeFailed
}

public enum AllowanceHistory {
    public static let retainedViewDays = 84
    public static let maximumFileBytes = 4 * 1_024 * 1_024
    public static let maximumReadBytes = 32 * 1_024 * 1_024
    public static let maximumRecordBytes = 512
    public static let maximumReadRecords = 200_000
    private static let maximumAppendRecords = 64

    public static func append(
        _ observations: [AllowanceObservation],
        in directory: URL
    ) throws {
        guard observations.count <= maximumAppendRecords else {
            throw AllowanceHistoryError.invalidRecord
        }
        guard observations.allSatisfy(\.hasValidFields) else {
            throw AllowanceHistoryError.invalidRecord
        }
        let observations = observations.filter { $0.observedAt < $0.resetsAt }
        guard !observations.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        let days = Dictionary(grouping: observations, by: { dayName($0.observedAt) })
        for day in days.keys.sorted() {
            try appendDay(days[day]!.sorted(by: ordered), to: directory.appendingPathComponent(day))
        }
    }

    public static func read(in directory: URL, now: Date, since: Date? = nil) throws -> [AllowanceObservation] {
        guard AllowanceObservation.validDate(now),
              since.map(AllowanceObservation.validDate) ?? true else {
            throw AllowanceHistoryError.invalidRecord
        }
        let cutoff = max(since ?? Date(timeIntervalSince1970: 0),
                         now.addingTimeInterval(-Double(retainedViewDays) * 86_400))
        guard cutoff <= now else { return [] }
        var day = calendar.startOfDay(for: cutoff)
        var totalBytes = 0
        var recordCount = 0
        var observations: Set<AllowanceObservation> = []
        while day <= now {
            try Task.checkCancellation()
            let name = dayName(day)
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(64 * 1_024, maximumFileBytes + 1 - data.count)),
                      !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= maximumFileBytes,
                          totalBytes + data.count <= maximumReadBytes else {
                        throw AllowanceHistoryError.readLimitExceeded
                    }
                    try Task.checkCancellation()
                }
                totalBytes += data.count
                var lineStart = data.startIndex
                for newline in data.indices where data[newline] == 10 {
                    let line = data[lineStart ..< newline]
                    lineStart = data.index(after: newline)
                    recordCount += 1
                    guard recordCount <= maximumReadRecords else {
                        throw AllowanceHistoryError.readLimitExceeded
                    }
                    let observation = try decode(line)
                    guard dayName(observation.observedAt) == name else {
                        throw AllowanceHistoryError.invalidRecord
                    }
                    if observation.observedAt >= cutoff, observation.observedAt <= now {
                        observations.insert(observation)
                    }
                }
                if let end = data.lastIndex(of: 10) {
                    guard data.distance(from: data.index(after: end), to: data.endIndex) <= maximumRecordBytes else {
                        throw AllowanceHistoryError.invalidRecord
                    }
                } else if data.count > maximumRecordBytes {
                    throw AllowanceHistoryError.invalidRecord
                }
            }
            day = day.addingTimeInterval(86_400)
        }
        return observations.sorted(by: ordered)
    }

    public static func delete(in directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func appendDay(_ observations: [AllowanceObservation], to url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let lockDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            try Task.checkCancellation()
            guard errno == EWOULDBLOCK || errno == EINTR,
                  ProcessInfo.processInfo.systemUptime < lockDeadline else {
                throw AllowanceHistoryError.writeFailed
            }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw AllowanceHistoryError.writeFailed }
        let size = lseek(descriptor, 0, SEEK_END)
        guard size >= 0 else { throw AllowanceHistoryError.writeFailed }
        let tailCount = min(Int(size), (maximumAppendRecords + 2) * maximumRecordBytes)
        var bytes = [UInt8](repeating: 0, count: tailCount)
        let count = pread(descriptor, &bytes, tailCount, size - off_t(tailCount))
        guard count == tailCount else { throw AllowanceHistoryError.writeFailed }
        var tail = Data(bytes)
        if !tail.isEmpty, tail.last != 10 {
            let partialStart = tail.lastIndex(of: 10).map { tail.index(after: $0) } ?? tail.startIndex
            let partial = tail[partialStart...]
            guard partial.count <= maximumRecordBytes else { throw AllowanceHistoryError.invalidRecord }
            if (try? decode(partial)) != nil {
                try write(Data([10]), to: descriptor)
                tail.append(10)
            } else {
                guard ftruncate(descriptor, size - off_t(partial.count)) == 0 else {
                    throw AllowanceHistoryError.writeFailed
                }
                tail.removeSubrange(partialStart...)
            }
        }
        if size > tailCount, let newline = tail.firstIndex(of: 10) {
            tail.removeSubrange(...newline)
        }
        let recent = try completeLines(tail).map(decode)
        guard recent.allSatisfy({ dayName($0.observedAt) == url.lastPathComponent }) else {
            throw AllowanceHistoryError.invalidRecord
        }
        var seen = Set(recent)
        var latest = Dictionary(grouping: recent, by: \.metric).mapValues {
            $0.map(\.observedAt).max()!
        }
        // ponytail: ordered sources need only bounded-tail retry deduplication;
        // arbitrary historical imports would need an indexed merge path.
        let encoder = JSONEncoder()
        for observation in observations {
            guard latest[observation.metric].map({ observation.observedAt >= $0 }) ?? true,
                  seen.insert(observation).inserted else { continue }
            var data = try encoder.encode(observation)
            guard data.count <= maximumRecordBytes else { throw AllowanceHistoryError.invalidRecord }
            data.append(10)
            try write(data, to: descriptor)
            latest[observation.metric] = observation.observedAt
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AllowanceHistoryError.writeFailed }
                written += count
            }
        }
    }

    private static func completeLines(_ data: Data) -> [Data.SubSequence] {
        guard let last = data.lastIndex(of: 10) else { return [] }
        return data[..<last].split(separator: 10, omittingEmptySubsequences: false)
    }

    private static func decode(_ line: Data.SubSequence) throws -> AllowanceObservation {
        guard !line.isEmpty, line.count <= maximumRecordBytes,
              let value = try? JSONDecoder().decode(AllowanceObservation.self, from: line),
              value.isValid else { throw AllowanceHistoryError.invalidRecord }
        return value
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func dayName(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", parts.year!, parts.month!, parts.day!)
    }

    private static func ordered(_ lhs: AllowanceObservation, _ rhs: AllowanceObservation) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.metric != rhs.metric { return lhs.metric < rhs.metric }
        if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
        return lhs.remainingPercent < rhs.remainingPercent
    }
}
