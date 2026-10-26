// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunToolApprovalTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

/// "Allow for this run" through the real check sites: the Action-node arm of `WorkflowExecutor` and the agent tool loop.
/// Every confirmation that DOES reach a banner is denied by the collector, so a regression shows as a banner plus a
/// denial rather than a hung test.
final class RunToolApprovalTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private let conversationID = UUID()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
    }

    override func tearDown() {
        let cid = conversationID
        Task { await SessionToolApprovals.shared.clear(conversationID: cid) }
        super.tearDown()
    }

    /// Drains a stream, denying every confirmation it raises, and reports which tools asked.
    private func collectDenyingConfirmations(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>
    ) async throws -> (events: [AgentStreamEvent], asked: [String]) {
        var events: [AgentStreamEvent] = []
        var asked: [String] = []
        for try await event in stream {
            events.append(event)
            if case .requestConfirmation(let toolName, _, let operationID, _, _) = event {
                asked.append(toolName)
                try await Task.sleep(for: .milliseconds(50))
                await ExecutionSuspensionService.shared.resume(for: operationID, approved: false, resolvedBy: .localUI)
            }
        }
        return (events, asked)
    }

    private func succeededToolNames(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .toolSucceeded(let output, _, _) = $0 { return output.toolName }; return nil }
    }

    // MARK: - Action nodes

    /// Two Action nodes using the same confirming tool, run inside `runID`.
    private func runTwoActionNodes(inRun runID: UUID, bindings: [String: String] = ["path": "~/Demo/a.txt"])
        async throws -> (events: [AgentStreamEvent], asked: [String]) {
        let scenario = WorkflowTestScenario()
        let first = scenario.addActionNode(name: "Move A", toolName: "move_file",
                                           argumentBindings: bindings, requiresConfirmation: true)
        let second = scenario.addActionNode(name: "Move B", toolName: "move_file",
                                            argumentBindings: bindings, requiresConfirmation: true)
        scenario.connect(from: first, to: second)
        mockProvider.scriptTool(name: "move_file", output: "moved", requiresConfirmation: true)

        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = ToolApprovalRun.$id.withValue(runID) {
            executor.executeWorkflow(
                userInput: "go", conversationID: conversationID, traceContext: traceContext,
                onTraceUpdate: { _ in }, layout: scenario.layout, profileMap: scenario.profileMap,
                streamProvider: mockProvider)
        }
        return try await collectDenyingConfirmations(stream)
    }

    /// The feature: one run grant covers BOTH nodes. The durable chat grant is node-scoped and could not do this.
    func testRunGrant_CoversEveryActionNodeInTheRun() async throws {
        let run = UUID()
        await SessionToolApprovals.shared.allowForRun(
            .anyArguments, toolName: "move_file", risk: .moderate, conversationID: conversationID, runID: run)

        let result = try await runTwoActionNodes(inRun: run)

        XCTAssertTrue(result.asked.isEmpty, "no node should ask once the run allowed the tool; asked: \(result.asked)")
        XCTAssertEqual(succeededToolNames(result.events), ["move_file", "move_file"])
    }

    /// The same grant does nothing for the NEXT run — both nodes ask (and are denied by the collector).
    func testRunGrant_DoesNotCoverALaterRun() async throws {
        await SessionToolApprovals.shared.allowForRun(
            .anyArguments, toolName: "move_file", risk: .moderate, conversationID: conversationID, runID: UUID())

        let result = try await runTwoActionNodes(inRun: UUID())

        XCTAssertEqual(result.asked, ["move_file"], "the first node asks; its denial fails it and skips the second")
        XCTAssertTrue(succeededToolNames(result.events).isEmpty)
    }

    /// An exact-call grant, keyed from the very JSON the Action node sends, covers that call in every node.
    func testExactCallGrant_CoversTheIdenticalActionCall() async throws {
        let run = UUID()
        let argsData = WorkflowActionArgs.build(
            bindings: ["path": "~/Demo/a.txt"], schema: ToolParameters(type: "object", properties: [:], required: []),
            input: "go", inputJSON: nil, variables: [:])
        let canonical = try XCTUnwrap(SessionToolApprovals.canonicalArguments(json: argsData))
        await SessionToolApprovals.shared.allowForRun(
            .exactCall(canonicalArguments: canonical), toolName: "move_file", risk: .moderate,
            conversationID: conversationID, runID: run)

        let result = try await runTwoActionNodes(inRun: run)

        XCTAssertTrue(result.asked.isEmpty, "the identical call must not ask; asked: \(result.asked)")
        XCTAssertEqual(succeededToolNames(result.events), ["move_file", "move_file"])
    }

    func testExactCallGrant_DoesNotCoverDifferentArguments() async throws {
        let run = UUID()
        await SessionToolApprovals.shared.allowForRun(
            .exactCall(canonicalArguments: SessionToolApprovals.canonicalArguments(["path": .string("~/Demo/a.txt")])),
            toolName: "move_file", risk: .moderate, conversationID: conversationID, runID: run)

        let result = try await runTwoActionNodes(inRun: run, bindings: ["path": "~/Demo/OTHER.txt"])

        XCTAssertEqual(result.asked, ["move_file"], "a different path must ask")
    }

    // MARK: - Agent tool loop

    /// Driven through the real `ReActAgentExecutor`, since the workflow mock replaces the inner executor and never reaches
    /// `ToolExecutionLoop`'s confirmation arm.
    private func runAgent(inRun runID: UUID, input callInput: String = "payload")
        async throws -> (events: [AgentStreamEvent], asked: [String]) {
        let tool = TestToolFactory.make(name: "send_webhook", output: "sent", requiresConfirmation: true)
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "Posting.",
                                toolCalls: [TestToolCallFactory.make(name: "send_webhook", input: callInput)]),
            ModernCognitiveStep(reasoning: "Done.")
        ])
        var input = TestAgentInputFactory.make(query: "post the payload", tools: [tool])
        input.conversationID = conversationID
        let stream = ToolApprovalRun.$id.withValue(runID) {
            ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in }
        }
        return try await collectDenyingConfirmations(stream)
    }

    func testRunGrant_ServesTheAgentToolLoop() async throws {
        let run = UUID()
        await SessionToolApprovals.shared.allowForRun(
            .anyArguments, toolName: "send_webhook", risk: .moderate, conversationID: conversationID, runID: run)

        let result = try await runAgent(inRun: run)

        XCTAssertTrue(result.asked.isEmpty, "asked: \(result.asked)")
        XCTAssertEqual(succeededToolNames(result.events), ["send_webhook"])
    }

    /// The agent side keys the call from its structured arguments; the grant was keyed the same way.
    func testExactCallGrant_ServesTheAgentToolLoop_OnlyForTheSameArguments() async throws {
        let run = UUID()
        let call = TestToolCallFactory.make(name: "send_webhook", input: "payload")
        await SessionToolApprovals.shared.allowForRun(
            .exactCall(canonicalArguments: SessionToolApprovals.canonicalArguments(call.arguments)),
            toolName: "send_webhook", risk: .moderate, conversationID: conversationID, runID: run)

        let same = try await runAgent(inRun: run, input: "payload")
        XCTAssertTrue(same.asked.isEmpty, "asked: \(same.asked)")

        let different = try await runAgent(inRun: run, input: "another payload")
        XCTAssertEqual(different.asked, ["send_webhook"])
    }

    // MARK: - Wiring: the run id must be bound where every run starts

    /// Every test above binds the run id itself, so none would notice if the app stopped binding it — run grants would then
    /// silently never apply. The send path's single chokepoint must bind it to the same id banners carry.
    func testStartMessageStreamBindsTheRunIDBannersCarry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("devgentic/Core/Utils/ActiveStreamManager.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("ToolApprovalRun.$id.withValue(agentMessage.id)"),
                      "startMessageStream must bind ToolApprovalRun.id to the run's agent message id")
        XCTAssertTrue(source.contains("TraceContext(profile: config.profile, messageID: agentMessage.id)"),
                      "banners carry traceContext.messageID as runMessageID; it must be the same agent message id")
    }
}
