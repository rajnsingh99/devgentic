// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SessionToolApprovalsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SessionToolApprovalsTests: XCTestCase {

    /// An isolated UserDefaults suite so the durable store doesn't touch `.standard` or other tests.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.sessionToolApprovals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// The core of the user's requirement: an approval in one conversation must NOT apply to another.
    func testApprovalIsScopedPerConversation() async {
        let defaults = makeDefaults()
        let convA = UUID()
        let convB = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "write_file", risk: .moderate, conversationID: convA)

        let inA = await store.isAllowed(toolName: "write_file", conversationID: convA)
        let inB = await store.isAllowed(toolName: "write_file", conversationID: convB)
        XCTAssertTrue(inA, "the tool must be allowed in the conversation it was approved in")
        XCTAssertFalse(inB, "the approval must NOT leak into a different conversation")
    }

    /// Survives a quit/relaunch: a fresh instance reading the same store sees the grant.
    func testApprovalSurvivesRestart() async {
        let defaults = makeDefaults()
        let conv = UUID()

        let original = SessionToolApprovals(defaults: defaults)
        await original.allow(toolName: "execute_shell", risk: .moderate, conversationID: conv)

        // Simulate relaunch: a brand-new actor hydrating from the same durable store.
        let reloaded = SessionToolApprovals(defaults: defaults)
        let allowed = await reloaded.isAllowed(toolName: "execute_shell", conversationID: conv)
        XCTAssertTrue(allowed, "a per-conversation grant must survive an app restart")
    }

    /// Clearing a conversation (deletion) drops its grants — including from the durable store.
    func testClearRemovesConversationGrant() async {
        let defaults = makeDefaults()
        let conv = UUID()

        let store = SessionToolApprovals(defaults: defaults)
        await store.allow(toolName: "delete_file", risk: .moderate, conversationID: conv)
        await store.clear(conversationID: conv)

        let reloaded = SessionToolApprovals(defaults: defaults)
        let allowed = await reloaded.isAllowed(toolName: "delete_file", conversationID: conv)
        XCTAssertFalse(allowed, "a cleared grant must not persist after the conversation is deleted")
    }

    /// Clearing one conversation must not disturb another's grants.
    func testClearIsScopedToOneConversation() async {
        let defaults = makeDefaults()
        let convA = UUID()
        let convB = UUID()

        let store = SessionToolApprovals(defaults: defaults)
        await store.allow(toolName: "move_file", risk: .moderate, conversationID: convA)
        await store.allow(toolName: "move_file", risk: .moderate, conversationID: convB)
        await store.clear(conversationID: convA)

        let stillInB = await store.isAllowed(toolName: "move_file", conversationID: convB)
        XCTAssertTrue(stillInB, "clearing one conversation must not affect another")
    }

    // MARK: - Workflow node scoping
    //
    // Every node of a workflow run shares ONE conversationID, so a conversation-wide grant meant
    // approving a tool in one node silently auto-approved it in every other node — including
    // nodes the user had deliberately configured to ask. Nodes configure their tools
    // independently, so an approval given to one is not an answer for another.

    /// The requirement, stated directly: same conversation, same tool, different node → ask again.
    func testApprovalInOneNodeDoesNotLeakToAnotherNode() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let nodeA = UUID()
        let nodeB = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation, nodeID: nodeA)

        let inA = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeA)
        let inB = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeB)
        XCTAssertTrue(inA, "the granting node must not be re-prompted")
        XCTAssertFalse(inB, "a different node of the SAME run must still ask")
    }

    /// No fall-back in either direction. A node grant must not satisfy a conversation-scoped
    /// check (that would leak into ordinary chat), and a conversation grant must not silently
    /// cover every node (that is the leak this scope exists to close).
    func testNodeAndConversationScopesDoNotFallBackToEachOther() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let node = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "read_file", risk: .moderate, conversationID: conversation, nodeID: node)
        let asConversation = await store.isAllowed(toolName: "read_file", conversationID: conversation)
        XCTAssertFalse(asConversation, "a node grant must not answer a conversation-scoped check")

        await store.allow(toolName: "grep_files", risk: .moderate, conversationID: conversation)
        let asNode = await store.isAllowed(toolName: "grep_files", conversationID: conversation, nodeID: node)
        XCTAssertFalse(asNode, "a conversation grant must not blanket-approve every node")
    }

    /// Deleting a conversation drops the whole run, nodes included — otherwise node grants would
    /// outlive the thing they were scoped to and never be reachable to clear.
    func testClearRemovesEveryNodeScopeInTheConversation() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let nodeA = UUID()
        let nodeB = UUID()
        let other = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation, nodeID: nodeA)
        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation, nodeID: nodeB)
        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation)
        await store.allow(toolName: "write_file", risk: .moderate, conversationID: other, nodeID: nodeA)

        await store.clear(conversationID: conversation)

        let a = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeA)
        let b = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeB)
        let conv = await store.isAllowed(toolName: "write_file", conversationID: conversation)
        let untouched = await store.isAllowed(toolName: "write_file", conversationID: other, nodeID: nodeA)
        XCTAssertFalse(a); XCTAssertFalse(b); XCTAssertFalse(conv)
        XCTAssertTrue(untouched, "a different conversation's node grant must survive")
    }

    func testNodeScopedGrantSurvivesRestart() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let node = UUID()

        let original = SessionToolApprovals(defaults: defaults)
        await original.allow(toolName: "batch_command", risk: .moderate, conversationID: conversation, nodeID: node)

        let reloaded = SessionToolApprovals(defaults: defaults)
        let sameNode = await reloaded.isAllowed(toolName: "batch_command", conversationID: conversation, nodeID: node)
        let otherNode = await reloaded.isAllowed(toolName: "batch_command", conversationID: conversation, nodeID: UUID())
        XCTAssertTrue(sameNode, "a node grant must survive an app restart")
        XCTAssertFalse(otherNode, "and must still not leak to another node after restart")
    }

    /// Grants written before node scoping existed are stored under a bare conversation UUID.
    /// They must hydrate as conversation-scoped rather than being discarded — the store key was
    /// deliberately NOT version-bumped so users keep the approvals they already gave.
    func testLegacyConversationOnlyKeysStillHydrate() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        // Exactly the v1 on-disk shape: [conversationUUID: [toolName]], no node component.
        defaults.set([conversation.uuidString: ["execute_shell"]],
                     forKey: "hitl.perConversationToolApprovals.v1")

        let store = SessionToolApprovals(defaults: defaults)
        let allowed = await store.isAllowed(toolName: "execute_shell", conversationID: conversation)
        XCTAssertTrue(allowed, "a pre-existing conversation grant must not be dropped by the upgrade")
    }

    // MARK: - [WF-SE6] Grants are attended-only

    /// The store reads `WorkflowRunAttendance.isAttended` (a TaskLocal) on the caller's task:
    /// an interactive "Allow for this chat" grant must never auto-approve a scheduled or
    /// ChatOps run — that leak made one banner click a permanent unattended auto-approve.
    func testGrantIsNotServedWhenTheRunIsUnattended() async {
        let store = SessionToolApprovals(defaults: UserDefaults(suiteName: "se6-attendance-\(UUID().uuidString)")!)
        let conv = UUID(), node = UUID()
        await store.allow(toolName: "send_webhook", risk: .moderate, conversationID: conv, nodeID: node)

        let attended = await store.isAllowed(toolName: "send_webhook", conversationID: conv, nodeID: node)
        XCTAssertTrue(attended, "the default (attended) task keeps the existing behaviour")

        let unattended = await WorkflowRunAttendance.$isAttended.withValue(false) {
            await store.isAllowed(toolName: "send_webhook", conversationID: conv, nodeID: node)
        }
        XCTAssertFalse(unattended,
                       "an unattended run must not consume an interactive grant — unattended approval is the node's explicit setting, never a banner side effect")
    }

    // MARK: - Run-scoped grants ("allow for this run")

    /// Checks `isAllowed` from inside run `runID`, as a tool check site in that run would.
    private func isAllowed(_ store: SessionToolApprovals, _ tool: String, conv: UUID, run: UUID?,
                           node: UUID? = nil, args: String? = nil) async -> Bool {
        await ToolApprovalRun.$id.withValue(run) {
            await store.isAllowed(toolName: tool, conversationID: conv, nodeID: node, canonicalArguments: args)
        }
    }

    /// The point of the feature: one grant covers every node of the run, unlike the node-scoped chat grant.
    func testRunGrant_AnyArguments_CoversEveryNodeAndAnyArguments() async {
        let store = SessionToolApprovals(defaults: makeDefaults())
        let conv = UUID(), run = UUID()
        await store.allowForRun(.anyArguments, toolName: "move_file", risk: .moderate, conversationID: conv, runID: run)

        let nodeA = await isAllowed(store, "move_file", conv: conv, run: run, node: UUID(), args: #"{"path":"/a"}"#)
        let nodeB = await isAllowed(store, "move_file", conv: conv, run: run, node: UUID(), args: #"{"path":"/b"}"#)
        let otherTool = await isAllowed(store, "copy_file", conv: conv, run: run, node: UUID())
        XCTAssertTrue(nodeA)
        XCTAssertTrue(nodeB, "a run grant is not narrowed to the node that asked")
        XCTAssertFalse(otherTool, "only the granted tool")
    }

    /// A run grant ends with its run: the next run, a task outside any run, and another conversation all ask again.
    func testRunGrant_DoesNotLeakToAnotherRunOrConversationOrOutsideARun() async {
        let store = SessionToolApprovals(defaults: makeDefaults())
        let conv = UUID(), run = UUID()
        await store.allowForRun(.anyArguments, toolName: "move_file", risk: .moderate, conversationID: conv, runID: run)

        let nextRun = await isAllowed(store, "move_file", conv: conv, run: UUID())
        let noRun = await isAllowed(store, "move_file", conv: conv, run: nil)
        let otherConv = await isAllowed(store, "move_file", conv: UUID(), run: run)
        XCTAssertFalse(nextRun, "a later run of the same conversation must ask again")
        XCTAssertFalse(noRun, "a task with no run id (e.g. detached) must not be served a run grant")
        XCTAssertFalse(otherConv)
    }

    func testRunGrant_IsInMemoryOnly() async {
        let defaults = makeDefaults()
        let conv = UUID(), run = UUID()
        await SessionToolApprovals(defaults: defaults)
            .allowForRun(.anyArguments, toolName: "move_file", risk: .moderate, conversationID: conv, runID: run)

        let reloaded = await isAllowed(SessionToolApprovals(defaults: defaults), "move_file", conv: conv, run: run)
        XCTAssertFalse(reloaded, "a run grant must not survive a relaunch")
    }

    func testRunGrant_AnyArguments_IsRefusedForDestructiveTools() async {
        let store = SessionToolApprovals(defaults: makeDefaults())
        let conv = UUID(), run = UUID()
        await store.allowForRun(.anyArguments, toolName: "delete_file", risk: .destructive, conversationID: conv, runID: run)

        let allowed = await isAllowed(store, "delete_file", conv: conv, run: run, args: #"{"path":"/x"}"#)
        XCTAssertFalse(allowed, "an any-arguments grant would approve deletions the user never saw")
    }

    /// An exact-call grant covers the identical call only — and, unlike "any arguments", is allowed for destructive tools.
    func testRunGrant_ExactCall_MatchesOnlyTheSameArguments_EvenWhenDestructive() async {
        let store = SessionToolApprovals(defaults: makeDefaults())
        let conv = UUID(), run = UUID()
        let approved = SessionToolApprovals.canonicalArguments(["command": .string("npm test")])
        await store.allowForRun(.exactCall(canonicalArguments: approved), toolName: "run_command", risk: .destructive,
                                conversationID: conv, runID: run)

        let same = await isAllowed(store, "run_command", conv: conv, run: run, node: UUID(), args: approved)
        let different = await isAllowed(store, "run_command", conv: conv, run: run,
                                        args: SessionToolApprovals.canonicalArguments(["command": .string("rm -rf build")]))
        let noArgs = await isAllowed(store, "run_command", conv: conv, run: run, args: nil)
        XCTAssertTrue(same)
        XCTAssertFalse(different, "different arguments must ask again")
        XCTAssertFalse(noArgs, "a check site that cannot state its arguments must not match an exact grant")
    }

    func testRunGrant_IsNotServedToAnUnattendedRun() async {
        let store = SessionToolApprovals(defaults: makeDefaults())
        let conv = UUID(), run = UUID()
        await store.allowForRun(.anyArguments, toolName: "move_file", risk: .moderate, conversationID: conv, runID: run)

        let unattended = await WorkflowRunAttendance.$isAttended.withValue(false) {
            await self.isAllowed(store, "move_file", conv: conv, run: run)
        }
        XCTAssertFalse(unattended, "banner grants never serve a run nobody can answer")
    }

    func testEndRunAndClearDropRunGrants() async {
        let store = SessionToolApprovals(defaults: makeDefaults())
        let conv = UUID(), runA = UUID(), runB = UUID()
        await store.allowForRun(.anyArguments, toolName: "move_file", risk: .moderate, conversationID: conv, runID: runA)
        await store.allowForRun(.anyArguments, toolName: "move_file", risk: .moderate, conversationID: conv, runID: runB)

        await store.endRun(conversationID: conv, runID: runA)
        let endedRun = await isAllowed(store, "move_file", conv: conv, run: runA)
        let liveRun = await isAllowed(store, "move_file", conv: conv, run: runB)
        XCTAssertFalse(endedRun)
        XCTAssertTrue(liveRun, "ending one run leaves another's grants alone")

        await store.clear(conversationID: conv)
        let afterClear = await isAllowed(store, "move_file", conv: conv, run: runB)
        XCTAssertFalse(afterClear, "deleting the conversation drops its run grants too")
    }

    // MARK: - Canonical arguments: the banner side and the check side must agree

    /// The banner builds its key from params the mediator encoded WITHOUT sorted keys, re-parsed; the check site builds it from
    /// the structured arguments. If these disagreed, an exact-call grant would never match its own call.
    func testCanonicalArguments_BannerSideEqualsCheckSide() throws {
        let arguments: [String: JSONValue] = [
            "path": .string("~/DemoWorkspace/Downloads_messy/"),
            "recursive": .bool(true),
            "limit": .number(3),
            "options": .object(["b": .string("2"), "a": .array([.number(1), .null])]),
        ]
        let unsortedParams = String(data: try JSONEncoder().encode(arguments), encoding: .utf8)!
        let confirmation = PendingToolConfirmation(toolName: "list_directory", params: unsortedParams,
                                                   arguments: JSONValue.parseStructured(unsortedParams))

        XCTAssertEqual(SessionToolApprovals.canonicalArguments(of: confirmation),
                       SessionToolApprovals.canonicalArguments(arguments))
        XCTAssertEqual(SessionToolApprovals.canonicalArguments(json: Data(unsortedParams.utf8)),
                       SessionToolApprovals.canonicalArguments(arguments),
                       "the Action-node side (raw JSON data) must agree too")
    }

    /// The same file spelled two ways is the same call; a different file is not.
    func testCanonicalArguments_NormalisesPathArgumentsByName() {
        let tilde = SessionToolApprovals.canonicalArguments(["path": .string("~/Demo/a.txt")])
        let absolute = SessionToolApprovals.canonicalArguments(["path": .string(NSHomeDirectory() + "/Demo//a.txt")])
        let other = SessionToolApprovals.canonicalArguments(["path": .string("~/Demo/b.txt")])
        XCTAssertEqual(tilde, absolute)
        XCTAssertNotEqual(tilde, other)
    }

    func testCanonicalArguments_TextOnlyBannerHasNone() {
        let confirmation = PendingToolConfirmation(toolName: "large_request", params: "About 40,000 tokens to model X",
                                                   arguments: JSONValue.parseStructured("About 40,000 tokens to model X"))
        XCTAssertNil(SessionToolApprovals.canonicalArguments(of: confirmation),
                     "a banner without structured arguments cannot offer 'allow this exact call'")
    }

    // MARK: - Queued requests a new grant covers

    private func pendingConfirmation(tool: String, args: [String: JSONValue], risk: HITLRiskTier = .moderate,
                                     conv: UUID, run: UUID?) throws -> PendingHITL {
        let params = String(data: try JSONEncoder().encode(args), encoding: .utf8)!
        let id = UUID()
        return PendingHITL(
            id: id,
            origin: HITLOrigin(interface: .workflow, conversationID: conv, nodeID: UUID(), nodeName: nil,
                               title: "Permission required", profileID: nil, runMessageID: run),
            kind: .toolConfirmation(PendingToolConfirmation(id: id, toolName: tool, params: params, risk: risk,
                                                            arguments: JSONValue.parseStructured(params))))
    }

    func testPendingCovered_AnyArguments_PicksSameRunAndTool_OnlyNonDestructive() throws {
        let conv = UUID(), run = UUID()
        let current = try pendingConfirmation(tool: "move_file", args: ["path": .string("/a")], conv: conv, run: run)
        let sibling = try pendingConfirmation(tool: "move_file", args: ["path": .string("/b")], conv: conv, run: run)
        let otherTool = try pendingConfirmation(tool: "copy_file", args: ["path": .string("/b")], conv: conv, run: run)
        let otherRun = try pendingConfirmation(tool: "move_file", args: ["path": .string("/b")], conv: conv, run: UUID())
        let noRun = try pendingConfirmation(tool: "move_file", args: ["path": .string("/b")], conv: conv, run: nil)
        let otherConv = try pendingConfirmation(tool: "move_file", args: ["path": .string("/b")], conv: UUID(), run: run)
        let destructive = try pendingConfirmation(tool: "move_file", args: ["path": .string("/c")], risk: .destructive,
                                                  conv: conv, run: run)

        let covered = SessionToolApprovals.pendingCovered(
            by: .anyArguments, toolName: "move_file", conversationID: conv, runID: run,
            in: [current, sibling, otherTool, otherRun, noRun, otherConv, destructive], excluding: current.id)
        XCTAssertEqual(covered, [sibling.id])
    }

    func testPendingCovered_ExactCall_PicksOnlyIdenticalArguments() throws {
        let conv = UUID(), run = UUID()
        let args: [String: JSONValue] = ["sourcePaths": .array([.string("/x")]), "destinationFolder": .string("/d")]
        let current = try pendingConfirmation(tool: "batch_move_files", args: args, risk: .destructive, conv: conv, run: run)
        let identical = try pendingConfirmation(tool: "batch_move_files", args: args, risk: .destructive, conv: conv, run: run)
        var otherArgs = args; otherArgs["destinationFolder"] = .string("/e")
        let different = try pendingConfirmation(tool: "batch_move_files", args: otherArgs, risk: .destructive,
                                                conv: conv, run: run)

        let covered = SessionToolApprovals.pendingCovered(
            by: .exactCall(canonicalArguments: SessionToolApprovals.canonicalArguments(args)),
            toolName: "batch_move_files", conversationID: conv, runID: run,
            in: [current, identical, different], excluding: current.id)
        XCTAssertEqual(covered, [identical.id], "destructive is fine for an exact call; different arguments are not covered")
    }

    // MARK: - Which standing approvals a banner offers (shared by the main window and QuickAccess)

    private func confirmationItem(risk: HITLRiskTier, run: UUID?, params: String = #"{"path":"/a"}"#) -> PendingHITL {
        let id = UUID()
        return PendingHITL(
            id: id,
            origin: HITLOrigin(interface: .chat, conversationID: UUID(), title: "Permission required", runMessageID: run),
            kind: .toolConfirmation(PendingToolConfirmation(id: id, toolName: "move_file", params: params, risk: risk,
                                                            arguments: JSONValue.parseStructured(params))))
    }

    func testStandingOptions_ModerateToolInARun_OffersAllThree() {
        let options = StandingApprovalOptions(for: confirmationItem(risk: .moderate, run: UUID()))
        XCTAssertEqual(options.exactCallArguments, SessionToolApprovals.canonicalArguments(["path": .string("/a")]))
        XCTAssertTrue(options.canAllowToolForRun)
        XCTAssertTrue(options.canAllowForChat)
    }

    func testStandingOptions_DestructiveTool_OffersOnlyTheExactCall() {
        let options = StandingApprovalOptions(for: confirmationItem(risk: .destructive, run: UUID()))
        XCTAssertTrue(options.canAllowExactCallForRun)
        XCTAssertFalse(options.canAllowToolForRun)
        XCTAssertFalse(options.canAllowForChat)
    }

    func testStandingOptions_OutsideARun_OffersOnlyTheChatGrant() {
        let options = StandingApprovalOptions(for: confirmationItem(risk: .moderate, run: nil))
        XCTAssertFalse(options.canAllowExactCallForRun, "a run grant needs a run to belong to")
        XCTAssertFalse(options.canAllowToolForRun)
        XCTAssertTrue(options.canAllowForChat)
    }

    func testStandingOptions_TextOnlyBanner_HasNoExactCall() {
        let options = StandingApprovalOptions(for: confirmationItem(risk: .moderate, run: UUID(), params: "About 40,000 tokens"))
        XCTAssertFalse(options.canAllowExactCallForRun)
        XCTAssertTrue(options.canAllowToolForRun)
    }

    func testStandingOptions_ExactCallCoversTheEditedArguments() {
        let edited: [String: JSONValue] = ["path": .string("/edited")]
        let options = StandingApprovalOptions(for: confirmationItem(risk: .moderate, run: UUID()), editedArguments: edited)
        XCTAssertEqual(options.exactCallArguments, SessionToolApprovals.canonicalArguments(edited),
                       "the grant must cover what actually runs")
    }

    func testStandingOptions_NonToolRequest_OffersNothing() {
        let item = PendingHITL(id: UUID(),
                               origin: HITLOrigin(interface: .workflow, conversationID: UUID(), title: "Gate", runMessageID: UUID()),
                               kind: .gate(PendingGate(prompt: "Approve?", options: ["Yes", "No"])))
        XCTAssertTrue(StandingApprovalOptions(for: item).isEmpty)
    }

    /// Both banners must offer standing approvals from the one shared rule and grant them through the one shared path; a
    /// private copy in either would let the two windows disagree about the same request.
    func testBothBannersUseTheSharedOptionsAndGrantPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let main = try source("devgentic/Interfaces/Shared/ChatInput/InteractionBannerStack.swift")
        let quickAccessBanner = try source("devgentic/Interfaces/QuickAccess/Views/QuickAccessHITLBanner.swift")
        let quickAccessSession = try source("devgentic/Interfaces/QuickAccess/QuickAccessSessionViewModel.swift")

        XCTAssertTrue(main.contains("StandingApprovalOptions(for: pending"), "main banner must use the shared options")
        XCTAssertTrue(main.contains("vm.allowToolForRun("), "main banner must grant through the shared path")
        XCTAssertTrue(quickAccessBanner.contains("StandingApprovalOptions(for: pending"), "QuickAccess must use the shared options")
        XCTAssertTrue(quickAccessSession.contains("$0.allowToolForRun(pending, approval: approval)"),
                      "QuickAccess must grant through the shared path")
        for (name, code) in [("main", main), ("QuickAccess", quickAccessBanner + quickAccessSession)] {
            XCTAssertFalse(code.contains("SessionToolApprovals.shared.allowForRun"),
                           "\(name) registers run grants itself instead of through MainApplicationViewModel.allowToolForRun")
        }
    }
}
