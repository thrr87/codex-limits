import Foundation
import XCTest
@testable import CodexLimits

final class UsageReceiptTests: XCTestCase {
    func testEnginePublishesReceiptsInTheReaderSnapshot() {
        let start = Date(timeIntervalSince1970: 1_000)
        let fetchedAt = Date(timeIntervalSince1970: 2_000)
        let account = UsageSnapshot(
            mainLimit: LimitReading(
                limitId: "weekly",
                name: "Weekly",
                window: UsageWindow(
                    remainingPercent: 80,
                    resetsAt: start.addingTimeInterval(7 * 86_400),
                    durationMinutes: 10_080
                )
            ),
            otherLimits: [],
            tokenHistory: [],
            emergencyResetCount: 0,
            fetchedAt: fetchedAt
        )
        let reader = UsageIntelligenceEngine.evaluate(
            UsageIntelligenceInput(
                account: account,
                samples: [],
                safetyBuffer: 3,
                sourceState: .available,
                now: fetchedAt,
                previousStatus: nil,
                localActivityFacts: [
                    tokenFact(
                        eventID: "root-a",
                        date: Date(timeIntervalSince1970: 1_500),
                        tokens: 75,
                        taskID: "root"
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

        let receipts = reader.usageReceipts.slice(
            in: reader.usageReceipts.interval,
            filters: .all
        )

        XCTAssertEqual(receipts.receipts.map(\.rootTaskID), ["root"])
        XCTAssertEqual(receipts.totalTokens, 75)
    }

    func testSeveralTasksInOneProjectBecomeRootTaskReceipts() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let facts = [
            tokenFact(
                eventID: "root-1-a",
                date: Date(timeIntervalSince1970: 1_100),
                tokens: 100,
                taskID: "root-1"
            ),
            tokenFact(
                eventID: "child-1-a",
                date: Date(timeIntervalSince1970: 1_200),
                tokens: 40,
                taskID: "child-1"
            ),
            tokenFact(
                eventID: "root-2-a",
                date: Date(timeIntervalSince1970: 1_300),
                tokens: 60,
                taskID: "root-2"
            )
        ]
        let projections = [
            projection(taskID: "root-1", project: "atlas"),
            projection(
                taskID: "child-1",
                parentTaskID: "root-1",
                project: "atlas"
            ),
            projection(taskID: "root-2", project: "atlas")
        ]

        let slice = UsageReceiptAggregator.evaluate(
            facts: facts,
            projections: projections,
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(slice.totalTokens, 200)
        XCTAssertEqual(slice.unattributedTokens, 0)
        XCTAssertEqual(slice.coverage, .high)
        XCTAssertEqual(slice.receiptCoverage, .partial)
        XCTAssertEqual(
            slice.receiptReason,
            "Task Tree may omit Review and Guardian Tasks"
        )
        XCTAssertEqual(slice.receipts.map(\.projectLabel), ["atlas", "atlas"])
        XCTAssertEqual(slice.receipts.map(\.rootTaskID), ["root-1", "root-2"])
        XCTAssertEqual(slice.receipts.map(\.tokens), [140, 60])
    }

    func testSelectedRangeKeepsOneTaskAcrossDaysAndDeduplicatesReplay() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 200_000)
        )
        let first = tokenFact(
            eventID: "root-a",
            date: Date(timeIntervalSince1970: 10_000),
            tokens: 100,
            taskID: "root"
        )
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                first,
                first,
                tokenFact(
                    eventID: "root-b",
                    date: Date(timeIntervalSince1970: 100_000),
                    tokens: 60,
                    taskID: "root"
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

        let firstDay = snapshot.slice(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 1_000),
                end: Date(timeIntervalSince1970: 50_000)
            ),
            filters: .all
        )
        let full = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(firstDay.receipts.count, 1)
        XCTAssertEqual(firstDay.receipts.first?.tokens, 100)
        XCTAssertEqual(full.receipts.count, 1)
        XCTAssertEqual(full.receipts.first?.tokens, 160)
    }

    func testMissingMetadataLowersCoverageWithoutGuessingIdentity() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let missingProject = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "known-task",
                    date: Date(timeIntervalSince1970: 1_200),
                    tokens: 40,
                    taskID: "root"
                )
            ],
            projections: [
                projection(taskID: "root", project: nil)
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        ).slice(in: interval, filters: .all)
        let missingTask = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "unknown-task",
                    date: Date(timeIntervalSince1970: 1_300),
                    tokens: 60,
                    taskID: nil
                )
            ],
            projections: [],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(missingProject.receipts.first?.projectLabel, nil)
        XCTAssertEqual(missingProject.coverage, .partial)
        XCTAssertEqual(missingTask.receipts, [])
        XCTAssertEqual(missingTask.coverage, .low)
        XCTAssertEqual(missingTask.unattributedTokens, 60)
        XCTAssertEqual(
            missingTask.receipts.reduce(0) { $0 + $1.tokens }
                + missingTask.unattributedTokens,
            missingTask.totalTokens
        )
    }

    func testProjectTaskModelAndReasoningFiltersUseTheSameSnapshot() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "atlas-sol",
                    date: Date(timeIntervalSince1970: 1_100),
                    tokens: 90,
                    taskID: "atlas-task",
                    model: "gpt-5.6-sol",
                    reasoning: "high"
                ),
                tokenFact(
                    eventID: "other-luna",
                    date: Date(timeIntervalSince1970: 1_200),
                    tokens: 30,
                    taskID: "other-task",
                    model: "gpt-5.6-luna",
                    reasoning: "medium"
                )
            ],
            projections: [
                projection(taskID: "atlas-task", project: "atlas"),
                projection(taskID: "other-task", project: "other")
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
                projectID: "atlas",
                taskTreeID: "atlas-task",
                model: "gpt-5.6-sol",
                reasoning: "high"
            )
        )

        XCTAssertEqual(slice.receipts.map(\.rootTaskID), ["atlas-task"])
        XCTAssertEqual(slice.totalTokens, 90)
        XCTAssertEqual(slice.points.last?.tokens, 90)
        XCTAssertEqual(
            snapshot.filterOptions(in: interval),
            UsageReceiptFilterOptions(
                projects: ["atlas", "other"],
                taskTrees: ["atlas-task", "other-task"],
                models: ["gpt-5.6-luna", "gpt-5.6-sol"],
                reasoningLevels: ["high", "medium"]
            )
        )
    }

    func testReceiptDetailSummarizesObservedTaskTreeAgentsAndTurns() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "root",
                    date: Date(timeIntervalSince1970: 1_100),
                    tokens: 70,
                    taskID: "root-task-long-id",
                    turnID: "turn-root",
                    agent: LocalAgentIdentity(
                        nickname: nil,
                        role: "default"
                    )
                ),
                tokenFact(
                    eventID: "child",
                    date: Date(timeIntervalSince1970: 1_200),
                    tokens: 30,
                    taskID: "child-task",
                    turnID: "turn-child",
                    agent: LocalAgentIdentity(
                        nickname: "Luna",
                        role: "worker"
                    )
                )
            ],
            projections: [
                projection(taskID: "root-task-long-id", project: "atlas"),
                projection(
                    taskID: "child-task",
                    parentTaskID: "root-task-long-id",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: .continuous(
                sourceVersion: "0.145.0",
                observedAt: interval.end
            )
        ).slice(in: interval, filters: .all)

        let receipt = try XCTUnwrap(slice.receipts.first)
        XCTAssertEqual(receipt.taskCount, 2)
        XCTAssertEqual(receipt.taskTree.directTokens, 70)
        XCTAssertEqual(receipt.taskTree.children.first?.agentLabel, "Luna")
        XCTAssertEqual(receipt.taskTree.children.first?.directTokens, 30)
        XCTAssertEqual(
            receipt.taskTree.turns.map(\.turnID),
            ["turn-root"]
        )
        XCTAssertEqual(
            receipt.taskTree.children.first?.turns.map(\.turnID),
            ["turn-child"]
        )
        XCTAssertTrue(receipt.accessibilityValue.contains("Project atlas"))
        XCTAssertTrue(receipt.accessibilityValue.contains("100 local tokens"))
        XCTAssertTrue(receipt.accessibilityValue.contains("2 tasks in the tree"))
        XCTAssertTrue(receipt.accessibilityValue.contains("Partial coverage"))
    }

    func testTaskTreeKeepsNestedAgentsAndCountsEachTokenDeltaOnce() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "root-turn",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 60,
                    taskID: "root",
                    model: "gpt-5.6-sol",
                    reasoning: "high",
                    turnID: "turn-root"
                ),
                tokenFact(
                    eventID: "child-turn",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 30,
                    taskID: "child",
                    model: "gpt-5.6-luna",
                    reasoning: "medium",
                    turnID: "turn-child",
                    agent: LocalAgentIdentity(
                        nickname: "Luna",
                        role: "worker"
                    )
                ),
                tokenFact(
                    eventID: "grandchild-turn",
                    date: interval.start.addingTimeInterval(150),
                    tokens: 10,
                    taskID: "grandchild",
                    model: "gpt-5.6-sol",
                    reasoning: "high",
                    turnID: "turn-grandchild",
                    agent: LocalAgentIdentity(
                        nickname: "Fermat",
                        role: "reviewer"
                    )
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas"),
                projection(
                    taskID: "child",
                    parentTaskID: "root",
                    project: "atlas"
                ),
                projection(
                    taskID: "grandchild",
                    parentTaskID: "child",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let receipt = try XCTUnwrap(slice.receipts.first)
        let root = receipt.taskTree
        let child = try XCTUnwrap(root.children.first)
        let grandchild = try XCTUnwrap(child.children.first)

        XCTAssertEqual(receipt.tokens, 100)
        XCTAssertEqual(root.taskID, "root")
        XCTAssertEqual(root.directTokens, 60)
        XCTAssertEqual(root.subtreeTokens, 100)
        XCTAssertEqual(child.taskID, "child")
        XCTAssertEqual(child.agentLabel, "Luna")
        XCTAssertEqual(child.directTokens, 30)
        XCTAssertEqual(child.subtreeTokens, 40)
        XCTAssertEqual(grandchild.taskID, "grandchild")
        XCTAssertEqual(grandchild.agentLabel, "Fermat")
        XCTAssertEqual(grandchild.directTokens, 10)
        XCTAssertEqual(grandchild.subtreeTokens, 10)
        XCTAssertEqual(
            root.directTokens + child.directTokens + grandchild.directTokens,
            receipt.tokens
        )
        XCTAssertEqual(root.taskCount, receipt.taskCount)
    }

    func testTaskTreeKeepsSiblingAgentsAndTurnsUnderTheirOwningTask() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "left-first",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 20,
                    taskID: "left",
                    model: "gpt-5.6-luna",
                    reasoning: "medium",
                    turnID: "turn-left",
                    agent: LocalAgentIdentity(
                        nickname: "Luna",
                        role: "worker"
                    )
                ),
                tokenFact(
                    eventID: "left-second",
                    date: interval.start.addingTimeInterval(75),
                    tokens: 5,
                    taskID: "left",
                    model: "gpt-5.6-luna",
                    reasoning: "medium",
                    turnID: "turn-left",
                    agent: LocalAgentIdentity(
                        nickname: "Luna",
                        role: "worker"
                    )
                ),
                tokenFact(
                    eventID: "right",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 15,
                    taskID: "right",
                    model: "gpt-5.6-sol",
                    reasoning: "high",
                    turnID: "turn-right",
                    agent: LocalAgentIdentity(
                        nickname: nil,
                        role: "reviewer"
                    )
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas"),
                projection(
                    taskID: "left",
                    parentTaskID: "root",
                    project: "atlas"
                ),
                projection(
                    taskID: "right",
                    parentTaskID: "root",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let root = try XCTUnwrap(slice.receipts.first?.taskTree)
        XCTAssertEqual(root.children.map(\.taskID), ["left", "right"])
        XCTAssertEqual(root.children.map(\.directTokens), [25, 15])
        XCTAssertEqual(root.children[0].turns.map(\.turnID), ["turn-left"])
        XCTAssertEqual(root.children[0].turns.map(\.tokens), [25])
        XCTAssertEqual(
            root.children[0].turns.first?.effectiveModels,
            [UsageReceiptBreakdown(label: "gpt-5.6-luna", tokens: 25)]
        )
        XCTAssertEqual(
            root.children[1].turns.first?.reasoningLevels,
            [UsageReceiptBreakdown(label: "high", tokens: 15)]
        )
    }

    func testTaskTreeIncludesAnObservedDescendantWithoutTokenActivity() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "root",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 20,
                    taskID: "root",
                    turnID: "turn-root"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas"),
                projection(
                    taskID: "quiet-agent",
                    parentTaskID: "root",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let receipt = try XCTUnwrap(slice.receipts.first)
        let quietAgent = try XCTUnwrap(receipt.taskTree.children.first)
        XCTAssertEqual(receipt.taskCount, 2)
        XCTAssertEqual(quietAgent.taskID, "quiet-agent")
        XCTAssertEqual(quietAgent.directTokens, 0)
        XCTAssertEqual(quietAgent.subtreeTokens, 0)
        XCTAssertTrue(quietAgent.turns.isEmpty)
        XCTAssertEqual(receipt.taskTree.subtreeTokens, receipt.tokens)
    }

    func testTaskAndTurnEvidenceNamesObservedSourcesAndCoverage() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "turn",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 20,
                    taskID: "child",
                    model: "gpt-5.6-sol",
                    reasoning: "high",
                    turnID: "turn-child"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas"),
                projection(
                    taskID: "child",
                    parentTaskID: "root",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let child = try XCTUnwrap(
            slice.receipts.first?.taskTree.children.first
        )
        let turn = try XCTUnwrap(child.turns.first)
        XCTAssertEqual(child.relationshipSource, .appServerThreadList)
        XCTAssertEqual(child.tokenSources, [.rolloutJSONL])
        XCTAssertEqual(child.coverage, .partial)
        XCTAssertEqual(turn.tokenSources, [.rolloutJSONL])
        XCTAssertEqual(turn.effectiveModel, "gpt-5.6-sol")
        XCTAssertEqual(turn.reasoning, "high")
        XCTAssertEqual(turn.coverage, .partial)
    }

    func testMissingTurnAndWorkloadMetadataStayVisibleAndReconcile() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "no-turn",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 20,
                    taskID: "root"
                ),
                tokenFact(
                    eventID: "turn-without-workload",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 30,
                    taskID: "child",
                    turnID: "turn-child"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas"),
                projection(
                    taskID: "child",
                    parentTaskID: "root",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let receipt = try XCTUnwrap(slice.receipts.first)
        let root = receipt.taskTree
        let child = try XCTUnwrap(root.children.first)
        let turn = try XCTUnwrap(child.turns.first)

        XCTAssertEqual(root.unattributedTurnTokens, 20)
        XCTAssertEqual(
            root.turns.reduce(0) { $0 + $1.tokens }
                + root.unattributedTurnTokens,
            root.directTokens
        )
        XCTAssertEqual(root.coverage, .partial)
        XCTAssertEqual(
            root.reason,
            "Some local token activity has no Turn metadata"
        )
        XCTAssertEqual(turn.coverage, .partial)
        XCTAssertEqual(
            turn.reason,
            "Effective model metadata is missing"
        )
        XCTAssertEqual(
            child.turns.reduce(0) { $0 + $1.tokens }
                + child.unattributedTurnTokens,
            child.directTokens
        )
        XCTAssertEqual(root.subtreeTokens, receipt.tokens)
    }

    func testSourceGapLowersEveryReceiptCoverage() {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "root",
                    date: Date(timeIntervalSince1970: 1_100),
                    tokens: 100,
                    taskID: "root"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: .gap(
                sourceVersion: "0.145.0",
                observedAt: interval.end,
                reason: "Local task records are missing"
            )
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(slice.receipts.first?.coverage, .low)
        XCTAssertEqual(
            slice.receipts.first?.reason,
            "Local task records are missing"
        )
    }

    func testRootProjectIsNeverGuessedFromAChildTask() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "child",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 80,
                    taskID: "child"
                )
            ],
            projections: [
                projection(taskID: "root", project: nil),
                projection(
                    taskID: "child",
                    parentTaskID: "root",
                    project: "child-folder"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let receipt = try XCTUnwrap(slice.receipts.first)
        XCTAssertNil(receipt.projectLabel)
        XCTAssertEqual(receipt.coverage, .partial)
        XCTAssertEqual(slice.coverage, .partial)
    }

    func testUnboundedCounterLowersReceiptAndSliceCoverage() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "baseline",
                    date: interval.start.addingTimeInterval(50),
                    tokens: nil,
                    taskID: "root",
                    reason: "segment-baseline"
                ),
                tokenFact(
                    eventID: "delta",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 80,
                    taskID: "root"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(slice.totalTokens, 80)
        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(
            slice.reason,
            "Local token activity starts from an unbounded counter"
        )
        XCTAssertEqual(try XCTUnwrap(slice.receipts.first).coverage, .low)
    }

    func testUnboundedCounterOnlyLowersItsOwnReceipt() {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "baseline-a",
                    date: interval.start.addingTimeInterval(25),
                    tokens: nil,
                    taskID: "root-a",
                    reason: "segment-baseline"
                ),
                tokenFact(
                    eventID: "delta-a",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 80,
                    taskID: "root-a"
                ),
                tokenFact(
                    eventID: "delta-b",
                    date: interval.start.addingTimeInterval(75),
                    tokens: 40,
                    taskID: "root-b"
                )
            ],
            projections: [
                projection(taskID: "root-a", project: "atlas"),
                projection(taskID: "root-b", project: "atlas")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(slice.coverage, .low)
        XCTAssertEqual(
            slice.receipts.first { $0.rootTaskID == "root-a" }?.coverage,
            .low
        )
        XCTAssertEqual(
            slice.receipts.first { $0.rootTaskID == "root-b" }?.coverage,
            .partial
        )
    }

    func testUnknownMetadataLowersCoverageForAnActiveFilter() {
        let interval = testInterval()
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "known",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 80,
                    taskID: "root",
                    model: "gpt-5.6-sol"
                ),
                tokenFact(
                    eventID: "unknown",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 20,
                    taskID: "root"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
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

        XCTAssertEqual(slice.totalTokens, 80)
        XCTAssertEqual(slice.coverage, .partial)
        XCTAssertEqual(
            slice.reason,
            "Some local activity has no model metadata"
        )
        XCTAssertEqual(slice.receipts.first?.coverage, .partial)
    }

    func testKnownOtherProjectDoesNotLowerCombinedFilterCoverage() {
        let interval = testInterval()
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "atlas-sol",
                    date: interval.start.addingTimeInterval(50),
                    tokens: 80,
                    taskID: "atlas-root",
                    model: "gpt-5.6-sol"
                ),
                tokenFact(
                    eventID: "other-unknown-model",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 20,
                    taskID: "other-root"
                )
            ],
            projections: [
                projection(taskID: "atlas-root", project: "atlas"),
                projection(taskID: "other-root", project: "other")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        )

        let slice = snapshot.slice(
            in: interval,
            filters: WorkspaceFilters(
                projectID: "atlas",
                taskTreeID: nil,
                model: "gpt-5.6-sol",
                reasoning: nil
            )
        )

        XCTAssertEqual(slice.totalTokens, 80)
        XCTAssertEqual(slice.coverage, .high)
        XCTAssertEqual(
            slice.reason,
            "Only local activity on this Mac is observed"
        )
    }

    func testMissingAncestorLeavesChildTokensUnattributed() {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "review-or-guardian",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 80,
                    taskID: "child"
                )
            ],
            projections: [
                projection(
                    taskID: "child",
                    parentTaskID: "omitted-parent",
                    project: "atlas"
                )
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        XCTAssertTrue(slice.receipts.isEmpty)
        XCTAssertEqual(slice.unattributedTokens, 80)
        XCTAssertEqual(slice.coverage, .low)
    }

    func testModelBreakdownUsesTheEffectiveModel() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "effective",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 80,
                    taskID: "root",
                    model: "gpt-5.6-sol"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(
            try XCTUnwrap(slice.receipts.first).models,
            [UsageReceiptBreakdown(label: "gpt-5.6-sol", tokens: 80)]
        )
    }

    func testProjectionHierarchyWinsOverAnIncompleteRolloutRoot() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                rootFact(taskID: "child"),
                tokenFact(
                    eventID: "child-token",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 80,
                    taskID: "child"
                )
            ],
            projections: [
                projection(
                    taskID: "child",
                    parentTaskID: "older-root",
                    project: "atlas"
                ),
                projection(taskID: "older-root", project: "atlas")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        XCTAssertEqual(
            try XCTUnwrap(slice.receipts.first).rootTaskID,
            "older-root"
        )
    }

    func testReceiptIntervalsExcludeTheEndBoundary() {
        let interval = testInterval()
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "inside",
                    date: interval.end.addingTimeInterval(-1),
                    tokens: 80,
                    taskID: "root",
                    model: "inside-model"
                ),
                tokenFact(
                    eventID: "next-range",
                    date: interval.end,
                    tokens: 20,
                    taskID: "root",
                    model: "end-model"
                )
            ],
            projections: [
                projection(taskID: "root", project: "atlas")
            ],
            interval: interval,
            observation: continuousObservation(for: interval)
        )
        let slice = snapshot.slice(in: interval, filters: .all)

        XCTAssertEqual(slice.totalTokens, 80)
        XCTAssertEqual(
            snapshot.filterOptions(in: interval).models,
            ["inside-model"]
        )
    }

    func testDiagnosticSnapshotKeepsOnlyFactsThatIntersectItsInterval() throws {
        let interval = testInterval()
        let context = LocalActivityContext(
            taskID: "root",
            turnID: "turn-1",
            agent: nil,
            effectiveModel: nil,
            reasoning: nil
        )
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                diagnosticFact(
                    key: .tool,
                    value: .text("web_search"),
                    eventID: "before",
                    date: interval.start.addingTimeInterval(-10),
                    context: context,
                    availability: .partial
                ),
                diagnosticFact(
                    key: .tool,
                    value: .text("web_search"),
                    eventID: "inside",
                    date: interval.start.addingTimeInterval(10),
                    context: context,
                    availability: .partial
                ),
                durationFact(
                    key: .wait,
                    eventID: "crosses-start",
                    start: interval.start.addingTimeInterval(-5),
                    end: interval.start.addingTimeInterval(5),
                    context: context
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        )

        let diagnostics = try XCTUnwrap(
            snapshot.slice(in: interval, filters: .all)
                .receipts.first?.diagnostics
        )
        XCTAssertEqual(diagnostics.tools.first?.count, 1)
        XCTAssertEqual(diagnostics.duration.waitingMilliseconds, 5_000)
    }

    func testDiagnosticOnlyScopeAppearsInSharedFilterOptions() {
        let interval = testInterval()
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                diagnosticFact(
                    key: .tool,
                    value: .text("web_search"),
                    eventID: "diagnostic-only",
                    date: interval.start.addingTimeInterval(10),
                    context: LocalActivityContext(
                        taskID: "root",
                        turnID: "turn-1",
                        agent: nil,
                        effectiveModel: "gpt-5.6-sol",
                        reasoning: "high"
                    ),
                    availability: .partial
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        )

        XCTAssertEqual(
            snapshot.filterOptions(in: interval),
            UsageReceiptFilterOptions(
                projects: ["atlas"],
                taskTrees: ["root"],
                models: ["gpt-5.6-sol"],
                reasoningLevels: ["high"]
            )
        )
    }

    func testReceiptDiagnosticsReconcileTokensContextToolsCompactionAndTime() throws {
        let interval = testInterval()
        let turnContext = LocalActivityContext(
            taskID: "root",
            turnID: "turn-1",
            agent: nil,
            effectiveModel: "gpt-5.6-sol",
            reasoning: "high",
            modelContextWindow: 272_000
        )
        let facts = [
            tokenFact(
                eventID: "tokens",
                date: interval.start.addingTimeInterval(20),
                tokens: 360,
                taskID: "root",
                model: "gpt-5.6-sol",
                reasoning: "high",
                turnID: "turn-1",
                tokenDelta: LocalTokenUsage(
                    inputTokens: 300,
                    cachedInputTokens: 100,
                    cacheWriteInputTokens: 10,
                    outputTokens: 60,
                    reasoningOutputTokens: 20,
                    totalTokens: 360
                )
            ),
            diagnosticFact(
                key: .context,
                value: .tokens(
                    LocalTokenUsage(
                        inputTokens: 800,
                        cachedInputTokens: 300,
                        cacheWriteInputTokens: 15,
                        outputTokens: 140,
                        reasoningOutputTokens: 60,
                        totalTokens: 940
                    )
                ),
                eventID: "context",
                date: interval.start.addingTimeInterval(21),
                context: turnContext
            ),
            diagnosticFact(
                key: .compaction,
                value: .count(1),
                eventID: "compact",
                date: interval.start.addingTimeInterval(22),
                context: turnContext
            ),
            diagnosticFact(
                key: .tool,
                value: .text("command_execution"),
                eventID: "tool-1",
                date: interval.start.addingTimeInterval(23),
                context: turnContext,
                availability: .partial
            ),
            diagnosticFact(
                key: .tool,
                value: .text("command_execution"),
                eventID: "tool-2",
                date: interval.start.addingTimeInterval(24),
                context: turnContext,
                availability: .partial
            ),
            diagnosticFact(
                key: .time,
                value: .turnTiming(
                    LocalTurnTiming(
                        startedAt: interval.start.addingTimeInterval(20),
                        completedAt: interval.start.addingTimeInterval(30),
                        durationMilliseconds: 10_000,
                        timeToFirstTokenMilliseconds: 500
                    )
                ),
                eventID: "time",
                date: interval.start.addingTimeInterval(30),
                context: turnContext
            ),
            durationFact(
                key: .execution,
                eventID: "execution",
                start: interval.start.addingTimeInterval(20),
                end: interval.start.addingTimeInterval(24),
                context: turnContext
            ),
            durationFact(
                key: .toolTime,
                eventID: "tool-time",
                start: interval.start.addingTimeInterval(24),
                end: interval.start.addingTimeInterval(25),
                context: turnContext
            ),
            durationFact(
                key: .wait,
                eventID: "wait",
                start: interval.start.addingTimeInterval(25),
                end: interval.start.addingTimeInterval(27),
                context: turnContext
            ),
            durationFact(
                key: .poll,
                eventID: "poll",
                start: interval.start.addingTimeInterval(27),
                end: interval.start.addingTimeInterval(28),
                context: turnContext
            )
        ]
        let slice = UsageReceiptAggregator.evaluate(
            facts: facts,
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let receipt = try XCTUnwrap(slice.receipts.first)
        let diagnostics = receipt.diagnostics
        XCTAssertEqual(diagnostics.tokens?.totalTokens, 360)
        XCTAssertEqual(diagnostics.tokens?.cachedInputTokens, 100)
        XCTAssertEqual(diagnostics.tokens?.reasoningOutputTokens, 20)
        XCTAssertEqual(diagnostics.tokens?.reconciles, true)
        XCTAssertEqual(diagnostics.context?.usedTokens, 940)
        XCTAssertEqual(diagnostics.context?.windowTokens, 272_000)
        XCTAssertEqual(
            diagnostics.tools,
            [UsageReceiptToolSummary(toolClass: "command_execution", count: 2)]
        )
        XCTAssertEqual(diagnostics.compactions.count, 1)
        XCTAssertEqual(diagnostics.duration.elapsedMilliseconds, 10_000)
        XCTAssertEqual(diagnostics.duration.executionMilliseconds, 4_000)
        XCTAssertEqual(diagnostics.duration.toolMilliseconds, 1_000)
        XCTAssertEqual(diagnostics.duration.waitingMilliseconds, 2_000)
        XCTAssertEqual(diagnostics.duration.pollingMilliseconds, 1_000)
        XCTAssertEqual(diagnostics.duration.unclassifiedMilliseconds, 2_000)
        XCTAssertEqual(diagnostics.duration.reconciles, true)

        let turn = try XCTUnwrap(receipt.taskTree.turns.first)
        XCTAssertEqual(turn.diagnostics.compactions.count, 1)
        XCTAssertEqual(turn.diagnostics.tools.first?.count, 2)
    }

    func testReceiptDiagnosticsUseTheSelectedRangeAndFilters() throws {
        let interval = testInterval()
        let sol = LocalActivityContext(
            taskID: "root",
            turnID: "sol",
            agent: nil,
            effectiveModel: "gpt-5.6-sol",
            reasoning: "high"
        )
        let luna = LocalActivityContext(
            taskID: "root",
            turnID: "luna",
            agent: nil,
            effectiveModel: "gpt-5.6-luna",
            reasoning: "medium"
        )
        let snapshot = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "sol-token",
                    date: interval.start.addingTimeInterval(100),
                    tokens: 10,
                    taskID: "root",
                    model: "gpt-5.6-sol",
                    reasoning: "high",
                    turnID: "sol"
                ),
                diagnosticFact(
                    key: .tool,
                    value: .text("web_search"),
                    eventID: "sol-tool",
                    date: interval.start.addingTimeInterval(100),
                    context: sol,
                    availability: .partial
                ),
                diagnosticFact(
                    key: .tool,
                    value: .text("extension"),
                    eventID: "unknown-model-tool",
                    date: interval.start.addingTimeInterval(110),
                    context: LocalActivityContext(
                        taskID: "root",
                        turnID: "unknown",
                        agent: nil,
                        effectiveModel: nil,
                        reasoning: "high"
                    ),
                    availability: .partial
                ),
                tokenFact(
                    eventID: "luna-token",
                    date: interval.start.addingTimeInterval(700),
                    tokens: 20,
                    taskID: "root",
                    model: "gpt-5.6-luna",
                    reasoning: "medium",
                    turnID: "luna"
                ),
                diagnosticFact(
                    key: .tool,
                    value: .text("command_execution"),
                    eventID: "luna-tool",
                    date: interval.start.addingTimeInterval(700),
                    context: luna,
                    availability: .partial
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        )
        let selected = DateInterval(
            start: interval.start,
            end: interval.start.addingTimeInterval(500)
        )
        let slice = snapshot.slice(
            in: selected,
            filters: WorkspaceFilters(
                projectID: "atlas",
                taskTreeID: "root",
                model: "gpt-5.6-sol",
                reasoning: "high"
            )
        )

        let receipt = try XCTUnwrap(slice.receipts.first)
        XCTAssertEqual(receipt.tokens, 10)
        XCTAssertEqual(
            receipt.diagnostics.tools,
            [UsageReceiptToolSummary(toolClass: "web_search", count: 1)]
        )
        XCTAssertEqual(receipt.taskTree.turns.map(\.turnID), ["sol"])
        XCTAssertEqual(
            slice.reason,
            "Some local diagnostics have no model metadata"
        )
    }

    func testMalformedDurationFallsBackWithoutClaimingReconciliation() throws {
        let interval = testInterval()
        let context = LocalActivityContext(
            taskID: "root",
            turnID: "turn-1",
            agent: nil,
            effectiveModel: nil,
            reasoning: nil
        )
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "token",
                    date: interval.start.addingTimeInterval(10),
                    tokens: 10,
                    taskID: "root",
                    turnID: "turn-1"
                ),
                diagnosticFact(
                    key: .time,
                    value: .turnTiming(
                        LocalTurnTiming(
                            startedAt: interval.start.addingTimeInterval(10),
                            completedAt: interval.start.addingTimeInterval(15),
                            durationMilliseconds: 5_000,
                            timeToFirstTokenMilliseconds: nil
                        )
                    ),
                    eventID: "time",
                    date: interval.start.addingTimeInterval(15),
                    context: context
                ),
                durationFact(
                    key: .execution,
                    eventID: "bad-execution",
                    start: interval.start.addingTimeInterval(16),
                    end: interval.start.addingTimeInterval(20),
                    context: context
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let diagnostics = try XCTUnwrap(slice.receipts.first).diagnostics
        XCTAssertEqual(diagnostics.duration.reconciles, false)
        XCTAssertNil(diagnostics.duration.unclassifiedMilliseconds)
        XCTAssertEqual(diagnostics.coverage, .low)
        XCTAssertEqual(
            diagnostics.reason,
            "Recorded activity exceeds observed Turn time"
        )
    }

    func testOverlappingDurationCategoriesUseCoveredWallTimeForReconciliation() throws {
        let interval = testInterval()
        let context = LocalActivityContext(
            taskID: "root",
            turnID: "turn-1",
            agent: nil,
            effectiveModel: nil,
            reasoning: nil
        )
        let start = interval.start.addingTimeInterval(10)
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "token",
                    date: start,
                    tokens: 10,
                    taskID: "root",
                    turnID: "turn-1"
                ),
                diagnosticFact(
                    key: .time,
                    value: .turnTiming(
                        LocalTurnTiming(
                            startedAt: start,
                            completedAt: start.addingTimeInterval(10),
                            durationMilliseconds: 10_000,
                            timeToFirstTokenMilliseconds: nil
                        )
                    ),
                    eventID: "time",
                    date: start.addingTimeInterval(10),
                    context: context
                ),
                durationFact(
                    key: .execution,
                    eventID: "execution",
                    start: start,
                    end: start.addingTimeInterval(8),
                    context: context
                ),
                durationFact(
                    key: .toolTime,
                    eventID: "tool",
                    start: start.addingTimeInterval(2),
                    end: start.addingTimeInterval(4),
                    context: context
                ),
                durationFact(
                    key: .wait,
                    eventID: "wait",
                    start: start.addingTimeInterval(8),
                    end: start.addingTimeInterval(10),
                    context: context
                ),
                durationFact(
                    key: .poll,
                    eventID: "poll",
                    start: start.addingTimeInterval(8),
                    end: start.addingTimeInterval(9),
                    context: context
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let duration = try XCTUnwrap(
            slice.receipts.first
        ).diagnostics.duration
        XCTAssertEqual(duration.executionMilliseconds, 8_000)
        XCTAssertEqual(duration.toolMilliseconds, 2_000)
        XCTAssertEqual(duration.waitingMilliseconds, 2_000)
        XCTAssertEqual(duration.pollingMilliseconds, 1_000)
        XCTAssertEqual(duration.unclassifiedMilliseconds, 0)
        XCTAssertEqual(duration.reconciles, true)
    }

    func testContextGrowthAndMalformedTokenTotalsRemainFactual() throws {
        let interval = testInterval()
        let context = LocalActivityContext(
            taskID: "root",
            turnID: "turn-1",
            agent: nil,
            effectiveModel: nil,
            reasoning: nil,
            modelContextWindow: 100_000
        )
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "token",
                    date: interval.start.addingTimeInterval(10),
                    tokens: 20,
                    taskID: "root",
                    turnID: "turn-1",
                    tokenDelta: LocalTokenUsage(
                        inputTokens: 10,
                        cachedInputTokens: 2,
                        cacheWriteInputTokens: 0,
                        outputTokens: 5,
                        reasoningOutputTokens: 1,
                        totalTokens: 20
                    )
                ),
                diagnosticFact(
                    key: .context,
                    value: .tokens(
                        LocalTokenUsage(
                            inputTokens: 10_000,
                            cachedInputTokens: 5_000,
                            cacheWriteInputTokens: 0,
                            outputTokens: 1_000,
                            reasoningOutputTokens: 100,
                            totalTokens: 11_000
                        )
                    ),
                    eventID: "context-1",
                    date: interval.start.addingTimeInterval(11),
                    context: context
                ),
                diagnosticFact(
                    key: .context,
                    value: .tokens(
                        LocalTokenUsage(
                            inputTokens: 15_000,
                            cachedInputTokens: 7_000,
                            cacheWriteInputTokens: 0,
                            outputTokens: 2_000,
                            reasoningOutputTokens: 200,
                            totalTokens: 17_000
                        )
                    ),
                    eventID: "context-2",
                    date: interval.start.addingTimeInterval(12),
                    context: context
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let diagnostics = try XCTUnwrap(slice.receipts.first).diagnostics
        XCTAssertEqual(diagnostics.context?.usedTokens, 17_000)
        XCTAssertEqual(diagnostics.context?.peakTokens, 17_000)
        XCTAssertEqual(diagnostics.context?.changeTokens, 6_000)
        XCTAssertEqual(diagnostics.context?.sampleCount, 2)
        XCTAssertEqual(diagnostics.tokens?.reconciles, false)
        XCTAssertEqual(diagnostics.coverage, .low)
        XCTAssertEqual(
            diagnostics.reason,
            "Token components do not match total"
        )
    }

    func testMissingDiagnosticFieldsStayUnavailable() throws {
        let interval = testInterval()
        let slice = UsageReceiptAggregator.evaluate(
            facts: [
                tokenFact(
                    eventID: "baseline",
                    date: interval.start.addingTimeInterval(10),
                    tokens: 10,
                    taskID: "root",
                    turnID: "turn-1"
                )
            ],
            projections: [projection(taskID: "root", project: "atlas")],
            interval: interval,
            observation: continuousObservation(for: interval)
        ).slice(in: interval, filters: .all)

        let diagnostics = try XCTUnwrap(slice.receipts.first).diagnostics
        XCTAssertNil(diagnostics.tokens)
        XCTAssertNil(diagnostics.context)
        XCTAssertNil(diagnostics.duration.elapsedMilliseconds)
        XCTAssertNil(diagnostics.duration.reconciles)
        XCTAssertEqual(diagnostics.coverage, .partial)
        XCTAssertEqual(
            diagnostics.reason,
            "Some local diagnostics are not recorded by this Codex version"
        )
    }

    private func tokenFact(
        eventID: String,
        date: Date,
        tokens: Int64?,
        taskID: String?,
        model: String? = nil,
        reasoning: String? = nil,
        turnID: String? = nil,
        agent: LocalAgentIdentity? = nil,
        reason: String? = nil,
        tokenDelta: LocalTokenUsage? = nil
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: .token,
            availability: .available,
            value: nil,
            numericDelta: tokens,
            tokenSegment: 0,
            reason: reason,
            eventID: eventID,
            eventTimestamp: ISO8601DateFormatter().string(from: date),
            source: source(observedAt: date),
            context: LocalActivityContext(
                taskID: taskID,
                turnID: turnID,
                agent: agent,
                effectiveModel: model,
                reasoning: reasoning
            ),
            tokenDelta: tokenDelta
        )
    }

    private func diagnosticFact(
        key: LocalActivityFactKey,
        value: LocalActivityFactValue,
        eventID: String,
        date: Date,
        context: LocalActivityContext,
        availability: LocalActivityAvailability = .available
    ) -> LocalActivityFact {
        LocalActivityFact(
            key: key,
            availability: availability,
            value: value,
            numericDelta: nil,
            tokenSegment: nil,
            reason: availability == .partial ? "partial-source" : nil,
            eventID: eventID,
            eventTimestamp: ISO8601DateFormatter().string(from: date),
            source: source(observedAt: date),
            context: context
        )
    }

    private func durationFact(
        key: LocalActivityFactKey,
        eventID: String,
        start: Date,
        end: Date,
        context: LocalActivityContext
    ) -> LocalActivityFact {
        diagnosticFact(
            key: key,
            value: .duration(
                LocalActivityDuration(
                    startedAt: start,
                    completedAt: end
                )
            ),
            eventID: eventID,
            date: end,
            context: context
        )
    }

    private func testInterval() -> DateInterval {
        DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
    }

    private func continuousObservation(
        for interval: DateInterval
    ) -> LocalActivityObservation {
        .continuous(
            sourceVersion: "0.145.0",
            observedAt: interval.end
        )
    }

    private func projection(
        taskID: String,
        parentTaskID: String? = nil,
        project: String?
    ) -> ThreadProjection {
        ThreadProjection(
            taskID: taskID,
            parentTaskID: parentTaskID,
            projectLabel: project,
            rolloutFileURL: nil,
            createdAt: nil,
            updatedAt: nil,
            source: LocalActivitySourceMetadata(
                source: .appServerThreadList,
                sourceVersion: "0.145.0",
                schemaVersion: "app-server-v2",
                sourceGeneration: 0,
                historyMode: nil,
                observedAt: .distantPast
            )
        )
    }

    private func rootFact(taskID: String) -> LocalActivityFact {
        LocalActivityFact(
            key: .root,
            availability: .available,
            value: .identifier(taskID),
            numericDelta: nil,
            tokenSegment: nil,
            reason: nil,
            eventID: "root-\(taskID)",
            eventTimestamp: "1970-01-01T00:16:40Z",
            source: source(observedAt: Date(timeIntervalSince1970: 1_000))
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
