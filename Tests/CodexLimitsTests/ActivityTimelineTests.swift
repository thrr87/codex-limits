import Foundation
import XCTest
@testable import CodexLimits

final class ActivityTimelineTests: XCTestCase {
    func testActiveTimeUnionsRootsAndCountsChildActivityOnce() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "root-a-turn",
                    taskID: "root-a",
                    turnID: "turn-a",
                    start: 10,
                    end: 40
                ),
                timingFact(
                    eventID: "child-a-turn",
                    taskID: "child-a",
                    turnID: "turn-child",
                    start: 20,
                    end: 50
                ),
                timingFact(
                    eventID: "root-b-turn",
                    taskID: "root-b",
                    turnID: "turn-b",
                    start: 30,
                    end: 60
                )
            ],
            projections: [
                projection(taskID: "root-a", project: "atlas"),
                projection(
                    taskID: "child-a",
                    parentTaskID: "root-a",
                    project: "atlas"
                ),
                projection(taskID: "root-b", project: "beacon")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(slice.activeTime, 50)
        XCTAssertEqual(slice.maximumConcurrency, 2)
        XCTAssertEqual(
            slice.points.map { $0.date.timeIntervalSince1970 },
            [10, 30, 50, 60]
        )
        XCTAssertEqual(slice.points.map(\.count), [1, 2, 1, 0])
        XCTAssertEqual(slice.coverage, .partial)
    }

    func testMissingAndInvalidEndsLowerCoverageWithoutCreatingAnActiveTail() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "complete",
                    taskID: "root",
                    turnID: "complete",
                    start: 10,
                    end: 20
                ),
                timingFact(
                    eventID: "missing-end",
                    taskID: "root",
                    turnID: "open",
                    start: 30,
                    end: nil
                ),
                timingFact(
                    eventID: "clock-error",
                    taskID: "root",
                    turnID: "reversed",
                    start: 50,
                    end: 40
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(slice.activeTime, 10)
        XCTAssertEqual(slice.points.last?.date.timeIntervalSince1970, 20)
        XCTAssertEqual(slice.coverage, .partial)
        XCTAssertEqual(
            slice.reason,
            "Some Active Turn boundaries are missing or invalid"
        )
    }

    func testCompletedTurnSupersedesItsEarlierStartRecord() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "started",
                    taskID: "root",
                    turnID: "turn",
                    start: 10,
                    end: nil
                ),
                timingFact(
                    eventID: "completed",
                    taskID: "root",
                    turnID: "turn",
                    start: 10,
                    end: 40
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(slice.activeTime, 30)
        XCTAssertEqual(
            slice.reason,
            "Task Tree may omit Review and Guardian Tasks"
        )
    }

    func testTaskWithoutAProvenRootDoesNotBecomeItsOwnTaskTree() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "unknown-child",
                    taskID: "child",
                    turnID: "turn",
                    start: 10,
                    end: 40
                )
            ],
            projections: [],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(slice.activeTime, 0)
        XCTAssertEqual(slice.maximumConcurrency, 0)
        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(slice.reason, "Task Tree metadata is missing")
    }

    func testMissingTaskTreeLowersCoverageInsideTheOmittedTurn() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "unknown-child",
                    taskID: "child",
                    turnID: "turn",
                    start: 10,
                    end: 40
                )
            ],
            projections: [],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 20),
                end: Date(timeIntervalSince1970: 30)
            ),
            filters: .all
        )

        XCTAssertEqual(slice.activeTime, 0)
        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(slice.reason, "Task Tree metadata is missing")
    }

    func testOpenTurnLowersCoverageAfterItsStartWithoutAddingTime() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "open",
                    taskID: "root",
                    turnID: "turn",
                    start: 10,
                    end: nil
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 20),
                end: Date(timeIntervalSince1970: 30)
            ),
            filters: .all
        )

        XCTAssertEqual(slice.activeTime, 0)
        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(
            slice.reason,
            "Some Active Turn boundaries are missing or invalid"
        )
    }

    func testMissingStartLowersCoverageBeforeItsObservedEnd() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let completedAt = Date(timeIntervalSince1970: 40)
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                LocalActivityFact(
                    key: .time,
                    availability: .partial,
                    value: .turnTiming(
                        LocalTurnTiming(
                            startedAt: nil,
                            completedAt: completedAt,
                            durationMilliseconds: nil,
                            timeToFirstTokenMilliseconds: nil
                        )
                    ),
                    numericDelta: nil,
                    tokenSegment: nil,
                    reason: "turn-start-not-observed",
                    eventID: "missing-start",
                    eventTimestamp: ISO8601DateFormatter().string(
                        from: completedAt
                    ),
                    source: source(observedAt: completedAt),
                    context: LocalActivityContext(
                        taskID: "root",
                        turnID: "turn",
                        agent: nil,
                        effectiveModel: nil,
                        reasoning: nil
                    )
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 20),
                end: Date(timeIntervalSince1970: 30)
            ),
            filters: .all
        )

        XCTAssertEqual(slice.activeTime, 0)
        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(
            slice.reason,
            "Some Active Turn boundaries are missing or invalid"
        )
    }

    func testElapsedTurnDoesNotPretendUnknownWaitAndPollTimeIsExecution() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "turn",
                    taskID: "root",
                    turnID: "turn",
                    start: 10,
                    end: 40
                ),
                unavailableFact(
                    key: .wait,
                    reason: "no-universal-durable-wait-pair"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(slice.activeTime, 30)
        XCTAssertNil(slice.waitingTime)
        XCTAssertNil(slice.pollingTime)
        XCTAssertEqual(
            slice.activityBreakdownReason,
            "Wait and poll time are unavailable"
        )
    }

    func testReplayIdleThreadsAndFiltersDoNotInflateConcurrency() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let atlas = timingFact(
            eventID: "atlas-turn",
            taskID: "root-atlas",
            turnID: "turn-atlas",
            start: 10,
            end: 30,
            model: "gpt-5.6-sol",
            reasoning: "high"
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                atlas,
                atlas,
                timingFact(
                    eventID: "beacon-turn",
                    taskID: "root-beacon",
                    turnID: "turn-beacon",
                    start: 20,
                    end: 50,
                    model: "gpt-5.6-luna",
                    reasoning: "medium"
                )
            ],
            projections: [
                projection(taskID: "root-atlas", project: "atlas"),
                projection(taskID: "root-beacon", project: "beacon"),
                projection(taskID: "idle", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let all = snapshot.slice(in: interval, filters: .all)
        let atlasOnly = snapshot.slice(
            in: interval,
            filters: WorkspaceFilters(
                projectID: "atlas",
                taskTreeID: nil,
                model: nil,
                reasoning: nil
            )
        )
        let lunaOnly = snapshot.slice(
            in: interval,
            filters: WorkspaceFilters(
                projectID: nil,
                taskTreeID: "root-beacon",
                model: "gpt-5.6-luna",
                reasoning: "medium"
            )
        )

        XCTAssertEqual(all.activeTime, 40)
        XCTAssertEqual(all.maximumConcurrency, 2)
        XCTAssertEqual(atlasOnly.activeTime, 20)
        XCTAssertEqual(atlasOnly.maximumConcurrency, 1)
        XCTAssertEqual(lunaOnly.activeTime, 30)
        XCTAssertEqual(lunaOnly.maximumConcurrency, 1)
    }

    func testMissingMetadataLowersCoverageForAnActiveFilter() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ActivityTimelineAggregator.evaluate(
            facts: [
                timingFact(
                    eventID: "known-model",
                    taskID: "root",
                    turnID: "known",
                    start: 10,
                    end: 30,
                    model: "gpt-5.6-sol"
                ),
                timingFact(
                    eventID: "missing-model",
                    taskID: "root",
                    turnID: "unknown",
                    start: 40,
                    end: 70
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        )

        let slice = snapshot.slice(
            in: interval,
            filters: WorkspaceFilters(
                projectID: nil,
                taskTreeID: nil,
                model: "gpt-5.6-sol",
                reasoning: nil
            )
        )

        XCTAssertEqual(slice.activeTime, 20)
        XCTAssertEqual(slice.coverage, .partial)
        XCTAssertEqual(
            slice.reason,
            "Some Active Turns have no model metadata"
        )
    }

    func testEnginePublishesActivityForTheWeeklyAllowanceWindow() {
        let windowStart = Date(timeIntervalSince1970: 1_000)
        let fetchedAt = Date(timeIntervalSince1970: 2_000)
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: accountSnapshot(
                    windowStart: windowStart,
                    fetchedAt: fetchedAt
                ),
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil,
                localActivityFacts: [
                    timingFact(
                        eventID: "turn",
                        taskID: "root",
                        turnID: "turn",
                        start: 1_500,
                        end: 1_600
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: fetchedAt
                ),
                localTaskProjections: [
                    projection(taskID: "root", project: "atlas")
                ]
            )
        )

        let slice = reader.activityTimeline.slice(
            in: reader.activityTimeline.interval,
            filters: .all
        )

        XCTAssertEqual(slice.activeTime, 100)
    }

    func testEngineCountsSiblingAgentsAsOneActiveTaskTree() {
        let windowStart = Date(timeIntervalSince1970: 1_000)
        let fetchedAt = Date(timeIntervalSince1970: 2_000)
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: accountSnapshot(
                    windowStart: windowStart,
                    fetchedAt: fetchedAt
                ),
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil,
                localActivityFacts: [
                    timingFact(
                        eventID: "root-turn",
                        taskID: "root",
                        turnID: "root-turn",
                        start: 1_100,
                        end: 1_200
                    ),
                    timingFact(
                        eventID: "child-a-turn",
                        taskID: "child-a",
                        turnID: "child-a-turn",
                        start: 1_150,
                        end: 1_300
                    ),
                    timingFact(
                        eventID: "child-b-turn",
                        taskID: "child-b",
                        turnID: "child-b-turn",
                        start: 1_175,
                        end: 1_250
                    )
                ],
                localActivityObservation: .continuous(
                    sourceVersion: "0.145.0",
                    observedAt: fetchedAt
                ),
                localTaskProjections: [
                    projection(taskID: "root", project: "atlas"),
                    projection(
                        taskID: "child-a",
                        parentTaskID: "root",
                        project: "atlas"
                    ),
                    projection(
                        taskID: "child-b",
                        parentTaskID: "root",
                        project: "atlas"
                    )
                ]
            )
        )

        let slice = reader.activityTimeline.slice(
            in: reader.activityTimeline.interval,
            filters: .all
        )

        XCTAssertEqual(slice.activeTime, 200)
        XCTAssertEqual(slice.maximumConcurrency, 1)
        XCTAssertEqual(
            reader.activeTimeAvailability.activeTimeThisWeek,
            200
        )
    }

    private func accountSnapshot(
        windowStart: Date,
        fetchedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "weekly",
                name: "Weekly",
                window: UsageWindow(
                    remainingPercent: 80,
                    resetsAt: windowStart.addingTimeInterval(7 * 86_400),
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: fetchedAt
        )
    }

    private func timingFact(
        eventID: String,
        taskID: String,
        turnID: String,
        start: TimeInterval,
        end: TimeInterval?,
        model: String? = nil,
        reasoning: String? = nil
    ) -> LocalActivityFact {
        let startedAt = Date(timeIntervalSince1970: start)
        return LocalActivityFact(
            key: .time,
            availability: end == nil ? .partial : .available,
            value: .turnTiming(
                LocalTurnTiming(
                    startedAt: startedAt,
                    completedAt: end.map(Date.init(timeIntervalSince1970:)),
                    durationMilliseconds: end.map {
                        Int64(($0 - start) * 1_000)
                    },
                    timeToFirstTokenMilliseconds: nil
                )
            ),
            numericDelta: nil,
            tokenSegment: nil,
            reason: end == nil ? "turn-end-not-observed" : nil,
            eventID: eventID,
            eventTimestamp: ISO8601DateFormatter().string(from: startedAt),
            source: source(observedAt: startedAt),
            context: LocalActivityContext(
                taskID: taskID,
                turnID: turnID,
                agent: nil,
                effectiveModel: model,
                reasoning: reasoning
            )
        )
    }

    private func projection(
        taskID: String,
        parentTaskID: String? = nil,
        project: String
    ) -> ThreadProjection {
        ThreadProjection(
            taskID: taskID,
            parentTaskID: parentTaskID,
            projectLabel: project,
            rolloutFileURL: nil,
            createdAt: nil,
            updatedAt: nil,
            source: source(observedAt: .distantPast)
        )
    }

    private func unavailableFact(
        key: LocalActivityFactKey,
        reason: String
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: key,
            availability: .unavailable,
            value: nil,
            numericDelta: nil,
            tokenSegment: nil,
            reason: reason,
            eventID: nil,
            eventTimestamp: nil,
            source: source(observedAt: .distantPast)
        )
    }

    private func source(observedAt: Date) -> LocalActivitySourceMetadata {
        LocalActivitySourceMetadata(
            source: .rolloutJSONL,
            sourceVersion: "0.145.0",
            schemaVersion: "rollout-v1",
            sourceGeneration: 0,
            historyMode: "paginated",
            observedAt: observedAt
        )
    }
}
