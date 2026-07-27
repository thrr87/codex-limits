import Foundation

enum ThreadProjectionReadRequest: Equatable, Sendable {
    case list(cursor: String?, limit: Int, useStateDBOnly: Bool)
    case read(threadID: String, includeTurns: Bool)
}

struct ThreadProjection: Equatable, Sendable {
    let taskID: String
    let parentTaskID: String?
    let projectLabel: String?
    let createdAt: Date?
    let updatedAt: Date?
    let source: LocalActivitySourceMetadata
}

struct ThreadProjectionPage: Equatable, Sendable {
    let tasks: [ThreadProjection]
    let nextCursor: String?
}

protocol ThreadProjectionSource {
    func list(cursor: String?, limit: Int) async throws -> ThreadProjectionPage
    func read(threadID: String) async throws -> ThreadProjection?
}

struct ReadOnlyThreadProjectionSource: ThreadProjectionSource {
    typealias Request = @Sendable (ThreadProjectionReadRequest) async throws -> Data

    private let request: Request
    private let now: @Sendable () -> Date

    init(
        request: @escaping Request,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.request = request
        self.now = now
    }

    func list(cursor: String?, limit: Int) async throws -> ThreadProjectionPage {
        let data = try await request(
            .list(cursor: cursor, limit: limit, useStateDBOnly: true)
        )
        let response = try JSONDecoder().decode(
            ThreadListRPCResponse.self,
            from: data
        )
        return ThreadProjectionPage(
            tasks: response.result.data.map(projection),
            nextCursor: response.result.nextCursor
        )
    }

    func read(threadID: String) async throws -> ThreadProjection? {
        let data = try await request(
            .read(threadID: threadID, includeTurns: false)
        )
        let response = try JSONDecoder().decode(
            ThreadReadRPCResponse.self,
            from: data
        )
        return projection(response.result.thread)
    }

    private func projection(_ thread: ThreadProjectionWire) -> ThreadProjection {
        ThreadProjection(
            taskID: thread.id,
            parentTaskID: thread.parentThreadId,
            projectLabel: projectLabel(from: thread.cwd),
            createdAt: thread.createdAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            updatedAt: thread.updatedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            source: LocalActivitySourceMetadata(
                source: .appServerThreadList,
                sourceVersion: thread.cliVersion ?? "unknown",
                schemaVersion: "app-server-v2",
                sourceGeneration: 0,
                historyMode: nil,
                observedAt: now()
            )
        )
    }

    private func projectLabel(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let label = URL(fileURLWithPath: path).lastPathComponent
        return label.isEmpty ? nil : label
    }
}

private struct ThreadListRPCResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let data: [ThreadProjectionWire]
        let nextCursor: String?
    }
}

private struct ThreadReadRPCResponse: Decodable {
    let result: Result

    struct Result: Decodable {
        let thread: ThreadProjectionWire
    }
}

private struct ThreadProjectionWire: Decodable {
    let id: String
    let parentThreadId: String?
    let cliVersion: String?
    let cwd: String?
    let createdAt: Int64?
    let updatedAt: Int64?
}
