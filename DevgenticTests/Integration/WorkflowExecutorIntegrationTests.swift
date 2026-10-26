// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowExecutorIntegrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class WorkflowExecutorIntegrationTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private var innerBuilders: [InnerWorkflowBuilder] = []
    /// Rows written directly to the SHARED stores by tests that must exercise the
    /// nothing-is-injected production path. Torn down unconditionally below.
    private var savedProfileIDs: [UUID] = []
    private var savedLayoutIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
        innerBuilders = []
        savedProfileIDs = []
        savedLayoutIDs = []
    }

    override func tearDown() {
        for builder in innerBuilders {
            builder.cleanup()
        }
        innerBuilders = []
        for id in savedLayoutIDs {
            WorkflowLayoutStore.shared.delete(for: id)
        }
        savedLayoutIDs = []
        for id in savedProfileIDs {
            try? BackendProfileStore.shared.deleteProfile(withId: id)
        }
        savedProfileIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// Executes a workflow scenario and collects all stream events.
    /// - Parameter startingDepth: binds `WorkflowDepth.current` around the CALL, simulating a run
    ///   that began inside `startingDepth` enclosing workflows (WF-TS10). `nil` = a top-level run.
    private func execute(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input",
        attachmentContext: String? = nil,
        startingDepth: Int? = nil
    ) async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let makeStream = {
            executor.executeWorkflow(
                userInput: userInput,
                conversationID: UUID(),
                attachmentContext: attachmentContext,
                traceContext: self.traceContext,
                onTraceUpdate: { _ in },
                layout: scenario.layout,
                profileMap: scenario.profileMap,
                streamProvider: self.mockProvider
            )
        }
        // ⚠️ The binding must wrap the CALL, not the consumption: `AsyncThrowingStream`'s build
        // closure runs synchronously during init, so the `Task` created inside it captures the
        // task-locals in effect HERE. Binding around the `for try await` would be a no-op.
        let stream = startingDepth.map { WorkflowDepth.$current.withValue($0, operation: makeStream) }
            ?? makeStream()
        // ⚠️ Resolves any HITL gate with nil instead of ignoring it. Since 2026-08-13 a Router asks
        // on overlapping rules BY DEFAULT and waits INDEFINITELY, so a plain collect would park
        // forever on any scenario whose rules double-match — a hang, not a failure. It bit a
        // pre-existing test (`testCondition_MultipleRules_FirstMatchWins`) written years before the
        // feature existed, whose input matches both a `contains` and an `isNotEmpty` rule.
        //
        // nil resolves to first-match, which is exactly what these tests asserted before arbitration
        // existed, so no expectation changes. Tests that care about the ask use `executeWithGate`,
        // and tests asserting no ask still catch a spurious one via `gateRequests`.
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
    }

    /// Creates a workflow stream (without consuming it) for cancellation tests.
    ///
    /// - Parameter workflowProfileID: defaults to a fresh, unregistered UUID.
    private func makeStream(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input",
        workflowProfileID: UUID = UUID(),
        conversationID: UUID = UUID()
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let executor = WorkflowExecutor(workflowProfileID: workflowProfileID)
        return executor.executeWorkflow(
            userInput: userInput,
            conversationID: conversationID,
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
    }

    /// Executes a workflow with gate auto-response.
    private func executeWithGate(
        _ scenario: WorkflowTestScenario,
        choosing option: String?,
        userInput: String = "Test input"
    ) async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = executor.executeWorkflow(
            userInput: userInput,
            conversationID: UUID(),
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: option)
    }

    // MARK: - Group 1: Foundation

    func testEmptyWorkflow_Throws() async {
        let scenario = WorkflowTestScenario()
        // No nodes added
        do {
            _ = try await execute(scenario)
            XCTFail("Expected WorkflowError.emptyWorkflow")
        } catch let error as WorkflowError {
            if case .emptyWorkflow = error {
                // Expected
            } else {
                XCTFail("Expected emptyWorkflow, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSingleBot_ProducesOutput() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [
            .content("Hello from Bot A")
        ])

        let events = try await execute(scenario)

        // Verify node lifecycle
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].profileName, "Bot A")

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.count, 1)

        // Verify final output
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Hello from Bot A")

        // Verify progress
        let progress = WorkflowStreamCollector.progressEvents(from: events)
        XCTAssertTrue(progress.contains(where: { $0.completed == 1 && $0.total == 1 }))
    }

    func testMissingProfile_EmitsFailure() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Ghost Bot")

        // Remove the profile from the map so it's not found
        let profileID = scenario.profileID(for: botA)!
        scenario.profileMap.removeValue(forKey: profileID)

        // Pre-flight validation catches a missing profile and rejects the run.
        do {
            _ = try await execute(scenario)
            XCTFail("Expected validationFailed for a missing profile")
        } catch let error as WorkflowError {
            guard case .validationFailed(let issues, _) = error else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(issues.contains(where: { $0.nodeID == botA }),
                          "Validation should flag the node with the missing profile")
        }
    }

    func testCycleDetection_Throws() async {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botA) // Creates cycle

        do {
            _ = try await execute(scenario)
            XCTFail("Expected WorkflowError.cycleDetected")
        } catch let error as WorkflowError {
            if case .cycleDetected = error {
                // Expected
            } else {
                XCTFail("Expected cycleDetected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Group 2: Sequential Chains

    func testTwoNodeChain_SequentialOrder() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A output")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B output")])

        let events = try await execute(scenario)

        // A executes before B
        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [botA, botB])

        // Only terminal node (B) in final output
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "B output")

        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 2)
    }

    func testThreeNodeChain_ContextPropagates() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("alpha")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("beta")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("gamma")])

        let events = try await execute(scenario)

        // Sequential execution
        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [botA, botB, botC])

        // B receives A's output via WorkflowInputAssembler (check mock invocations)
        let bProfileID = scenario.profileID(for: botB)!
        let bInvocation = mockProvider.invocations.first(where: { $0.profileID == bProfileID })
        XCTAssertNotNil(bInvocation)
        XCTAssertTrue(bInvocation!.userInput.contains("alpha"),
                      "Bot B should receive Bot A's output as context")

        // C receives B's output
        let cProfileID = scenario.profileID(for: botC)!
        let cInvocation = mockProvider.invocations.first(where: { $0.profileID == cProfileID })
        XCTAssertTrue(cInvocation!.userInput.contains("beta"),
                      "Bot C should receive Bot B's output as context")
    }

    func testChain_FirstFails_RestSkipped() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        // A fails
        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // A fails, B and C skipped
        // ⚠️ The old assertion was `failed.count == 3` — it encoded the defect as the
        // expectation, counting two nodes that never ran as failures.
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events)
        XCTAssertEqual(failed.map(\.nodeID), [botA], "only A actually failed")
        XCTAssertEqual(Set(skipped.map(\.nodeID)), [botB, botC], "B and C did not run")
        XCTAssertTrue(skipped.allSatisfy { $0.reason == .upstreamFailed || $0.reason == .upstreamSkipped },
                      "the cause must trace back to A's failure, got \(skipped.map(\.reason))")

        // B and C never had their streams invoked
        let bProfileID = scenario.profileID(for: botB)!
        let cProfileID = scenario.profileID(for: botC)!
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }))
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == cProfileID }))
    }

    func testChain_MiddleFails_LastSkipped() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A ok")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // A completes
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botA }))

        // B fails, C skipped
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botB }), "B failed")
        XCTAssertTrue(skipped.contains(where: { $0.nodeID == botC }), "C did not run")
    }

    // MARK: - Group 3: Condition Branching

    func testCondition_TrueBranch() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Router",
            rules: [
                ConditionRule(label: "Match", field: .upstreamOutput, op: .contains, value: "yes")
            ],
            fallbackLabel: "NoMatch"
        )
        let botB = scenario.addBotNode(name: "Match Handler")
        let botC = scenario.addBotNode(name: "Fallback Handler")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botB, portLabel: "Match")
        scenario.connect(from: condition, to: botC, portLabel: "NoMatch")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("yes approved")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("Match path")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("Fallback path")])

        let events = try await execute(scenario)

        // Bot B executes (match), Bot C does not
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botB), "Match handler should execute")
        XCTAssertFalse(started.contains(botC), "Fallback handler should NOT execute")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Match path")
    }

    func testCondition_FallbackBranch() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Router",
            rules: [
                ConditionRule(label: "Match", field: .upstreamOutput, op: .contains, value: "yes")
            ],
            fallbackLabel: "NoMatch"
        )
        let botB = scenario.addBotNode(name: "Match Handler")
        let botC = scenario.addBotNode(name: "Fallback Handler")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botB, portLabel: "Match")
        scenario.connect(from: condition, to: botC, portLabel: "NoMatch")

        // A output does NOT contain "yes"
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("no rejected")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("Match path")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("Fallback path")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "Match handler should NOT execute")
        XCTAssertTrue(started.contains(botC), "Fallback handler should execute")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Fallback path")
    }

    func testCondition_VariableField() async throws {
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(
            name: "Set Status",
            template: "approved",
            outputVariable: "status"
        )
        let condition = scenario.addConditionNode(
            name: "Check Status",
            rules: [
                ConditionRule(label: "Approved", field: .variable, op: .equals, value: "approved", variableName: "status")
            ],
            fallbackLabel: "Rejected"
        )
        let botApproved = scenario.addBotNode(name: "Approved Bot")
        let botRejected = scenario.addBotNode(name: "Rejected Bot")

        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botApproved, portLabel: "Approved")
        scenario.connect(from: condition, to: botRejected, portLabel: "Rejected")

        mockProvider.scriptStream(for: scenario.profileID(for: botApproved)!, events: [.content("Approved!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botRejected)!, events: [.content("Rejected!")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botApproved), "Approved bot should execute")
        XCTAssertFalse(started.contains(botRejected), "Rejected bot should NOT execute")
    }

    // MARK: - Group 4: Code Nodes

    func testCodeNode_InputSubstitution() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let code = scenario.addCodeNode(name: "Transform", template: "Prefix: {{ input }}")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: code)
        scenario.connect(from: code, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("raw data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B output")])

        let events = try await execute(scenario)

        // Bot B should receive the code node's transformed output
        let bProfileID = scenario.profileID(for: botB)!
        let bInvocation = mockProvider.invocations.first(where: { $0.profileID == bProfileID })
        XCTAssertNotNil(bInvocation)
        XCTAssertTrue(bInvocation!.userInput.contains("Prefix: raw data"),
                      "Bot B should receive transformed code output")
    }

    func testCodeNode_VariableWriteAndRead() async throws {
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Writer", template: "hello_world", outputVariable: "myVar")
        let codeB = scenario.addCodeNode(name: "Reader", template: "Value is: {{ var.myVar }}")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: codeA, to: codeB)
        scenario.connect(from: codeB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("done")])

        let events = try await execute(scenario)

        // Bot C should receive "Value is: hello_world" from code B
        let cProfileID = scenario.profileID(for: botC)!
        let cInvocation = mockProvider.invocations.first(where: { $0.profileID == cProfileID })
        XCTAssertNotNil(cInvocation)
        XCTAssertTrue(cInvocation!.userInput.contains("Value is: hello_world"),
                      "Code B should read variable written by Code A")
    }

    // MARK: - Group 5: Gate Nodes

    func testGate_Approved_PassesThrough() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Approval Gate", prompt: "Approve this?")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB, portLabel: "Approve")   // botB on the "Approve" branch

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data to approve")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B processed")])

        let events = try await executeWithGate(scenario, choosing: "Approve")

        // "Approve" chosen → its port routes to Bot B, which executes.
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botB), "Bot B (Approve branch) should execute after choosing Approve")

        // The structured gate request was emitted with its options.
        let gates = WorkflowStreamCollector.gateRequests(from: events)
        XCTAssertEqual(gates.count, 1)
        XCTAssertEqual(gates[0].options, ["Approve", "Reject"])
    }

    func testGate_Rejected_SkipsDownstream() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Approval Gate")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB, portLabel: "Approve")   // botB only on the "Approve" branch

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])

        let events = try await executeWithGate(scenario, choosing: "Reject")

        // "Reject" chosen → routes to the (unwired) Reject port, so the Approve-branch Bot B is skipped.
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "Bot B (Approve branch) should NOT execute when Reject is chosen")
    }

    // MARK: - Group 6: Error Routing & Policies

    func testErrorRouting_FailedNode_ErrorPortActivated() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Risky Bot")
        let botB = scenario.addBotNode(name: "Normal Handler")
        let botC = scenario.addBotNode(name: "Error Handler")

        scenario.connect(from: botA, to: botB) // default port
        scenario.connect(from: botA, to: botC, portLabel: "error") // error port

        // A fails
        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("normal")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("error handled")])

        let events = try await execute(scenario)

        // Error handler executes, normal handler skipped
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botC), "Error handler should execute")
        XCTAssertFalse(started.contains(botB), "Normal handler should NOT execute when error port active")
    }

    func testMultiPort_SameUpstream_RunsOnError() async throws {
        // A node wired to BOTH the default and `error` ports of one upstream must run
        // when that upstream FAILS (its error branch is live). Per-upstream join — not
        // per-edge AND — is what keeps this node reachable.
        let scenario = WorkflowTestScenario()
        let worker = scenario.addBotNode(name: "Worker")
        let finalizer = scenario.addBotNode(name: "Finalizer")

        scenario.connect(from: worker, to: finalizer)                     // default (success) port
        scenario.connect(from: worker, to: finalizer, portLabel: "error") // error port

        mockProvider.scriptError(for: scenario.profileID(for: worker)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: finalizer)!, events: [.content("recovered")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(finalizer),
                      "Finalizer wired to both default+error should run when the upstream fails")
    }

    func testMultiPort_SameUpstream_RunsOnSuccess_OutputOnce() async throws {
        // The same dual-wired node must also run when the upstream SUCCEEDS (default
        // branch is live), with the upstream's output injected exactly once (dedup),
        // not once per edge.
        let scenario = WorkflowTestScenario()
        let worker = scenario.addBotNode(name: "Worker")
        let finalizer = scenario.addBotNode(name: "Finalizer")

        scenario.connect(from: worker, to: finalizer)
        scenario.connect(from: worker, to: finalizer, portLabel: "error")

        mockProvider.scriptStream(for: scenario.profileID(for: worker)!, events: [.content("worker output")])
        mockProvider.scriptStream(for: scenario.profileID(for: finalizer)!, events: [.content("done")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(finalizer),
                      "Finalizer wired to both default+error should run when the upstream succeeds")

        let fPid = scenario.profileID(for: finalizer)!
        let fInv = mockProvider.invocations.first(where: { $0.profileID == fPid })!
        let occurrences = fInv.userInput.components(separatedBy: "worker output").count - 1
        XCTAssertEqual(occurrences, 1, "Upstream output should be injected once, not duplicated per edge")
    }

    /// A failure with no `error` edge stops its branch: the downstream never runs.
    func testFailureWithNoErrorEdge_BranchStops() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Bot")
        let botB = scenario.addBotNode(name: "Downstream Bot")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("must not run")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "with no error edge the branch stops")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == botA })
    }

    /// Wire the `error` port and the downstream runs, with the failure.
    func testErrorPortWired_DownstreamRunsWithFailure() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Bot")
        let handler = scenario.addBotNode(name: "Handler")

        scenario.connect(from: botA, to: handler, portLabel: "error")

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("handled")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == handler },
                      "an error-wired handler must run when its upstream fails")

        guard let invocation = mockProvider.workflowInvocations.first(where: {
            $0.profileID == scenario.profileID(for: handler)
        }) else { return XCTFail("handler never invoked") }
        XCTAssertTrue(invocation.context.input.contains("[Upstream node \"Failing Bot\" failed:"),
                      "…and must receive the annotated failure, got: \(invocation.context.input.prefix(160))")
    }


    // MARK: - Group 7: Retry & Complex

    func testRetry_SucceedsOnSecondAttempt() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Flaky Bot")
        scenario.setNodeConfig(
            WorkflowNodeConfig(maxNodeRetries: 1, retryDelay: 0),
            for: botA
        )

        let profileID = scenario.profileID(for: botA)!

        // First call: retryable error, second call: success
        mockProvider.scriptError(for: profileID, error: AgentExecutionError(reason: .modelError(provider: "test", error: "transient")))
        mockProvider.scriptStream(for: profileID, events: [.content("Recovered!")])

        let events = try await execute(scenario)

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botA }))

        // 2 invocations: first fails, second succeeds
        let calls = mockProvider.invocations.filter { $0.profileID == profileID }
        XCTAssertEqual(calls.count, 2, "Should retry once after failure")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Recovered!")
    }

    func testComplexChain_BotCodeConditionBot() async throws {
        // Real-world scenario: Bot generates text → Code extracts keyword → Condition routes
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Analyzer")
        let code = scenario.addCodeNode(name: "Extractor", template: "sentiment: positive", outputVariable: "sentiment")
        let condition = scenario.addConditionNode(
            name: "Sentiment Router",
            rules: [
                ConditionRule(label: "Positive", field: .variable, op: .contains, value: "positive", variableName: "sentiment")
            ],
            fallbackLabel: "Negative"
        )
        let botPositive = scenario.addBotNode(name: "Celebrate Bot")
        let botNegative = scenario.addBotNode(name: "Console Bot")

        scenario.connect(from: botA, to: code)
        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botPositive, portLabel: "Positive")
        scenario.connect(from: condition, to: botNegative, portLabel: "Negative")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("Great product!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botPositive)!, events: [.content("Wonderful!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNegative)!, events: [.content("Sorry to hear")])

        let events = try await execute(scenario)

        // Full chain: Analyzer → Extractor → Router → Celebrate Bot
        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [botA, code, condition, botPositive])

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botNegative), "Negative bot should NOT execute for positive sentiment")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Wonderful!")
    }

    // MARK: - Group 8: Condition Operator Coverage

    func testConditionOp_NotContains() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Filter",
            rules: [ConditionRule(label: "Clean", field: .upstreamOutput, op: .notContains, value: "error")],
            fallbackLabel: "Dirty"
        )
        let botClean = scenario.addBotNode(name: "Clean Bot")
        let botDirty = scenario.addBotNode(name: "Dirty Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botClean, portLabel: "Clean")
        scenario.connect(from: condition, to: botDirty, portLabel: "Dirty")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("all good")])
        mockProvider.scriptStream(for: scenario.profileID(for: botClean)!, events: [.content("clean")])
        mockProvider.scriptStream(for: scenario.profileID(for: botDirty)!, events: [.content("dirty")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botClean), "notContains 'error' should match 'all good'")
        XCTAssertFalse(started.contains(botDirty))
    }

    func testConditionOp_IsEmpty() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Empty Check",
            rules: [ConditionRule(label: "Empty", field: .upstreamOutput, op: .isEmpty, value: "")],
            fallbackLabel: "NotEmpty"
        )
        let botEmpty = scenario.addBotNode(name: "Empty Bot")
        let botNotEmpty = scenario.addBotNode(name: "NotEmpty Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botEmpty, portLabel: "Empty")
        scenario.connect(from: condition, to: botNotEmpty, portLabel: "NotEmpty")

        // Bot A produces empty output
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [])
        mockProvider.scriptStream(for: scenario.profileID(for: botEmpty)!, events: [.content("was empty")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNotEmpty)!, events: [.content("not empty")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botEmpty), "isEmpty should match empty upstream")
        XCTAssertFalse(started.contains(botNotEmpty))
    }

    func testConditionOp_IsNotEmpty() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "NonEmpty Check",
            rules: [ConditionRule(label: "HasContent", field: .upstreamOutput, op: .isNotEmpty, value: "")],
            fallbackLabel: "NoContent"
        )
        let botHas = scenario.addBotNode(name: "HasContent Bot")
        let botNo = scenario.addBotNode(name: "NoContent Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botHas, portLabel: "HasContent")
        scenario.connect(from: condition, to: botNo, portLabel: "NoContent")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("hello")])
        mockProvider.scriptStream(for: scenario.profileID(for: botHas)!, events: [.content("yes")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNo)!, events: [.content("no")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botHas), "isNotEmpty should match non-empty upstream")
        XCTAssertFalse(started.contains(botNo))
    }

    func testConditionOp_NotEquals() async throws {
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(name: "Set", template: "beta", outputVariable: "ver")
        let condition = scenario.addConditionNode(
            name: "Version Check",
            rules: [ConditionRule(label: "NotAlpha", field: .variable, op: .notEquals, value: "alpha", variableName: "ver")],
            fallbackLabel: "IsAlpha"
        )
        let botNotAlpha = scenario.addBotNode(name: "NotAlpha Bot")
        let botIsAlpha = scenario.addBotNode(name: "IsAlpha Bot")

        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botNotAlpha, portLabel: "NotAlpha")
        scenario.connect(from: condition, to: botIsAlpha, portLabel: "IsAlpha")

        mockProvider.scriptStream(for: scenario.profileID(for: botNotAlpha)!, events: [.content("not alpha")])
        mockProvider.scriptStream(for: scenario.profileID(for: botIsAlpha)!, events: [.content("is alpha")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botNotAlpha), "notEquals 'alpha' should match 'beta'")
        XCTAssertFalse(started.contains(botIsAlpha))
    }

    // MARK: - Group 9: DAG Topology Edge Cases

    func testDiamondDAG_MultiInputNode() async throws {
        // A → C, B → C (C has two upstream parents)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("from A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("merged")])

        let events = try await execute(scenario)

        // A and B both complete (same level, independent)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botA))
        XCTAssertTrue(completed.contains(botB))
        XCTAssertTrue(completed.contains(botC))

        // C receives context from BOTH A and B
        let cProfileID = scenario.profileID(for: botC)!
        let cInvocation = mockProvider.invocations.first(where: { $0.profileID == cProfileID })!
        XCTAssertTrue(cInvocation.userInput.contains("from A"), "C should receive A's output")
        XCTAssertTrue(cInvocation.userInput.contains("from B"), "C should receive B's output")
    }

    func testDiamondDAG_OneParentFails_ChildSkipped() async throws {
        // A → C, B → C; A fails → C skipped (needs ALL parents)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from B")])

        let events = try await execute(scenario)

        // A fails, B completes, C skipped (allSatisfy requires ALL upstream to pass)
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).map(\.nodeID)
        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(failed.contains(botA))
        XCTAssertTrue(skipped.contains(botC), "C should be SKIPPED when any parent fails — not failed")
    }

    // MARK: - Run-level terminal verdict (WF-EX5)
    //
    // ⚠️ The run's `executionFinished(outcome:reason:)` is what `ActiveStreamManager` turns into
    // the run chip, the persisted status and the trace span's outcome — and NOTHING in this
    // 151-case suite looked at it. The verdict logic was rewritten on 2026-08-15 into three
    // branches; the third (every terminal skipped ⇒ a COMPLETED run with an explanatory answer,
    // deliberately not a failure) shipped with no test at all. These pin all three.

    /// A run with a successful terminal reports `.completed` — and exactly ONE terminal event.
    func testSuccessfulRunReportsCompletedExactlyOnce() async throws {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Bot A")
        mockProvider.scriptStream(for: scenario.profileID(for: bot)!, events: [.content("the answer")])

        let events = try await execute(scenario)
        let outcomes = WorkflowStreamCollector.terminalOutcomes(from: events)

        XCTAssertEqual(outcomes.count, 1, "a run must report its verdict exactly once")
        XCTAssertEqual(outcomes.first?.outcome, .completed)
        XCTAssertNil(outcomes.first?.reason, "a clean completion carries no reason")
        XCTAssertTrue(WorkflowStreamCollector.contentText(from: events).contains("the answer"))
    }

    /// A genuine failure reports `.failed`, and the reason NAMES the failing node count — the
    /// message the chat surfaces instead of the old "all terminal nodes failed".
    func testFailedRunReportsFailedWithAReason() async throws {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Bot A")
        mockProvider.scriptError(for: scenario.profileID(for: bot)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)
        let outcomes = WorkflowStreamCollector.terminalOutcomes(from: events)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.outcome, .failed)
        XCTAssertEqual(outcomes.first?.reason, "1 node failed",
                       "the verdict must count the nodes that actually failed — got: \(String(describing: outcomes.first?.reason))")
    }

    /// ⚠️ THE BRANCH SHIPPED TODAY WITH NO TEST — a run where nothing failed but no terminal
    /// produced an answer. It must COMPLETE, never be reported as a failure (that was WF-EX1's
    /// defect in its second shape).
    ///
    /// Built with `fallbackLabel: "False"` (the builder's default), so the Router MATCHES its
    /// fallback port and completes; the handler hangs off a different port and is skipped, leaving
    /// the Router itself as the only terminal — successful, but with no text.
    func testRunThatProducesNoAnswerCompletesWithAnExplanation() async throws {
        let scenario = WorkflowTestScenario()
        let router = scenario.addConditionNode(
            name: "Router",
            rules: [ConditionRule(label: "Taken", field: .upstreamOutput, op: .contains, value: "zzz-never")]
        )
        let handler = scenario.addCodeNode(name: "OnlyTerminal")
        scenario.connect(from: router, to: handler, portLabel: "Taken")

        let events = try await execute(scenario)
        let outcomes = WorkflowStreamCollector.terminalOutcomes(from: events)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.outcome, .completed,
                       "nothing failed — an unwired branch is not a run failure")
        XCTAssertTrue(WorkflowStreamCollector.errorMessages(from: events).isEmpty,
                      "nothing failed, so no error may be surfaced — got: \(WorkflowStreamCollector.errorMessages(from: events))")
        // ⚠️ Deliberately NOT asserting explanatory content: a terminal can succeed with empty text
        // and still have done its job (an artifact, a written file), so the engine stays silent and
        // logs instead — see `testTerminalNode_EmptyOutput_NotInFinalContent`.
    }

    /// A Router with NO fallback that matches nothing genuinely fails — and the verdict must name
    /// the failure rather than describing the skipped terminal downstream of it.
    func testRouterWithNoMatchAndNoFallbackFailsTheRun() async throws {
        let scenario = WorkflowTestScenario()
        let router = scenario.addConditionNode(
            name: "Router",
            rules: [
                ConditionRule(label: "Taken", field: .upstreamOutput, op: .contains, value: "zzz-never"),
                ConditionRule(label: "Other", field: .upstreamOutput, op: .contains, value: "qqq-never")
            ],
            fallbackLabel: ""
        )
        let handler = scenario.addCodeNode(name: "Downstream")
        scenario.connect(from: router, to: handler, portLabel: "Taken")

        let events = try await execute(scenario)
        let outcomes = WorkflowStreamCollector.terminalOutcomes(from: events)

        XCTAssertEqual(outcomes.first?.outcome, .failed)
        XCTAssertTrue(WorkflowStreamCollector.errorMessages(from: events).contains { $0.contains("The workflow failed.") },
                      "the failure must name the node that failed — got: \(WorkflowStreamCollector.errorMessages(from: events))")
        XCTAssertTrue(WorkflowStreamCollector.nodeSkippedEvents(from: events).contains { $0.nodeID == handler },
                      "the downstream node did not run — that is a skip, not a failure")
    }

    /// The verdict must not be emitted twice, and must be the LAST workflow event — everything
    /// downstream (chip, persisted status, span) keys off exactly one.
    func testTerminalVerdictIsTheFinalEvent() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "A")
        let b = scenario.addBotNode(name: "B")
        scenario.connect(from: a, to: b)
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("one")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("two")])

        let events = try await execute(scenario)

        XCTAssertEqual(WorkflowStreamCollector.terminalOutcomes(from: events).count, 1)
        guard case .executionFinished = events.last else {
            return XCTFail("the run's verdict must be the final event, got: \(String(describing: events.last))")
        }
    }

    /// ⚠️ WF-EX4: exactly ONE terminal event per structural node. The node's own emit and the
    /// timeout wrapper's used to both fire, logging a green success and a red failure for the same
    /// node seconds apart.
    func testStructuralNodeEmitsExactlyOneTerminalEvent() async throws {
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(name: "Transform")

        let events = try await execute(scenario)

        let terminals = WorkflowStreamCollector.nodeCompletedEvents(from: events).filter { $0.nodeID == code }.count
            + WorkflowStreamCollector.nodeFailedEvents(from: events).filter { $0.nodeID == code }.count
            + WorkflowStreamCollector.nodeSkippedEvents(from: events).filter { $0.nodeID == code }.count
            + WorkflowStreamCollector.nodeCancelledEvents(from: events).filter { $0.nodeID == code }.count
        XCTAssertEqual(terminals, 1, "a node must report its outcome exactly once")
    }

    func testAllTerminalsFailed_EmitsErrorMessage() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // Should emit an error about all terminals failing
        let errors = events.compactMap { event -> String? in
            if case .error(let err) = event { return err.message }
            return nil
        }
        // ⚠️ The message names the nodes that ACTUALLY FAILED. "all terminal nodes failed"
        // described the symptom and hid the cause — the failing node is usually mid-graph.
        XCTAssertTrue(errors.contains(where: { $0.contains("The workflow failed.") }),
                       "Should report the run as failed, got errors: \(errors)")
        XCTAssertTrue(errors.contains(where: { $0.contains("Bot A") }),
                       "…and must NAME the node that failed, got errors: \(errors)")
    }

    func testTriggerNode_AsEntryPoint() async throws {
        let scenario = WorkflowTestScenario()
        let trigger = scenario.addTriggerNode(name: "Start")
        let botA = scenario.addBotNode(name: "Bot A")

        scenario.connect(from: trigger, to: botA)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("triggered")])

        let events = try await execute(scenario)

        // Trigger completes (no-op), Bot A executes
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == trigger }), "Trigger should complete")
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botA }), "Bot A should execute after trigger")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "triggered")
    }

    // MARK: - Group 10: Code Node Edge Cases

    func testCodeNode_InjectionPrevention() async throws {
        // Upstream text contains {{ var.x }} — should NOT be replaced
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Set Var", template: "safe_value", outputVariable: "x")
        let botA = scenario.addBotNode(name: "Bot A")
        let codeB = scenario.addCodeNode(name: "Transform", template: "Result: {{ input }}")
        let botOut = scenario.addBotNode(name: "Output Bot")

        scenario.connect(from: codeA, to: botA)
        scenario.connect(from: botA, to: codeB)
        scenario.connect(from: codeB, to: botOut)

        // Bot A returns text that contains a template pattern
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("payload: {{ var.x }}")])
        mockProvider.scriptStream(for: scenario.profileID(for: botOut)!, events: [.content("done")])

        let events = try await execute(scenario)

        // codeB should output "Result: payload: {{ var.x }}" — the {{ var.x }} is NOT replaced
        let outProfileID = scenario.profileID(for: botOut)!
        let outInvocation = mockProvider.invocations.first(where: { $0.profileID == outProfileID })!
        XCTAssertTrue(outInvocation.userInput.contains("{{ var.x }}"),
                       "Template pattern in upstream text should NOT be substituted (injection prevention)")
    }

    func testCodeNode_EmptyTemplate() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let code = scenario.addCodeNode(name: "Empty", template: "")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: code)
        scenario.connect(from: code, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("done")])

        let events = try await execute(scenario)

        // Code node with empty template produces empty output
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == code }))
    }

    // MARK: - Group 11: Structural Node Failure Policies

    /// An unanswered gate fails, and its branch stops — here because no `error` edge was drawn,
    /// so the `["error"]` activation reaches nothing. Previously this test relied on the retired
    /// `stopWorkflow` policy; the outcome is now graph-driven.
    ///
    /// ⚠️ WF-TS9: the doc comment used to claim "a gate exposes only its option ports, so the
    /// `["error"]` activation matches no drawable edge". That has been false since WF61 —
    /// `WorkflowCanvasState.outputPortLabels(for:)` returns `withErrorPort(config.options)`, and
    /// `testGateWithTimeout_Unanswered_FailsOntoErrorPortAndSkipsOptionBranch` (Group 32) proves
    /// the edge is live. Also note this test reaches `chosenOption == nil` through the HARNESS,
    /// not through the gate's timer — Group 32 is what covers the timer.
    func testUnansweredGate_BranchStops() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Critical Gate")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("should not run")])

        let events = try await executeWithGate(scenario, choosing: nil)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "no gate option was chosen, so no branch is taken")
        XCTAssertFalse(started.contains(botC), "and the skip cascades transitively")
    }


    // MARK: - Group 12: Retry Edge Cases

    func testRetry_NonRetryableError_NoRetry() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        scenario.setNodeConfig(
            WorkflowNodeConfig(maxNodeRetries: 2, retryDelay: 0),
            for: botA
        )

        let profileID = scenario.profileID(for: botA)!
        // Non-retryable error: .repetitiveActionLoop has isRetryable = false
        mockProvider.scriptError(for: profileID, error: AgentExecutionError(reason: .repetitiveActionLoop(action: "test_action", count: 3)))

        let events = try await execute(scenario)

        // Should NOT retry — non-retryable error exits immediately
        let calls = mockProvider.invocations.filter { $0.profileID == profileID }
        XCTAssertEqual(calls.count, 1, "Non-retryable error should not trigger retry")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertEqual(failed.count, 1)
    }

    func testRetry_ExhaustsAllAttempts() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Persistent Failure Bot")
        scenario.setNodeConfig(
            WorkflowNodeConfig(maxNodeRetries: 2, retryDelay: 0),
            for: botA
        )

        let profileID = scenario.profileID(for: botA)!
        // All 3 attempts fail with retryable error (cycles last entry)
        mockProvider.scriptError(for: profileID, error: AgentExecutionError(reason: .modelError(provider: "test", error: "still failing")))

        let events = try await execute(scenario)

        // 3 total invocations: initial + 2 retries
        let calls = mockProvider.invocations.filter { $0.profileID == profileID }
        XCTAssertEqual(calls.count, 3, "Should attempt 1 + 2 retries = 3 total")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botA }))
    }

    // MARK: - Group 13: compileForWorkflow Unit Tests
    // (The former Group 13 tested the legacy `compile()` — dead code, deleted with it 2026-08-15.)

    func testCompileForWorkflow_EmptyResults() {
        let result = WorkflowInputAssembler.compileForWorkflow(results: [])
        XCTAssertEqual(result, "", "Empty results should produce empty string")
    }

    func testCompileForWorkflow_AllFailed_ReturnsEmpty() {
        let failedA = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "oops")),
            output: "failed output", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let skippedB = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot B", profileType: .bot,
            status: .skipped(reason: .upstreamFailed),
            output: "skipped output", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [failedA, skippedB])
        XCTAssertEqual(result, "", "All failed/skipped should produce empty string")
    }

    func testCompileForWorkflow_SingleCompleted_NoSeparator() {
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot, status: .completed,
            output: "The research shows three key findings.", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [envelope])
        XCTAssertEqual(result, "The research shows three key findings.", "Single result should be raw text, no separator")
        XCTAssertFalse(result.contains("---"), "Single result should have no separator")
        XCTAssertFalse(result.contains("Step"), "Should have no metadata labels")
        XCTAssertFalse(result.contains("Status"), "Should have no status labels")
    }

    func testCompileForWorkflow_MultipleCompleted_SeparatedByDashes() {
        let envelopeA = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot, status: .completed,
            output: "Research output", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let envelopeB = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot B", profileType: .bot, status: .completed,
            output: "SEO keywords", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [envelopeA, envelopeB])
        XCTAssertTrue(result.contains("Research output"), "Should contain first output")
        XCTAssertTrue(result.contains("SEO keywords"), "Should contain second output")
        XCTAssertTrue(result.contains("---"), "Multiple results should be separated by ---")
        XCTAssertFalse(result.contains("Bot A"), "Should not contain profile names")
        XCTAssertFalse(result.contains("Bot B"), "Should not contain profile names")
    }

    func testCompileForWorkflow_MixedStatus_OnlyCompletedIncluded() {
        let completed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Good Bot", profileType: .bot, status: .completed,
            output: "Useful data", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let failed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bad Bot", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "crash")),
            output: "Error garbage", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [completed, failed])
        XCTAssertEqual(result, "Useful data", "Only completed results should be included")
        XCTAssertFalse(result.contains("Error garbage"), "Failed output should be excluded")
    }

    /// ⚠️ INVERTED 2026-08-13 (user decision): a workflow no longer truncates upstream output at
    /// all. The old version of this test asserted the opposite — that a 5,000-char output was cut to
    /// 2,000 — which is exactly the silent loss the change removes. Fitting the input is now a
    /// function of which model the downstream node runs, and that is the author's choice.
    func testCompileForWorkflow_PassesLongOutputThroughUntruncated() {
        let longOutput = String(repeating: "word ", count: 1000) // 5,000 chars
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Verbose Bot", profileType: .bot, status: .completed,
            output: longOutput, artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [envelope])
        XCTAssertEqual(result, longOutput, "the output must arrive byte-for-byte")
        XCTAssertFalse(result.contains("truncated"), "no truncation marker may be injected")
    }

    /// Several verbose upstreams also pass through whole — the old TOTAL budget divided 6,000 chars
    /// between them, so three chatty nodes each lost most of their output.
    func testCompileForWorkflow_MultipleVerboseUpstreamsAllSurvive() {
        let envelopes = (1...3).map { i in
            NodeResultEnvelope(
                taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
                profileName: "Bot \(i)", profileType: .bot, status: .completed,
                output: String(repeating: "chunk\(i) ", count: 1000), artifacts: [],
                metadata: .simple(start: Date(), end: Date(), output: "")
            )
        }

        let result = WorkflowInputAssembler.compileForWorkflow(results: envelopes)
        for i in 1...3 {
            XCTAssertEqual(result.components(separatedBy: "chunk\(i) ").count - 1, 1000,
                           "every occurrence from Bot \(i) must survive")
        }
        XCTAssertFalse(result.contains("truncated"))
    }

    func testCompileForWorkflow_EmptyOutputCompleted() {
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Silent Bot", profileType: .bot, status: .completed,
            output: "", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [envelope])
        XCTAssertEqual(result, "", "Completed but empty output should produce empty string")
    }

    func testCompileForWorkflow_IncludeFailures_AnnotatesFailedUpstream() {
        let failed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Risky Bot", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "boom")),
            output: "partial result before failure", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        // Default: failed upstream excluded (error handler would see nothing).
        XCTAssertEqual(
            WorkflowInputAssembler.compileForWorkflow(results: [failed]), "",
            "Failed upstream should be excluded by default"
        )

        // includeFailures: surfaced with a reason annotation + the partial output,
        // so an error-handler node can act on what failed.
        let recovered = WorkflowInputAssembler.compileForWorkflow(results: [failed], includeFailures: true)
        XCTAssertTrue(recovered.contains("Risky Bot"), "Should name the failed upstream")
        XCTAssertTrue(recovered.contains("failed"), "Should mark the upstream as failed")
        XCTAssertTrue(recovered.contains("partial result before failure"), "Should include the partial output")
    }

    func testCompileForWorkflow_IncludeFailures_MixedKeepsBoth() {
        let completed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Good Bot", profileType: .bot, status: .completed,
            output: "useful data", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let failed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bad Bot", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "crash")),
            output: "garbage", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = WorkflowInputAssembler.compileForWorkflow(results: [completed, failed], includeFailures: true)
        XCTAssertTrue(result.contains("useful data"), "Completed output should be included")
        XCTAssertTrue(result.contains("Bad Bot"), "Failed upstream should be annotated and included")
        XCTAssertTrue(result.contains("---"), "Two usable upstreams should be separated by ---")
    }

    // MARK: - Group 14: Error Routing with Success

    func testErrorRouting_SuccessfulNode_DefaultPortActive() async throws {
        // When a node succeeds, default port (nil label) should work, error port should NOT
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Healthy Bot")
        let botB = scenario.addBotNode(name: "Normal Handler")
        let botC = scenario.addBotNode(name: "Error Handler")

        scenario.connect(from: botA, to: botB) // default port
        scenario.connect(from: botA, to: botC, portLabel: "error") // error port

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("success")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("normal")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("error handled")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botB), "Normal handler should execute on success")
        XCTAssertFalse(started.contains(botC), "Error handler should NOT execute on success")
    }

    // MARK: - Group 15: Long Chain Propagation

    func testFiveNodeChain_EndToEndPropagation() async throws {
        let scenario = WorkflowTestScenario()
        let n1 = scenario.addBotNode(name: "Node 1")
        let n2 = scenario.addBotNode(name: "Node 2")
        let n3 = scenario.addBotNode(name: "Node 3")
        let n4 = scenario.addBotNode(name: "Node 4")
        let n5 = scenario.addBotNode(name: "Node 5")

        scenario.connect(from: n1, to: n2)
        scenario.connect(from: n2, to: n3)
        scenario.connect(from: n3, to: n4)
        scenario.connect(from: n4, to: n5)

        for n in [n1, n2, n3, n4, n5] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("output-\(n.uuidString.prefix(4))")])
        }

        let events = try await execute(scenario)

        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [n1, n2, n3, n4, n5])
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // Only terminal node (n5) in final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.starts(with: "output-"), "Only terminal node output in final content")
    }

    // MARK: - Group 16: Cancellation Scenarios

    func testCancel_DuringFirstNode_EmitsPartialResults() async throws {
        // A→B→C; cancel while A is streaming
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Slow Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        // A streams initial events then blocks (simulating slow LLM)
        mockProvider.scriptSlowStream(for: scenario.profileID(for: botA)!, initialEvents: [
            .content("partial A output")
        ])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])

        let stream = makeStream(scenario)

        // Run stream in a cancellable task
        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        // Give the executor time to start, then cancel
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let events: [AgentStreamEvent]
        do {
            events = try await task.value
        } catch is CancellationError {
            events = [] // Stream cancelled before collecting
        } catch {
            events = []
        }

        // Bot B and C should NOT have been invoked
        let bProfileID = scenario.profileID(for: botB)!
        let cProfileID = scenario.profileID(for: botC)!
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }),
                       "Bot B should not execute after cancellation")
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == cProfileID }),
                       "Bot C should not execute after cancellation")
    }

    func testCancel_DuringSecondNode_FirstNodeOutputPreserved() async throws {
        // A→B; A completes instantly, B blocks. Cancel during B.
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Fast Bot A")
        let botB = scenario.addBotNode(name: "Slow Bot B")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A done")])
        mockProvider.scriptSlowStream(for: scenario.profileID(for: botB)!, initialEvents: [
            .content("B partial")
        ])

        let stream = makeStream(scenario)

        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        // Wait for A to complete and B to start, then cancel
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let events: [AgentStreamEvent]
        do {
            events = try await task.value
        } catch {
            events = []
        }

        // A should have completed before cancellation
        let aProfileID = scenario.profileID(for: botA)!
        XCTAssertTrue(mockProvider.invocations.contains(where: { $0.profileID == aProfileID }),
                       "Bot A should have been invoked before cancellation")

        // B should have been invoked (but cancelled mid-stream)
        let bProfileID = scenario.profileID(for: botB)!
        XCTAssertTrue(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }),
                       "Bot B should have been invoked before cancel")
    }

    func testCancel_BetweenLevels_CompletedLevelOutput() async throws {
        // A→B; A completes fast, cancellation happens at level boundary
        // This tests that completed work isn't lost
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Fast Bot A")
        let botB = scenario.addBotNode(name: "Slow Bot B")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A completed")])
        mockProvider.scriptSlowStream(for: scenario.profileID(for: botB)!, initialEvents: [])

        let stream = makeStream(scenario)

        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Expected cancellation
        }

        // A was invoked, B was invoked (or about to be)
        let aProfileID = scenario.profileID(for: botA)!
        XCTAssertTrue(mockProvider.invocations.contains(where: { $0.profileID == aProfileID }),
                       "Bot A should have completed before cancellation")
    }

    func testCancel_DuringGate_GateIsCancelled() async throws {
        // A→Gate→B; cancel while gate is waiting for approval
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Waiting Gate")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])

        let stream = makeStream(scenario)

        var collectedEvents: [AgentStreamEvent] = []
        let task = Task {
            var events: [AgentStreamEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }

        // Give gate time to emit requestGate, then cancel
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        do {
            collectedEvents = try await task.value
        } catch {
            // Expected
        }

        // Bot B should NOT have been invoked — gate was cancelled, not approved
        let bProfileID = scenario.profileID(for: botB)!
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }),
                       "Bot B should NOT execute when gate is cancelled")

        // Gate request should have been emitted before cancel
        let gates = WorkflowStreamCollector.gateRequests(from: collectedEvents)
        XCTAssertTrue(gates.count <= 1, "Gate request should have been emitted (or not if cancel was too fast)")
    }

    // [WF-CC1] No dedicated regression test for the Gate/sub-workflow `Task.isCancelled` fix: the
    // observable difference it makes (`.workflowNodeCancelled` vs `.workflowNodeFailed`) is a
    // STREAM EVENT emitted from inside the same cancellation arm the Group 29 header comment above
    // documents as unobservable through this harness — cancelling the task that consumes the stream
    // races the event's own delivery, and the race always loses (`onTermination` fires because the
    // consumer tore the stream down, so by the time the arm runs and yields, the stream is already
    // terminal). An earlier draft of this test asserted on those events directly and failed with
    // BOTH the cancelled and failed arrays empty — not because the fix is wrong, but because the
    // assertion was reaching for something this seam structurally cannot deliver, confirmed by the
    // engine's own internal log line recording the correct `status=canceled` for the exact same run.
    // `ExecutionSuspensionService`'s drain state (Group 29's proxy) doesn't help either: draining
    // was already true before this fix — only the STATUS value changed, not whether it drains.
    // Verified instead by code review and the internal log evidence above.

    func testCancel_DoesNotInvokeDownstreamNodes() async throws {
        // 5-node chain: cancel after node 2 starts
        let scenario = WorkflowTestScenario()
        let n1 = scenario.addBotNode(name: "Node 1")
        let n2 = scenario.addBotNode(name: "Node 2")
        let n3 = scenario.addBotNode(name: "Node 3")
        let n4 = scenario.addBotNode(name: "Node 4")
        let n5 = scenario.addBotNode(name: "Node 5")

        scenario.connect(from: n1, to: n2)
        scenario.connect(from: n2, to: n3)
        scenario.connect(from: n3, to: n4)
        scenario.connect(from: n4, to: n5)

        mockProvider.scriptStream(for: scenario.profileID(for: n1)!, events: [.content("1")])
        mockProvider.scriptSlowStream(for: scenario.profileID(for: n2)!, initialEvents: [.content("2 partial")])
        mockProvider.scriptStream(for: scenario.profileID(for: n3)!, events: [.content("3")])
        mockProvider.scriptStream(for: scenario.profileID(for: n4)!, events: [.content("4")])
        mockProvider.scriptStream(for: scenario.profileID(for: n5)!, events: [.content("5")])

        let stream = makeStream(scenario)
        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do { _ = try await task.value } catch {}

        // Nodes 3, 4, 5 should NEVER be invoked
        for (node, name) in [(n3, "Node 3"), (n4, "Node 4"), (n5, "Node 5")] {
            let pid = scenario.profileID(for: node)!
            XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == pid }),
                           "\(name) should NOT be invoked after cancellation")
        }
    }

    // =========================================================================
    // MARK: - Group 17: Graph Topology Edge Cases
    // =========================================================================

    func testDisconnectedSubgraphs_BothChainsExecute() async throws {
        // Two independent chains: A→B, C→D (no connection between them)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Chain1-A")
        let botB = scenario.addBotNode(name: "Chain1-B")
        let botC = scenario.addBotNode(name: "Chain2-C")
        let botD = scenario.addBotNode(name: "Chain2-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botC, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("D")])

        let events = try await execute(scenario)

        // All 4 nodes should execute
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 4)

        // Terminal nodes are B and D — both outputs in final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("B"), "Chain1 terminal output should be in content")
        XCTAssertTrue(content.contains("D"), "Chain2 terminal output should be in content")
    }

    func testIsolatedNode_NoEdges_ExecutesAsTerminal() async throws {
        // Single node with no incoming or outgoing edges
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Isolated")

        // No edges — it's both an entry point and a terminal
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("alone")])

        let events = try await execute(scenario)

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(StreamCollector.contentText(from: events), "alone")
    }

    func testWideFanOut_OneToMany() async throws {
        // A → B, C, D, E (one source, four targets)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Target-B")
        let botC = scenario.addBotNode(name: "Target-C")
        let botD = scenario.addBotNode(name: "Target-D")
        let botE = scenario.addBotNode(name: "Target-E")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)
        scenario.connect(from: botA, to: botE)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("broadcast")])
        for n in [botB, botC, botD, botE] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("received")])
        }

        let events = try await execute(scenario)

        // All 5 nodes execute; B, C, D, E are all terminals
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // All 4 downstream nodes receive A's context
        for n in [botB, botC, botD, botE] {
            let pid = scenario.profileID(for: n)!
            let inv = mockProvider.invocations.first(where: { $0.profileID == pid })!
            XCTAssertTrue(inv.userInput.contains("broadcast"), "\(n) should receive A's output as context")
        }
    }

    func testWideFanIn_ManyToOne() async throws {
        // A, B, C, D → E (four sources, one target)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source-A")
        let botB = scenario.addBotNode(name: "Source-B")
        let botC = scenario.addBotNode(name: "Source-C")
        let botD = scenario.addBotNode(name: "Source-D")
        let botE = scenario.addBotNode(name: "Aggregator")

        scenario.connect(from: botA, to: botE)
        scenario.connect(from: botB, to: botE)
        scenario.connect(from: botC, to: botE)
        scenario.connect(from: botD, to: botE)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("from-A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from-B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("from-C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("from-D")])
        mockProvider.scriptStream(for: scenario.profileID(for: botE)!, events: [.content("aggregated")])

        let events = try await execute(scenario)

        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // E receives context from all 4 upstream nodes
        let ePid = scenario.profileID(for: botE)!
        let eInv = mockProvider.invocations.first(where: { $0.profileID == ePid })!
        XCTAssertTrue(eInv.userInput.contains("from-A"))
        XCTAssertTrue(eInv.userInput.contains("from-B"))
        XCTAssertTrue(eInv.userInput.contains("from-C"))
        XCTAssertTrue(eInv.userInput.contains("from-D"))
    }

    func testSelfLoop_DetectedByCycleCheck() {
        // A → A (self-loop)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Self Loop")
        scenario.connect(from: botA, to: botA)

        // computeExecutionLevels should detect this as a cycle
        let levels = scenario.layout.computeExecutionLevels()
        XCTAssertNil(levels, "Self-loop should be detected as a cycle")
    }

    // =========================================================================
    // MARK: - Group 18: Mixed Upstream Status & Cascaded Policies
    // =========================================================================

    func testFanIn_OneParentSkipped_ChildSkipped() async throws {
        // A(fails)→C, B(ok)→C: C should be skipped because A failed (allSatisfy)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Parent")
        let botB = scenario.addBotNode(name: "Good Parent")
        let botC = scenario.addBotNode(name: "Child")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])

        let events = try await execute(scenario)

        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(skipped.contains(botC), "C should be SKIPPED when ANY parent fails (allSatisfy)")
    }

    /// Fan-in with a failed parent: the child SKIPS under the default `.all` join, because the
    /// failed parent's branch is not live. (This previously passed via `continueAll`.)
    func testFanIn_FailedParent_ChildSkipsUnderAllJoin() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Parent")
        let botB = scenario.addBotNode(name: "Good Parent")
        let botC = scenario.addBotNode(name: "Child")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ran")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botC), "an `.all` join needs every branch live")

        // The healthy parent still completed — a failure never touches a parallel branch.
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == botB })
    }


    // MARK: - Router: arbitration highlights

    /// Spans are attributed to the rule that matched them, and each one really covers the matched
    /// text in `inputText`. ⚠️ The input deliberately differs in CASE from the needles — that is what
    /// proves start/end come from the returned `Range` rather than from `needle.count`.
    func testArbitrationHighlights_SpansCoverTheMatchedTextPerRule() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Urgent")
        scenario.connect(from: router, to: b, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("URGENT problem with my Invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        let events = try await executeWithGate(scenario, choosing: "Urgent")
        let request = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first)
        let input = try XCTUnwrap(request.inputText)

        XCTAssertEqual(Set(request.highlights.map(\.label)), ["Urgent", "Billing"])

        // Every span must resolve, inside the carried string, to text equal to its rule's needle.
        let needles = ["Urgent": "urgent", "Billing": "invoice"]
        for span in request.highlights {
            let chars = Array(input)
            XCTAssertLessThanOrEqual(span.end, chars.count, "span must stay inside inputText")
            let matched = String(chars[span.start..<span.end])
            XCTAssertEqual(matched.lowercased(), needles[span.label], "span \(span) covered '\(matched)'")
        }
    }

    /// Only `contains` has a locatable span. Operators that match by absence or unconditionally have
    /// nothing to paint — highlighting a near-miss for `does not contain` would colour exactly the
    /// text that would have made the rule NOT match.
    func testArbitrationHighlights_NonLocatableOperatorsProduceNoSpans() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Any", field: .upstreamOutput, op: .isNotEmpty, value: ""),
            // `.notContains` of an absent needle: matches by ABSENCE, so nothing to highlight —
            // the same non-locatable property the deleted `always` operator provided here.
            ConditionRule(label: "All", field: .upstreamOutput, op: .notContains, value: "xyzzy")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Any")
        scenario.connect(from: router, to: b, portLabel: "All")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("anything at all")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        let events = try await executeWithGate(scenario, choosing: "Any")
        let request = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first)

        XCTAssertEqual(request.options, ["Any", "All"], "both rules matched, so both are offered")
        XCTAssertTrue(request.highlights.isEmpty, "neither operator has a locatable span")
        XCTAssertEqual(request.inputText, "anything at all", "…but the input is still shown")
    }

    /// ⚠️ One rule's comma-separated needles can match overlapping text ("urgent, urgently"). The
    /// spans must come back merged, sorted and non-overlapping — the banner's painter walks them
    /// with a forward-only cursor and would mis-paint on an unsorted or overlapping list.
    func testArbitrationHighlights_OverlappingNeedlesAreMerged() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent, urgently"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Urgent")
        scenario.connect(from: router, to: b, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("please urgently fix the invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        let events = try await executeWithGate(scenario, choosing: "Urgent")
        let request = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first)

        let urgent = request.highlights.filter { $0.label == "Urgent" }
        XCTAssertEqual(urgent.count, 1, "'urgent' and 'urgently' overlap and must merge — got \(urgent)")
        let input = try XCTUnwrap(request.inputText)
        XCTAssertEqual(String(Array(input)[urgent[0].start..<urgent[0].end]), "urgently",
                       "the merged span covers the longer alternative")

        // Sorted and non-overlapping across the whole set.
        let sorted = request.highlights.sorted { $0.start < $1.start }
        for (lhs, rhs) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(lhs.end, rhs.start, "spans must not overlap: \(lhs) vs \(rhs)")
        }
    }

    /// ⚠️ THE FOLDING CASE — the reason start AND end must both come from the returned `Range`.
    ///
    /// `range(of:options:.caseInsensitive)` performs full case folding, so the 7-character needle
    /// "strasse" matches the 6-character text "straße". Computing `end = start + needle.count` would
    /// paint one character too many and drift every later span in the string. Verified empirically:
    /// ß/ss and the ﬁ ligature both differ in length; precomposed vs decomposed accents do not,
    /// because grapheme-cluster counting already normalises those away.
    ///
    /// Found by mutation-checking — the original highlight tests all used needles whose length
    /// happened to equal the match, so the bug passed them all.
    func testArbitrationHighlights_FoldedMatchUsesTheRangeNotTheNeedleLength() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Street", field: .upstreamOutput, op: .contains, value: "strasse"),
            ConditionRule(label: "Here", field: .upstreamOutput, op: .contains, value: "hier")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Street")
        scenario.connect(from: router, to: b, portLabel: "Here")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("die straße hier")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        let events = try await executeWithGate(scenario, choosing: "Street")
        let request = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first)
        let input = try XCTUnwrap(request.inputText)

        let street = try XCTUnwrap(request.highlights.first { $0.label == "Street" })
        XCTAssertEqual(street.end - street.start, 6, "the MATCH is 6 chars ('straße'), the needle is 7")
        XCTAssertEqual(String(Array(input)[street.start..<street.end]), "straße")

        // …and the later span is still correctly placed, which an off-by-one would break.
        let here = try XCTUnwrap(request.highlights.first { $0.label == "Here" })
        XCTAssertEqual(String(Array(input)[here.start..<here.end]), "hier")
    }

    /// ⚠️ `equals` is excluded from highlighting on purpose: a match covers the ENTIRE field, so
    /// painting it colours the whole input and tells the reader nothing. Only `contains` has a
    /// span worth showing. (Also found by mutation-checking — dropping the operator guard changed
    /// nothing until this case existed.)
    func testArbitrationHighlights_EqualsProducesNoSpan() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Exact", field: .upstreamOutput, op: .equals, value: "escalate now"),
            ConditionRule(label: "Partial", field: .upstreamOutput, op: .contains, value: "escalate")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Exact")
        scenario.connect(from: router, to: b, portLabel: "Partial")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("escalate now")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        let events = try await executeWithGate(scenario, choosing: "Exact")
        let request = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first)

        XCTAssertEqual(request.options, ["Exact", "Partial"], "both rules matched")
        XCTAssertTrue(request.highlights.filter { $0.label == "Exact" }.isEmpty,
                      "`equals` covers the whole field — no useful span")
        XCTAssertFalse(request.highlights.filter { $0.label == "Partial" }.isEmpty,
                       "`contains` still highlights")
    }

    /// An ordinary Gate node shows the approver its upstream input, but carries no highlight spans — those are a Router
    /// arbitration concept and must not leak into every gate.
    func testOrdinaryGate_CarriesItsInputButNoHighlights() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let gate = scenario.addGateNode(name: "Approve?", options: ["Yes", "No"])
        let yes = scenario.addBotNode(name: "Yes Arm")
        scenario.connect(from: source, to: gate)
        scenario.connect(from: gate, to: yes, portLabel: "Yes")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: yes)!, events: [.content("ok")])

        let events = try await executeWithGate(scenario, choosing: "Yes")
        let request = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first)

        XCTAssertEqual(request.inputText, "data", "the approver must see what they are approving")
        XCTAssertTrue(request.highlights.isEmpty)
    }

    /// Two parallel upstreams feeding one Gate: the approver sees BOTH outputs, not just the prompt.
    func testGate_FedByTwoUpstreams_ShowsBothInputsToTheApprover() async throws {
        let scenario = WorkflowTestScenario()
        let first = scenario.addBotNode(name: "File Mover")
        let second = scenario.addBotNode(name: "Instrumentation")
        let gate = scenario.addGateNode(name: "Approve?", options: ["Yes", "No"])
        let yes = scenario.addBotNode(name: "Yes Arm")
        scenario.connect(from: first, to: gate)
        scenario.connect(from: second, to: gate)
        scenario.connect(from: gate, to: yes, portLabel: "Yes")

        mockProvider.scriptStream(for: scenario.profileID(for: first)!, events: [.content("moved 3 files")])
        mockProvider.scriptStream(for: scenario.profileID(for: second)!, events: [.content("latency p95 120ms")])
        mockProvider.scriptStream(for: scenario.profileID(for: yes)!, events: [.content("ok")])

        let events = try await executeWithGate(scenario, choosing: "Yes")
        let input = try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first?.inputText)

        XCTAssertTrue(input.contains("moved 3 files"), "first upstream missing from the review text: \(input)")
        XCTAssertTrue(input.contains("latency p95 120ms"), "second upstream missing from the review text: \(input)")
    }

    func testGateReviewText_ShortInputIsShownInFull() {
        let input = String(repeating: "a", count: WorkflowExecutor.gateReviewTextLimit)
        XCTAssertEqual(WorkflowExecutor.gateReviewText(input), input)
    }

    func testGateReviewText_LongInputIsCutAndSaysHowMuchIsHidden() {
        let input = String(repeating: "a", count: WorkflowExecutor.gateReviewTextLimit + 250)
        let shown = WorkflowExecutor.gateReviewText(input)

        XCTAssertTrue(shown.hasPrefix(String(repeating: "a", count: WorkflowExecutor.gateReviewTextLimit)))
        XCTAssertTrue(shown.contains("250 more characters not shown"), "the cut must be visible: \(shown.suffix(120))")
        XCTAssertLessThan(shown.count, input.count)
    }

    // MARK: - Retries: per-node, and only where retrying is safe

    /// A per-node retry count still works on a Profile node — the one kind where a transient
    /// provider error is worth another attempt.
    func testProfileNode_PerNodeRetry_RetriesTransientFailure() async throws {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Flaky Bot")
        var cfg = WorkflowNodeConfig()
        cfg.maxNodeRetries = 2
        scenario.setNodeConfig(cfg, for: bot)

        let pid = scenario.profileID(for: bot)!
        mockProvider.scriptError(for: pid, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: pid, events: [.content("succeeded on retry")])

        let events = try await execute(scenario)
        XCTAssertTrue(StreamCollector.contentText(from: events).contains("succeeded on retry"),
                      "a per-node retry must still fire")
    }

    /// ⚠️ Retry does not apply to DETERMINISTIC structural kinds. Re-running a Router is pointless:
    /// same input, same rules, same no-match. A stored `maxNodeRetries` is inert on Router / Code /
    /// Gate / Trigger.
    ///
    /// ⚠️ UPDATED 2026-08-19 — this comment used to say retry never applies to structural kinds AT
    /// ALL, including sub-workflows. That is no longer true and was the §9 N4 defect: a sub-workflow
    /// is LLM-driven and non-deterministic, so it now DOES retry via the outer loop in
    /// `executeStructuralNodeBounded`. See `testSubWorkflowNode_RetriesOnFailure…` below. The
    /// vehicle here is a Router precisely because it is one of the kinds that still must not.
    ///
    /// ⚠️ WF-TS8 — WHY THE VEHICLE IS A ROUTER AND NOT A CODE NODE. This test used to configure
    /// `maxNodeRetries = 3` on a Code node with an unresolvable template and assert
    /// `starts.count <= 1`. But a Code node **cannot fail**: `WorkflowTemplate.render` is
    /// non-throwing and leaves the placeholder verbatim, and the `.code` arm of
    /// `executeStructuralNode` never assigns `.failed`. With no failure there is no state a retry
    /// could even be attempted from, so the assertion held for a reason that had nothing to do
    /// with the retry guard — and `<=` also passes at 0 starts, i.e. if the node never ran at all.
    /// A Router with `decisionPolicy == .failNode` and no matching rule is the one structural
    /// node that reliably DOES fail, which is what makes the retry guard observable.
    func testStructuralNode_NeverRetries_EvenWithRetriesConfigured() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")

        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "URGENT"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .failNode   // stated explicitly — this is what makes it fail
        let router = scenario.addConditionNode(name: "Router", config: config)

        var cfg = WorkflowNodeConfig()
        cfg.maxNodeRetries = 3
        cfg.retryDelay = 0                   // keep the test fast if the guard ever regresses
        scenario.setNodeConfig(cfg, for: router)

        let urgent = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!,
                                  events: [.content("nothing here matches those rules")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("must not run")])

        let events = try await execute(scenario)

        // PRECONDITION — the assertion the old test lacked. Without a real failure the retry
        // guard is never even reached and everything below is vacuous.
        let failures = WorkflowStreamCollector.nodeFailedEvents(from: events).filter { $0.nodeID == router }
        XCTAssertEqual(failures.count, 1,
                       "precondition: the Router must FAIL exactly once (no rule matched, .failNode) — got \(failures.map(\.error))")

        // THE ASSERTION. A retry re-enters the structural path, which yields
        // `.workflowNodeStarted` at its top — so attempt 2 would show as a second start event.
        // EQUAL, not `<=`: `<=` also passes when the node never ran at all.
        let starts = WorkflowStreamCollector.nodeStartedEvents(from: events).filter { $0.nodeID == router }
        XCTAssertEqual(starts.count, 1,
                       "a structural node must not be retried — got \(starts.count) starts with maxNodeRetries = 3")
    }

    /// ⚠️ §9 N4 — a sub-workflow node MUST honour its Node-Level Retries setting.
    ///
    /// The stepper was rendered for these nodes and did nothing: they are dispatched structurally
    /// (so they never reach `executeProfileNodeWithRetry`) and the structural path had no loop.
    /// A user set Retries = 3 on a flaky nested pipeline and got exactly one attempt, with no log
    /// line and no UI hint saying the setting was ignored.
    ///
    /// Uses the same observation as the Router test above: a retry re-enters the structural path,
    /// which yields `.workflowNodeStarted` at its top, so each attempt shows as one start event.
    func testSubWorkflowNode_RetriesOnFailure_WhenRetriesConfigured() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Flaky Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let subWorkflow = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)

        var cfg = WorkflowNodeConfig()
        cfg.maxNodeRetries = 2
        cfg.retryDelay = 0        // keep the test fast; the delay is covered by the unit tests
        scenario.setNodeConfig(cfg, for: subWorkflow)

        // The child fails every time, so every configured attempt is used.
        mockProvider.scriptError(for: inner.profileID(for: innerBot)!,
                                 error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // THE FIX: 2 retries means 3 attempts, each re-entering the structural path.
        let starts = WorkflowStreamCollector.nodeStartedEvents(from: events).filter { $0.nodeID == subWorkflow }
        XCTAssertEqual(starts.count, 3,
                       "a sub-workflow node must honour maxNodeRetries = 2 (3 attempts) — got \(starts.count)")

        // And the node reports failure exactly ONCE, at the end. Emitting the terminal event per
        // attempt would show the node failing three times on the canvas and would activate its
        // `error` port before the retries had run.
        let failures = WorkflowStreamCollector.nodeFailedEvents(from: events).filter { $0.nodeID == subWorkflow }
        XCTAssertEqual(failures.count, 1,
                       "the failure must be reported once, after the last attempt — got \(failures.count)")
    }

    // MARK: - Sub-workflow boundary: artifacts + structured JSON cross INTO the child (EXA-4)

    /// ⚠️ Register EXA-4 — a parent upstream's media must reach the CHILD's entry profile node.
    ///
    /// Before the fix, the child was started with flattened text only: its entry node computed
    /// `upstreamArtifacts = []` (no incoming edges), while the sub-workflow node's own envelope
    /// still forwarded the artifact DOWNSTREAM of itself — media provably flowed around the child
    /// but never into it, and nothing logged the drop.
    func testSubWorkflow_UpstreamArtifactsCrossIntoChildEntryProfileNode() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Body Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let producer = scenario.addBotNode(name: "Producer")
        let nested = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        scenario.connect(from: producer, to: nested)

        let artifact = MediaArtifact(kind: .image, reference: .ephemeralData(Data([1])), mimeType: "image/png", label: "chart")
        mockProvider.scriptStream(for: scenario.profileID(for: producer)!,
                                  events: [.content("made a chart"), .artifactProduced(artifact)])
        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [.content("described it")])

        _ = try await execute(scenario)

        let bodyInvocation = mockProvider.workflowInvocations.first { $0.profileID == inner.profileID(for: innerBot)! }
        XCTAssertNotNil(bodyInvocation, "the child's body bot must have run")
        XCTAssertEqual(bodyInvocation?.context.upstreamArtifacts.map(\.id), [artifact.id],
                       "the parent upstream's artifact must cross the sub-workflow boundary into the child's entry node — media must flow INTO the child, not only around it")
    }

    /// ⚠️ Register EXA-4, structured half — `{{ input.json.path }}` at the CHILD's entry Code node
    /// must resolve against the parent upstream's structured output.
    ///
    /// `WorkflowTemplate` has no text-parse fallback for `input.json` (the `inputJSON` parameter is
    /// its only source), so before the fix the literal placeholder survived into the child's output
    /// — the failure asserted here is exactly the one the register filed.
    func testSubWorkflow_UpstreamStructuredJSONResolvesInChildEntryCodeNode() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        inner.addCodeNode(name: "Formatter", template: "City: {{ input.json.city }}")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let producer = scenario.addBotNode(name: "JSON Producer")
        let nested = scenario.addSubWorkflowNode(name: "Nested Format", workflowProfileID: inner.workflowProfileID)
        scenario.connect(from: producer, to: nested)

        mockProvider.scriptStream(for: scenario.profileID(for: producer)!,
                                  events: [.content("{\"city\":\"NYC\"}")])

        let events = try await execute(scenario)

        let content = WorkflowStreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("City: NYC"),
                      "the parent's structured JSON must resolve at the child's entry Code node — got: \(content)")
        XCTAssertFalse(content.contains("{{ input.json.city }}"),
                       "the literal placeholder surviving means structured JSON did not cross the boundary")
    }

    /// ⚠️ Register EXA-4, forwarding half — a STRUCTURAL entry node inside the child (a Trigger)
    /// must hand the inherited artifacts downstream through its envelope, exactly as it hands
    /// upstream media inside a flat graph. Without the envelope-tail forward the seed dies at the
    /// first structural hop and the bot below the Trigger sees nothing.
    func testSubWorkflow_ChildEntryTriggerForwardsInheritedArtifactsDownstream() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerTrigger = inner.addTriggerNode(name: "Body Trigger")
        let innerBot = inner.addBotNode(name: "Below Bot")
        inner.connect(from: innerTrigger, to: innerBot)
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let producer = scenario.addBotNode(name: "Producer")
        let nested = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        scenario.connect(from: producer, to: nested)

        let artifact = MediaArtifact(kind: .image, reference: .ephemeralData(Data([2])), mimeType: "image/png", label: "photo")
        mockProvider.scriptStream(for: scenario.profileID(for: producer)!,
                                  events: [.content("made a photo"), .artifactProduced(artifact)])
        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [.content("saw it")])

        _ = try await execute(scenario)

        let belowInvocation = mockProvider.workflowInvocations.first { $0.profileID == inner.profileID(for: innerBot)! }
        XCTAssertNotNil(belowInvocation, "the bot below the child's entry Trigger must have run")
        XCTAssertEqual(belowInvocation?.context.upstreamArtifacts.map(\.id), [artifact.id],
                       "an entry Trigger inside the child must FORWARD inherited artifacts downstream via its envelope")
    }

    // MARK: - Sub-workflow boundary: event forwarding (EXC-3)

    /// ⚠️ Register EXC-3, the materially lossy half — a child node's `.tokenUsage` must reach the
    /// parent's stream. ActiveStreamManager ACCUMULATES the run total additively and the child
    /// emits no aggregate of its own, so the old `default:` suppression silently excluded ALL
    /// nested work from the run's token count — the deeper the nesting, the larger the
    /// under-report, with no ceiling. (Its comment claimed the suppression was deliberate.)
    func testSubWorkflow_ForwardsChildTokenUsage() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Spender")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        _ = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)

        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!,
                                  events: [.content("worked"),
                                           .tokenUsage(TokenUsage(inputTokens: 100, outputTokens: 50, isEstimated: false))])

        let events = try await execute(scenario)

        let usages = events.compactMap { event -> TokenUsage? in
            if case .tokenUsage(let usage) = event { return usage }
            return nil
        }
        XCTAssertTrue(usages.contains { $0.inputTokens == 100 && $0.outputTokens == 50 },
                      "the child node's token usage must cross the sub-workflow boundary — the run total otherwise excludes all nested work. Got \(usages)")
    }

    /// EXC-3, capability half — a plan/subtask event raised inside the child must reach the
    /// parent's stream, exactly as the direct profile path forwards it (milestones, cards, and the
    /// subtask boundary flush all hang off these).
    func testSubWorkflow_ForwardsChildCapabilityEvents() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Planner")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        _ = scenario.addSubWorkflowNode(name: "Nested Plan", workflowProfileID: inner.workflowProfileID)

        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!,
                                  events: [.subtaskStarted(id: "s1", index: 1, total: 2, description: "step one"),
                                           .content("planned")])

        let events = try await execute(scenario)

        let sawSubtask = events.contains {
            if case .subtaskStarted(let id, _, _, _) = $0 { return id == "s1" }
            return false
        }
        XCTAssertTrue(sawSubtask,
                      "a subtask event inside the child must reach the parent's stream — the old default: swallowed every capability event")
    }

    /// EXC-3's other edge — the split must not over-forward: the child's OWN orchestration events
    /// (its per-node completed rows, its progress counter) stay suppressed, or the parent's
    /// timeline shows the child's nodes as siblings of its own and the progress counter
    /// double-counts.
    func testSubWorkflow_StillSuppressesChildOrchestration() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Inner Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let nested = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)

        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [.content("inner")])

        let events = try await execute(scenario)

        // The inner bot ran (its invocation is recorded), but no node-lifecycle event for it may
        // surface on the parent stream — only the sub-workflow node's own.
        XCTAssertNotNil(mockProvider.workflowInvocations.first { $0.profileID == inner.profileID(for: innerBot)! })
        let startedIDs = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        let completedIDs = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertEqual(startedIDs, [nested], "only the sub-workflow node itself may announce on the parent stream — got \(startedIDs)")
        XCTAssertEqual(completedIDs, [nested], "the child's own node-completed rows must stay suppressed — got \(completedIDs)")

        // The counter twins — a leaked child `workflowRunFinished` overwrites the parent's run
        // verdict at the consumer, and a leaked child progress event corrupts the parent's N/M
        // counter. Both graphs have one node each, so a leak shows as a COUNT of 2, not a
        // different payload.
        let runFinishedCount = events.filter { if case .workflowRunFinished = $0 { return true }; return false }.count
        XCTAssertEqual(runFinishedCount, 1,
                       "exactly the PARENT's run verdict may surface — a second one is the child's leaking through")
        let progressCount = WorkflowStreamCollector.progressEvents(from: events).count
        XCTAssertEqual(progressCount, 1,
                       "exactly the parent's one progress tick may surface — got \(progressCount)")
    }

    // MARK: - Node timeout: applies everywhere, counts compute not waiting

    /// ⚠️ WF22: structural nodes had NO timeout at all — the race existed only on the profile-stream
    /// and Action-tool paths, while the settings sheet promised a "maximum wall-clock time per node".
    /// A sub-workflow whose body runs long is now bounded like anything else.
    /// (Originally exercised through a Loop node; rewritten onto a sub-workflow node when the Loop
    /// was retired 2026-08-15 — the behaviour under test is the structural-path timeout, not the
    /// vehicle.)
    func testStructuralNode_ExceedingItsTimeout_Fails() async throws {
        let scenario = WorkflowTestScenario()
        let (innerID, _) = makeInnerBotWorkflow(botName: "Slow Body Bot", scenario: scenario)
        let nested = scenario.addSubWorkflowNode(name: "Slow Nested", workflowProfileID: innerID)

        var cfg = WorkflowNodeConfig()
        cfg.hardTimeout = 0.3
        scenario.setNodeConfig(cfg, for: nested)

        // The body sleeps 1s, blowing a 0.3s budget with no park involved.
        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Slow Body Bot" })!.key
        mockProvider.scriptDelayedStream(for: innerPid, events: [.content("late")], milliseconds: 1000)

        let events = try await execute(scenario)
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let failure = failed.first { $0.nodeID == nested }
        XCTAssertNotNil(failure,
                        "a structural node must be bounded by its timeout — got \(failed.map(\.profileName))")
        // ⚠️ The REASON is asserted too, not just "it failed": the dispatch guard (missing profile)
        // and a child layout that fails to load produce the identical `.workflowNodeFailed`, so
        // without this a broken test setup would keep passing as a fast failure and the timeout
        // itself could regress unnoticed.
        XCTAssertTrue(failure?.error.localizedCaseInsensitiveContains("timeout") == true,
                      "the failure must BE the timeout, not a setup failure wearing its event — got: \(failure?.error ?? "<none>")")
    }

    /// ⚠️ THE PRINCIPLE: the clock counts COMPUTE, not waiting for a human.
    ///
    /// A Router with a 1s timeout parks for ambiguity arbitration and is answered after ~2s. Under
    /// the old raw `Task.sleep` race that node would have died; the parked time is excluded, so it
    /// completes and routes to the chosen branch.
    ///
    /// This is also the pre-existing profile-path defect in miniature — an agent asking for tool
    /// confirmation killed its own node at 120s if the user was slow.
    func testParkedTimeDoesNotCountAgainstTheNodeTimeout() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        var cfg = WorkflowNodeConfig()
        cfg.hardTimeout = 1.0                      // shorter than the answer delay below
        scenario.setNodeConfig(cfg, for: router)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Urgent")
        scenario.connect(from: router, to: b, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("URGENT invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        // Answer well after the 1s budget would have expired on a wall-clock race.
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = executor.executeWorkflow(
            userInput: "Test input", conversationID: UUID(),
            traceContext: traceContext, onTraceUpdate: { _ in },
            layout: scenario.layout, profileMap: scenario.profileMap, streamProvider: mockProvider)

        var events: [AgentStreamEvent] = []
        for try await event in stream {
            events.append(event)
            if case .requestGate(_, _, let opID, _, _, _, _, _) = event {
                try await Task.sleep(for: .milliseconds(2200))
                await ExecutionSuspensionService.shared.resumeGate(for: opID, chosenOption: "Billing", resolvedBy: .localUI)
            }
        }

        XCTAssertFalse(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                       "2.2s parked against a 1s COMPUTE budget must not time out")
        XCTAssertTrue(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(b),
                      "…and the human's choice must still route")
    }

    // MARK: - Router: no-match is a failure under `.failNode`

    /// ⚠️ With no rule matching and the policy set to fail, the Router FAILS rather than silently
    /// swallowing the input. The failure is visible in the run instead of the input
    /// vanishing down a catch-all nobody chose.
    ///
    /// ⚠️ Deliberately a NODE failure, not a run-level stop — that would be `stopWorkflow` under a
    /// new name, retired 2026-08-12.
    func testRouter_NoRuleMatches_NodeFails() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .failNode
        let router = scenario.addConditionNode(name: "Router", config: config)
        let arm = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: arm, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("something else entirely")])
        mockProvider.scriptStream(for: scenario.profileID(for: arm)!, events: [.content("handled")])

        let events = try await execute(scenario)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains { $0.nodeID == router }, "the Router must fail, not route silently")
        XCTAssertFalse(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(arm),
                       "no branch is taken")
    }

    /// A failed Router activates its `error` port (WF61), so a recovery branch runs. This is what
    /// makes "no match is a failure" safe rather than a dead end.
    func testRouter_NoRuleMatches_ErrorPortRunsRecovery() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .failNode
        let router = scenario.addConditionNode(name: "Router", config: config)
        let arm = scenario.addBotNode(name: "Urgent Arm")
        let recovery = scenario.addBotNode(name: "Unmatched Handler")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: arm, portLabel: "Urgent")
        scenario.connect(from: router, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("something else entirely")])
        mockProvider.scriptStream(for: scenario.profileID(for: arm)!, events: [.content("handled")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("caught it")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(recovery), "the error port carries the unmatched case")
        XCTAssertFalse(started.contains(arm))
    }

    /// `decisionPolicy = .route` sends unmatched input to a chosen rule's branch.
    func testRouter_NoMatchRoutesToConfiguredDefault() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        let generalRule = ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "generalstuff")
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            generalRule
        ]
        // ⚠️ Stored by the rule's STABLE ID, not its label — renames must not strand the default.
        config.decisionPolicy = .route(ruleID: generalRule.id)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        let general = scenario.addBotNode(name: "General Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")
        scenario.connect(from: router, to: general, portLabel: "General")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("just a normal question")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("urgent")])
        mockProvider.scriptStream(for: scenario.profileID(for: general)!, events: [.content("general")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(general), "unmatched input takes the configured route")
        XCTAssertFalse(started.contains(urgent))
        // ⚠️ NOT `nodeFailedEvents.isEmpty` — the untaken branch is cascade-skipped and a skip is
        // ALSO reported as `.workflowNodeFailed`. Assert about the Router itself.
        XCTAssertFalse(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                       "the Router routed per its policy, so it must not fail")
    }

    /// A new Router asks when it cannot decide, failing if nobody answers — and an absent key
    /// decodes to that same default.
    func testNewConfig_DefaultsToAskWithFailFallback() throws {
        XCTAssertEqual(ConditionNodeConfig().decisionPolicy, .ask(fallback: .failNode))

        var config = ConditionNodeConfig()
        config.decisionPolicy = .endBranch
        let round = try JSONDecoder().decode(ConditionNodeConfig.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(round.decisionPolicy, .endBranch, "a stored policy survives the round trip")

        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(config)) as! [String: Any]
        json.removeValue(forKey: "decisionPolicy")
        let absent = try JSONDecoder().decode(ConditionNodeConfig.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(absent.decisionPolicy, .ask(fallback: .failNode), "an absent key decodes to the default")
    }

    // MARK: - Condition: multi-match arbitration (Ask)

    /// Builds Source → Router(Urgent|Billing) → two arms, where the input matches BOTH rules. The
    /// policy is Ask, failing the node when nobody answers.
    private func ambiguousRouterScenario() -> (WorkflowTestScenario, router: UUID, urgent: UUID, billing: UUID) {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        let billing = scenario.addBotNode(name: "Billing Arm")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")
        scenario.connect(from: router, to: billing, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("URGENT problem with my invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("urgent handled")])
        mockProvider.scriptStream(for: scenario.profileID(for: billing)!, events: [.content("billing handled")])
        return (scenario, router, urgent, billing)
    }

    /// ⚠️ ON BY DEFAULT (user decision 2026-08-13) — a fresh Router asks rather than guessing.
    func testAmbiguity_ArbitrationIsOnByDefault() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()          // untouched — whatever the default is
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        let router = scenario.addConditionNode(name: "Router", config: config)
        let a = scenario.addBotNode(name: "A"), b = scenario.addBotNode(name: "B")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: a, portLabel: "Urgent")
        scenario.connect(from: router, to: b, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("URGENT invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("a")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("b")])

        let events = try await executeWithGate(scenario, choosing: "Billing")
        XCTAssertEqual(WorkflowStreamCollector.gateRequests(from: events).count, 1,
                       "a default Router must ask when its rules overlap")
        XCTAssertTrue(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(b))
    }

    /// ⚠️ NO per-node timeout — `deadline` is nil, so the banner shows no countdown and the wait is
    /// bounded only by the container (Stop, or a scheduled run's deadline).
    func testAmbiguity_RequestCarriesNoDeadline() async throws {
        let (scenario, _, _, _) = ambiguousRouterScenario()
        let events = try await executeWithGate(scenario, choosing: "Urgent")
        for event in events {
            if case .requestGate(_, _, _, let deadline, _, _, _, _) = event {
                XCTAssertNil(deadline, "the arbitration waits indefinitely — a countdown would lie")
            }
        }
    }

    /// The request carries EXACTLY the matched labels — not every rule, and not the fallback.
    /// Offering a non-matching branch would let a human route on a rule the input does not satisfy.
    func testAmbiguity_RequestOffersOnlyTheMatchedRules() async throws {
        let (scenario, _, _, _) = ambiguousRouterScenario()
        let events = try await executeWithGate(scenario, choosing: "Urgent")
        let requests = WorkflowStreamCollector.gateRequests(from: events)

        XCTAssertEqual(requests.count, 1, "one ambiguity, one ask")
        XCTAssertEqual(requests.first?.options, ["Urgent", "Billing"], "matched labels, in rule order")
        // ⚠️ The input travels in `inputText`, NOT in the prompt — the highlight spans are measured
        // against that exact string, so it must be carried verbatim rather than embedded in prose.
        XCTAssertEqual(requests.first?.inputText, "URGENT problem with my invoice")
    }

    /// The human overrides the tiebreak: picking the SECOND matched rule routes there, which is the
    /// entire point — first-match is an authoring artefact, not a decision.
    func testAmbiguity_HumanPicksSecondRule_RoutesThere() async throws {
        let (scenario, _, urgent, billing) = ambiguousRouterScenario()
        let events = try await executeWithGate(scenario, choosing: "Billing")
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(billing), "the chosen branch runs")
        XCTAssertFalse(started.contains(urgent), "…and the first-match branch does NOT")
    }

    /// ⚠️ Unanswered takes the configured 'If nobody can answer' action — here, fail the node —
    /// never a first-match tiebreak (rule order is not a priority).
    func testAmbiguity_Unanswered_TakesTheConfiguredFallback() async throws {
        let (scenario, router, urgent, billing) = ambiguousRouterScenario()
        let events = try await executeWithGate(scenario, choosing: nil)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertFalse(started.contains(urgent), "no first-match tiebreak")
        XCTAssertFalse(started.contains(billing))
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                      "the fallback is fail-the-node")
    }

    /// ⚠️ A stale or mis-indexed answer must not activate a port this run never matched. The
    /// suspension resolves from several surfaces (banner, QuickAccess, and a remote index lookup),
    /// so the executor validates the answer against the matched set rather than trusting it.
    func testAmbiguity_AnswerNotAmongMatches_TakesTheConfiguredFallback() async throws {
        let (scenario, router, urgent, billing) = ambiguousRouterScenario()
        let events = try await executeWithGate(scenario, choosing: "SomeOtherRule")
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertFalse(started.contains(urgent), "an unrecognised answer is treated as unanswered")
        XCTAssertFalse(started.contains(billing))
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router })
    }

    /// Only AMBIGUITY asks. A single match is not a decision anyone needs to make.
    func testSingleMatch_ArbitrationOn_DoesNotAsk() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .ask(fallback: .failNode)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let billing = scenario.addBotNode(name: "Billing Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: billing, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("about my invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: billing)!, events: [.content("handled")])

        // Hang-proof: if a regression made this ask, `execute()` would park forever rather than fail.
        let events = try await executeWithGate(scenario, choosing: nil)
        XCTAssertTrue(WorkflowStreamCollector.gateRequests(from: events).isEmpty,
                      "one rule matched — there is nothing to arbitrate")
        XCTAssertTrue(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(billing))
    }

    // MARK: - Condition: collect-all-matches

    /// A second rule that matches must not be reached when an earlier one already did — and equally
    /// must not suppress it. This is the control for the loop no longer having a `break`.
    func testSingleMatch_UnambiguousRoutingUnchanged() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let router = scenario.addConditionNode(
            name: "Router",
            rules: [
                ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
                ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
            ],
            fallbackLabel: "Billing"
        )
        let urgentArm = scenario.addBotNode(name: "Urgent Arm")
        let billingArm = scenario.addBotNode(name: "Billing Arm")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgentArm, portLabel: "Urgent")
        scenario.connect(from: router, to: billingArm, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("question about my invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgentArm)!, events: [.content("urgent handled")])
        mockProvider.scriptStream(for: scenario.profileID(for: billingArm)!, events: [.content("billing handled")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(billingArm), "only rule 2 matched, so rule 2 routes")
        XCTAssertFalse(started.contains(urgentArm))
    }

    /// ⚠️ The classifier trigger is "no rule matched", NOT `count != 1`. An AMBIGUOUS input is
    /// resolved by the decision policy — invoking a model for it would spend time and GPU, and
    /// (since the classifier can only return a rule label) could not resolve the ambiguity anyway.
    ///
    /// Observable because the classifier is enabled with no MLX model: entering that branch throws
    /// and yields an "AI Classifier failed" thought. Its ABSENCE is the assertion.
    func testAmbiguousInput_DoesNotInvokeTheClassifier() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .failNode
        config.llmFallbackEnabled = true
        config.llmPrompt = "Classify the message."
        // ⚠️ A NIL model is blocked by pre-flight validation (`.error`), so the run would never
        // start. A model name that is not installed passes validation and throws at RUN time —
        // which is exactly the observable "the branch was entered" signal this test needs.
        config.llmModelName = "not-an-installed-model-\(UUID().uuidString.prefix(8))"
        let router = scenario.addConditionNode(name: "Router", config: config)
        let urgentArm = scenario.addBotNode(name: "Urgent Arm")
        let billingArm = scenario.addBotNode(name: "Billing Arm")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgentArm, portLabel: "Urgent")
        scenario.connect(from: router, to: billingArm, portLabel: "Billing")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("URGENT invoice problem")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgentArm)!, events: [.content("handled")])
        mockProvider.scriptStream(for: scenario.profileID(for: billingArm)!, events: [.content("handled")])

        let events = try await execute(scenario)
        let thoughts = WorkflowStreamCollector.thoughtText(from: events)

        XCTAssertFalse(thoughts.contains("AI Classifier failed"),
                       "two rules matched — the classifier must not run. Thoughts: \(thoughts)")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                      "the ambiguity is resolved by the policy (fail), not by the classifier")
        XCTAssertFalse(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(urgentArm))
    }

    /// ⚠️ WF61: a Code node has a wireable `error` port, so a recovery branch can be attached
    /// instead of the whole subtree dying silently. This test covers the two halves that are
    /// actually reachable: the edge VALIDATES, and on a healthy run the error branch stands down.
    ///
    /// ⚠️ WF-TS7 — WHAT THIS TEST DELIBERATELY DOES NOT COVER, and why. The old name was
    /// `testFailedCodeNode_ErrorPortRunsRecoveryBranch`, but a Code node **cannot fail**:
    /// `WorkflowTemplate.render` is non-throwing and leaves an unresolvable placeholder verbatim
    /// in the output, and the `.code` arm of `executeStructuralNode` has no path that assigns
    /// `.failed`. The old body scripted `{{ input.json.missing.deeper }}` expecting a throw, then
    /// discarded the run entirely with `_ = events` — so the "runs recovery branch" half was never
    /// asserted at all, and its one live assertion searched for "doesn't match any output port",
    /// a string that appears nowhere in the app (the validator says "no longer exists",
    /// WorkflowValidation.swift:223) — it could not fail. A Code node's error port firing needs a
    /// production change first; until then this pins what is actually true.
    func testCodeNodeErrorEdge_ValidatesAndStandsDownWhenTheCodeNodeSucceeds() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        // An unresolvable placeholder does NOT throw — it renders verbatim. See the note above.
        let code = scenario.addCodeNode(name: "Transform", template: "{{ input.json.missing.deeper }}")
        let happy = scenario.addBotNode(name: "Happy Path")
        let recovery = scenario.addBotNode(name: "Recovery")

        scenario.connect(from: source, to: code)
        scenario.connect(from: code, to: happy)
        scenario.connect(from: code, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: happy)!, events: [.content("happy")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("recovered")])

        let events = try await execute(scenario)
        let issues = WorkflowValidator.validate(layout: scenario.layout, profileMap: scenario.profileMap)

        // (1) The canvas accepts the wiring — the `error` edge is not reported as stranded.
        XCTAssertFalse(issues.contains { $0.nodeID == code && $0.message.contains("no longer exists") },
                       "an `error` edge from a Code node must validate — got: \(issues.map(\.message))")

        // (2) The run: the Code node completes, the default branch runs, the error branch stands down.
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == code },
                      "a Code node cannot fail — if this ever flips, the docstring above is stale")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty,
                      "nothing failed on this run")
        XCTAssertTrue(started.contains(happy), "the default port carries the success path")
        XCTAssertFalse(started.contains(recovery), "the error handler must NOT run on a healthy run")

        // The side effect is what actually matters — a recovery branch that posts or notifies.
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: recovery)! },
                       "the recovery profile was invoked on a run where nothing failed")

        // …and it is REPORTED as stood-down, not silently absent.
        XCTAssertTrue(WorkflowStreamCollector.nodeSkippedEvents(from: events)
                        .contains { $0.nodeID == recovery && $0.reason == .errorPortNotTaken },
                      "got: \(WorkflowStreamCollector.nodeSkippedEvents(from: events).map(\.reason))")
        XCTAssertFalse(WorkflowStreamCollector.contentText(from: events).contains("recovered"),
                       "the un-run branch's output must not reach the final answer")
    }

    // MARK: - Graph-derived joins (the retired "Fan-in Behavior" setting)

    /// ⚠️ THE case the derived join exists for, and the one the old default got wrong.
    ///
    /// A diamond over a Condition — C routes to one arm, both arms rejoin at M — is the shape a
    /// user builds without thinking. Under the retired `.all` default the merge could NEVER run:
    /// exactly one arm ever fires, so the other's edge is dead on every single run, and nothing
    /// failed to explain it. The arms are mutually exclusive on C, so the dead one is excused.
    func testDiamondOverCondition_MergeRunsOnTheTakenArm() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let router = scenario.addConditionNode(name: "Router")
        let trueArm = scenario.addBotNode(name: "Urgent Handler")
        let falseArm = scenario.addBotNode(name: "Routine Handler")
        let merge = scenario.addBotNode(name: "Formatter")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: trueArm, portLabel: "True")
        scenario.connect(from: router, to: falseArm, portLabel: "False")
        scenario.connect(from: trueArm, to: merge)
        scenario.connect(from: falseArm, to: merge)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("has content")])
        mockProvider.scriptStream(for: scenario.profileID(for: trueArm)!, events: [.content("urgent output")])
        mockProvider.scriptStream(for: scenario.profileID(for: falseArm)!, events: [.content("routine output")])
        mockProvider.scriptStream(for: scenario.profileID(for: merge)!, events: [.content("formatted")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(trueArm), "the matched arm runs")
        XCTAssertFalse(started.contains(falseArm), "the unmatched arm cascade-skips")
        XCTAssertTrue(started.contains(merge), "the merge must run — the dead arm is an unchosen alternative")

        // ⚠️ And it sees ONLY the taken arm. The derived join widens the RUN condition; it never
        // widens the input. A skipped branch contributes nothing.
        let mergeInput = mockProvider.workflowInvocations
            .first { $0.profileID == scenario.profileID(for: merge)! }?.context.input ?? ""
        XCTAssertTrue(mergeInput.contains("urgent output"), "got: \(mergeInput)")
        XCTAssertFalse(mergeInput.contains("routine output"), "the skipped arm must not leak — got: \(mergeInput)")
    }

    /// ⚠️ THE FAIL-SAFE HALF, and it must never be traded away for the convenience above.
    /// Three independent branches with nothing exclusive between them are all REQUIRED. One fails
    /// ⇒ the merge is skipped rather than silently running on partial input.
    func testParallelBranches_OneFails_MergeIsSkipped() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let r1 = scenario.addBotNode(name: "Researcher 1")
        let r2 = scenario.addBotNode(name: "Researcher 2")
        let r3 = scenario.addBotNode(name: "Researcher 3")
        let merge = scenario.addBotNode(name: "Synthesizer")

        for r in [r1, r2, r3] {
            scenario.connect(from: source, to: r)
            scenario.connect(from: r, to: merge)
        }

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("topic")])
        mockProvider.scriptStream(for: scenario.profileID(for: r1)!, events: [.content("finding 1")])
        mockProvider.scriptError(for: scenario.profileID(for: r2)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: r3)!, events: [.content("finding 3")])
        mockProvider.scriptStream(for: scenario.profileID(for: merge)!, events: [.content("synthesis")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertFalse(started.contains(merge),
                       "independent branches are all required — running on 2 of 3 is silent partial output")
        // The healthy siblings still completed; a failure never touches a parallel branch.
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == r3 })
    }

    /// A merge wired to ONE arm of a Condition plus an independent node. The arm has no live
    /// exclusive sibling reaching the merge, so it stays REQUIRED — drawing an edge from a single
    /// port means "run on this outcome", and routing elsewhere must skip.
    /// ⚠️ This is the case that killed my first two formulations of the rule: "excuse any
    /// routed-away branch" would wrongly run this node on the False path.
    func testSingleConditionArmPlusIndependent_SkipsWhenArmNotTaken() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        // isEmpty on non-empty content ⇒ the "True" rule does NOT match ⇒ routes to the fallback.
        let router = scenario.addConditionNode(
            name: "Router",
            rules: [ConditionRule(label: "True", field: .upstreamOutput, op: .isEmpty, value: "")],
            fallbackLabel: "False"
        )
        let independent = scenario.addBotNode(name: "Always Runs")
        let merge = scenario.addBotNode(name: "Merge")

        scenario.connect(from: source, to: router)
        scenario.connect(from: source, to: independent)
        scenario.connect(from: router, to: merge, portLabel: "True")
        scenario.connect(from: independent, to: merge)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("not empty")])
        mockProvider.scriptStream(for: scenario.profileID(for: independent)!, events: [.content("side data")])
        mockProvider.scriptStream(for: scenario.profileID(for: merge)!, events: [.content("merged")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(independent), "the independent branch ran")
        XCTAssertFalse(started.contains(merge),
                       "the condition routed away from the only arm feeding this merge — it must skip")
    }

    /// The finaliser pattern, free: a node wired to A's `error` port AND to a node downstream of
    /// A's default port runs whichever way A went. Those two branches are exclusive on A's own
    /// ports, so each excuses the other.
    func testErrorPortAndSuccessPath_MergeRunsEitherWay() async throws {
        for aFails in [false, true] {
            let scenario = WorkflowTestScenario()
            let risky = scenario.addBotNode(name: "Risky")
            let onSuccess = scenario.addBotNode(name: "Happy Path")
            let finalizer = scenario.addBotNode(name: "Finalizer")

            scenario.connect(from: risky, to: onSuccess)
            scenario.connect(from: onSuccess, to: finalizer)
            scenario.connect(from: risky, to: finalizer, portLabel: "error")

            if aFails {
                mockProvider.scriptError(for: scenario.profileID(for: risky)!, error: NSError(domain: "t", code: 1))
            } else {
                mockProvider.scriptStream(for: scenario.profileID(for: risky)!, events: [.content("ok")])
            }
            mockProvider.scriptStream(for: scenario.profileID(for: onSuccess)!, events: [.content("happy")])
            mockProvider.scriptStream(for: scenario.profileID(for: finalizer)!, events: [.content("done")])

            let events = try await execute(scenario)
            let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
            XCTAssertTrue(started.contains(finalizer),
                          "finalizer must run with risky \(aFails ? "failing" : "succeeding")")
        }
    }

    /// ⚠️ The shape NEITHER retired setting could express: one independent branch plus a mutually
    /// exclusive pair. `.all` never ran (the unchosen arm is always dead); `.any` would have run on
    /// the independent branch alone even with both arms dead. Derived: the pair OR-satisfies itself,
    /// the independent branch stays required.
    func testIndependentPlusExclusivePair_RunsWithBoth() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let router = scenario.addConditionNode(name: "Router")
        let armA = scenario.addBotNode(name: "Arm A")
        let armB = scenario.addBotNode(name: "Arm B")
        let independent = scenario.addBotNode(name: "Context Fetcher")
        let merge = scenario.addBotNode(name: "Merge")

        scenario.connect(from: source, to: router)
        scenario.connect(from: source, to: independent)
        scenario.connect(from: router, to: armA, portLabel: "True")
        scenario.connect(from: router, to: armB, portLabel: "False")
        scenario.connect(from: armA, to: merge)
        scenario.connect(from: armB, to: merge)
        scenario.connect(from: independent, to: merge)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("has content")])
        mockProvider.scriptStream(for: scenario.profileID(for: armA)!, events: [.content("arm A out")])
        mockProvider.scriptStream(for: scenario.profileID(for: armB)!, events: [.content("arm B out")])
        mockProvider.scriptStream(for: scenario.profileID(for: independent)!, events: [.content("context out")])
        mockProvider.scriptStream(for: scenario.profileID(for: merge)!, events: [.content("merged")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(merge), "exclusive pair OR-satisfies; independent branch is live")
        let input = mockProvider.workflowInvocations
            .first { $0.profileID == scenario.profileID(for: merge)! }?.context.input ?? ""
        XCTAssertTrue(input.contains("arm A out"), "got: \(input)")
        XCTAssertTrue(input.contains("context out"), "the independent branch must contribute — got: \(input)")
        XCTAssertFalse(input.contains("arm B out"), "the unchosen arm must not leak — got: \(input)")
    }

    /// ⚠️ The DEEP diamond — the arms are two hops long, so the Condition is no longer the merge's
    /// direct predecessor. Exclusivity has to be inherited transitively through the chain, and a
    /// mutation that stops inheriting ancestry passes every other test in this file.
    ///
    /// Found by mutation-checking: reverting ancestry inheritance in `computePortReach` failed NO
    /// test, because every other diamond here puts the decision one hop from the merge.
    func testDeepDiamondOverCondition_ExclusivityIsInheritedTransitively() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let router = scenario.addConditionNode(name: "Router")
        let urgentClassify = scenario.addBotNode(name: "Urgent Classify")
        let urgentDraft = scenario.addBotNode(name: "Urgent Draft")
        let routineClassify = scenario.addBotNode(name: "Routine Classify")
        let routineDraft = scenario.addBotNode(name: "Routine Draft")
        let merge = scenario.addBotNode(name: "Send")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgentClassify, portLabel: "True")
        scenario.connect(from: router, to: routineClassify, portLabel: "False")
        scenario.connect(from: urgentClassify, to: urgentDraft)
        scenario.connect(from: routineClassify, to: routineDraft)
        scenario.connect(from: urgentDraft, to: merge)
        scenario.connect(from: routineDraft, to: merge)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("has content")])
        for n in [urgentClassify, urgentDraft, routineClassify, routineDraft, merge] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("out")])
        }

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(urgentDraft), "the taken path runs to its end")
        XCTAssertFalse(started.contains(routineDraft), "the untaken path cascade-skips all the way")
        XCTAssertTrue(started.contains(merge),
                      "the merge must still run — the arms are exclusive via an ancestor TWO hops up")
    }

    /// The diamond where the TAKEN arm fails. The exclusive group has no LIVE member, so nothing is
    /// excused and the merge skips. Failure safety needs no separate mechanism — a failed branch
    /// simply is not live.
    func testDiamondOverCondition_TakenArmFails_MergeSkips() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let router = scenario.addConditionNode(name: "Router")
        let trueArm = scenario.addBotNode(name: "Urgent Handler")
        let falseArm = scenario.addBotNode(name: "Routine Handler")
        let merge = scenario.addBotNode(name: "Formatter")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: trueArm, portLabel: "True")
        scenario.connect(from: router, to: falseArm, portLabel: "False")
        scenario.connect(from: trueArm, to: merge)
        scenario.connect(from: falseArm, to: merge)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("has content")])
        mockProvider.scriptError(for: scenario.profileID(for: trueArm)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: falseArm)!, events: [.content("routine output")])
        mockProvider.scriptStream(for: scenario.profileID(for: merge)!, events: [.content("formatted")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(merge), "the chosen path failed — there is nothing to merge")
    }

    func testCascadedSkip_SkippedNodeDownstreamAlsoSkipped() async throws {
        // A(fails)→B→C: B skipped, C should also be skipped
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Root Failure")
        let botB = scenario.addBotNode(name: "Middle")
        let botC = scenario.addBotNode(name: "Leaf")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "t", code: 1))

        let events = try await execute(scenario)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events)
        XCTAssertEqual(failed.count, 1, "only A actually failed")
        XCTAssertEqual(skipped.count, 2, "B and C did not run — that is not a failure")
        XCTAssertTrue(skipped.contains { $0.reason == .upstreamSkipped },
                      "the cascade must be reported as a cascade, got \(skipped.map(\.reason))")
    }

    // =========================================================================
    // MARK: - Group 19: Variable Edge Cases
    // =========================================================================

    func testCondition_ReferencesUndefinedVariable_DefaultsToEmpty() async throws {
        // Condition checks variable "status" that was never written
        let scenario = WorkflowTestScenario()
        let condition = scenario.addConditionNode(
            name: "Check Missing",
            rules: [
                ConditionRule(label: "HasValue", field: .variable, op: .isNotEmpty, value: "", variableName: "nonexistent")
            ],
            fallbackLabel: "Empty"
        )
        let botHas = scenario.addBotNode(name: "Has Value")
        let botEmpty = scenario.addBotNode(name: "Is Empty")

        scenario.connect(from: condition, to: botHas, portLabel: "HasValue")
        scenario.connect(from: condition, to: botEmpty, portLabel: "Empty")

        mockProvider.scriptStream(for: scenario.profileID(for: botHas)!, events: [.content("has")])
        mockProvider.scriptStream(for: scenario.profileID(for: botEmpty)!, events: [.content("empty")])

        let events = try await execute(scenario)

        // Undefined variable = "" → isNotEmpty fails → fallback "Empty"
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botEmpty), "Missing variable should default to empty string")
        XCTAssertFalse(started.contains(botHas))
    }

    func testTwoCodeNodes_SameVariable_LastWriteWins() async throws {
        // Code A writes x="first", Code B writes x="second" (sequential)
        // Condition reads x
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Writer 1", template: "first", outputVariable: "x")
        let codeB = scenario.addCodeNode(name: "Writer 2", template: "second", outputVariable: "x")
        let condition = scenario.addConditionNode(
            name: "Read X",
            rules: [ConditionRule(label: "IsSecond", field: .variable, op: .equals, value: "second", variableName: "x")],
            fallbackLabel: "NotSecond"
        )
        let botYes = scenario.addBotNode(name: "Yes Bot")
        let botNo = scenario.addBotNode(name: "No Bot")

        scenario.connect(from: codeA, to: codeB)
        scenario.connect(from: codeB, to: condition)
        scenario.connect(from: condition, to: botYes, portLabel: "IsSecond")
        scenario.connect(from: condition, to: botNo, portLabel: "NotSecond")

        mockProvider.scriptStream(for: scenario.profileID(for: botYes)!, events: [.content("yes")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNo)!, events: [.content("no")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botYes), "Last write wins — variable x should be 'second'")
    }

    func testCodeNode_VariableSubstitutionOrder_NoInjectionFromVariableValues() async throws {
        // Variable x = "{{ input }}" — when code B reads {{ var.x }},
        // the resolved value "{{ input }}" should NOT be re-scanned
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Set Tricky", template: "{{ input }}", outputVariable: "tricky")
        let botA = scenario.addBotNode(name: "Bot A")
        let codeB = scenario.addCodeNode(name: "Use Tricky", template: "prefix_{{ var.tricky }}_suffix")

        scenario.connect(from: codeA, to: botA)
        scenario.connect(from: botA, to: codeB)

        // codeA with no upstream produces {{ input }} literally since input replacement happens
        // on template "{{ input }}" with empty upstream → empty string
        // Actually codeA has no upstream so {{ input }} = "" → tricky = ""
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("bot output")])

        let events = try await execute(scenario)

        // codeB's template: "prefix_{{ var.tricky }}_suffix"
        // tricky = "" (codeA had no upstream), so codeB outputs "prefix__suffix"
        // Then {{ input }} = "bot output" (codeB's upstream is botA)
        // But we do variable substitution FIRST → "prefix__suffix" → then {{ input }} not in template
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.count >= 3, "All structural + profile nodes should complete")
    }

    // =========================================================================
    // MARK: - Group 20: Cascaded Structural Nodes
    // =========================================================================

    func testCascadedConditions_TwoConditionNodesInChain() async throws {
        // Source → Router1 → Router2 → [Routed: BotA, NotRouted: BotB]
        //
        // A Router always passes content through, so Router2 keys off the actual payload.
        let scenario = WorkflowTestScenario()
        let botSrc = scenario.addBotNode(name: "Source")
        let cond1 = scenario.addConditionNode(
            name: "First Filter",
            rules: [ConditionRule(label: "Pass", field: .upstreamOutput, op: .isNotEmpty, value: "")],
            fallbackLabel: "Fail"
        )
        let cond2 = scenario.addConditionNode(
            name: "Second Filter",
            rules: [ConditionRule(label: "Routed", field: .upstreamOutput, op: .contains, value: "escalate")],
            fallbackLabel: "NotRouted"
        )
        let botRouted = scenario.addBotNode(name: "Routed Handler")
        let botNotRouted = scenario.addBotNode(name: "NotRouted Handler")

        scenario.connect(from: botSrc, to: cond1)
        scenario.connect(from: cond1, to: cond2, portLabel: "Pass")
        scenario.connect(from: cond2, to: botRouted, portLabel: "Routed")
        scenario.connect(from: cond2, to: botNotRouted, portLabel: "NotRouted")

        mockProvider.scriptStream(for: scenario.profileID(for: botSrc)!, events: [.content("please escalate this")])
        mockProvider.scriptStream(for: scenario.profileID(for: botRouted)!, events: [.content("handled!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNotRouted)!, events: [.content("meh")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)

        XCTAssertTrue(started.contains(botRouted), "both routers must chain on the real content")
        XCTAssertFalse(started.contains(botNotRouted))
    }

    /// The content survives a Router unchanged — routing decides WHERE it goes, never WHAT it says.
    func testRouter_AlwaysPassesContentThrough() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Pass", field: .upstreamOutput, op: .isNotEmpty, value: ""),
            ConditionRule(label: "Empty", field: .upstreamOutput, op: .isEmpty, value: "")
        ]
        config.decisionPolicy = .failNode
        let router = scenario.addConditionNode(name: "Router", config: config)
        let sink = scenario.addBotNode(name: "Sink")

        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: sink, portLabel: "Pass")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("the real payload")])
        mockProvider.scriptStream(for: scenario.profileID(for: sink)!, events: [.content("done")])

        _ = try await execute(scenario)

        let sinkInput = mockProvider.workflowInvocations
            .first { $0.profileID == scenario.profileID(for: sink)! }?.context.input ?? ""
        XCTAssertTrue(sinkInput.contains("the real payload"), "content must flow — got: \(sinkInput)")
    }

    func testCodeThenGateThenCondition_ComplexStructuralChain() async throws {
        // Code(transform) → Gate(approve) → Condition(route)
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(name: "Transform", template: "status: approved")
        let gate = scenario.addGateNode(name: "Review")
        let condition = scenario.addConditionNode(
            name: "Route",
            rules: [ConditionRule(label: "Approved", field: .upstreamOutput, op: .contains, value: "approved")],
            fallbackLabel: "Rejected"
        )
        let botApproved = scenario.addBotNode(name: "Approved Bot")
        let botRejected = scenario.addBotNode(name: "Rejected Bot")

        scenario.connect(from: code, to: gate)
        scenario.connect(from: gate, to: condition, portLabel: "Approve")   // gate's "Approve" branch → condition
        scenario.connect(from: condition, to: botApproved, portLabel: "Approved")
        scenario.connect(from: condition, to: botRejected, portLabel: "Rejected")

        mockProvider.scriptStream(for: scenario.profileID(for: botApproved)!, events: [.content("approved!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botRejected)!, events: [.content("rejected!")])

        let events = try await executeWithGate(scenario, choosing: "Approve")

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botApproved), "Full structural chain: Code→Gate(Approve)→Condition→Approved")
        XCTAssertFalse(started.contains(botRejected))
    }

    func testCondition_FallbackNoEdge_DownstreamSkipped() async throws {
        // Condition routes to "Fallback" but no edge exists for that port
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Router",
            rules: [ConditionRule(label: "Match", field: .upstreamOutput, op: .contains, value: "xyz")],
            fallbackLabel: "NoEdge"
        )
        let botMatch = scenario.addBotNode(name: "Match Bot")
        // Only wire the "Match" port — "NoEdge" has no edge

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botMatch, portLabel: "Match")

        // A output doesn't contain "xyz" → fallback "NoEdge" activates → no edge for it
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("no match here")])
        mockProvider.scriptStream(for: scenario.profileID(for: botMatch)!, events: [.content("matched")])

        let events = try await execute(scenario)

        // Match bot should NOT execute (wrong port), condition routes to NoEdge which has no target
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botMatch), "Match bot should not fire when fallback port is active")
    }

    // =========================================================================
    // MARK: - Group 21: Terminal Synthesis Edge Cases
    // =========================================================================

    /// A → B(fails), A → C(succeeds): both are terminals, so the final answer is LABELED and
    /// carries both — the working half AND why the other half didn't.
    ///
    /// This previously asserted `content == "good result"`: the failing terminal contributed
    /// nothing and, with several terminals, you could not tell which node produced which text.
    /// Changed deliberately on 2026-08-12.
    func testMultipleTerminals_LabeledOutputCarriesSuccessAndFailure() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing Terminal")
        let botC = scenario.addBotNode(name: "Good Terminal")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("good result")])

        let events = try await execute(scenario)
        let content = StreamCollector.contentText(from: events)

        XCTAssertTrue(content.contains("## Good Terminal"), "each terminal must be attributed — got: \(content)")
        XCTAssertTrue(content.contains("good result"), "the working half must survive")
        XCTAssertTrue(content.contains("## Failing Terminal"), "the failed terminal must appear, not vanish")
        XCTAssertTrue(content.contains("**Failed:**"), "…with its reason, so the gap is explained")

        // A parallel failure must not have cancelled the healthy branch.
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == botC })
    }

    /// ⚠️ REGRESSION PIN for the 2026-08-12 design decision: a failure in one parallel branch must
    /// NOT cancel its siblings. Parallel branches are independent by construction — nothing
    /// connects them — so a sibling's work stays valid and its output still belongs in the answer.
    /// Aborting them destroyed usable results to save tokens.
    ///
    /// The earlier version of this pin could not see the regression: both branches finished
    /// instantly, so `group.cancelAll()` arrived after the healthy node was already done and the
    /// assertions passed with cross-branch abort fully reinstated. The slow branch is what makes
    /// the abort observable — it is still mid-flight when the sibling fails.
    func testParallelFailure_DoesNotCancelSlowSiblingBranch() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let failFast = scenario.addBotNode(name: "Fails Fast")
        let slowButFine = scenario.addBotNode(name: "Slow Survivor")

        scenario.connect(from: source, to: failFast)
        scenario.connect(from: source, to: slowButFine)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: failFast)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptDelayedStream(for: scenario.profileID(for: slowButFine)!,
                                         events: [.content("slow but valuable")], milliseconds: 300)

        let events = try await execute(scenario)
        let content = StreamCollector.contentText(from: events)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == slowButFine },
                      "the slow sibling must run to completion despite the fast failure")
        XCTAssertTrue(content.contains("slow but valuable"),
                      "…and its output must reach the final answer — got: \(content)")
    }

    /// The control: a SINGLE terminal stays bare. The common one-answer case must not grow a
    /// heading it never had.
    func testSingleTerminal_OutputStaysUnlabeled() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Only Terminal")
        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("the answer")])

        let events = try await execute(scenario)

        XCTAssertEqual(StreamCollector.contentText(from: events), "the answer")
    }

    func testTerminalNode_EmptyOutput_NotInFinalContent() async throws {
        // Terminal produces empty output — should not add blank content
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Empty Bot")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: []) // Empty output

        let events = try await execute(scenario)

        // No .content event since output is empty
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.isEmpty, "Empty terminal output should not yield .content event")
    }

    func testMultipleTerminals_OutputsConcatenated() async throws {
        // Disconnected: A, B both terminals — outputs joined with \n\n
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("result-A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("result-B")])

        let events = try await execute(scenario)

        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("result-A"), "Should contain A's output")
        XCTAssertTrue(content.contains("result-B"), "Should contain B's output")
    }

    // =========================================================================
    // MARK: - Group 22: Boundary Conditions
    // =========================================================================

    func testEmptyUserInput_StillExecutes() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("response")])

        let events = try await execute(scenario, userInput: "")

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.count, 1, "Should execute even with empty user input")
    }

    /// ⚠️ INVERTED 2026-08-13 (user decision): a workflow passes upstream output through in FULL.
    /// This test previously asserted that a 25,000-char upstream reached the next node cut to
    /// ~6,000 with a truncation marker — the silent information loss the change removes. Fitting the
    /// input is now a function of which model the downstream node runs.
    ///
    /// ⚠️ The trade is real and deliberate: a node's input is unbounded, so a small local model
    /// downstream of a verbose upstream will fail at the provider on context length rather than
    /// receive a shortened prompt.
    func testLargeUpstreamContext_PassedThroughInFull() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Verbose Bot")
        let botB = scenario.addBotNode(name: "Receiver Bot")

        scenario.connect(from: botA, to: botB)

        let largeOutput = String(repeating: "word ", count: 5000) // ~25,000 chars
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content(largeOutput)])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("done")])

        let events = try await execute(scenario)
        _ = events

        let bPid = scenario.profileID(for: botB)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!

        XCTAssertTrue(bInv.userInput.contains(largeOutput),
                      "the full 25K upstream output must reach the downstream node")
        XCTAssertFalse(bInv.userInput.contains("truncated"),
                       "no truncation marker may be injected")
    }

    func testProgressEvents_MonotonicallyIncreasing() async throws {
        let scenario = WorkflowTestScenario()
        let n1 = scenario.addBotNode(name: "N1")
        let n2 = scenario.addBotNode(name: "N2")
        let n3 = scenario.addBotNode(name: "N3")

        scenario.connect(from: n1, to: n2)
        scenario.connect(from: n2, to: n3)

        for n in [n1, n2, n3] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("ok")])
        }

        let events = try await execute(scenario)

        let progress = WorkflowStreamCollector.progressEvents(from: events)
        // Progress completed counts should be monotonically increasing
        var prevCompleted = 0
        for p in progress {
            XCTAssertGreaterThanOrEqual(p.completed, prevCompleted, "Progress should be monotonically increasing")
            prevCompleted = p.completed
        }
        XCTAssertEqual(progress.last?.completed, 3, "Final progress should show all 3 completed")
        XCTAssertEqual(progress.last?.total, 3)
    }

    // =========================================================================
    // MARK: - Group 23: WorkflowLayout Algorithm Tests
    // =========================================================================

    func testTopologicalSort_SingleNodeNoEdges() {
        let nodeID = UUID()
        let layout = WorkflowLayout(
            nodes: [WorkflowNode(id: nodeID, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "Solo")],
            edges: []
        )
        let sorted = layout.topologicalSort()
        XCTAssertEqual(sorted, [nodeID])
    }

    func testTopologicalSort_LinearChain() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = WorkflowLayout(
            nodes: [
                WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A"),
                WorkflowNode(id: b, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "B"),
                WorkflowNode(id: c, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "C")
            ],
            edges: [
                WorkflowEdge(sourceNodeID: a, targetNodeID: b),
                WorkflowEdge(sourceNodeID: b, targetNodeID: c)
            ]
        )
        let sorted = layout.topologicalSort()
        XCTAssertEqual(sorted, [a, b, c])
    }

    func testComputeExecutionLevels_DiamondGraph() {
        // A → B, A → C, B → D, C → D
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let layout = WorkflowLayout(
            nodes: [
                WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A"),
                WorkflowNode(id: b, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "B"),
                WorkflowNode(id: c, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "C"),
                WorkflowNode(id: d, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "D")
            ],
            edges: [
                WorkflowEdge(sourceNodeID: a, targetNodeID: b),
                WorkflowEdge(sourceNodeID: a, targetNodeID: c),
                WorkflowEdge(sourceNodeID: b, targetNodeID: d),
                WorkflowEdge(sourceNodeID: c, targetNodeID: d)
            ]
        )
        let levels = layout.computeExecutionLevels()!
        XCTAssertEqual(levels.count, 3, "Diamond graph should have 3 levels")
        XCTAssertEqual(levels[0], [a], "Level 0: entry node A")
        XCTAssertEqual(Set(levels[1]), Set([b, c]), "Level 1: B and C (parallel)")
        XCTAssertEqual(levels[2], [d], "Level 2: D (depends on both B and C)")
    }

    func testWouldCreateCycle_SelfLoop() {
        let a = UUID()
        let layout = WorkflowLayout(
            nodes: [WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A")],
            edges: []
        )
        XCTAssertTrue(layout.wouldCreateCycle(source: a, target: a), "Self-loop should be detected as cycle")
    }

    func testEdgesReferenceNonExistentNode_SilentlyIgnored() {
        // Edge references node not in layout — computeExecutionLevels should handle gracefully
        let a = UUID(), b = UUID(), phantom = UUID()
        let layout = WorkflowLayout(
            nodes: [
                WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A"),
                WorkflowNode(id: b, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "B")
            ],
            edges: [
                WorkflowEdge(sourceNodeID: a, targetNodeID: b),
                WorkflowEdge(sourceNodeID: a, targetNodeID: phantom) // phantom not in nodes
            ]
        )
        let levels = layout.computeExecutionLevels()
        XCTAssertNotNil(levels, "Should not crash on phantom node edge")
        XCTAssertEqual(levels?.flatMap({ $0 }).count, 2, "Only real nodes in levels")
    }

    // =========================================================================
    // MARK: - Group 24: shared inner-workflow helper
    // (The Loop node tests that lived here were deleted with the Loop node, 2026-08-15.)
    // =========================================================================

    /// Helper: creates an inner workflow with a single bot, saves it, registers profiles.
    private func makeInnerBotWorkflow(
        botName: String,
        scenario: WorkflowTestScenario
    ) -> (innerWorkflowID: UUID, innerBotNodeID: UUID) {
        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: botName)
        inner.save()
        innerBuilders.append(inner)

        // Merge inner profiles into outer scenario
        for (id, profile) in inner.profileMap {
            scenario.profileMap[id] = profile
        }

        return (inner.workflowProfileID, innerBot)
    }
    // MARK: - Group 25: Parallel Execution
    // =========================================================================

    /// ⚠️ WF-TS12: renamed from `testParallel_TwoBotsExecuteConcurrently`. It never asserted
    /// concurrency — `.events` scripts never suspend, so "B and C both completed" holds just as
    /// well under a sequential executor. The name is why the real gap went unnoticed for so long;
    /// `testParallel_SiblingSpansOverlap_NotSequential` below is the test that can tell them apart.
    func testParallel_BothSiblingsReceiveUpstreamAndComplete() async throws {
        // A → B, A → C; B and C at same level (parallel)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Parallel-B")
        let botC = scenario.addBotNode(name: "Parallel-C")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("shared input")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B result")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C result")])

        let events = try await execute(scenario)

        // Both B and C should execute
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botB), "Parallel node B should complete")
        XCTAssertTrue(completed.contains(botC), "Parallel node C should complete")

        // Both receive A's context
        let bPid = scenario.profileID(for: botB)!
        let cPid = scenario.profileID(for: botC)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        let cInv = mockProvider.invocations.first(where: { $0.profileID == cPid })!
        XCTAssertTrue(bInv.userInput.contains("shared input"), "B should receive A's output")
        XCTAssertTrue(cInv.userInput.contains("shared input"), "C should receive A's output")

        // Both are terminal nodes — outputs concatenated
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("B result"), "Final content should include B")
        XCTAssertTrue(content.contains("C result"), "Final content should include C")
    }

    /// ⚠️ WF-TS12: the ONLY test in this group that can tell parallel level dispatch from
    /// sequential. Every other Group 25 test passes against a sequential executor too, because
    /// `.events` scripts never suspend. Here each sibling sleeps 400 ms and the assertion is that
    /// their execution spans INTERSECT — something sequential dispatch cannot produce, since C's
    /// provider would not be called until B's stream had finished.
    ///
    /// Threshold-free by construction: both spans are measured under the same load, so a slow or
    /// loaded machine shifts them together rather than turning the test red. The spans are stamped
    /// inside the producer (`MockWorkflowStreamProvider.InvocationSpan`) precisely so consumer-side
    /// buffering can't manufacture a false overlap.
    func testParallel_SiblingSpansOverlap_NotSequential() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let slowB = scenario.addBotNode(name: "Slow-B")
        let slowC = scenario.addBotNode(name: "Slow-C")
        scenario.connect(from: source, to: slowB)
        scenario.connect(from: source, to: slowC)

        let bPid = scenario.profileID(for: slowB)!
        let cPid = scenario.profileID(for: slowC)!
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("go")])
        mockProvider.scriptDelayedStream(for: bPid, events: [.content("B done")], milliseconds: 400)
        mockProvider.scriptDelayedStream(for: cPid, events: [.content("C done")], milliseconds: 400)

        let events = try await execute(scenario)

        // Both really ran — otherwise a missing span would read as "no overlap" for the wrong reason.
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(slowB), "B must complete")
        XCTAssertTrue(completed.contains(slowC), "C must complete")

        let spans = mockProvider.spans
        let b = try XCTUnwrap(spans.first(where: { $0.profileID == bPid }), "no span recorded for B")
        let c = try XCTUnwrap(spans.first(where: { $0.profileID == cPid }), "no span recorded for C")

        XCTAssertTrue(b.start < c.end && c.start < b.end,
                      "same-level siblings ran back-to-back, not in parallel — B \(b.start)…\(b.end), C \(c.start)…\(c.end)")
    }

    // MARK: - WF-CC2: MLX-aware lane dispatch
    //
    // ⚠️ `MLXService` keeps exactly ONE model container resident. `loadModel` calls
    // `performUnload()` before loading a DIFFERENT directory (MLXService.swift:246) but
    // EARLY-RETURNS for the one already resident (:215-219). So two same-level nodes on different
    // MLX models evict each other on every generation call — i.e. every ReAct iteration, since
    // `container(expecting:)` is consulted per generation — each eviction re-reading multi-GB of
    // weights, and `container(expecting:)` throws `modelIdentityMismatch` after two attempts.
    //
    // ⚠️ These tests are HERMETIC. `apiProvider` on the scenario's profiles is inert for
    // execution — `MockWorkflowStreamProvider` keys on `profile.id` and never reads `details` — so
    // `.mlx` here reaches the dispatch decision and nothing else. No MLXService, no model, no disk.

    /// The headline: two same-level siblings on DIFFERENT MLX models must NOT overlap.
    ///
    /// ⚠️ This test was written and confirmed RED against HEAD before the lane split existed. If it
    /// ever passes without the split, the premise is wrong and the whole change needs re-deriving.
    func testParallel_TwoDifferentMLXModels_Serialize() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let deep = scenario.addBotNode(name: "Deep", apiProvider: .mlx, modelName: "qwen3-8b")
        let fast = scenario.addBotNode(name: "Fast", apiProvider: .mlx, modelName: "llama3-3b")
        scenario.connect(from: source, to: deep)
        scenario.connect(from: source, to: fast)

        let dPid = scenario.profileID(for: deep)!
        let fPid = scenario.profileID(for: fast)!
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("go")])
        mockProvider.scriptDelayedStream(for: dPid, events: [.content("deep done")], milliseconds: 250)
        mockProvider.scriptDelayedStream(for: fPid, events: [.content("fast done")], milliseconds: 250)

        let events = try await execute(scenario)

        // Serializing must not cost anyone their work — both still run, both still land.
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(deep), "Deep must complete")
        XCTAssertTrue(completed.contains(fast), "Fast must complete")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty, "a lane split must fail nothing")
        let content = WorkflowStreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("deep done") && content.contains("fast done"),
                      "both terminals' output must still reach the final answer")

        let spans = mockProvider.spans
        XCTAssertEqual(spans.count, 2, "both providers must have been invoked exactly once")
        let d = try XCTUnwrap(spans.first(where: { $0.profileID == dPid }), "no span for Deep")
        let f = try XCTUnwrap(spans.first(where: { $0.profileID == fPid }), "no span for Fast")

        XCTAssertFalse(d.start < f.end && f.start < d.end,
                       "two DIFFERENT MLX models ran CONCURRENTLY against a single global model container — they will evict each other's weights on every generation call. Deep \(d.start)…\(d.end), Fast \(f.start)…\(f.end)")
    }

    /// ⚠️ THE OVER-SERIALIZATION GUARD, and the reason the split is per-model rather than
    /// per-level. A "any MLX node ⇒ run this level sequentially" implementation would pass the
    /// test above and every other test in this file — and quietly destroy cloud parallelism. Only
    /// this test fails under that mutation.
    func testParallel_CloudSiblingStillOverlaps_MLXLaneIsNotALevelLock() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let deep = scenario.addBotNode(name: "Deep", apiProvider: .mlx, modelName: "qwen3-8b")
        let fast = scenario.addBotNode(name: "Fast", apiProvider: .mlx, modelName: "llama3-3b")
        let cloud = scenario.addBotNode(name: "Cloud", apiProvider: .anthropic, modelName: "claude")
        scenario.connect(from: source, to: deep)
        scenario.connect(from: source, to: fast)
        scenario.connect(from: source, to: cloud)

        let dPid = scenario.profileID(for: deep)!
        let fPid = scenario.profileID(for: fast)!
        let cPid = scenario.profileID(for: cloud)!
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("go")])
        mockProvider.scriptDelayedStream(for: dPid, events: [.content("deep")], milliseconds: 150)
        mockProvider.scriptDelayedStream(for: fPid, events: [.content("fast")], milliseconds: 150)
        // Long enough to still be running while the MLX lanes hand over.
        mockProvider.scriptDelayedStream(for: cPid, events: [.content("cloud")], milliseconds: 600)

        let events = try await execute(scenario)
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty)

        let spans = mockProvider.spans
        let d = try XCTUnwrap(spans.first(where: { $0.profileID == dPid }))
        let f = try XCTUnwrap(spans.first(where: { $0.profileID == fPid }))
        let c = try XCTUnwrap(spans.first(where: { $0.profileID == cPid }))

        XCTAssertFalse(d.start < f.end && f.start < d.end, "the two MLX models must still be serialized")
        XCTAssertTrue((c.start < d.end && d.start < c.end) || (c.start < f.end && f.start < c.end),
                      "the cloud node must still overlap real work — the MLX split is a per-model lane, NOT a level-wide lock. Cloud \(c.start)…\(c.end), Deep \(d.start)…\(d.end), Fast \(f.start)…\(f.end)")
    }

    /// ⚠️ DECISION D6 (owner, 2026-10-07, local inference coordinator) REVERSED this test. Two
    /// siblings on the SAME MLX model used to be pinned as overlapping ("they share one container").
    /// They now run one after another: the weights are shared, but each concurrent decode carries its
    /// own KV cache, mlx-swift-lm has no batched generation (two decodes each run at about half speed),
    /// and concurrent decode on one container was never verified on device. Integration-level twin of
    /// `WorkflowMLXDispatchLaneTests.testOneMLXModel_OneLanePerNode`.
    func testParallel_SameMLXModel_RunsSerially() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let a = scenario.addBotNode(name: "A", apiProvider: .mlx, modelName: "qwen3-8b")
        let b = scenario.addBotNode(name: "B", apiProvider: .mlx, modelName: "qwen3-8b")
        scenario.connect(from: source, to: a)
        scenario.connect(from: source, to: b)

        let aPid = scenario.profileID(for: a)!
        let bPid = scenario.profileID(for: b)!
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("go")])
        mockProvider.scriptDelayedStream(for: aPid, events: [.content("a")], milliseconds: 250)
        mockProvider.scriptDelayedStream(for: bPid, events: [.content("b")], milliseconds: 250)

        _ = try await execute(scenario)

        let spans = mockProvider.spans
        let sa = try XCTUnwrap(spans.first(where: { $0.profileID == aPid }))
        let sb = try XCTUnwrap(spans.first(where: { $0.profileID == bPid }))
        XCTAssertFalse(sa.start < sb.end && sb.start < sa.end,
                       "same-model MLX siblings must run one after another (D6) — A \(sa.start)…\(sa.end), B \(sb.start)…\(sb.end)")
    }

    func testParallel_ThreeBotsWithFanIn() async throws {
        // A → (B, C, D) → E
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Worker-B")
        let botC = scenario.addBotNode(name: "Worker-C")
        let botD = scenario.addBotNode(name: "Worker-D")
        let botE = scenario.addBotNode(name: "Aggregator")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)
        scenario.connect(from: botB, to: botE)
        scenario.connect(from: botC, to: botE)
        scenario.connect(from: botD, to: botE)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("query")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from-B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("from-C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("from-D")])
        mockProvider.scriptStream(for: scenario.profileID(for: botE)!, events: [.content("aggregated")])

        let events = try await execute(scenario)

        // All 5 nodes complete
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // E receives context from B, C, and D
        let ePid = scenario.profileID(for: botE)!
        let eInv = mockProvider.invocations.first(where: { $0.profileID == ePid })!
        XCTAssertTrue(eInv.userInput.contains("from-B"), "Aggregator should see B's output")
        XCTAssertTrue(eInv.userInput.contains("from-C"), "Aggregator should see C's output")
        XCTAssertTrue(eInv.userInput.contains("from-D"), "Aggregator should see D's output")

        // Only terminal E in final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "aggregated")
    }

    /// A failure never cancels a parallel branch (design decision 2026-08-12). C completes; D is
    /// blocked only because its own upstream B died, not by any policy.
    func testParallel_OneFails_SiblingCompletes_DependentSkips() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing-B")
        let botC = scenario.addBotNode(name: "Healthy-C")
        let botD = scenario.addBotNode(name: "Next-Level-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == botC },
                      "the parallel branch is independent and must keep its result")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == botB })
        XCTAssertFalse(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(botD),
                       "D is downstream of B with no error edge")
    }


    func testParallel_OneFailsDefault_SharedDownstreamSkipped() async throws {
        // A → (B, C) → D; B fails with default skipDependents
        // D depends on BOTH B and C (allSatisfy) → D skipped
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing-B")
        let botC = scenario.addBotNode(name: "Healthy-C")
        let botD = scenario.addBotNode(name: "Downstream-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botD)
        scenario.connect(from: botC, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        // C completes, B fails, D skipped (allSatisfy requires both parents)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botC), "Healthy-C should complete")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botB }), "B should fail")
        XCTAssertTrue(skipped.contains(where: { $0.nodeID == botD }), "D should be SKIPPED (upstream B failed)")
    }

    func testParallel_StructuralBeforeProfile() async throws {
        // Level 1 has: Code node (structural) + 2 Bot nodes (profile)
        // Code runs FIRST, then bots run in parallel seeing the variable
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Entry")
        let code = scenario.addCodeNode(name: "Set Config", template: "strict_mode", outputVariable: "mode")
        let botB = scenario.addBotNode(name: "Worker-B")
        let botC = scenario.addBotNode(name: "Worker-C")

        // All three depend on A → same level
        scenario.connect(from: botA, to: code)
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)

        // Code node also feeds into a downstream condition to verify variable was set
        let condition = scenario.addConditionNode(
            name: "Mode Check",
            rules: [ConditionRule(label: "Strict", field: .variable, op: .equals, value: "strict_mode", variableName: "mode")],
            fallbackLabel: "Relaxed"
        )
        let botStrict = scenario.addBotNode(name: "Strict Bot")

        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botStrict, portLabel: "Strict")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("init")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B done")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C done")])
        mockProvider.scriptStream(for: scenario.profileID(for: botStrict)!, events: [.content("strict!")])

        let events = try await execute(scenario)

        // Code runs first (structural), then B and C run in parallel
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(code), "Code node should complete")
        XCTAssertTrue(completed.contains(botB), "Worker-B should complete")
        XCTAssertTrue(completed.contains(botC), "Worker-C should complete")

        // Condition node reads variable set by Code node → routes to Strict
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botStrict), "Strict bot should execute (variable set by Code before bots)")
    }

    func testParallel_ErrorPortActivation_OnlyFailedNode() async throws {
        // A → (B, C); B fails → ErrorHandler-B; C succeeds → NormalHandler-C
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing-B")
        let botC = scenario.addBotNode(name: "Healthy-C")
        let errorHandler = scenario.addBotNode(name: "Error-Handler")
        let normalHandler = scenario.addBotNode(name: "Normal-Handler")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: errorHandler, portLabel: "error")
        scenario.connect(from: botC, to: normalHandler)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: errorHandler)!, events: [.content("handled error")])
        mockProvider.scriptStream(for: scenario.profileID(for: normalHandler)!, events: [.content("normal")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        // Error handler activates for B's failure
        XCTAssertTrue(started.contains(errorHandler), "Error handler should execute for B's failure")
        // Normal handler activates for C's success
        XCTAssertTrue(started.contains(normalHandler), "Normal handler should execute for C's success")
    }

    func testParallel_ProgressEventsComplete() async throws {
        // A → (B, C, D); 4 nodes total, progress should reach 4/4
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "P-B")
        let botC = scenario.addBotNode(name: "P-C")
        let botD = scenario.addBotNode(name: "P-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("go")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("D")])

        let events = try await execute(scenario)

        let progress = WorkflowStreamCollector.progressEvents(from: events)

        // Should have 4 progress events (one per node)
        XCTAssertEqual(progress.count, 4, "Should have 4 progress events")

        // All should report total = 4
        XCTAssertTrue(progress.allSatisfy { $0.total == 4 }, "All progress events should report total = 4")

        // Final progress should show 4/4
        XCTAssertEqual(progress.last?.completed, 4, "Final progress should be 4/4")

        // Completed counts should be monotonically increasing
        var prev = 0
        for p in progress {
            XCTAssertGreaterThan(p.completed, prev, "Progress completed should increase monotonically")
            prev = p.completed
        }
    }

    func testParallel_SnapshotIsolation_NodesDoNotSeeEachOther() async throws {
        // A and B are both entry nodes (no upstream) → same level, parallel
        // C depends on both → next level, sees both outputs
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Entry-A")
        let botB = scenario.addBotNode(name: "Entry-B")
        let botC = scenario.addBotNode(name: "Merger")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A-output")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B-output")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("merged")])

        let events = try await execute(scenario)

        // A and B are at Level 0 (parallel entries), C at Level 1
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botA))
        XCTAssertTrue(completed.contains(botB))
        XCTAssertTrue(completed.contains(botC))

        // A should NOT see B's output (snapshot isolation — they're parallel)
        let aPid = scenario.profileID(for: botA)!
        let aInv = mockProvider.invocations.first(where: { $0.profileID == aPid })!
        XCTAssertFalse(aInv.userInput.contains("B-output"), "A should NOT see B's output (parallel isolation)")

        // B should NOT see A's output
        let bPid = scenario.profileID(for: botB)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        XCTAssertFalse(bInv.userInput.contains("A-output"), "B should NOT see A's output (parallel isolation)")

        // C should see BOTH (next level, after both complete)
        let cPid = scenario.profileID(for: botC)!
        let cInv = mockProvider.invocations.first(where: { $0.profileID == cPid })!
        XCTAssertTrue(cInv.userInput.contains("A-output"), "Merger should see A's output")
        XCTAssertTrue(cInv.userInput.contains("B-output"), "Merger should see B's output")
    }

    // =========================================================================
    // MARK: - Group 26: Parallel Edge Cases
    // =========================================================================

    func testParallel_AllNodesFail_AllFailuresReported() async throws {
        // A → (B, C, D); all three fail simultaneously
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Fail-B")
        let botC = scenario.addBotNode(name: "Fail-C")
        let botD = scenario.addBotNode(name: "Fail-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptError(for: scenario.profileID(for: botC)!, error: NSError(domain: "t", code: 2))
        mockProvider.scriptError(for: scenario.profileID(for: botD)!, error: NSError(domain: "t", code: 3))

        let events = try await execute(scenario)

        // All three failures should be reported individually
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let failedIDs = Set(failed.map(\.nodeID))
        XCTAssertTrue(failedIDs.contains(botB), "B failure should be reported")
        XCTAssertTrue(failedIDs.contains(botC), "C failure should be reported")
        XCTAssertTrue(failedIDs.contains(botD), "D failure should be reported")

        // All terminals failed → error message
        let errors = events.compactMap { e -> String? in
            if case .error(let err) = e { return err.message }
            return nil
        }
        XCTAssertTrue(errors.contains(where: { $0.contains("The workflow failed.") }),
                       "Should report the run as failed")
        for name in ["Fail-B", "Fail-C", "Fail-D"] {
            XCTAssertTrue(errors.contains(where: { $0.contains(name) }),
                          "every failing node must be named, missing \(name)")
        }

        // Progress should still reach 4/4 (A completed + B,C,D failed = 4 processed)
        let progress = WorkflowStreamCollector.progressEvents(from: events)
        XCTAssertEqual(progress.last?.completed, 4)
    }

    /// Two parallel failures, no policies: the shared dependent skips (both branches dead), and
    /// both failures are reported. Nothing "wins" — the graph decides.
    func testParallel_BothBranchesFail_DependentSkips() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Fails-B")
        let botC = scenario.addBotNode(name: "Fails-C")
        let botD = scenario.addBotNode(name: "Next-Level-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botD)
        scenario.connect(from: botC, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptError(for: scenario.profileID(for: botC)!, error: NSError(domain: "t", code: 2))
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        XCTAssertFalse(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID).contains(botD))
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(failed.contains(botB))
        XCTAssertTrue(failed.contains(botC), "both failures are reported — neither cancels the other")
    }


    func testParallel_SingleProfileNode_UsesDirectPath() async throws {
        // A → B: Level 1 has exactly 1 profile node → uses if-branch (no TaskGroup)
        // Verify behavior is identical to parallel path
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Single-B")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("input")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B output")])

        let events = try await execute(scenario)

        // B executes, receives A's context, is terminal
        let bPid = scenario.profileID(for: botB)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        XCTAssertTrue(bInv.userInput.contains("input"), "Single-path B should receive A's context")

        // B failure activates error port (same as parallel path)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botB }))

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "B output")
    }

    // =========================================================================
    // MARK: - Group 26: Sub-Workflow Nodes (WF2) and body profile resolution (WF1)
    // =========================================================================

    /// A node backed by a workflow profile runs that workflow's canvas and hands its output on.
    ///
    /// Before the fix this node type could not run at all: the dispatch loop sent it down the
    /// agent path, whose `case .workflow, .imageGen` arm yields an error and finishes, and because
    /// no `.executionFinished` followed, the default `.completed` stuck — the node went GREEN with
    /// empty output and the downstream node ran on nothing.
    func testSubWorkflowNode_RunsChildWorkflow_AndPassesOutputDownstream() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Nested Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let subWorkflow = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: subWorkflow, to: consumer)

        let innerPid = inner.profileID(for: innerBot)!
        mockProvider.scriptStream(for: innerPid, events: [.content("NESTED RESULT")])
        let consumerPid = scenario.profileID(for: consumer)!
        mockProvider.scriptStream(for: consumerPid, events: [.content("consumer output")])

        let events = try await execute(scenario)

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        let subResult = completed.first(where: { $0.nodeID == subWorkflow })
        XCTAssertNotNil(subResult, "The sub-workflow node must complete, not be skipped")
        XCTAssertEqual(subResult?.summary, "NESTED RESULT",
                       "The node's output must be the child workflow's output, not empty")

        XCTAssertTrue(completed.contains(where: { $0.nodeID == consumer }),
                      "The downstream node must run")
        let consumerInvocation = mockProvider.invocations.first(where: { $0.profileID == consumerPid })
        XCTAssertNotNil(consumerInvocation)
        XCTAssertTrue(consumerInvocation?.userInput.contains("NESTED RESULT") == true,
                      "The child's output must reach the downstream node's input — got: \(consumerInvocation?.userInput ?? "<none>")")
    }

    /// ⚠️ A GATE INSIDE A SUB-WORKFLOW BODY must reach the outer stream and, once answered, let the
    /// child continue. The FOUR HITL forwards in the sub-workflow arm (`requestConfirmation` /
    /// `requestGate` / `requestClarification` / `requestPlanReview`, each keeping the INNER node's
    /// id) are the only thing standing between a suspending inner node and the `default:`
    /// suppression arm — and a swallowed suspending event is a PERMANENT hang: no banner, nobody to
    /// answer, and the compute clock excludes parked time so not even the node timeout fires.
    ///
    /// ⚠️ This comment said "three" until 2026-08-19, and that count WAS the bug: `requestPlanReview`
    /// was the missing fourth. Pinned by `testPlanReviewInsideSubWorkflowBody…` below. If a fifth
    /// suspending event kind is ever added, it needs a forward here and a test beside that one.
    ///
    /// ⚠️ This pin previously lived in `LoopHITLForwardingTests` (a source scan over the loop arm)
    /// and was deleted with the Loop node (2026-08-15). This is its behavioural replacement, on the
    /// surviving forwarder: it drives the REAL child executor (the inner layout is saved and loaded
    /// from `WorkflowLayoutStore`), so a regression that drops `.requestGate` into `default:` is
    /// caught by the assertions below — see the gate-timeout note inside for why a swallowed event
    /// fails fast here instead of hanging.
    func testGateInsideSubWorkflowBody_ReachesTheOuterStream_AndTheRunCompletes() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Prep Bot")
        // ⚠️ The 5s timeout is the test's OWN safety net, not part of the behaviour under test: with
        // an indefinite gate, a forwarder regression would HANG this test forever rather than fail
        // it (the harness answers the gate only when it SEES the event on the outer stream). With
        // the timeout, a swallowed event times the gate out in 5s and the assertions below fail
        // loudly. On the healthy path the harness answers within ~50ms, so the timeout never fires.
        let innerGate = inner.addGateNode(name: "Inner Approval", options: ["Go", "Stop"], timeout: 5)
        let innerAfter = inner.addBotNode(name: "After Gate")
        inner.connect(from: innerBot, to: innerGate)
        inner.connect(from: innerGate, to: innerAfter, portLabel: "Go")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let subWorkflow = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: subWorkflow, to: consumer)

        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [.content("prepped")])
        mockProvider.scriptStream(for: inner.profileID(for: innerAfter)!, events: [.content("APPROVED RESULT")])
        mockProvider.scriptStream(for: scenario.profileID(for: consumer)!, events: [.content("done")])

        // Answer the inner gate with "Go" — through the same suspension service the banner uses.
        let events = try await executeWithGate(scenario, choosing: "Go")

        // 1. The gate REQUEST escaped the child stream — the forwarder, not the default: arm.
        let gates = WorkflowStreamCollector.gateRequests(from: events)
        XCTAssertEqual(gates.count, 1, "the inner gate must surface exactly once on the outer stream")

        // 2. The answer resumed the CHILD: its post-gate node ran and its output flowed out.
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.first(where: { $0.nodeID == subWorkflow })?.summary, "APPROVED RESULT",
                       "the child must continue past the answered gate and publish its result")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: consumer)! },
                      "downstream must receive the completed sub-workflow's output")
    }

    /// ⚠️ A PLAN REVIEW INSIDE A SUB-WORKFLOW BODY must reach the outer stream. [design doc §9 N2]
    ///
    /// This was the FOURTH HITL kind and the only one the sub-workflow arm did not forward: it fell
    /// into the `default:` suppression arm, so no banner ever appeared while the child sat in
    /// `ExecutionSuspensionService.suspendForPlanReview`, which has NO timeout by design ("awaiting
    /// user action"). The per-node compute timeout could not rescue it either — the sentinel
    /// subtracts `cumulativeParkedTime` and extends itself by the shortfall, and a run doing nothing
    /// but waiting on a human is 100% parked, so it re-armed forever. The user saw a workflow frozen
    /// at N-1 of N nodes with no banner, no error and no timeout; only Stop ended it.
    ///
    /// The sibling test above (`testGateInsideSubWorkflowBody…`) pins the same property for gates,
    /// and its doc comment said "the THREE HITL forwards" — that count WAS the bug.
    ///
    /// The inner node emits the event directly rather than driving a real PlanningCapability: what
    /// is under test is the FORWARDER, not plan generation. Scripting it keeps the test fast and
    /// deterministic, and a regression that drops the case back into `default:` fails the first
    /// assertion immediately instead of hanging the suite.
    func testPlanReviewInsideSubWorkflowBody_ReachesTheOuterStream() async throws {
        let scenario = WorkflowTestScenario()
        let reviewOpID = UUID()
        let subtasks = [SubTask(id: "s1", description: "Draft the summary")]

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Planner Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let subWorkflow = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: subWorkflow, to: consumer)

        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [
            .requestPlanReview(subtasks: subtasks, operationID: reviewOpID),
            .content("PLANNED RESULT")
        ])
        mockProvider.scriptStream(for: scenario.profileID(for: consumer)!, events: [.content("done")])

        let events = try await execute(scenario)

        // 1. THE FIX: the request escaped the child stream via the forwarder, not `default:`.
        let reviews = WorkflowStreamCollector.planReviewRequests(from: events)
        XCTAssertEqual(reviews.count, 1,
                       "a plan review raised inside a sub-workflow must surface on the outer stream — "
                       + "swallowing it is a permanent hang with no banner and no timeout")
        XCTAssertEqual(reviews.first?.operationID, reviewOpID,
                       "the operationID must survive the hop — it is what the child is suspended on, "
                       + "so a rewritten id would make the answer unroutable")

        // 2. Attribution: the inner node's id is preserved (approval scope keys on it), and a
        //    display name is carried so the banner is not a bare "Plan review" (design doc §9 N5).
        XCTAssertNotNil(reviews.first?.sourceNodeID, "the request must be attributed to a node")
        // FULL PATH: outer sub-workflow node › the inner node that actually asked.
        //
        // ⚠️ This asserted just "Nested Step" when first written, and the value IMPROVED when the
        // direct profile-node path was fixed to stamp `sourceNodeID` on plan reviews. Before that
        // fix the inner id arrived nil, so `hitlDisplayName(nil)` could only fall back to the
        // sub-workflow node's own name. With the id present, the harvested inner name resolves too.
        // The parent's `nodeResults` can never contain an inner node id, so this name has to travel
        // with the event — the id alone is not resolvable on the far side.
        XCTAssertEqual(reviews.first?.sourceNodeName, "Nested Step › Planner Bot",
                       "the banner must name the sub-workflow node AND the inner node that asked")

        // 3. The run still completes and the child's output flows downstream.
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.first(where: { $0.nodeID == subWorkflow })?.summary, "PLANNED RESULT")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: consumer)! },
                      "downstream must receive the completed sub-workflow's output")
    }

    /// A plan review raised by a DIRECT workflow node must be attributed to that node.
    ///
    /// The profile-node path forwarded this as a bare `continuation.yield(event)` while its three
    /// HITL siblings all stamped `sourceNodeID: nodeID`. `PlanningCapability` never sets the field,
    /// so it arrived nil and flipped `enqueueHITL`'s
    /// `isWorkflow = workflowState != nil && sourceNodeID != nil` to false. Nothing hung — but the
    /// banner was labelled `.chat` with a speech-bubble icon, carried no node name, produced no
    /// "awaiting input" badge (`WorkflowDedicatedView.awaitingNodeIDs` compactMaps nil away), and
    /// the cross-conversation chip switched the app to CHAT mode instead of the canvas.
    ///
    /// ⚠️ Pairs with `testPlanReviewInsideSubWorkflowBody…`. Fixing N2 gave the NESTED path correct
    /// attribution first, which briefly left the direct path worse-behaved than the nested one.
    /// Both are pinned now; a regression in either shows up as a nil here.
    func testPlanReviewFromDirectWorkflowNode_IsAttributedToThatNode() async throws {
        let scenario = WorkflowTestScenario()
        let reviewOpID = UUID()
        let subtasks = [SubTask(id: "s1", description: "Draft the summary")]

        let planner = scenario.addBotNode(name: "Planner Node")
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: planner, to: consumer)

        mockProvider.scriptStream(for: scenario.profileID(for: planner)!, events: [
            .requestPlanReview(subtasks: subtasks, operationID: reviewOpID),
            .content("PLANNED RESULT")
        ])
        mockProvider.scriptStream(for: scenario.profileID(for: consumer)!, events: [.content("done")])

        let events = try await execute(scenario)

        let reviews = WorkflowStreamCollector.planReviewRequests(from: events)
        XCTAssertEqual(reviews.count, 1, "the plan review must reach the outer stream")
        XCTAssertEqual(reviews.first?.operationID, reviewOpID, "the operationID must survive the hop")

        // THE FIX: nil here is the defect — it is what makes enqueueHITL label a workflow request
        // as chat, drop the node name, and suppress the canvas badge.
        XCTAssertEqual(reviews.first?.sourceNodeID, planner,
                       "a plan review from a workflow node must carry THAT node's id — nil makes "
                       + "enqueueHITL treat a workflow request as a chat one")
        XCTAssertEqual(reviews.first?.sourceNodeName, "Planner Node",
                       "and its display name, so the banner is not a bare 'Plan review' on a canvas "
                       + "with several nodes in flight")
    }

    /// ⚠️ THE ENTRY-NODE INPUT SHAPE. An entry node's input IS the run's query — nothing is fused
    /// into it, and there is no second directive channel.
    ///
    /// This replaces `testEntryNodeTask_IsUserQueryFirstThenNodeTask_WithNoLabel`, which pinned the
    /// two-channel model: a per-node `taskDescription` rendered into `<task>`, with the user's query
    /// prepended to it at the entry node. Both are gone (2026-08-29) — a node's behaviour is its
    /// profile's system instructions, and everything it acts on arrives as `<input>`. The history is
    /// worth keeping because the fusion caused a real field failure: `<task>` opened with
    /// "User Query: ### MCP server guidance", carried ~2,000 chars of instructions for tools the node
    /// did not have, and buried the real 61-char question at the end, derailing a 3B model five times.
    func testEntryNodeInput_IsTheUserQueryVerbatim() async throws {
        let scenario = WorkflowTestScenario()
        let entry = scenario.addBotNode(name: "Entry")

        mockProvider.scriptStream(for: scenario.profileID(for: entry)!, events: [.content("ok")])
        _ = try await execute(scenario, userInput: "List all the files in Acme")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == entry })?.context)

        XCTAssertEqual(ctx.input, "List all the files in Acme",
                       "the entry node's input is the user's query, verbatim and alone")
        XCTAssertTrue(ctx.isFirstNode, "precondition: the node under test is the entry node")

        // The specific regressions, asserted by name so a re-fusion is caught explicitly.
        XCTAssertFalse(ctx.input.contains("User Query:"), "the inline label must not come back")
        XCTAssertFalse(ctx.input.contains("---"), "the separator line must not come back")
    }

    // MARK: - Structural error handlers receive the failure reason (EXA-3 / EIO-7)

    /// ⚠️ THE FILED BUG. A structural handler wired to an `error` port used to receive the failed
    /// upstream's bare `output` — "" for every thrown failure — because the structural path joined
    /// raw outputs instead of using the assembler. The handler now gets the same annotated form the
    /// profile path gets: `[Upstream node "X" failed: <reason>]`.
    func testAStructuralErrorHandlerReceivesTheAnnotatedFailure() async throws {
        let scenario = WorkflowTestScenario()
        let failing = scenario.addBotNode(name: "Failing Bot")
        let handler = scenario.addCodeNode(name: "Handler", template: "ALERT: {{ input }}")
        let sink = scenario.addBotNode(name: "Sink")
        scenario.connect(from: failing, to: handler, portLabel: WorkflowEdge.errorPortLabel)
        scenario.connect(from: handler, to: sink)

        mockProvider.scriptError(for: scenario.profileID(for: failing)!, error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "the model exploded"]))
        mockProvider.scriptStream(for: scenario.profileID(for: sink)!, events: [.content("ok")])
        _ = try await execute(scenario)

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == sink })?.context)
        XCTAssertTrue(ctx.input.contains("[Upstream node \"Failing Bot\" failed:"),
                      "the Code handler's {{ input }} must carry the annotated failure, not \"\" — got: \(ctx.input.prefix(160))")
    }

    // MARK: - Attachments reach a structural entry node (EXA-6)

    /// A run started with files whose entry node is a Trigger used to carry the query (EXA-1) while
    /// silently dropping every attachment — the run then read CORRECTLY while answering about
    /// documents it never received.
    func testAttachmentsFlowThroughAStructuralEntryNode() async throws {
        let scenario = WorkflowTestScenario()
        let trigger = scenario.addTriggerNode(name: "Start")
        let worker = scenario.addBotNode(name: "Worker")
        scenario.connect(from: trigger, to: worker)

        mockProvider.scriptStream(for: scenario.profileID(for: worker)!, events: [.content("done")])
        _ = try await execute(scenario, userInput: "summarize this",
                              attachmentContext: "ATTACHED-DOC-CONTENT-9b2e")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == worker })?.context)
        XCTAssertTrue(ctx.input.contains("ATTACHED-DOC-CONTENT-9b2e"),
                      "the Trigger must forward the run's attachments — they have no other route into the graph")
        XCTAssertTrue(ctx.input.contains("summarize this"), "…alongside the query, not instead of it")
    }

    /// ⚠️ The over-correction guard: a MID-GRAPH structural node must not receive the run's
    /// attachments — same rule as the query (WF13's shape).
    func testMidGraphStructuralNodeReceivesNoRunAttachments() async throws {
        let scenario = WorkflowTestScenario()
        let entry = scenario.addBotNode(name: "Entry")
        let code = scenario.addCodeNode(name: "Pass", template: "{{ input }}")
        let sink = scenario.addBotNode(name: "Sink")
        scenario.connect(from: entry, to: code)
        scenario.connect(from: code, to: sink)

        mockProvider.scriptStream(for: scenario.profileID(for: entry)!, events: [.content("UP")])
        mockProvider.scriptStream(for: scenario.profileID(for: sink)!, events: [.content("ok")])
        _ = try await execute(scenario, userInput: "q", attachmentContext: "ATTACHED-DOC-CONTENT-9b2e")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == sink })?.context)
        XCTAssertFalse(ctx.input.contains("ATTACHED-DOC-CONTENT-9b2e"),
                       "a mid-graph structural node must not be handed the run's attachments")
    }

    // MARK: - Structural entry nodes receive the run's query (EXA-1)
    //
    // `executeStructuralNode` took no `userInput` at all, so a workflow whose ENTRY node was a
    // Trigger, Router, Code, Gate, Action or sub-workflow silently discarded the user's question:
    // the entry node ran on "", and every node behind it has an incoming edge — so `isEntryNode`
    // is false there and none of them could receive the query either. The run answered a question
    // it was never given and reported success.

    /// ⚠️ THE FILED BUG, in the shape the app's own guidance recommends: the Trigger is documented
    /// as "an entry-point marker only", so wiring `Trigger → Agent` is the advertised way to make a
    /// starting point explicit — and it was the way to lose the user's query entirely.
    func testTriggerEntryNode_ForwardsTheUserQueryDownstream() async throws {
        let scenario = WorkflowTestScenario()
        let trigger = scenario.addTriggerNode(name: "Start")
        let worker = scenario.addBotNode(name: "Worker")
        scenario.connect(from: trigger, to: worker)

        mockProvider.scriptStream(for: scenario.profileID(for: worker)!, events: [.content("done")])
        _ = try await execute(scenario, userInput: "Summarize the Q3 report")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == worker })?.context)
        XCTAssertEqual(ctx.input, "Summarize the Q3 report",
                       "the Trigger must forward the query — it is the ONLY route the query has into the graph")
        XCTAssertFalse(ctx.isFirstNode,
                       "precondition: the worker is NOT an entry node, so it cannot receive the query directly")
    }

    /// A Router as the entry node must route on the QUERY. This one failed silently rather than
    /// loudly: "" MATCHES the stock `isEmpty` rule, so such a Router routed down its empty-branch
    /// on every run and nothing reported a problem.
    func testRouterEntryNode_RoutesOnTheUserQuery() async throws {
        let scenario = WorkflowTestScenario()
        let router = scenario.addConditionNode(name: "Router")
        let onNotEmpty = scenario.addBotNode(name: "HasText")
        let onEmpty = scenario.addBotNode(name: "NoText")
        scenario.connect(from: router, to: onNotEmpty, portLabel: "True")
        scenario.connect(from: router, to: onEmpty, portLabel: "False")

        mockProvider.scriptStream(for: scenario.profileID(for: onNotEmpty)!, events: [.content("ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: onEmpty)!, events: [.content("ok")])
        _ = try await execute(scenario, userInput: "a real question")

        let invoked = Set(mockProvider.workflowInvocations.map(\.context.nodeID))
        XCTAssertTrue(invoked.contains(onNotEmpty),
                      "a non-empty query must take the isNotEmpty branch; routing on \"\" took the other one silently")
        XCTAssertFalse(invoked.contains(onEmpty), "the empty branch must not fire for a non-empty query")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == onNotEmpty })?.context)
        XCTAssertEqual(ctx.input, "a real question", "the Router passes its input through to the chosen branch")
    }

    /// An entry Code node renders `{{ input }}` from the query.
    func testCodeEntryNode_RendersTheUserQuery() async throws {
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(name: "Shape", template: "PREFIX: {{ input }}")
        let worker = scenario.addBotNode(name: "Worker")
        scenario.connect(from: code, to: worker)

        mockProvider.scriptStream(for: scenario.profileID(for: worker)!, events: [.content("done")])
        _ = try await execute(scenario, userInput: "hello world")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == worker })?.context)
        XCTAssertEqual(ctx.input, "PREFIX: hello world",
                       "an entry Code node's {{ input }} is the run's query; it used to render empty")
    }

    /// ⚠️ THE OVER-CORRECTION GUARD, and the more dangerous direction. A mid-graph structural node
    /// must NEVER see the run's query — injecting it deep in a graph fabricates input that the
    /// author never wired, which is worse than the starvation being fixed. This is WF13's shape,
    /// which is why entry-ness is derived from the GRAPH and never from empty upstream data.
    func testMidGraphStructuralNode_NeverReceivesTheUserQuery() async throws {
        let scenario = WorkflowTestScenario()
        let entry = scenario.addBotNode(name: "Entry")
        let code = scenario.addCodeNode(name: "Passthrough", template: "{{ input }}")
        let sink = scenario.addBotNode(name: "Sink")
        scenario.connect(from: entry, to: code)
        scenario.connect(from: code, to: sink)

        mockProvider.scriptStream(for: scenario.profileID(for: entry)!, events: [.content("UPSTREAM OUTPUT")])
        mockProvider.scriptStream(for: scenario.profileID(for: sink)!, events: [.content("done")])
        _ = try await execute(scenario, userInput: "the user question")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == sink })?.context)
        XCTAssertEqual(ctx.input, "UPSTREAM OUTPUT",
                       "the mid-graph Code node must pass its UPSTREAM through, not the run's query")
        XCTAssertFalse(ctx.input.contains("the user question"),
                       "the query must not reach a node the author wired behind another node")
    }

    /// A Trigger wired MID-GRAPH must forward its upstream. Nothing on the canvas prevents this
    /// shape, and the node used to emit "" in every position — so a Trigger dropped in mid-graph
    /// black-holed the branch it sat on.
    func testMidGraphTrigger_ForwardsItsUpstreamInsteadOfBlackHolingIt() async throws {
        let scenario = WorkflowTestScenario()
        let entry = scenario.addBotNode(name: "Entry")
        let trigger = scenario.addTriggerNode(name: "Marker")
        let sink = scenario.addBotNode(name: "Sink")
        scenario.connect(from: entry, to: trigger)
        scenario.connect(from: trigger, to: sink)

        mockProvider.scriptStream(for: scenario.profileID(for: entry)!, events: [.content("REAL CONTENT")])
        mockProvider.scriptStream(for: scenario.profileID(for: sink)!, events: [.content("done")])
        _ = try await execute(scenario, userInput: "q")

        let ctx = try XCTUnwrap(mockProvider.workflowInvocations.first(where: { $0.context.nodeID == sink })?.context)
        XCTAssertEqual(ctx.input, "REAL CONTENT",
                       "a mid-graph Trigger is transparent; it used to emit \"\" and drop the branch's content")
    }

    /// A sub-workflow node with no task description must not block the run.
    ///
    /// The validator demanded one for every profile node and told the user to "Double-click to
    /// configure"; the double-click handler excluded exactly this node type and `targetConfigNode`
    /// has no other writer — so the blocking error was unfixable from the app.
    func testSubWorkflowNode_WithoutTaskDescription_DoesNotBlockValidation() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Nested Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let subWorkflow = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)

        // Direct validator assertion — this is the gate that threw `validationFailed`.
        let issues = WorkflowValidator.validate(layout: scenario.layout, profileMap: scenario.profileMap)
        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,
                      "A sub-workflow node without a task description must not be a validation error — got: \(errors.map(\.message))")

        // And end-to-end: the run reaches the node instead of throwing before any node executes.
        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [.content("ok")])
        let events = try await execute(scenario)
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains(where: { $0.nodeID == subWorkflow }))
    }

    /// A child workflow that fails must fail the node — never report an empty success.
    func testSubWorkflowNode_ChildFailure_FailsNodeAndSkipsDependents() async throws {
        let scenario = WorkflowTestScenario()

        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Failing Nested Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let subWorkflow = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: subWorkflow, to: consumer)

        mockProvider.scriptError(for: inner.profileID(for: innerBot)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: consumer)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == subWorkflow }),
                      "A failing child workflow must fail the node, not complete it green")
        XCTAssertFalse(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains(where: { $0.nodeID == subWorkflow }),
                       "The node must not also report completion")
        XCTAssertFalse(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains(where: { $0.nodeID == consumer }),
                       "Dependents must skip rather than run on the failed node's empty output")
    }

    // [WF-CC1] The sub-workflow half of this fix (`childOutcome == nil` at the point a cancelled
    // child `executeWorkflow` stream finishes via plain `continuation.finish()`, split into
    // `case nil where Task.isCancelled:` vs the pre-existing `case nil:`) has no dedicated
    // regression test either, for the identical structural reason noted above this file's Group 29
    // header comment and the consolidated note near `testCancel_DoesNotInvokeDownstreamNodes`: the
    // resulting stream event cannot cross the cancelled-consumer boundary. Verified by code review.

    /// WF5 — an inner stream that reports an error and then finishes with no terminal event must
    /// FAIL the node, not report an empty success.
    ///
    /// This is the shape `streamWorkflowNodeResponse` produces for a profile type it cannot run
    /// (`case .workflow, .imageGen` yields `.error` and finishes). The node used to go green with
    /// empty output: downstream consumed nothing, joins were satisfied, the error port never
    /// activated and the run reported success.
    func testErrorWithoutTerminalEvent_FailsNodeInsteadOfReportingEmptySuccess() async throws {
        let scenario = WorkflowTestScenario()
        let producer = scenario.addBotNode(name: "Producer")
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: producer, to: consumer)

        // `.error` then end-of-stream — NO `.executionFinished`.
        mockProvider.scriptStream(
            for: scenario.profileID(for: producer)!,
            // Byte-identical to what `streamWorkflowNodeResponse` emits for an unsupported
            // profile type (AgentConnect.swift:664) — the shape under test.
            events: [.error("Unsupported profile type for workflow node: imageGen")]
        )
        mockProvider.scriptStream(for: scenario.profileID(for: consumer)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        XCTAssertTrue(
            WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == producer },
            "A node whose stream errored and produced no terminal outcome must fail"
        )
        XCTAssertFalse(
            WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == producer },
            "…and must not ALSO report completion"
        )
        XCTAssertFalse(
            WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == consumer },
            "Dependents must skip rather than run on the failed node's empty output"
        )
    }

    /// The guard on the narrowness of the fix: a clean stream that simply ends without an
    /// `.executionFinished` event is still a SUCCESS. Treating "no terminal event" as failure on
    /// its own would break every ordinary node — most of this suite's mocks end exactly that way.
    func testCleanStreamWithoutTerminalEventStillCompletes() async throws {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Quiet Bot")
        mockProvider.scriptStream(for: scenario.profileID(for: bot)!, events: [.content("all good")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == bot })
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty)
    }

    /// WF5 — an ImageGen profile node is rejected at validation, so the user learns when they add
    /// it rather than after a run that silently produced nothing.
    func testImageGenProfileNodeIsARejectedAtValidation() async throws {
        let scenario = WorkflowTestScenario()
        let profileID = UUID()
        scenario.profileMap[profileID] = BackendProfileSnapshot(
            id: profileID,
            displayName: "Poster Generator",
            details: .imageGen(ImageGenConfig(llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-image-1")))
        )
        var node = WorkflowNode(
            id: UUID(),
            kind: .profile(profileID: profileID, profileType: .imageGen),
            position: .zero,
            displayName: "Poster Generator"
        )
        let layout = WorkflowLayout(nodes: [node], edges: [], annotations: [])

        let errors = WorkflowValidator.validate(layout: layout, profileMap: scenario.profileMap)
            .filter { $0.severity == .error }

        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].message.contains("Image generation profiles can't be used as a workflow step"),
                      "got: \(errors[0].message)")
    }

    // MARK: - WF8: Action nodes and semantic tool failure

    /// A tool that reports failure by RETURNING an error string must fail the node.
    ///
    /// `http_request` answers a dead endpoint with "Error: HTTP request failed …" and returns
    /// normally. The node used to go green, the tool card said success, and no `error` port
    /// activated — so the error-handler branch was unreachable for that whole class of tool.
    func testActionNode_SemanticToolFailure_FailsNodeAndActivatesErrorPort() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Post Webhook", toolName: "http_request")
        let handler = scenario.addBotNode(name: "Error Handler")
        let happyPath = scenario.addBotNode(name: "Happy Path")
        scenario.connect(from: action, to: handler, portLabel: "error")
        scenario.connect(from: action, to: happyPath)

        mockProvider.scriptTool(name: "http_request", output: "Error: HTTP request failed — The Internet connection appears to be offline.")
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("escalated")])
        mockProvider.scriptStream(for: scenario.profileID(for: happyPath)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == action },
                      "A tool whose output reports a failure must fail the node")
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == handler },
                      "The error-port branch must run — that is the whole point of the error port")
        XCTAssertFalse(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == happyPath },
                       "The default-port branch must NOT run on a failed tool")
    }

    /// The control: an ordinary successful tool return still completes the node and takes the
    /// default port. Guards against the semantic check swallowing normal output.
    func testActionNode_SuccessfulTool_CompletesAndTakesDefaultPort() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Post Webhook", toolName: "http_request")
        let happyPath = scenario.addBotNode(name: "Happy Path")
        scenario.connect(from: action, to: happyPath)

        mockProvider.scriptTool(name: "http_request", output: "{\"status\":\"ok\"}")
        mockProvider.scriptStream(for: scenario.profileID(for: happyPath)!, events: [.content("done")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == action })
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == happyPath })
    }

    /// Tools that legitimately surface error text opt out via `contentMayLookLikeError` — a shell
    /// tool returning stderr must NOT be misread as a failure. Same opt-out the agent path uses.
    func testActionNode_ContentMayLookLikeErrorTool_IsNotTreatedAsFailure() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Run Build", toolName: "execute_shell")
        let next = scenario.addBotNode(name: "Reader")
        scenario.connect(from: action, to: next)

        mockProvider.scriptTool(
            name: "execute_shell",
            output: "Error: 3 warnings emitted",   // legitimate stderr content
            contentMayLookLikeError: true
        )
        mockProvider.scriptStream(for: scenario.profileID(for: next)!, events: [.content("read it")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == action },
                      "A tool that opted out of content sniffing must not be failed on its own output")
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == next })
    }

    // MARK: - WF-CC4: Action-node tool retry loop cancellation (2026-08-26)
    //
    // Before this fix, the loop had no `Task.isCancelled` check anywhere and swallowed a cancelled
    // retry-delay sleep via `try?` — a Stop pressed mid-retry could let the tool run again for real.
    // Regression coverage for the ordinary (non-cancelled) retry path is included too: before this
    // fix touched the loop, `scriptThrowingTool` had never been exercised by a single test in this
    // file, so the retry-then-fail flow itself had zero test coverage of any kind.

    /// ⚠️ WEAKER THAN IT LOOKS. Every Action node is bounded (`WorkflowConfig.nodeTimeout` when it
    /// sets no `hardTimeout`), so `runToolWithTimeout` always races `tool.run` against a `Task.sleep`
    /// sentinel — and once the ambient Task is cancelled that sentinel throws `CancellationError`
    /// almost instantly and can win the race, aborting a retried attempt BEFORE it reaches the mocked
    /// tool. With the retry loop reverted to its pre-WF-CC4 shape this test can therefore still
    /// pass: the sentinel, not the loop's own cancellation handling, may be what stops the second
    /// invocation. (It used to run with the workflow's node timeout switched OFF to take the
    /// no-race path; that setting was removed 2026-10-03.) Treat it as a regression smoke test.
    ///
    /// A multi-second `retryDelay` gives the test a wide, deterministic window: after the tool's
    /// first attempt fails and the loop decides to retry, it blocks on `Task.sleep`. Cancelling
    /// during that sleep (not a coin-flip — the window is seconds, the cancel lands in microseconds)
    /// must NOT let the tool run a second time.
    func testActionNode_CancelDuringRetryDelay_DoesNotInvokeToolAgain() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Flaky Call", toolName: "flaky_tool")
        scenario.setNodeConfig(WorkflowNodeConfig(maxNodeRetries: 2, retryDelay: 5), for: action)

        let reached = expectation(description: "tool invoked once")
        reached.assertForOverFulfill = false
        mockProvider.scriptThrowingToolWithBarrier(name: "flaky_tool", error: URLError(.networkConnectionLost)) { count in
            if count == 1 { reached.fulfill() }
        }

        let stream = makeStream(scenario)
        let task = Task { try await StreamCollector.collect(from: stream) }

        await fulfillment(of: [reached], timeout: 10)
        task.cancel()
        _ = try? await task.value

        // ⚠️ `task.value` only settles the STREAM-CONSUMING task, not the workflow's own inner Task
        // (the one `executeWorkflow`'s `AsyncThrowingStream` closure creates internally) — cancelling
        // the consumer merely REQUESTS the inner task's cancellation via `continuation.onTermination`,
        // it does not wait for it. Asserting immediately after `task.value` races ahead of the inner
        // task's own unwind and can read the count before a real regression's second/third invocation
        // has happened yet — mirroring the same async-teardown caveat `testCancel_TearsDownTheInFlightNodeStream`
        // above documents and polls around. Poll for a short bounded window so a real second
        // invocation has time to land before the assertion below runs.
        //
        // ⚠️ 100×20ms (2000ms), matching `testCancel_TearsDownTheInFlightNodeStream` and
        // `testCancel_DuringGate_GateWasActuallyRequested` above — this is a NEGATIVE assertion
        // ("nothing else happened"), so a too-short window fails safe in the wrong direction: it
        // cannot produce a spurious failure, only a spurious PASS that hides a real regression on a
        // loaded machine. Give it the same margin those two established sibling tests give the
        // identical outer-task-cancel-to-inner-task-settled race, not a smaller one with no stated reason.
        var invocationCount = mockProvider.toolInvocationCount(for: "flaky_tool")
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            invocationCount = mockProvider.toolInvocationCount(for: "flaky_tool")
        }

        XCTAssertEqual(invocationCount, 1,
                       "a retry must never fire once Stop has been pressed, however the cancellation surfaced")
    }

    /// Regression guard: the ordinary, non-cancelled retry path must still retry up to the
    /// configured cap and then fail — this loop's restructuring must not change that.
    func testActionNode_RetriesTransientFailureUpToCapThenFails() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Flaky Call", toolName: "flaky_tool")
        scenario.setNodeConfig(WorkflowNodeConfig(maxNodeRetries: 2, retryDelay: 0), for: action)

        mockProvider.scriptThrowingTool(name: "flaky_tool", error: URLError(.networkConnectionLost))

        let events = try await execute(scenario)

        XCTAssertEqual(mockProvider.toolInvocationCount(for: "flaky_tool"), 3,
                       "maxNodeRetries: 2 means 3 total attempts (1 initial + 2 retries)")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == action })
    }

    // MARK: - Group 31: Router no-match behaviour

    /// `.endBranch`: unmatched input ends the BRANCH gracefully — downstream skips as
    /// not-chosen (never failed), and the Router's passthrough becomes the final output because
    /// terminality is computed over LIVE edges.
    func testRouter_NoMatchEndWorkflow_EndsBranchGracefullyWithPassthroughAsFinalOutput() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        config.decisionPolicy = .endBranch
        let router = scenario.addConditionNode(name: "Router", config: config)
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("nothing that matches")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        // Nothing failed, downstream never ran, and it skipped as NOT CHOSEN (quiet, not red).
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty,
                      "a graceful end is not a failure — got: \(WorkflowStreamCollector.nodeFailedEvents(from: events))")
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: urgent)! })
        XCTAssertTrue(WorkflowStreamCollector.nodeSkippedEvents(from: events)
                        .contains { $0.nodeID == urgent && $0.reason == .notChosen })

        // The Router became a terminal: its passthrough content is the run's answer.
        XCTAssertTrue(WorkflowStreamCollector.contentText(from: events).contains("nothing that matches"),
                      "the passthrough must become the final output — that is the point of 'End workflow here'")
        XCTAssertEqual(WorkflowStreamCollector.terminalOutcomes(from: events).last?.outcome, .completed,
                       "the run COMPLETED — ending a branch by choice is not a failure")
    }

    /// A rename of the default-route rule must not strand the route — the target is stored by ID.
    func testRouter_NoMatchRoute_SurvivesRuleRename() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = ConditionNodeConfig()
        var fallbackRule = ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "generalzz")
        config.decisionPolicy = .route(ruleID: fallbackRule.id)
        // Rename AFTER the route was configured — the id is what the engine resolves.
        fallbackRule.label = "Fallback"
        config.rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            fallbackRule
        ]
        let router = scenario.addConditionNode(name: "Router", config: config)
        let arm = scenario.addBotNode(name: "Fallback Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: arm, portLabel: "Fallback")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("plain input")])
        mockProvider.scriptStream(for: scenario.profileID(for: arm)!, events: [.content("fallback ran")])

        let events = try await execute(scenario)
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: arm)! },
                      "the route resolves by rule ID, so the rename must not strand it")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty)
    }

    // MARK: - WF-TS4: the AI Classifier's FAILURE path
    //
    // ⚠️ The classifier's happy path is unreachable in tests without an MLX model, so its failure
    // path — the one users actually hit on a machine with no model, a deleted model, or a bad
    // config — had NO coverage at all. These pin what happens to the RUN when the classifier
    // throws, under the decision-policy choices.
    //
    // ⚠️ HERMETIC CLASSIFIER FAILURE (the load-bearing fact — do not "fix" this config):
    // `evaluateConditionWithLLM`'s FIRST guard is `!config.llmPrompt.isEmpty`, and an empty prompt
    // is only a validator WARNING while an empty `llmModelName` is an ERROR that blocks the run.
    // So this config passes pre-flight, ENTERS the classifier, and throws before any
    // MLXModelService/MLXService contact. No disk scan, no model load, fully deterministic.

    private func makeThrowingClassifierConfig(rules: [ConditionRule]) -> ConditionNodeConfig {
        var config = ConditionNodeConfig()
        config.rules = rules
        config.decisionPolicy = .failNode
        config.llmFallbackEnabled = true
        config.llmPrompt = ""                    // <- the throw
        config.llmModelName = "never-loaded"     // non-empty so pre-flight passes
        return config
    }

    /// [WF-EX10] The classifier's 4000-char input budget must be LOUD when it bites: the routing
    /// decision is made on the truncated text, and before this a Router downstream of a long
    /// document took the wrong branch with a clean-looking trace. The warning is emitted at
    /// classifier entry (before the config guards), so the hermetic throwing config observes it.
    func testClassifierInputTruncation_IsSurfacedAsANodeWarning() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let config = makeThrowingClassifierConfig(rules: [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "NEVERMATCHES-A"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "NEVERMATCHES-B")
        ])
        let router = scenario.addConditionNode(name: "Router", config: config)
        let arm = scenario.addBotNode(name: "Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: arm, portLabel: "Urgent")

        // 4500 chars, no rule match → the classifier is entered with an oversized input.
        mockProvider.scriptStream(for: scenario.profileID(for: source)!,
                                  events: [.content(String(repeating: "x", count: 4500))])
        mockProvider.scriptStream(for: scenario.profileID(for: arm)!, events: [.content("unused")])

        let events = try await execute(scenario)

        let truncationWarnings = events.compactMap { event -> UUID? in
            if case .warning(let category, let message, _, let sourceNodeID) = event,
               category == .contextPressure, message.contains("4,000") { return sourceNodeID }
            return nil
        }
        XCTAssertEqual(truncationWarnings, [router],
                       "an input past the classifier budget must surface a warning ON THE ROUTER's timeline — silently routing on a fraction of the text was the defect")
    }

    /// …and the warning must NOT cry wolf on inputs within the budget.
    func testClassifierInputWithinBudget_EmitsNoTruncationWarning() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let config = makeThrowingClassifierConfig(rules: [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "NEVERMATCHES-A"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "NEVERMATCHES-B")
        ])
        let router = scenario.addConditionNode(name: "Router", config: config)
        let arm = scenario.addBotNode(name: "Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: arm, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("short input")])
        mockProvider.scriptStream(for: scenario.profileID(for: arm)!, events: [.content("unused")])

        let events = try await execute(scenario)

        let truncationWarnings = events.filter { event in
            if case .warning(let category, let message, _, _) = event,
               category == .contextPressure, message.contains("4,000") { return true }
            return false
        }
        XCTAssertTrue(truncationWarnings.isEmpty, "no truncation happened — no warning")
    }

    /// A classifier failure must FAIL the node (default `.failNode`) with a reason that NAMES the
    /// classifier, and must light the `error` port so a wired recovery branch runs.
    func testClassifierFailure_FailsTheNodeOntoErrorPortWithAClassifierSpecificReason() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let config = makeThrowingClassifierConfig(rules: [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ])
        let router = scenario.addConditionNode(name: "Router", config: config)
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        let recovery = scenario.addBotNode(name: "Recovery")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")
        scenario.connect(from: router, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        // Matches NEITHER rule, so the classifier is actually entered.
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("plain input")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("must not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("recovered")])

        let events = try await execute(scenario)

        let thoughts = WorkflowStreamCollector.thoughtText(from: events)
        XCTAssertTrue(thoughts.contains("AI Classifier failed"),
                      "the classifier's failure must reach the event stream. Thoughts: \(thoughts)")
        // ⚠️ VEHICLE PRECONDITION. This test depends on the FIRST guard in
        // `evaluateConditionWithLLM` throwing before any MLX contact. Without this assertion, a
        // change that reorders the guards — or adds a "treat an empty prompt as classifier-off"
        // pre-check — silently turns all three of these into "the classifier never ran" tests
        // that still pass while proving nothing about a classifier FAULT.
        XCTAssertTrue(thoughts.contains("no routing prompt configured"),
                      "the FIRST guard must be what threw — this test is about a classifier that ran and faulted, not one that was skipped. Thoughts: \(thoughts)")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains { $0.nodeID == router },
                      "a throwing classifier with .failNode must fail the node. Got: \(failed.map(\.error))")

        // ⚠️ WF-CC10's assertion proper. The old test asserted only that the node failed — which
        // was already true — and left the REASON unasserted (it appeared only inside an XCTAssert
        // failure message, which never runs on a pass). The reason is the whole finding.
        let reason = try XCTUnwrap(failed.first { $0.nodeID == router }).error
        XCTAssertTrue(reason.contains("could not be consulted"),
                      "the reason must say the classifier never produced a verdict: \(reason)")
        XCTAssertTrue(reason.contains("no routing prompt configured"),
                      "the underlying fault must survive into the reason — a support bundle has to name the cause, not just the symptom: \(reason)")
        XCTAssertFalse(reason.contains("did not return a label"),
                       "the classifier never ran. Wording it as an inconclusive ANSWER reports an infrastructure fault as a content fault and sends the user to fix their rules for a problem in their model directory: \(reason)")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: recovery)! },
                      "a classifier failure must fail the node onto `error`, so a wired recovery branch runs")
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: urgent)! },
                       "no rule matched and the classifier threw — no option branch may run")
    }

    /// ⚠️ WF-CC10. A crashed classifier used to honour the configured default route: an MLX slot
    /// race silently became a routing decision and the run reported SUCCESS with an arbitrary
    /// branch taken.
    ///
    /// `decisionPolicy` answers "no single rule described this input" — a verdict about CONTENT. A
    /// classifier that threw produced no verdict at all, so the setting is not applied. Only a
    /// classifier FAULT bypasses it; an explicit "none of these" and an unreadable reply are
    /// verdicts the model did produce and still follow the setting (see `WorkflowNoMatchDispositionTests`).
    func testClassifierCrash_OverridesTheConfiguredDefaultRoute_AndFailsOntoError() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        // Build the default rule first so its stable `id` is available for `.route(ruleID:)`.
        let generalRule = ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "zzz")
        var config = makeThrowingClassifierConfig(rules: [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            generalRule
        ])
        config.decisionPolicy = .route(ruleID: generalRule.id)
        let router = scenario.addConditionNode(name: "Router", config: config)
        let generalArm = scenario.addBotNode(name: "General Arm")
        let recovery = scenario.addBotNode(name: "Recovery")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: generalArm, portLabel: "General")
        scenario.connect(from: router, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("plain input")])
        mockProvider.scriptStream(for: scenario.profileID(for: generalArm)!, events: [.content("handled by default")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("recovered")])

        let events = try await execute(scenario)

        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: generalArm)! },
                       "a crash is not a no-match — the author's default route answers a question that was never asked, so it must NOT be taken")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                      "the Router must fail: nothing classified this input")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: recovery)! },
                      "the `error` port is the documented recovery channel for a classifier fault — wire it to the branch you would have defaulted to")
        // ⚠️ The thought reaches the EVENT STREAM, but a `.condition` node renders no timeline
        // (`kindSupportsTimeline` is false for it), so this is NOT a user-visible guarantee — do
        // not restore the old comment claiming it is.
        XCTAssertTrue(WorkflowStreamCollector.thoughtText(from: events).contains("AI Classifier failed"),
                      "the failure must still reach the event stream and the logs")
    }

    /// ⚠️ WF-CC10. A crashed classifier used to end the branch gracefully under "end the branch",
    /// reporting the run as COMPLETED. A classifier fault is now a node failure regardless of the setting.
    ///
    /// ⚠️ The one half that is KEPT VERBATIM is the load-bearing one: `try await execute(scenario)`
    /// must still NOT throw. That pins that the classifier's `do/catch` stays a CATCH — if the
    /// throw ever propagated out of `executeWorkflow`, one misconfigured Router would abort the
    /// entire run instead of failing one node.
    ///
    /// ⚠️ User-visible cost of this change, stated rather than hidden: the Router no longer
    /// passes its upstream content through on this path (`.fail` sets `output = ""`), so it is no
    /// longer a terminal contributing to the final answer. That is why the old
    /// `contentText contains "plain input"` assertion is gone rather than merely relocated.
    func testClassifierCrash_IsNotAGracefulEnd_EvenWhenTheAuthorChoseEndWorkflow() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        var config = makeThrowingClassifierConfig(rules: [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ])
        config.decisionPolicy = .endBranch
        let router = scenario.addConditionNode(name: "Router", config: config)
        let urgentArm = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgentArm, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("plain input")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgentArm)!, events: [.content("must not run")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                      "a classifier FAULT fails the node — `.endWorkflow` describes what to do with input the classifier judged, and nothing judged this input")
        XCTAssertTrue(WorkflowStreamCollector.nodeSkippedEvents(from: events)
                        .contains { $0.nodeID == urgentArm && $0.reason == .upstreamFailed },
                      "downstream is skipped because its upstream FAILED, not because a branch was 'not chosen' — the distinction is what tells the user a fault occurred. Got: \(WorkflowStreamCollector.nodeSkippedEvents(from: events).map(\.reason))")
        XCTAssertEqual(WorkflowStreamCollector.terminalOutcomes(from: events).last?.outcome, .failed,
                       "the run must report FAILED — reporting success on a run where nothing classified the input is the defect WF-CC10 fixes")
    }

    // MARK: - Group 30: WF-OB4 — an unreadable canvas must not run as "has no nodes"

    /// ⚠️ THE LIE THIS PINS: `WorkflowLayoutStore.load(for:)` deliberately returns `.empty` for a
    /// missing row AND an undecodable blob, so the executor's `!layout.nodes.isEmpty` guard told
    /// the user "The workflow has no nodes. Add profiles to the canvas before running." about a
    /// canvas that HAS nodes (the denormalized counts prove it) and REFUSES every save while
    /// unreadable — impossible advice, contradicting the canvas overlay on screen at the same
    /// moment. Exposure widened when the Loop node was retired with no decode shim: every old
    /// loop-bearing layout now takes this exact path.
    ///
    /// ⚠️ Test mechanics: the corrupt row is planted through a SEPARATE `ModelContext`, never the
    /// store API. Two reasons: `save(_:for:)` refuses to write over an unreadable row (so it cannot
    /// create one), and `WorkflowLayoutSD`'s decode state is a per-instance `@Transient` cache —
    /// corrupting an instance the mainContext has already materialized would leave its cached
    /// "decodes fine" verdict in place. A separate context writes the bytes to DISK; the executor's
    /// mainContext then materializes a FRESH instance whose first prime reads the garbage.
    func testUnreadableLayout_RunIsRefusedWithCountsNotReportedAsEmpty() async throws {
        let container = try XCTUnwrap(WorkflowLayoutStore.shared.modelContainer,
                                      "test host must have configured the layout store")
        let pid = UUID()

        // A real 2-node layout gives the row honest denormalized counts…
        let donor = WorkflowTestScenario()
        donor.addBotNode(name: "A")
        donor.addBotNode(name: "B")
        let row = WorkflowLayoutSD(workflowProfileID: pid, layout: donor.layout)
        // …and then the blob is corrupted AFTER init, so counts say 2 nodes while decode fails.
        row.layoutData = Data("not a workflow layout".utf8)
        let plantingContext = ModelContext(container)
        plantingContext.insert(row)
        try plantingContext.save()
        defer { WorkflowLayoutStore.shared.delete(for: pid) }

        let executor = WorkflowExecutor(workflowProfileID: pid)
        let stream = executor.executeWorkflow(
            userInput: "run it", conversationID: UUID(),
            traceContext: traceContext, onTraceUpdate: { _ in },
            layout: nil,                       // ← the PRODUCTION path: load from the store
            profileMap: nil, streamProvider: mockProvider
        )

        do {
            _ = try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
            XCTFail("an unreadable layout must refuse the run")
        } catch let error as WorkflowError {
            guard case .layoutUnreadable(let nodes, let edges) = error else {
                return XCTFail("expected .layoutUnreadable, got \(error) — '\(error.localizedDescription)'")
            }
            XCTAssertEqual(nodes, 2, "the counts are the user's evidence and must survive into the error")
            XCTAssertEqual(edges, 0)
            XCTAssertFalse(error.localizedDescription.contains("has no nodes"),
                           "the old lie must be gone")
            XCTAssertTrue(error.localizedDescription.contains("could not be read"),
                          "the error must name the real problem — got: \(error.localizedDescription)")
        }
    }

    /// The control: a genuinely EMPTY (missing-row) workflow keeps the emptyWorkflow error —
    /// the unreadable check must not swallow the honest empty case.
    func testMissingLayout_StillReportsEmptyWorkflow() async throws {
        let executor = WorkflowExecutor(workflowProfileID: UUID())   // no row exists for this id
        let stream = executor.executeWorkflow(
            userInput: "run it", conversationID: UUID(),
            traceContext: traceContext, onTraceUpdate: { _ in },
            layout: nil, profileMap: nil, streamProvider: mockProvider
        )
        do {
            _ = try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
            XCTFail("an empty workflow must refuse the run")
        } catch let error as WorkflowError {
            guard case .emptyWorkflow = error else {
                return XCTFail("expected .emptyWorkflow, got \(error)")
            }
        }
    }

    // MARK: - Group 27: WF-EX2 — a skip only carries the `error` signal when a failure started it

    /// ⚠️ THIS is the test that pins the EXECUTOR. The unit tests in `WorkflowSkipReasonTests`
    /// exercise `WorkflowState.upstreamSignalledError` directly and REPRODUCE the driver's rule in a
    /// helper, so they cannot see the executor forgetting to apply it — mutating the `if` in
    /// `WorkflowExecutor` leaves them green. This one drives the real dispatch loop and fails.
    ///
    /// Shape: `Fetcher --error--> Handler --error--> Notify`, and Fetcher SUCCEEDS.
    /// Handler correctly stands down; before the fix it then activated its own `error` port and told
    /// Notify that Handler had failed — so an alerting branch fired on a run where nothing failed,
    /// while the run still reported success.
    func testSuccessfulRun_StoodDownErrorHandler_DoesNotFireItsOwnErrorBranch() async throws {
        let scenario = WorkflowTestScenario()
        let fetcher = scenario.addBotNode(name: "Fetcher")
        let handler = scenario.addBotNode(name: "Handler")
        let notify = scenario.addBotNode(name: "Notify")

        scenario.connect(from: fetcher, to: handler, portLabel: WorkflowEdge.errorPortLabel)
        scenario.connect(from: handler, to: notify, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptStream(for: scenario.profileID(for: fetcher)!, events: [.content("all good")])
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("handled")])
        mockProvider.scriptStream(for: scenario.profileID(for: notify)!, events: [.content("PAGED THE ONCALL")])

        let events = try await execute(scenario)

        // The side effect is what actually matters: Notify must never be invoked.
        let notifyProfileID = scenario.profileID(for: notify)!
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == notifyProfileID },
                       "Notify ran on a workflow where NOTHING failed — an alerting branch firing on a healthy run")
        let handlerProfileID = scenario.profileID(for: handler)!
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == handlerProfileID },
                       "precondition: the handler itself must stand down when its upstream succeeded")

        // …and it must not reach the user's answer either.
        XCTAssertFalse(WorkflowStreamCollector.contentText(from: events).contains("PAGED THE ONCALL"),
                       "the un-run branch's output must not appear in the final answer")

        let skipped = WorkflowStreamCollector.nodeSkippedEvents(from: events)
        XCTAssertTrue(skipped.contains { $0.nodeID == handler && $0.reason == .errorPortNotTaken })
        XCTAssertTrue(skipped.contains { $0.nodeID == notify },
                      "Notify must be reported as not-run, not silently absent")
    }

    // MARK: - Group 29: WF-TS2 — cancellation that can actually fail
    //
    // ⚠️ WHY THE ORIGINAL FIVE `testCancel_*` TESTS VERIFY NOTHING. Every one asserts only on
    // `mockProvider.invocations`, and their negative assertions ("B did not run") are satisfied for a
    // reason that has nothing to do with cancellation: the blocked node lands in `.canceled`, and
    // `WorkflowState.edgeIsLive` treats a `.canceled` upstream as dead, so in a single CHAIN the
    // downstream node is skipped whether or not the executor honours Stop at all. Deleting BOTH
    // `try Task.checkCancellation()` calls leaves all five green.
    //
    // ⚠️ THE CANCELLED VERDICT IS NOT ASSERTABLE THROUGH THIS SEAM, and that is not a test defect.
    // The only route into the executor's cancellation arm is `continuation.onTermination { task.cancel() }`,
    // which fires because the CONSUMER tore the stream down — so by the time the catch arm runs the
    // stream is already terminal and its `.executionFinished(.cancelled)` yield is dropped. That is
    // true in production too; `ActiveStreamManager` stamps `cancelled` itself. Do not write a test
    // that waits for that event: it can never arrive. What IS observable is below.

    /// Two DISCONNECTED chains: chain 1's node blocks forever, chain 2's first node COMPLETES so its
    /// second node has a live, completed upstream and is perfectly runnable. After Stop it must not
    /// run. Unlike the original five tests, this assertion is NOT satisfied by the
    /// dead-`.canceled`-upstream rule, because this node's upstream succeeded.
    ///
    /// ⚠️ WHAT THIS DOES **NOT** PIN, VERIFIED BY MUTATION — do not re-derive this.
    /// Replacing BOTH `try Task.checkCancellation()` calls (WorkflowExecutor.swift:364 and :659)
    /// with no-ops leaves this test — and all 167 — GREEN. Two reasons, and they are structural:
    ///   • level 1 holds the blocking node, and `withTaskGroup` awaits every child, so level 2 is
    ///     not reached while it blocks, with or without the checks; and
    ///   • once the outer Task is cancelled, every `await` inside subsequent node execution throws
    ///     `CancellationError` on its own, so the provider is never invoked either way.
    /// The explicit checks are therefore about PROMPTNESS and TELEMETRY (span closed `.error`,
    /// `.userCancelled` classified), not about whether downstream work runs. Pinning them needs an
    /// injectable trace sink, which does not exist — filed as its own item rather than faked here.
    ///
    /// What this test DOES pin, and the originals did not: that cancellation propagates into node
    /// execution at all. If nodes were ever run detached from the run's task — the natural way this
    /// breaks — `healthyTail` would be invoked and this fails.
    func testCancel_NoFurtherNodeIsInvoked_EvenWhenItsUpstreamSucceeded() async throws {
        let scenario = WorkflowTestScenario()
        let blocker = scenario.addBotNode(name: "Blocker")          // chain 1, level 1 — blocks forever
        let healthyHead = scenario.addBotNode(name: "Healthy Head") // chain 2, level 1 — completes
        let healthyTail = scenario.addBotNode(name: "Healthy Tail") // chain 2, level 2 — runnable
        scenario.connect(from: healthyHead, to: healthyTail)

        mockProvider.scriptSlowStream(for: scenario.profileID(for: blocker)!, initialEvents: [])
        mockProvider.scriptStream(for: scenario.profileID(for: healthyHead)!, events: [.content("done")])
        mockProvider.scriptStream(for: scenario.profileID(for: healthyTail)!, events: [.content("should never run")])

        let blockerProfileID = scenario.profileID(for: blocker)!
        let reachedBlocker = expectation(description: "provider called for the blocking node")
        reachedBlocker.assertForOverFulfill = false
        mockProvider.onInvoke = { pid in if pid == blockerProfileID { reachedBlocker.fulfill() } }

        let stream = makeStream(scenario)
        let task = Task { try await StreamCollector.collect(from: stream) }

        // Deterministic barrier — the provider has been called and is now blocked forever.
        await fulfillment(of: [reachedBlocker], timeout: 10)
        task.cancel()
        _ = try? await task.value

        let tailProfileID = scenario.profileID(for: healthyTail)!
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == tailProfileID },
                       "no node may be invoked after Stop — this one's upstream COMPLETED, so the dead-upstream rule is not what stops it")
    }

    /// Stop must reach the node that is actually running, not just stop scheduling new ones.
    func testCancel_TearsDownTheInFlightNodeStream() async throws {
        let scenario = WorkflowTestScenario()
        let blocker = scenario.addBotNode(name: "Blocker")
        let blockerProfileID = scenario.profileID(for: blocker)!
        mockProvider.scriptSlowStream(for: blockerProfileID, initialEvents: [])

        let reached = expectation(description: "provider called")
        reached.assertForOverFulfill = false
        mockProvider.onInvoke = { pid in if pid == blockerProfileID { reached.fulfill() } }

        let stream = makeStream(scenario)
        let task = Task { try await StreamCollector.collect(from: stream) }
        await fulfillment(of: [reached], timeout: 10)
        task.cancel()
        _ = try? await task.value

        // Teardown propagates through the executor's node task to the provider's stream.
        // Poll briefly: the cancellation is asynchronous, but bounded and fast.
        var tornDown = false
        for _ in 0..<100 where !tornDown {
            if mockProvider.tornDownProfileIDs.contains(blockerProfileID) { tornDown = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tornDown,
                      "the in-flight node's provider stream was never torn down — Stop did not reach the running node")
    }

    /// The gate test's original assertion was `gates.count <= 1`, which is vacuously true for 0.
    /// With a barrier on the gate request itself, the count is deterministic.
    func testCancel_DuringGate_GateWasActuallyRequested() async throws {
        let scenario = WorkflowTestScenario()
        let gate = scenario.addGateNode(name: "Approve?", options: ["Yes", "No"])
        scenario.connect(from: gate, to: scenario.addBotNode(name: "After"))

        let stream = makeStream(scenario)
        let collected = Task { try await StreamCollector.collect(from: stream) }

        // Poll for the gate request rather than sleeping a fixed interval.
        var sawGate = false
        for _ in 0..<200 where !sawGate {
            if await ExecutionSuspensionService.shared.hasPendingSuspensions() { sawGate = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawGate, "the gate must actually suspend — the old `gates.count <= 1` passed even when it never did")

        collected.cancel()
        _ = try? await collected.value

        // ⚠️ Catches a LEAKED suspension. It does NOT pin the executor's `cancel(for:)` line —
        // `suspendForGate`'s own cancellation handler also resumes with nil — and the test says so
        // rather than claiming coverage it does not have.
        var drained = false
        for _ in 0..<100 where !drained {
            if !(await ExecutionSuspensionService.shared.hasPendingSuspensions()) { drained = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(drained, "a cancelled gate must not leave its suspension parked forever")
    }

    /// ⚠️ Register EXC-2 — pins the executor's cancel ARM specifically (the service-level scoping
    /// is pinned by `WorkflowRunScopedDrainTests`). A FOREIGN run's park is hand-planted in the
    /// SAME conversation the run uses — a single live run plus one planted park is the
    /// deterministic distillation of the two-concurrent-runs scenario the park-accounting suite
    /// rejected as unmutatable. Stop cancels the run; its own gate drains (its cancellation
    /// handler AND the arm both point at it), but the foreign park must SURVIVE — the pre-fix
    /// `cancel(for: conversationID)` swept it with `approved = false`.
    func testStop_DoesNotDrainAForeignRunsPark() async throws {
        let conv = UUID()
        let foreignToken = UUID(), foreignOp = UUID()
        let baseline = await ExecutionSuspensionService.shared.pendingSuspensionCount()

        // The foreign run's parked tool confirmation (the register's run-B shape).
        let foreignTask = Task {
            await WorkflowRunScope.$token.withValue(foreignToken) {
                await ExecutionSuspensionService.shared.suspend(for: foreignOp, conversationID: conv)
            }
        }
        var foreignInstalled = false
        for _ in 0..<200 where !foreignInstalled {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() >= baseline + 1 { foreignInstalled = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(foreignInstalled, "the foreign park never installed — every later count in this test is meaningless")

        let scenario = WorkflowTestScenario()
        let gate = scenario.addGateNode(name: "Approve?", options: ["Yes", "No"])
        scenario.connect(from: gate, to: scenario.addBotNode(name: "After"))

        let stream = makeStream(scenario, conversationID: conv)
        let collected = Task { try await StreamCollector.collect(from: stream) }

        var runParked = false
        for _ in 0..<200 where !runParked {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() >= baseline + 2 { runParked = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(runParked, "the run's gate must actually suspend before Stop")

        collected.cancel()
        _ = try? await collected.value

        // The run's own park drains; the foreign park must NOT. Poll down to baseline+1, then
        // hold briefly and re-check — the cancel arm runs asynchronously in the stream task, so a
        // late over-drain must not slip past a single early read.
        var settled = false
        for _ in 0..<100 where !settled {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() == baseline + 1 { settled = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(settled, "the run's own gate park must drain on Stop")
        try await Task.sleep(for: .milliseconds(200))
        let after = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(after, baseline + 1,
                       "the FOREIGN run's park must survive this run's Stop — draining it force-denies a tool the other run's user never answered")

        // Rescue: the foreign run's user approves, and the waiter gets THE USER's answer.
        await ExecutionSuspensionService.shared.resume(for: foreignOp, approved: true, resolvedBy: .localUI)
        let foreignResult = await foreignTask.value
        XCTAssertTrue(foreignResult, "the foreign waiter must receive the user's real answer, not a forced denial")
    }

    /// ⚠️ EXC-2's mirror image — the arm's POSITIVE duty, without which deleting the whole
    /// depth-1 drain block passes every other test (the run's own gate drains via its suspend
    /// cancellation handler, and a foreign park's survival is exactly what arm-deletion produces).
    /// A TOKEN-LESS park — an MCP-broker consent raised on the transport's task, outside the run's
    /// task tree — has NO cancellation handler in the run's tree, so the arm's `cancelRun` sweep is
    /// the ONLY thing that ever resolves it on Stop. Skipping it is a banner standing forever for a
    /// run that no longer exists ("a HANG, not a warning").
    func testStop_DrainsTokenlessParksOfItsConversation() async throws {
        let conv = UUID()
        let tokenlessOp = UUID()
        let baseline = await ExecutionSuspensionService.shared.pendingSuspensionCount()

        // Raised with NO run token — the MCP-broker shape.
        let tokenlessTask = Task {
            await ExecutionSuspensionService.shared.suspend(for: tokenlessOp, conversationID: conv)
        }
        var installed = false
        for _ in 0..<200 where !installed {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() >= baseline + 1 { installed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(installed, "the token-less park never installed")

        let scenario = WorkflowTestScenario()
        let gate = scenario.addGateNode(name: "Approve?", options: ["Yes", "No"])
        scenario.connect(from: gate, to: scenario.addBotNode(name: "After"))

        let stream = makeStream(scenario, conversationID: conv)
        let collected = Task { try await StreamCollector.collect(from: stream) }

        var runParked = false
        for _ in 0..<200 where !runParked {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() >= baseline + 2 { runParked = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(runParked, "the run's gate must actually suspend before Stop")

        collected.cancel()
        _ = try? await collected.value

        // BOTH parks must drain: the run's own gate (handler or arm) AND the token-less consent
        // (the arm is its only resolver). Poll to baseline, with a rescue on failure so a
        // regression is a red assertion, not a hung runner.
        var bothDrained = false
        for _ in 0..<150 where !bothDrained {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() == baseline { bothDrained = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if !bothDrained {
            await ExecutionSuspensionService.shared.resume(for: tokenlessOp, approved: false, resolvedBy: .localUI)
        }
        XCTAssertTrue(bothDrained,
                      "the root Stop must sweep the conversation's token-less parks — nothing else can ever resolve an MCP consent raised outside the run's task tree")
        let tokenlessResult = await tokenlessTask.value
        XCTAssertFalse(tokenlessResult, "a swept consent resolves denied (outcome 'cancelled')")
    }

    // MARK: - Group 28: WF-TS1 — the inner-outcome demotion ladder
    //
    // ⚠️ WHY THIS GROUP EXISTS. Production node streams emit `.executionFinished` on essentially
    // every path (ChatExecutor, ReActAgentExecutor, Planning/SelfReflection capabilities), and
    // `WorkflowExecutor` reads it at :1234-1257 to decide whether a node that produced text actually
    // SUCCEEDED. Until now no test ever scripted one, so every one of the ~160 integration tests
    // drove the `streamResult.3 == nil` default — the EXCEPTIONAL shape — and the entire ladder was
    // unreachable. Deleting :1234-1257 outright failed NO test.
    //
    // ⚠️ NOTE FOR THE NEXT READER: the mock needed no new capability for this.
    // `.executionFinished` is an ordinary `AgentStreamEvent` and `scriptStream(for:events:)` yields
    // whatever it is handed. Do NOT "improve" `scriptStream` to append a terminal event by default:
    // it breaks `testErrorWithoutTerminalEvent_FailsNodeInsteadOfReportingEmptySuccess`, silently
    // neuters `testCleanStreamWithoutTerminalEventStillCompletes`, and removes the no-terminal-event
    // shape — which `AgentConnect` really does produce — from every other test in this file.

    /// A node whose stream finishes CLEANLY but reports `.failed` must FAIL, not report empty success.
    ///
    /// ⚠️ NO `.error` event is scripted, deliberately. With one, the neighbouring guard at :1222
    /// ("an error arrived and no terminal event did") could produce the failure instead, and the test
    /// would pass with the whole ladder deleted. Omitting it makes :1245-1251 the ONLY possible cause.
    func testInnerOutcomeFailed_FailsTheNode_EvenWhenTheStreamLooksClean() async throws {
        let scenario = WorkflowTestScenario()
        let agent = scenario.addBotNode(name: "Researcher")
        let downstream = scenario.addBotNode(name: "Summarizer")
        scenario.connect(from: agent, to: downstream)

        mockProvider.scriptStream(for: scenario.profileID(for: agent)!, events: [
            .content("Here is a confident-looking answer."),
            .executionFinished(outcome: .failed, reason: "Inner agent hit its iteration ceiling")
        ])
        mockProvider.scriptStream(for: scenario.profileID(for: downstream)!, events: [.content("summary")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == agent },
                      "the node reported .failed — it must not go green with laundered prose")
        XCTAssertFalse(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == agent })
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: downstream)! },
                       "downstream must not consume the output of a node that failed")
    }

    /// Degraded success stays SUCCESS — the run continues and the output flows — but the node is
    /// flagged so the UI can show it amber.
    ///
    /// ⚠️ Asserts BOTH halves. Asserting only "it completed" would pass with `nodeHasWarnings = true`
    /// deleted, which is exactly the trap this repo has hit before.
    func testInnerOutcomeCompletedWithWarnings_CompletesButFlagsTheNode() async throws {
        let scenario = WorkflowTestScenario()
        let agent = scenario.addBotNode(name: "Researcher")
        let downstream = scenario.addBotNode(name: "Summarizer")
        scenario.connect(from: agent, to: downstream)

        mockProvider.scriptStream(for: scenario.profileID(for: agent)!, events: [
            .content("best-effort answer"),
            .executionFinished(outcome: .completedWithWarnings, reason: "loop guard tripped")
        ])
        mockProvider.scriptStream(for: scenario.profileID(for: downstream)!, events: [.content("summary")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == agent },
                      "degraded success is still success — the run must continue")
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedWithWarnings(from: events).contains(agent),
                      "…and the warning must reach the UI, or the amber state is unreachable")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: downstream)! },
                      "the best-effort output is real and must flow downstream")
    }

    /// `.cancelled` demotes to `.canceled`, which is NOT a failure — distinct from every existing
    /// cancellation test, all of which reach that state by THROWING instead.
    func testInnerOutcomeCancelled_MarksTheNodeCancelledNotFailed() async throws {
        let scenario = WorkflowTestScenario()
        let agent = scenario.addBotNode(name: "Researcher")
        scenario.connect(from: agent, to: scenario.addBotNode(name: "Summarizer"))

        mockProvider.scriptStream(for: scenario.profileID(for: agent)!, events: [
            .content("partial"),
            .executionFinished(outcome: .cancelled, reason: "User stopped the run")
        ])

        let events = try await execute(scenario)

        XCTAssertFalse(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == agent },
                       "a cancelled node has not FAILED — conflating them is what made `.cancelled` unreachable before")
        XCTAssertFalse(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == agent })
    }

    /// The untested half of the :1222 guard: an explicit terminal event is the AUTHORITY, so a
    /// stream that errors mid-run and then reports `.completed` has RECOVERED.
    /// `testErrorWithoutTerminalEvent_…` covers only the no-terminal-event half.
    func testErrorFollowedByCompletedTerminalEvent_CountsAsRecovered() async throws {
        let scenario = WorkflowTestScenario()
        let agent = scenario.addBotNode(name: "Researcher")
        scenario.connect(from: agent, to: scenario.addBotNode(name: "Summarizer"))

        mockProvider.scriptStream(for: scenario.profileID(for: agent)!, events: [
            .error(StructuredError(message: "transient hiccup")),
            .content("recovered answer"),
            .executionFinished(outcome: .completed, reason: nil)
        ])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == agent },
                      "an explicit .completed outranks an earlier .error — the node recovered")
        XCTAssertFalse(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == agent })
    }

    /// ⚠️ Pins a STRING COUPLING ACROSS TWO FILES plus its consequence. `AgentFailureReason.classify`
    /// (AgentModel.swift:872-882) recognises the circuit-breaker sentence from
    /// `CognitiveCircuitBreaker.swift` and returns `.repetitiveActionLoop`, whose `isRetryable` is
    /// FALSE — retrying a deterministic stale-loop abort would just loop again at full token cost.
    /// If that literal is ever reworded, classification silently falls back to `.modelError`
    /// (retryable) and the node is re-run `maxNodeRetries` times. This test is what makes that loud.
    func testCircuitBreakerAbortIsClassifiedUnretryable_AndIsNotRetried() async throws {
        let scenario = WorkflowTestScenario()
        let agent = scenario.addBotNode(name: "Researcher")
        scenario.setNodeConfig(WorkflowNodeConfig(maxNodeRetries: 2), for: agent)
        scenario.connect(from: agent, to: scenario.addBotNode(name: "Summarizer"))

        mockProvider.scriptStream(for: scenario.profileID(for: agent)!, events: [
            .content("looping"),
            .executionFinished(
                outcome: .failed,
                reason: "Tool 'read_file' has been called 3 times with the same parameters and results across multiple iterations. Breaking stale loop."
            )
        ])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == agent })
        let attempts = mockProvider.invocations.filter { $0.profileID == scenario.profileID(for: agent)! }.count
        XCTAssertEqual(attempts, 1,
                       "a stale-loop abort is deterministic — retrying it burns \(2) more full agent turns for an identical failure")
    }

    /// The other half: P0-6 must survive. When something genuinely FAILS, the recovery chain still
    /// fires THROUGH a skipped intermediate node — the dead-end this fix must not reintroduce.
    func testFailedRun_ErrorSignalStillReachesARecoveryBranchThroughASkippedNode() async throws {
        let scenario = WorkflowTestScenario()
        let fetcher = scenario.addBotNode(name: "Fetcher")
        let summarizer = scenario.addBotNode(name: "Summarizer")
        let recovery = scenario.addBotNode(name: "Recovery")

        scenario.connect(from: fetcher, to: summarizer)                                     // default port
        scenario.connect(from: summarizer, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptError(for: scenario.profileID(for: fetcher)!,
                                 error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: summarizer)!, events: [.content("summary")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("RECOVERED")])

        _ = try await execute(scenario)

        let recoveryProfileID = scenario.profileID(for: recovery)!
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == recoveryProfileID },
                      "the recovery branch must still run when a real failure started the cascade")
    }

    // MARK: - Group 33: WF-TS10 — the runtime nesting-depth backstop
    //
    // ⚠️ `WorkflowDepth.maxDepth` had NO runtime coverage: every existing nesting test builds a
    // STATIC chain, which pre-flight validation refuses first, so the executor's own guard was
    // never reached. It is reached here by BINDING the TaskLocal — exactly what production does at
    // WorkflowExecutor.swift:150 — which is also the only way to model the case the backstop
    // exists for: validating A can be invalidated by editing B while A's canvas is closed.
    //
    // Every assertion is written against `WorkflowDepth.maxDepth`, never the literal 3, so
    // changing the cap again (it went 5 → 3 on 2026-08-13) does not break the suite.

    func testRunStartedBeyondMaxDepth_IsRefusedBeforeAnyNodeRuns() async throws {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Should Never Run")
        mockProvider.scriptStream(for: scenario.profileID(for: bot)!, events: [.content("ran")])

        do {
            // Entering at `maxDepth` means this run is level maxDepth + 1 — one past the limit.
            _ = try await execute(scenario, startingDepth: WorkflowDepth.maxDepth)
            XCTFail("A run entered at depth \(WorkflowDepth.maxDepth + 1) must be refused")
        } catch let error as WorkflowError {
            guard case .nodeExecutionFailed(_, let profileName, let underlying) = error else {
                XCTFail("Expected nodeExecutionFailed, got \(error)"); return
            }
            XCTAssertEqual(profileName, "Workflow")
            XCTAssertTrue(underlying.contains("Maximum workflow nesting depth (\(WorkflowDepth.maxDepth)) exceeded"),
                          "got: \(underlying)")
        }

        XCTAssertTrue(mockProvider.invocations.isEmpty,
                      "the guard must refuse BEFORE dispatching any node — no tokens may be spent past the limit")
    }

    /// ⚠️ The backstop's actual reason for existing: the STATIC chain here is only 2 levels, so
    /// pre-flight validation passes — this run is over the limit only because it STARTED inside
    /// another workflow. Also the only pin on the depth TaskLocal propagating into a child executor.
    func testSubWorkflowChildInheritsDepth_AndIsRefusedAtTheLimit() async throws {
        let scenario = WorkflowTestScenario()
        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Nested Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let sub = scenario.addSubWorkflowNode(name: "Nested Step", workflowProfileID: inner.workflowProfileID)
        let sibling = scenario.addBotNode(name: "Sibling")   // unconnected: proves the OUTER level was allowed

        mockProvider.scriptStream(for: inner.profileID(for: innerBot)!, events: [.content("MUST NOT RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: sibling)!, events: [.content("sibling ok")])

        // The outer workflow runs AT the limit; its child is therefore one past it.
        let events = try await execute(scenario, startingDepth: WorkflowDepth.maxDepth - 1)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains { $0.nodeID == sub },
                      "the child at depth \(WorkflowDepth.maxDepth + 1) must fail its node")
        XCTAssertTrue(failed.first(where: { $0.nodeID == sub })?.error.contains("nesting depth") == true,
                      "the failure must name the depth limit — got: \(failed.first(where: { $0.nodeID == sub })?.error ?? "<none>")")
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == inner.profileID(for: innerBot)! },
                       "no node inside the refused child may run")
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == sibling },
                      "the OUTER workflow, exactly at the limit, must still run")
    }

    /// The boundary in the allowed direction — `maxDepth` levels is the LIMIT, not one past it.
    func testRunAtExactlyMaxDepth_IsAllowed() async throws {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "At The Limit")
        mockProvider.scriptStream(for: scenario.profileID(for: bot)!, events: [.content("ok")])

        let events = try await execute(scenario, startingDepth: WorkflowDepth.maxDepth - 1)

        XCTAssertEqual(StreamCollector.contentText(from: events), "ok",
                       "\(WorkflowDepth.maxDepth) levels is the LIMIT, not one past it — the guard is `<=`")
    }

    // MARK: - Group 32: WF-TS9 — the gate auto-decision timeout

    /// ⚠️ WF-TS9: a configured gate timeout must actually auto-decide — the gate FAILS and routes
    /// onto its `error` port, which is what GateNodeInspectorView promises the user and what
    /// `outputPortLabels(for:)` draws. Nothing pinned it: `testUnansweredGate_BranchStops` reaches
    /// `chosenOption == nil` through the HARNESS (`choosing: nil`), never through the timer, so a
    /// regression that ignored `config.timeout` entirely would not have failed a single test.
    ///
    /// ⚠️ MUST use `makeStream` + `StreamCollector.collect`, NOT `execute` — `execute` answers
    /// every gate immediately, resolving it before the timer could ever run.
    func testGateWithTimeout_Unanswered_FailsOntoErrorPortAndSkipsOptionBranch() async throws {
        let scenario = WorkflowTestScenario()
        let source  = scenario.addBotNode(name: "Source")
        let gate    = scenario.addGateNode(name: "Timed Gate", options: ["Approve", "Reject"], timeout: 0.5)
        let approve = scenario.addBotNode(name: "Approve Arm")
        let handler = scenario.addBotNode(name: "Timeout Handler")
        scenario.connect(from: source, to: gate)
        scenario.connect(from: gate, to: approve, portLabel: "Approve")
        scenario.connect(from: gate, to: handler, portLabel: WorkflowEdge.errorPortLabel)
        mockProvider.scriptStream(for: scenario.profileID(for: source)!,  events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: approve)!, events: [.content("must not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("handled the no-answer")])

        // ⚠️ Nobody answers this gate. A regression that ignores `config.timeout` parks FOREVER,
        // so the watchdog converts a hang into a loud assertion failure instead of a dead suite.
        let stream = makeStream(scenario)
        let runner = Task { try await StreamCollector.collect(from: stream) }
        let watchdog = Task { try? await Task.sleep(for: .seconds(5)); runner.cancel() }
        let started = Date()
        let events = try await runner.value
        watchdog.cancel()
        let elapsed = Date().timeIntervalSince(started)

        // 1. It really PARKED and really auto-decided — not an instant nil, not a hang.
        XCTAssertGreaterThan(elapsed, 0.4, "the gate must actually wait for its deadline")
        XCTAssertLessThan(elapsed, 4.0, "the gate must auto-decide, not park until the watchdog")
        // 2. The banner got a live deadline to count down.
        let gates = WorkflowStreamCollector.gateRequests(from: events)
        XCTAssertEqual(gates.count, 1)
        XCTAssertNotNil(gates.first?.deadline, "a configured timeout must reach the banner as a deadline")
        // 3. The node FAILED with the unanswered reason.
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let gateFailure = try XCTUnwrap(failed.first(where: { $0.nodeID == gate }),
                                        "an unanswered timed gate must fail — got failures: \(failed.map(\.profileName))")
        // Reported as EXPIRED since 2026-09-27 (HITL Waiting Contract, decision B) — it was
        // "was not answered" under a `.modelError` whose remediation blamed the model.
        XCTAssertTrue(gateFailure.error.contains("Gate expired"), "got: \(gateFailure.error)")
        // 4. The error port is LIVE (the WF61 contract the inspector advertises) …
        let startedIDs = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(startedIDs.contains(handler),
                      "the timed-out gate must activate `error` so a recovery branch runs")
        // 5. … and no option branch was taken.
        XCTAssertFalse(startedIDs.contains(approve), "no option was chosen, so no option branch runs")
    }

    /// ⚠️ WF-TS9 twin: a configured timeout must not poison the healthy path — the human's choice
    /// wins the race and routes to its port. Before this, only `testGateInsideSubWorkflowBody_…`
    /// touched a timed gate at all, and there the timeout is a hang-guard, not the assertion.
    func testGateWithTimeout_AnsweredBeforeDeadline_RoutesToChosenPort() async throws {
        let scenario = WorkflowTestScenario()
        let source  = scenario.addBotNode(name: "Source")
        let gate    = scenario.addGateNode(name: "Timed Gate", options: ["Approve", "Reject"], timeout: 5)
        let approve = scenario.addBotNode(name: "Approve Arm")
        let handler = scenario.addBotNode(name: "Timeout Handler")
        scenario.connect(from: source, to: gate)
        scenario.connect(from: gate, to: approve, portLabel: "Approve")
        scenario.connect(from: gate, to: handler, portLabel: WorkflowEdge.errorPortLabel)
        mockProvider.scriptStream(for: scenario.profileID(for: source)!,  events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: approve)!, events: [.content("approved work")])
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("must not run")])

        let events = try await executeWithGate(scenario, choosing: "Approve")

        let startedIDs = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(startedIDs.contains(approve), "the answered choice must route to its port even with a timeout set")
        XCTAssertFalse(startedIDs.contains(handler), "an answered gate must not activate `error`")
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == gate },
                      "the gate must COMPLETE, not fail")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).allSatisfy { $0.nodeID != gate })
        XCTAssertNotNil(try XCTUnwrap(WorkflowStreamCollector.gateRequests(from: events).first).deadline,
                        "the deadline must reach the banner on the answered path too")
    }

    // MARK: - Group 34: the UNIFIED Router decision policy (2026-08-17 redesign)
    //
    // ⚠️ One setting, both triggers: EMPTY and AMBIGUOUS resolve through the same dropdown.

    private func policyRouterConfig(_ policy: RouterDecisionPolicy,
                                    rules: [ConditionRule]) -> ConditionNodeConfig {
        var config = ConditionNodeConfig()
        config.rules = rules
        config.decisionPolicy = policy
        return config
    }

    /// ⚠️ THE BEHAVIOUR CHANGE THE USER APPROVED. Two rules match; the policy says fail. Under the
    /// legacy pair this silently took the first match — rule order used as a tiebreak nobody chose.
    func testPolicyFailNode_AmbiguityFailsInsteadOfSilentlyTakingTheFirstMatch() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        let router = scenario.addConditionNode(name: "Router",
                                               config: policyRouterConfig(.failNode, rules: rules))
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        let recovery = scenario.addBotNode(name: "Recovery")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")
        scenario.connect(from: router, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        // Matches BOTH rules.
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("urgent invoice problem")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("must not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("recovered")])

        let events = try await execute(scenario)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains { $0.nodeID == router },
                      "two rules matched and the policy says fail — the first-match tiebreak is gone")
        let reason = try XCTUnwrap(failed.first { $0.nodeID == router }).error
        XCTAssertTrue(reason.contains("2 rules matched"), "the reason must name the ambiguity: \(reason)")
        XCTAssertTrue(reason.contains("Urgent") && reason.contains("Billing"),
                      "and name the competing branches: \(reason)")
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: urgent)! },
                       "no branch may be silently chosen")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: recovery)! },
                      "the error port is the documented recovery channel")
    }

    /// ⚠️ The author's explicit default beats the implicit rule-order tiebreak — including when
    /// rules DID match. That is the point of choosing it from a dropdown.
    func testPolicyRoute_OverridesEvenTheRulesThatMatched() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let general = ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "zzz")
        let rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice"),
            general
        ]
        let router = scenario.addConditionNode(
            name: "Router", config: policyRouterConfig(.route(ruleID: general.id), rules: rules))
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        let generalArm = scenario.addBotNode(name: "General Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")
        scenario.connect(from: router, to: generalArm, portLabel: "General")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("urgent invoice problem")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("must not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: generalArm)!, events: [.content("handled")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty)
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: generalArm)! },
                      "the chosen default wins")
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: urgent)! },
                       "a branch that matched must NOT also run — one port, one branch")
    }

    /// Exactly one match still routes without consulting the policy at all (spec point 1).
    func testPolicyIsNotConsultedWhenExactlyOneRuleMatches() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        // A policy that would FAIL if it were consulted — proving it is not.
        let router = scenario.addConditionNode(name: "Router",
                                               config: policyRouterConfig(.failNode, rules: rules))
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("urgent please")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("handled")])

        let events = try await execute(scenario)
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty,
                      "one clean match must never reach the can't-decide setting")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: urgent)! })
    }

    /// EMPTY under `.endBranch`: the branch ends quietly and the Router's content is the answer.
    func testPolicyEndBranch_OnEmptyEndsQuietly() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        let router = scenario.addConditionNode(name: "Router",
                                               config: policyRouterConfig(.endBranch, rules: rules))
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("nothing matches this")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("must not run")])

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty,
                      "`.endBranch` ends the branch — it does not fail it")
        XCTAssertTrue(WorkflowStreamCollector.nodeSkippedEvents(from: events)
                        .contains { $0.nodeID == urgent && $0.reason == .notChosen })
        XCTAssertTrue(WorkflowStreamCollector.contentText(from: events).contains("nothing matches this"),
                      "the Router becomes a terminal and its passthrough is the final answer")
    }

    /// ⚠️ Ask on an UNATTENDED run never parks — it applies the configured fallback immediately.
    /// `execute` resolves gates with nil, but this must not even reach a gate.
    func testPolicyAsk_UnattendedRunTakesTheFallbackWithoutParking() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice")
        ]
        let router = scenario.addConditionNode(
            name: "Router", config: policyRouterConfig(.ask(fallback: .failNode), rules: rules))
        let recovery = scenario.addBotNode(name: "Recovery")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: recovery, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("urgent invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: recovery)!, events: [.content("recovered")])

        let events = try await WorkflowRunAttendance.$isAttended.withValue(false) {
            try await execute(scenario)
        }

        XCTAssertTrue(WorkflowStreamCollector.gateRequests(from: events).isEmpty,
                      "an unattended run must NOT park on a banner nobody can see")
        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == router },
                      "the configured fallback (fail) applies instead")
    }

    /// The attended twin: the gate IS offered, and the options are the branches that matched.
    func testPolicyAsk_AttendedRunOffersTheMatchedBranches() async throws {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let rules = [
            ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
            ConditionRule(label: "Billing", field: .upstreamOutput, op: .contains, value: "invoice"),
            ConditionRule(label: "General", field: .upstreamOutput, op: .contains, value: "zzz")
        ]
        let router = scenario.addConditionNode(
            name: "Router", config: policyRouterConfig(.ask(fallback: .failNode), rules: rules))
        let urgent = scenario.addBotNode(name: "Urgent Arm")
        scenario.connect(from: source, to: router)
        scenario.connect(from: router, to: urgent, portLabel: "Urgent")

        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("urgent invoice")])
        mockProvider.scriptStream(for: scenario.profileID(for: urgent)!, events: [.content("handled")])

        let events = try await executeWithGate(scenario, choosing: "Urgent")

        let gates = WorkflowStreamCollector.gateRequests(from: events)
        XCTAssertEqual(gates.count, 1, "an attended ambiguous run must ask")
        XCTAssertEqual(gates.first?.options, ["Urgent", "Billing"],
                       "only the branches that matched are offered — General did not match")
        XCTAssertTrue(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: urgent)! },
                      "the human's choice routes")
    }
}
