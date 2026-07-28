import Foundation
import XCTest
@testable import CodexLimits

final class ThreadProjectionSourceTests: XCTestCase {
    func testProjectionUsesOnlyBoundedReadRequestsAndKeepsWhitelistedMetadata() async throws {
        let recorder = ProjectionRequestRecorder()
        let source = ReadOnlyThreadProjectionSource { request in
            try await recorder.response(for: request)
        }

        let page = try await source.list(cursor: nil, limit: 25)
        let detail = try await source.read(threadID: "task-child")
        let requests = await recorder.requests

        XCTAssertEqual(
            requests,
            [
                .list(
                    cursor: nil,
                    limit: 25,
                    useStateDBOnly: true,
                    sortKey: "updated_at"
                ),
                .read(threadID: "task-child", includeTurns: false)
            ]
        )
        XCTAssertEqual(page.tasks.count, 1)
        XCTAssertEqual(page.tasks[0].taskID, "task-child")
        XCTAssertEqual(page.tasks[0].parentTaskID, "task-root")
        XCTAssertEqual(page.tasks[0].projectLabel, "atlas")
        XCTAssertEqual(
            page.tasks[0].rolloutFileURL?.path,
            "/synthetic/private/rollout.jsonl"
        )
        XCTAssertEqual(page.tasks[0].source.source, .appServerThreadList)
        XCTAssertEqual(page.tasks[0].source.sourceVersion, "0.145.0")
        XCTAssertEqual(detail?.taskID, "task-child")
        XCTAssertEqual(detail?.projectLabel, "atlas")
    }
}

private actor ProjectionRequestRecorder {
    private(set) var requests: [ThreadProjectionReadRequest] = []

    func response(for request: ThreadProjectionReadRequest) throws -> Data {
        requests.append(request)
        switch request {
        case .list:
            return Data(#"""
            {"result":{"data":[{
              "id":"task-child",
              "parentThreadId":"task-root",
              "cliVersion":"0.145.0",
              "cwd":"/synthetic/projects/atlas",
              "createdAt":1785146400,
              "updatedAt":1785146460,
              "preview":"",
              "path":"/synthetic/private/rollout.jsonl",
              "gitInfo":{"repositoryUrl":"discard"}
            }],"nextCursor":"next"}}
            """#.utf8)
        case .read:
            return Data(#"""
            {"result":{"thread":{
              "id":"task-child",
              "parentThreadId":"task-root",
              "cliVersion":"0.145.0",
              "cwd":"/synthetic/projects/atlas",
              "createdAt":1785146400,
              "updatedAt":1785146460,
              "turns":[],
              "preview":""
            }}}
            """#.utf8)
        }
    }
}
