// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SessionToolApprovals.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "SessionToolApprovals")

// Why: one definition for both banners (main window and QuickAccess), so they cannot offer different standing approvals
// for the same request.
/// Which standing approvals a tool confirmation may offer. Pure, for tests.
struct StandingApprovalOptions: Equatable, Sendable {
    /// The canonical arguments an exact-call grant would cover, or nil when it cannot be offered.
    let exactCallArguments: String?
    /// "Allow <tool> for this run": needs a run, withheld from destructive tools.
    let canAllowToolForRun: Bool
    /// "Allow for this chat": the durable grant, withheld from destructive tools.
    let canAllowForChat: Bool

    /// "Allow this exact call for this run": needs a run and structured arguments.
    var canAllowExactCallForRun: Bool { exactCallArguments != nil }
    var isEmpty: Bool { !canAllowExactCallForRun && !canAllowToolForRun && !canAllowForChat }

    /// - Parameter editedArguments: the user's edits, when the banner has them; an exact-call grant covers what runs.
    init(for pending: PendingHITL, editedArguments: [String: JSONValue]? = nil) {
        guard case .toolConfirmation(let confirmation) = pending.kind else {
            self.exactCallArguments = nil; self.canAllowToolForRun = false; self.canAllowForChat = false
            return
        }
        let hasRun = pending.origin.runMessageID != nil
        let arguments = editedArguments.map(SessionToolApprovals.canonicalArguments)
            ?? SessionToolApprovals.canonicalArguments(of: confirmation)
        self.exactCallArguments = hasRun ? arguments : nil
        self.canAllowToolForRun = hasRun && confirmation.risk != .destructive
        self.canAllowForChat = confirmation.risk != .destructive
    }
}

// Why: a TaskLocal, not a parameter: the check sites (agent tool loop, Action node) sit far below the run and have only a
// conversation id. Bound around the run's Task creation, so a `Task.detached` reads nil and its run grants do not apply —
// it asks instead, which is the safe direction.
/// The run the current task belongs to: the id of the agent message whose stream started it, the same id a banner
/// carries as `HITLOrigin.runMessageID`. Bound in `ActiveStreamManager.startMessageStream`.
enum ToolApprovalRun {
    @TaskLocal static var id: UUID?
}

/// What a run-scoped approval covers. Both kinds end with the run and live in memory only.
enum RunApproval: Equatable, Sendable {
    /// This tool with any arguments, in every node of the run. Refused for destructive tools.
    case anyArguments
    /// This tool with exactly these arguments (`SessionToolApprovals.canonicalArguments`). Allowed for destructive tools:
    /// approving the identical call again is what the user already agreed to.
    case exactCall(canonicalArguments: String)
}

// Why: the node is part of the scope: nodes share one conversationID, so a conversation-wide grant would approve other nodes.
/// Allowlist of tools the user chose "Allow for this chat" for on a HITL banner.
/// Scoped to the conversation, and inside a workflow to the node that asked; it never touches the shared agent profile.
/// Mirrored to `UserDefaults` so grants survive relaunch; entries drop only when the conversation is deleted (`clear`).
actor SessionToolApprovals {

    static let shared = SessionToolApprovals()

    /// One approval scope: a conversation, and within a workflow the node that raised the prompt.
    /// `nodeID` is nil for ordinary chat/code runs, which have no node dimension.
    struct Scope: Hashable, Sendable {
        let conversationID: UUID
        let nodeID: UUID?

        init(conversationID: UUID, nodeID: UUID? = nil) {
            self.conversationID = conversationID
            self.nodeID = nodeID
        }

        /// `<conversation>` for a chat grant, `<conversation>|<node>` for a workflow-node grant.
        /// The un-suffixed form doubles as the on-disk key for conversation-scoped grants.
        var storageKey: String {
            guard let nodeID else { return conversationID.uuidString }
            return "\(conversationID.uuidString)|\(nodeID.uuidString)"
        }

        static func parse(storageKey: String) -> Scope? {
            let parts = storageKey.split(separator: "|", maxSplits: 1).map(String.init)
            guard let conversationID = parts.first.flatMap(UUID.init(uuidString:)) else { return nil }
            guard parts.count == 2 else { return Scope(conversationID: conversationID) }
            guard let nodeID = UUID(uuidString: parts[1]) else { return nil }
            return Scope(conversationID: conversationID, nodeID: nodeID)
        }
    }

    /// Key unchanged from v1 on purpose: the old format is a strict subset of the new one (a key
    /// with no `|` is a conversation-scoped grant), so there is nothing to migrate and no version
    /// bump that would discard grants users already gave.
    private static let storeKey = "hitl.perConversationToolApprovals.v1"

    private let defaults: UserDefaults
    private var allowed: [Scope: Set<String>] = [:]

    /// One run of one conversation. Keyed by run, so a grant cannot outlive it even if `endRun` were missed: the next run
    /// has a new id and matches nothing.
    struct RunScope: Hashable, Sendable {
        let conversationID: UUID
        let runID: UUID
    }

    /// A tool call allowed by exact arguments.
    struct ExactCall: Hashable, Sendable {
        let toolName: String
        let canonicalArguments: String
    }

    /// Run-scoped grants: tools allowed with any arguments, and exact calls. In memory only.
    private var runAnyArguments: [RunScope: Set<String>] = [:]
    private var runExactCalls: [RunScope: Set<ExactCall>] = [:]

    // Why: a grant must not cross a surface boundary: a bare conversation key let a paired phone inherit a voice grant.
    /// Conversations the user put in a blanket "approve everything" mode (Orb's Autonomous voice setting).
    /// In-memory only, unlike per-tool grants: a standing mode that survived relaunch would outlive the intent behind it.
    /// Checked inside `isAllowed` to inherit the `canReachAHuman` gate; keyed on (conversation, origin).
    private var autonomousConversations: Set<AutonomousGrant> = []

    /// One conversation, for runs started from ONE surface.
    struct AutonomousGrant: Hashable, Sendable {
        let conversationID: UUID
        /// The surface that was granted it, compared against `WorkflowRunAttendance.origin`.
        let origin: MessageSource
    }

    /// `defaults` is injectable so tests can exercise the durable round-trip on an isolated suite;
    /// the shared singleton uses `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Hydrate from durable storage so an "Allow for this chat" choice survives app restart.
        if let raw = defaults.dictionary(forKey: Self.storeKey) as? [String: [String]] {
            for (key, tools) in raw {
                guard let scope = Scope.parse(storageKey: key) else { continue }
                allowed[scope] = Set(tools)
            }
        }
    }

    // Why: enforce in the model, not only in views: a caller that skipped the check would persist a permanent grant
    // to delete or run shell.
    /// Marks `toolName` as allowed for this scope for the lifetime of the conversation.
    /// `risk` is required and a destructive tool is refused here, since the grant is durable (survives the run and restart).
    func allow(toolName: String, risk: HITLRiskTier, conversationID: UUID, nodeID: UUID? = nil) {
        guard risk != .destructive else {
            logger.error("[HITL] REFUSED a durable 'allow for this chat' grant for destructive tool '\(toolName)' (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: no grant was stored — this tool will ask again every time, which is the intended behaviour for something irreversible. The caller should not have offered the option.")
            return
        }
        allowed[Scope(conversationID: conversationID, nodeID: nodeID), default: []].insert(toolName)
        persist()
    }

    // Why: run-scoped rather than node-scoped: a workflow's nodes share one run, so the user approves a tool once for the
    // whole run instead of once per node; ending with the run keeps it from silently covering a later, edited workflow.
    /// Allows `toolName` for the rest of run `runID`, in every node. `.anyArguments` is refused for a destructive tool, as
    /// it would approve calls the user never saw; `.exactCall` is allowed for any tier.
    func allowForRun(_ approval: RunApproval, toolName: String, risk: HITLRiskTier, conversationID: UUID, runID: UUID) {
        let scope = RunScope(conversationID: conversationID, runID: runID)
        switch approval {
        case .anyArguments:
            guard risk != .destructive else {
                logger.error("[HITL] REFUSED an 'allow this tool for this run' grant for destructive tool '\(toolName)' (conv \(conversationID.uuidString.prefix(8)), run \(runID.uuidString.prefix(8))). CONSEQUENCE: no grant was stored — each call of this tool still asks unless its exact arguments were allowed. The caller should not have offered the option.")
                return
            }
            runAnyArguments[scope, default: []].insert(toolName)
            logger.info("[HITL] '\(toolName)' allowed with ANY arguments for run \(runID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: every node in this run calls it without asking until the run ends; nothing is saved.")
        case .exactCall(let canonicalArguments):
            runExactCalls[scope, default: []].insert(ExactCall(toolName: toolName, canonicalArguments: canonicalArguments))
            logger.info("[HITL] '\(toolName)' allowed for ONE exact set of arguments for run \(runID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: the identical call runs without asking until the run ends; any other arguments still ask.")
        }
    }

    /// Drops every grant of a finished run. Grants are keyed by run, so this is memory hygiene, not the safety boundary.
    func endRun(conversationID: UUID, runID: UUID) {
        let scope = RunScope(conversationID: conversationID, runID: runID)
        runAnyArguments.removeValue(forKey: scope)
        runExactCalls.removeValue(forKey: scope)
    }

    /// Whether the current run holds a grant for this call.
    private func runGrantCovers(toolName: String, conversationID: UUID, canonicalArguments: String?) -> Bool {
        guard let runID = ToolApprovalRun.id else {
            let hasAnyRunGrant = runAnyArguments.keys.contains { $0.conversationID == conversationID }
                || runExactCalls.keys.contains { $0.conversationID == conversationID }
            if hasAnyRunGrant {
                logger.notice("[HITL] '\(toolName)' checked OUTSIDE any run (no run id on this task) while conversation \(conversationID.uuidString.prefix(8)) holds run-scoped grants. CONSEQUENCE: those grants are not applied and the tool asks — likely a `Task.detached` on the check path.")
            }
            return false
        }
        let scope = RunScope(conversationID: conversationID, runID: runID)
        if runAnyArguments[scope]?.contains(toolName) == true {
            logger.info("[HITL] '\(toolName)' auto-approved by this run's 'allow this tool' grant (run \(runID.uuidString.prefix(8))).")
            return true
        }
        if let canonicalArguments,
           runExactCalls[scope]?.contains(ExactCall(toolName: toolName, canonicalArguments: canonicalArguments)) == true {
            logger.info("[HITL] '\(toolName)' auto-approved by this run's 'allow this exact call' grant (run \(runID.uuidString.prefix(8))).")
            return true
        }
        return false
    }

    // MARK: - Canonical arguments

    /// The one form exact-call grants are stored and matched in: sorted keys, path arguments normalised by name
    /// (`serializeToolParams`). Both sides must go through here, or equal calls would compare unequal.
    nonisolated static func canonicalArguments(_ arguments: [String: JSONValue]) -> String {
        serializeToolParams(arguments)
    }

    /// The canonical form of a confirmation's arguments, or nil when they are not a JSON object (a text-only banner such as
    /// the large-request gate), which cannot be allowed by exact call.
    nonisolated static func canonicalArguments(of confirmation: PendingToolConfirmation) -> String? {
        guard case .object(let dict)? = confirmation.arguments else { return nil }
        return canonicalArguments(dict)
    }

    /// The canonical form of a JSON-encoded arguments object, or nil when it is not one.
    nonisolated static func canonicalArguments(json data: Data) -> String? {
        guard let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return canonicalArguments(dict)
    }

    // Why: parallel nodes raise their confirmations before the user answers any, so a new grant must also answer the
    // ones already queued, or "allow for this run" would still need one click per node.
    /// The pending confirmations, other than `excluding`, that a new run grant covers: same conversation and run, same tool,
    /// and for an exact call the same canonical arguments. Pure, for tests.
    nonisolated static func pendingCovered(
        by approval: RunApproval,
        toolName: String,
        conversationID: UUID,
        runID: UUID,
        in pending: [PendingHITL],
        excluding operationID: UUID
    ) -> [UUID] {
        pending.compactMap { item in
            guard item.id != operationID,
                  item.origin.conversationID == conversationID,
                  item.origin.runMessageID == runID,
                  case .toolConfirmation(let confirmation) = item.kind,
                  confirmation.toolName == toolName else { return nil }
            switch approval {
            case .anyArguments:
                return confirmation.risk == .destructive ? nil : item.id
            case .exactCall(let canonical):
                return canonicalArguments(of: confirmation) == canonical ? item.id : nil
            }
        }
    }

    // Why: autonomous includes `execute_shell` by design; safety comes from its shape (typed picker, in-memory, one
    // conversation, `canReachAHuman` gate), so do not add a risk filter.
    /// Puts a conversation into (or out of) blanket-approval mode. See `autonomousConversations`.
    /// `origin` is required, not defaulted: a default would let a new caller grant approval to every surface by omission.
    func setAutonomous(_ enabled: Bool, conversationID: UUID, origin: MessageSource) {
        let grant = AutonomousGrant(conversationID: conversationID, origin: origin)
        let changed = enabled
            ? autonomousConversations.insert(grant).inserted
            : autonomousConversations.remove(grant) != nil
        guard changed else { return }
        logger.notice("[HITL] Autonomous approval \(enabled ? "ENABLED" : "disabled") for conversation \(conversationID.uuidString.prefix(8)), origin '\(origin.rawValue)'. CONSEQUENCE: while enabled, every tool in this conversation started FROM THAT SURFACE is approved without a prompt; a run of any other origin still asks. The grant is in-memory only and does not survive relaunch.")
    }

    /// Whether any surface holds a blanket grant on this conversation.
    /// Origin-agnostic on purpose: this answers a UI/reporting question; authorization is `isAllowed`, which compares origin.
    func isAutonomous(conversationID: UUID) -> Bool {
        autonomousConversations.contains { $0.conversationID == conversationID }
    }

    /// Whether the given surface holds a blanket grant on this conversation.
    func isAutonomous(conversationID: UUID, origin: MessageSource) -> Bool {
        autonomousConversations.contains(AutonomousGrant(conversationID: conversationID, origin: origin))
    }

    // Why: a banner grant must not serve scheduled runs nobody can answer; unattended approval is explicit per-node config.
    // ChatOps runs still get it (a human is reachable); blanket grants match `WorkflowRunAttendance.origin`.
    /// Whether the user already chose "Allow for this chat" for this tool in this scope.
    /// An exact scope match, with no fallback to the conversation-wide grant when a `nodeID` is supplied.
    /// Reachable-human runs only: `WorkflowRunAttendance.canReachAHuman` is read from TaskLocals on the caller's task.
    /// `canonicalArguments` (from `canonicalArguments(_:)`) lets an exact-call run grant match; nil checks tool-level grants
    /// only. Run grants are checked before the durable chat grant.
    func isAllowed(toolName: String, conversationID: UUID, nodeID: UUID? = nil, canonicalArguments: String? = nil) -> Bool {
        guard WorkflowRunAttendance.canReachAHuman else {
            if allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) == true {
                logger.notice("[HITL] Interactive grant for '\(toolName)' NOT served to a run nobody can answer (conv \(conversationID.uuidString.prefix(8)), scheduled). CONSEQUENCE: the tool is not auto-approved by the banner grant; unattended approval requires the node's explicit 'unattended auto-approve' setting.")
            }
            return false
        }
        let origin = WorkflowRunAttendance.origin
        if autonomousConversations.contains(AutonomousGrant(conversationID: conversationID, origin: origin)) {
            logger.notice("[HITL] '\(toolName)' auto-approved by AUTONOMOUS mode (conv \(conversationID.uuidString.prefix(8)), origin '\(origin.rawValue)'). CONSEQUENCE: no prompt was shown and the user did not see this tool's arguments.")
            return true
        }
        // A grant exists for this conversation but for a different surface: logged so "why did my phone prompt" is answerable.
        if autonomousConversations.contains(where: { $0.conversationID == conversationID }) {
            logger.notice("[HITL] Autonomous grant NOT served to a '\(origin.rawValue)' run of conversation \(conversationID.uuidString.prefix(8)) — the grant belongs to another surface. CONSEQUENCE: this tool asks for approval as normal; a standing 'approve everything' chosen on one surface deliberately does not carry to another.")
        }
        if runGrantCovers(toolName: toolName, conversationID: conversationID, canonicalArguments: canonicalArguments) {
            return true
        }
        return allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) ?? false
    }

    /// Drops all allowances for a conversation — every node scope within it included, since the
    /// conversation is what is being deleted.
    func clear(conversationID: UUID) {
        // Every surface's grant on this conversation: it is being deleted, so no origin retains a claim.
        autonomousConversations = autonomousConversations.filter { $0.conversationID != conversationID }
        runAnyArguments = runAnyArguments.filter { $0.key.conversationID != conversationID }
        runExactCalls = runExactCalls.filter { $0.key.conversationID != conversationID }
        let doomed = allowed.keys.filter { $0.conversationID == conversationID }
        guard !doomed.isEmpty else { return }
        for scope in doomed { allowed.removeValue(forKey: scope) }
        persist()
    }

    /// Mirrors the in-memory allowlist to `UserDefaults`.
    private func persist() {
        let raw = allowed.reduce(into: [String: [String]]()) { acc, entry in
            guard !entry.value.isEmpty else { return }
            acc[entry.key.storageKey] = Array(entry.value)
        }
        defaults.set(raw, forKey: Self.storeKey)
    }
}
