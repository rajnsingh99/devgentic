// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ActiveStreamManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AppKit
import os


private let logger = DGLogger(category: "ActiveStreamManager")

/// Delegate protocol for RemoteMirrorService to observe stream lifecycle.
@MainActor
protocol ActiveStreamMirrorDelegate: AnyObject {
    // Why: `.localUI` means 'not attributed', so a consumer sending data off the machine must treat it as a refusal.
    // Do not stamp `agentMessage.messageSource` earlier: `OrbAmbientRunWatcher` reads it at `didEndStream`.
    /// - Parameter startedBy: the surface that started this run, read from the user message.
    /// The agent message is not yet attributed when the delegate is called.
    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage, startedBy: MessageSource, for conversationID: UUID)
    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage)
    /// A started run is WAITING for the local model, which another run holds (local inference
    /// coordinator). Called once, when it starts waiting; `notice` is the plain-language status.
    func activeStreamManager(_ manager: ActiveStreamManager, didQueueForLocalModel message: ChatMessage,
                             notice: String, startedBy: MessageSource, for conversationID: UUID)
}

extension ActiveStreamMirrorDelegate {
    /// Only the remote mirror has someone to tell; every other observer ignores it.
    func activeStreamManager(_ manager: ActiveStreamManager, didQueueForLocalModel message: ChatMessage,
                             notice: String, startedBy: MessageSource, for conversationID: UUID) {}
}

@Observable @MainActor
final class ActiveStreamManager {

    private(set) var activeStreams: [UUID: ChatMessage] = [:]

    /// Live assistant message id → the id of the user question it is answering. Written and
    /// cleared in lockstep with `activeStreams`; see `incompleteTurnIDs`.
    @ObservationIgnored private var liveRunQuestionIDs: [UUID: UUID] = [:]

    // MARK: - Dependencies
    @ObservationIgnored private var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Conversation admission

    /// Coordinator that admits one local run at a time across conversations.
    /// Settable so tests can observe registration without the process-wide instance.
    @ObservationIgnored var inferenceCoordinator: LocalInferenceCoordinator = .shared

    @ObservationIgnored private lazy var admission = ConversationAdmission { [weak self] conversationID, messageID in
        guard let self else { return false }
        return Self.isConversationBusy(self.activeStreams, conversationID: conversationID, excluding: messageID)
    }

    /// Whether some other run is live in `conversationID`.
    /// `excluding` is the asking run's own message id: a waiting run is already registered and must not find itself busy.
    static func isConversationBusy(_ streams: [UUID: ChatMessage],
                                   conversationID: UUID,
                                   excluding messageID: UUID) -> Bool {
        streams.values.contains { $0.conversationId == conversationID && $0.id != messageID }
    }

    /// When each live run claimed its stream; written and removed in lockstep with `activeStreams`.
    /// Distinct from `ChatMessage.timestamp`, which is old for a Redo or Resume that streams into an existing message.
    @ObservationIgnored private var streamStartedAt: [UUID: Date] = [:]
    @ObservationIgnored nonisolated(unsafe) private var permissionResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var clarificationResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var planReviewResolvedObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var gateResolvedObserver: Any?

    @ObservationIgnored private let persistenceService: ChatPersistenceProtocol

    /// Per-message time of the last in-flight flush; rate-limits the token-path flush.
    /// Boundary flushes pass `immediate: true` and bypass it; cleared when the message finalizes.
    @ObservationIgnored private var lastInFlightFlush: [UUID: Date] = [:]
    private static let inFlightFlushInterval: TimeInterval = 2.0
    @ObservationIgnored private let fileProcessorService: FileProcessorService
    @ObservationIgnored private let backendOrchestrationService: BackendOrchestrationService

    /// Weak holder for a multicast stream-lifecycle delegate; each ChatOps transport registers its own mirror.
    /// A torn-down mirror service clears itself.
    private struct WeakMirror { weak var delegate: ActiveStreamMirrorDelegate? }
    @ObservationIgnored private var mirrorDelegates: [WeakMirror] = []

    /// Registers a mirror delegate (idempotent; prunes any dead refs).
    func addMirrorDelegate(_ delegate: ActiveStreamMirrorDelegate) {
        mirrorDelegates.removeAll { $0.delegate == nil || $0.delegate === delegate }
        mirrorDelegates.append(WeakMirror(delegate: delegate))
    }

    /// Unregisters a mirror delegate (e.g. when a transport stops); also prunes dead refs.
    func removeMirrorDelegate(_ delegate: ActiveStreamMirrorDelegate) {
        mirrorDelegates.removeAll { $0.delegate == nil || $0.delegate === delegate }
    }

    /// The currently-live delegates (dead weak refs filtered out).
    private var liveMirrorDelegates: [ActiveStreamMirrorDelegate] {
        mirrorDelegates.compactMap { $0.delegate }
    }

    /// Unified pending-interaction queue, owned by `MainApplicationViewModel` and injected after init.
    @ObservationIgnored var interactionCenter: InteractionCenter?

    init(
        persistenceService: ChatPersistenceProtocol,
        fileProcessorService: FileProcessorService
    ) {
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.backendOrchestrationService = BackendOrchestrationService(
            fileProcessorService: fileProcessorService
        )
        setupHITLResolvedObservers()
        logger.info("ActiveStreamManager initialized.")
    }

    deinit {
        if let observer = permissionResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = clarificationResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = planReviewResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = gateResolvedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Cross-Surface HITL Sync

    /// Observes resolved notifications so the Mac UI clears stale banners
    /// when Telegram (or a timeout) handles the HITL interaction.
    private func setupHITLResolvedObservers() {
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                // [HITL/P5] InteractionCenter is the single source of truth — clear by operationID.
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                // Nudge the active stream's thinking island forward immediately (subsequent stream
                // events refine it) so the UI doesn't briefly look stuck on "waiting".
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    // Only nudge a message that was actually awaiting input — don't clobber a
                    // concurrent stream's accurate state in the same conversation.
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    // Only nudge a message that was actually awaiting input — don't clobber a
                    // concurrent stream's accurate state in the same conversation.
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }

        planReviewResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPlanReviewResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (precise decision + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the same outcome (covers chat/code/workflow incl. gates).
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.planning)
                    }
                }
            }
        }

        // [E1] Gate resolved (chosen option / cancelled) → clear banner + trace + audit, like the others.
        gateResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlGateResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let operationID { self.interactionCenter?.resolve(operationID: operationID) }
                // [HITL/C1] Emit the resolution trace span (chosen option / cancelled + wait duration).
                let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String ?? "resolved"
                self.emitHITLTraceSpan(operationID: operationID, outcome: outcome)
                // [HITL/C2] Stamp the durable audit row with the chosen option.
                if let operationID {
                    Task { await TraceRecorder.shared.recordHITLResolved(operationID: operationID.uuidString, outcome: outcome, resolvedAt: Date()) }
                }
                guard let conversationID else { return }
                for (_, message) in self.activeStreams where message.conversationId == conversationID && message.isStreaming {
                    if case .interaction = message.agentState {
                        message.agentState = .thinking(.reflecting)
                    }
                }
            }
        }
    }


    // Why: Applied after `resolve`, not by filtering `inMemory`: the in-flight row reaches the store within ~100 ms.
    // Keyed on live in-process runs, not `lifecycleState`: a force-quit leaves persisted `.streaming` rows on disk.
    /// Ids of turns still being written (live assistant messages plus their questions), except `keeping`.
    /// Such turns are omitted from every run's history; the rule is a `nonisolated static` over plain values.
    nonisolated static func incompleteTurnIDs(
        liveRuns: [UUID: UUID],
        keeping keepID: UUID?
    ) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (assistantID, questionID) in liveRuns {
            ids.insert(assistantID)
            ids.insert(questionID)
        }
        if let keepID { ids.remove(keepID) }
        return ids
    }

    /// The single source both history consumers (request path and context gauge) use for omitted in-flight turns.
    /// - Parameter keeping: the question the calling run is itself asking, which is never omitted.
    func incompleteTurnIDs(keeping keepID: UUID? = nil) -> Set<UUID> {
        Self.incompleteTurnIDs(liveRuns: liveRunQuestionIDs, keeping: keepID)
    }

    /// The live assistant rows only: the context gauge's omission set.
    /// Unlike `incompleteTurnIDs`, the just-sent question stays counted because the next request carries it.
    func liveReplyIDs() -> Set<UUID> {
        Set(liveRunQuestionIDs.keys)
    }

    /// The text conversation memory is searched with: what the user said (the persisted row), not the model query.
    /// Falls back to `modelQuery` when the row has no text, e.g. an image-only turn.
    static func retrievalQuery(for userMessage: ChatMessage, modelQuery: String) -> String {
        guard let said = userMessage.content.textContent,
              !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return modelQuery }
        return said
    }

    static func deriveHistory(
        userMessage: ChatMessage,
        omitting: Set<UUID> = [],
        before boundary: ChatMessage?,
        persistence: ChatPersistenceProtocol
    ) async -> [ChatMessage] {
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: userMessage.conversationId,
            inMemory: [userMessage],
            persistence: persistence
        )
        let settled = omitting.isEmpty
            ? resolved.history
            : resolved.history.filter { $0.id == userMessage.id || !omitting.contains($0.id) }
        let final = boundary.map { MessagingCoordinator.historySlice(before: $0, in: settled) } ?? settled

        // Single place every run passes through, so the log shows what history the turn carried and what was left out.
        let omittedCount = resolved.history.count - settled.count
        let cutCount = settled.count - final.count
        var notes: [String] = []
        if resolved.capHit {
            notes.append("CAP HIT (\(BackendHistoryResolver.messageLimit)) → older turns are omitted from direct context and rely on RAG retrieval")
        }
        if omittedCount > 0 {
            notes.append("\(omittedCount) row(s) omitted as an UNFINISHED TURN (a live run's reply and the question it is answering) → the model is told nothing about a turn still being written, deliberately")
        }
        if cutCount > 0 {
            notes.append("\(cutCount) row(s) cut at or after the message being rewritten → regenerate/resume replays only what preceded it. The cut is by TIMESTAMP (strictly-earlier survives), so a row that TIES the boundary is cut too")
        }
        logger.info("[HISTORY] Derived \(final.count) message(s) for the request — stored: \(resolved.storedCount), source: \(userMessage.messageSource.rawValue), conversationID: \(userMessage.conversationId.uuidString.prefix(8)), messageID: \(userMessage.id.uuidString.prefix(8))\(notes.isEmpty ? "" : " — " + notes.joined(separator: "; "))")
        return final
    }

    /// Index of the first message older than its predecessor, or nil if `history` is oldest-first.
    /// Equal timestamps do not count: a tie is unordered, and `BackendHistoryResolver.merge` can produce one.
    nonisolated static func firstDescendingPair(in history: [ChatMessage]) -> Int? {
        guard history.count > 1 else { return nil }
        for index in 1..<history.count where history[index].timestamp < history[index - 1].timestamp {
            return index
        }
        return nil
    }

    @discardableResult
    func startMessageStream(
        withConfig config: BackendRequestConfig,
        userMessage: ChatMessage,
        promptOverride: String? = nil,
        files: [FileSystemItem],
        updating existingMessage: ChatMessage? = nil,
        workflowExecutionState: WorkflowExecutionState? = nil,
        resumeState: TimelineReconstruction? = nil,
        onComplete: @escaping () -> Void
    ) -> ChatMessage {

        // Both derived from the message so they cannot disagree with it.
        let conversationID = userMessage.conversationId
        let userQuery = promptOverride ?? userMessage.content.textContent ?? ""

        // A Code run takes its conversation's project, not whichever one is open; every send surface passes through here.
        let config = config.profile.profileType == .code
            ? BackendRequestConfig(profile: CodeSessionManager.profile(
                config.profile,
                forConversationProject: persistenceService.getConversation(withId: conversationID)?.projectPath))
            : config
        
        // Guard-rail: a workflow profile started without `WorkflowExecutionState` loses its run record and HITL attribution.
        // `WorkflowRunBootstrap.begin(...)` creates that state.
        if config.profile.profileType == .workflow && workflowExecutionState == nil {
            logger.error("""
                [WF_RUN] ⚠️ Workflow '\(config.profile.displayName)' (\(config.profile.id)) started \
                with NO WorkflowExecutionState — conv \(conversationID). CONSEQUENCE: this run \
                leaves no run record (nothing in run history, the run picker or the badge; per-node \
                timelines are never captured), any HITL it raises is attributed to the CHAT \
                interface instead of the workflow view, and capability-card routing stays enabled. \
                The run itself will execute normally. FIX: call WorkflowRunBootstrap.begin(...) at \
                this call site and pass its `state` + call `finalize()` in onComplete.
                """)
        }

        let agentMessage: ChatMessage
        let isRegeneration = existingMessage != nil

        if let messageToUpdate = existingMessage {
            agentMessage = messageToUpdate
            if resumeState != nil {
                // A resumed run regenerates the turn instead of continuing it, so the stale streamed text is cleared.
                // The timeline (tool rows, cards) survives.
                let staleChars = agentMessage.currentAgentContent?.textContent?.count
                    ?? agentMessage.content.textContent?.count ?? 0
                if let agentResponse = agentMessage.agentResponse,
                   agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                    agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex].content = .markdownText("")
                }
                agentMessage.content = .markdownText("")
                agentMessage.invalidateMarkdownCache()
                logger.notice("🚀 [STREAM_RESUME] Resuming message \(agentMessage.id.uuidString) — cleared \(staleChars) chars of interrupted partial prose before re-generation (ASM-3).")
            } else {
                logger.notice("🚀 [STREAM_REGENERATE] Updating message \(agentMessage.id.uuidString) in conversation \(conversationID.uuidString).")
            }
        } else {
            agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: .markdownText(""),
                isStreaming: true,
                backendEntityId: config.profile.id
            )
            agentMessage.profileType = config.profile.profileType
            // `messageSource` is read from the user's message, which every surface must stamp before this call.
            // `.localUI` also means 'not attributed', so on a run you did not type it may be a missing stamp.
            logger.notice("🚀 [STREAM_START] Created message \(agentMessage.id.uuidString) for conversation \(conversationID.uuidString) — started by \(userMessage.messageSource.rawValue), profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue))\(promptOverride != nil ? ", model-facing query DIFFERS from the displayed message (promptOverride)" : "").")
        }

        // Marks the run in-flight and stamps the model identity, so an interrupted run is distinguishable after restart.
        agentMessage.lifecycleState = .streaming
        if let llm = config.profile.resolvedLLMConfig {
            agentMessage.apiProvider = llm.apiProvider.rawValue
            agentMessage.modelName = llm.modelName
            agentMessage.modelDialect = llm.modelDialect.rawValue
        }

        activeStreams[agentMessage.id] = agentMessage
        // The question this run is answering, recorded from the caller since `ChatMessage` has no parent link.
        liveRunQuestionIDs[agentMessage.id] = userMessage.id
        streamStartedAt[agentMessage.id] = Date()
        for delegate in liveMirrorDelegates {
            // Uses `userMessage.messageSource`; the agent message is not yet attributed.
            delegate.activeStreamManager(self, didStartStream: agentMessage,
                                         startedBy: userMessage.messageSource, for: conversationID)
        }

        // Deferred to the next run-loop tick to avoid 'Modifying state during view update' when the caller
        // assigns the returned message to SwiftUI state.
        Task { @MainActor in
            agentMessage.agentState = .thinking(.reasoning)
        }
        
        // Why: Additive on purpose: other sources keep what the caller bound (ChatOps is unattended with a remote responder).
        // `SessionToolApprovals.isAllowed` reads it, so an unattended run cannot spend grants given at the keyboard.
        // The run's origin and attendance are bound around the Task's creation, which unstructured tasks inherit.
        // A woken `.backgroundTask` run is unattended: nobody typed it and nobody is watching.
        let attended = userMessage.messageSource == .backgroundTask
            ? false
            : WorkflowRunAttendance.isAttended
        // Only the unattended case is logged: it silently refuses standing grants, `ask_user` and tool confirmations.
        if !attended {
            logger.notice("[ATTENDANCE] Run \(agentMessage.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) is UNATTENDED (started by \(userMessage.messageSource.rawValue), remote responder: \(WorkflowRunAttendance.hasRemoteResponder)). CONSEQUENCE: standing 'allow for this chat' grants are NOT served to it, and ask_user plus any tool confirmation are refused with an honest observation instead of parking for an answer nobody will give.")
        }
        // The run's identity travels with it: local providers report which run touched a model via `LocalInferenceScope.runID`.
        let streamTask = WorkflowRunAttendance.$isAttended.withValue(attended) {
            WorkflowRunAttendance.$origin.withValue(userMessage.messageSource) {
            // Run-scoped tool approvals ("allow for this run") match on this id, the one a banner carries as `runMessageID`.
            ToolApprovalRun.$id.withValue(agentMessage.id) {
            LocalInferenceScope.$runID.withValue(agentMessage.id) {
            Task { [weak self] in
            guard let self = self else { return }

            // One run per conversation is enforced here, the send path's single chokepoint; the task waits for its turn.
            // The wait is credited to the run's open time bound, so a scheduled run's deadline does not expire in line.
            let admissionCredit: UUID? = ParkScope.chain.isEmpty ? nil : UUID()
            if let admissionCredit { await ExecutionSuspensionService.shared.beginQueueWait(admissionCredit) }
            let waited = await self.admission.awaitTurn(
                conversationID: conversationID, messageID: agentMessage.id,
                // Shown on screen as well as logged, so a queued run does not look like a stalled app.
                onWait: {
                    agentMessage.agentState = .thinking(.queued)
                    self.conversationQueueBegan(agentMessage, conversationID: conversationID)
                })
            if let admissionCredit { await ExecutionSuspensionService.shared.endQueueWait(admissionCredit) }
            if waited {
                agentMessage.agentState = .thinking(.reasoning)
                self.conversationQueueEnded(agentMessage, conversationID: conversationID)
            }
            if Task.isCancelled {
                logger.info("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) was cancelled while waiting for conversation \(conversationID.uuidString.prefix(8)).")
                Self.markWithdrawnBeforeStart(agentMessage, workflow: workflowExecutionState)
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
                // Same cleanup as every other exit of this task.
                // A run cancelled while queued must still reach `onComplete`; `SchedulerCoordinator.sendScheduledMessage` waits on it.
                self.removeTask(for: agentMessage.id)
                onComplete()
                return
            }

            // Local-model layer comes after conversation admission: a run queued behind its own conversation is not competing.
            // A local run waits while another holds the lock; released in `finalizeMessage`.
            let startedBy = userMessage.messageSource
            let localAcquire = await self.inferenceCoordinator.acquire(
                InferenceRunManifest.build(
                    runID: agentMessage.id,
                    conversationID: conversationID,
                    profile: config.profile,
                    source: userMessage.messageSource,
                    attended: attended,
                    isRegeneration: isRegeneration && resumeState == nil,
                    isResume: resumeState != nil),
                observer: LocalWaitObserver(
                    onHold: { [weak self] position, _ in
                        self?.localWaitBegan(agentMessage, conversationID: conversationID,
                                             startedBy: startedBy, position: position)
                    },
                    onWaitEnded: { [weak self] _ in
                        self?.localWaitEnded(agentMessage, conversationID: conversationID)
                    },
                    onConfirmationNeeded: { [weak self] concerns, deadline in
                        self?.localConfirmationNeeded(agentMessage, conversationID: conversationID,
                                                      concerns: concerns, deadline: deadline)
                    },
                    onConfirmed: { [weak self] in
                        self?.localConfirmed(agentMessage, conversationID: conversationID)
                    },
                    onPositionChanged: { [weak self] position, _ in
                        self?.localPositionChanged(agentMessage, conversationID: conversationID, position: position)
                    }))
            var localQueueWait: TimeInterval = 0
            switch localAcquire {
            case .admitted(let waited):
                localQueueWait = waited
            case .cancelled:
                logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) was cancelled while waiting for the local model.")
                Self.markWithdrawnBeforeStart(agentMessage, workflow: workflowExecutionState)
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
                // The same two lines every other exit of this task ends with — see the
                // conversation-admission early return above for what skipping them cost.
                self.removeTask(for: agentMessage.id)
                onComplete()
                return
            case .denied(let reason):
                let refusal = LocalInferenceRefusal(reason: reason)
                workflowExecutionState?.handleError(refusal.localizedDescription)
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: refusal)
                self.removeTask(for: agentMessage.id)
                onComplete()
                return
            }

            // Global compute-time ceiling, opened at admission so queue time never counts; HITL parks and local waits pause it.
            // It is the outermost `ExecutionBudget`, so inner turn, node or tool limits are shortened to fit.
            let ceilingScope = UUID()
            let ceiling = LocalInferenceCoordinator.globalCeiling
            let ceilingFrame: ExecutionBudget.Frame? = if let ceiling {
                await ExecutionBudget.frame(
                    owner: "the \(ToolExecutionMediator.describe(ceiling)) limit on any run",
                    limit: ceiling, scope: ceilingScope)
            } else { nil }
            if let ceiling {
                logger.debug("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) — global ceiling \(ToolExecutionMediator.describe(ceiling)) of compute time opened (scope \(ceilingScope.uuidString.prefix(8))).")
            } else {
                logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) has NO global ceiling (Settings → General → Maximum Run Time is Off). CONSEQUENCE: only its own profile, node and tool limits bound it.")
            }
            let ceilingTask: Task<Void, Never>? = ceiling.map { limit in
                Task { @MainActor [weak self] in
                    await self?.enforceGlobalCeiling(limit, scope: ceilingScope, on: agentMessage)
                }
            }
            await ParkScope.withScope(ceilingScope, conversationID: conversationID) {
            await ExecutionBudget.$frames.withValue(ExecutionBudget.frames + (ceilingFrame.map { [$0] } ?? [])) {

            // Structured Plan & Execute / Reflexion cards (chat and code agents only).
            // Workflow runs keep flat milestone chips: parallel nodes interleave segments the router cannot separate.
            let capabilityRouter = CapabilityCardRouter(message: agentMessage)
            let capabilityCardsEnabled = (workflowExecutionState == nil)

            do {
                let traceContext = TraceContext(profile: config.profile, messageID: agentMessage.id)
                agentMessage.traceID = traceContext.traceID
                // The wait happened before this trace existed, so it is recorded as a metric on it.
                if localQueueWait > 0 {
                    let waitedMs = Int(localQueueWait * 1000)
                    Task { await TraceRecorder.shared.emitMetric(span: traceContext, key: "local_queue_wait", valueMs: waitedMs) }
                }
                // The workflow run record carries the same trace id, linking run history to the trace store.
                workflowExecutionState?.traceID = traceContext.traceID

                let profileType = config.profile.profileType.rawValue
                // Every turn still being written is excluded: this run's own empty placeholder and any concurrent run's.
                // An unfinished turn would make `pairTurns` report its question as answered with nothing.
                let history = await Self.deriveHistory(
                    userMessage: userMessage,
                    omitting: self.incompleteTurnIDs(keeping: userMessage.id),
                    before: existingMessage,
                    persistence: self.persistenceService
                )

                logger.info("[TRACE_INIT] traceID: \(traceContext.traceID), spanID: \(traceContext.spanID), profileType: \(profileType), messageID: \(agentMessage.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                Task {
                    await TraceRecorder.shared.beginTrace(
                        context: traceContext,
                        conversationID: conversationID,
                        messageID: agentMessage.id,
                        // The resolved model for single-model profiles; nil for workflows. A trace label only:
                        // cost is priced per call at each call's own model.
                        modelName: config.profile.resolvedLLMConfig?.modelName
                    )

                    // Captures the complete request configuration for the Report Inspector (one `trace_configs` row per trace).
                    // TODO: pass `codeMemoryContent` from MainApplicationViewModel
                    // Uses the live-detected capability, not the stored copy, so the trace records the tool-calling mode actually used.
                    // Code-mode capture records only the project path; memory length and hash stay nil.
                    let snapshot = TraceConfigSnapshot.capture(
                        traceID: traceContext.traceID,
                        config: BackendRequestConfig(profile: await LiveModelDetection.resolving(config.profile)),
                        historyTurnCount: history.count,
                        files: files,
                        codeMemoryContent: nil
                    )
                    await TraceRecorder.shared.captureConfigSnapshot(snapshot)
                }

                // Log lines carry the query length, not its text: the raw prompt is user content and this reaches the OS log.
                // Callers do not supply history, so a surface cannot hand over a pagination window or a descending store dump.

                // Retained as a SELF-check, not a caller check. Nothing outside can get this
                // wrong any more, so a trip here means the resolver itself regressed.
                if let disorder = Self.firstDescendingPair(in: history) {
                    logger.error("[HISTORY] ⚠️ Derived history is not oldest-first — conv \(conversationID.uuidString.prefix(8)), \(history.count) message(s), first out-of-order pair at index \(disorder). CONSEQUENCE: `pairTurns` walks forward, so every reply is matched to the WRONG question, the newest agent turn is dropped, and the oldest user message is emitted as an orphan marked \"Agent never responded to this query\". Callers no longer supply history, so this is a regression in BackendHistoryResolver.merge, not a caller bug.")
                }

                logger.info("[STREAM_HANDOFF] Passing to BackendOrchestrationService — traceID: \(traceContext.traceID), query: \(userQuery.count) chars, history: \(history.count) msgs, files: \(files.count)")

                let stream = self.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    currentUserMessageID: userMessage.id,
                    retrievalQuery: Self.retrievalQuery(for: userMessage, modelQuery: userQuery),
                    // A Redo/Resume regenerates `existingMessage`: memory from it onward is the rejected answer.
                    regenerating: existingMessage.map { RegenerationBoundary(messageID: $0.id, timestamp: $0.timestamp) },
                    history: history,
                    files: files,
                    context: traceContext,
                    resumeState: resumeState,
                    onTraceUpdate: { _ in } // Trace logs are handled by events now
                )

                logger.info("[STREAM_LISTEN] Awaiting events — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8))")
                
                var tokenBuffer = ""
                var lastUpdateTime = Date()
                var tokensReceivedInWindow = 0
                var adaptiveInterval: TimeInterval = 0.1 // Start with default
                // The last `.error` event's message; consulted at stream end only when the engine's terminal outcome is `.failed`.
                var lastErrorEventMessage: String?
                // The bubble's content from before a `.draftText` preview started, or nil when no
                // draft is showing. Restored when the draft is withdrawn, and before the first
                // `.content` appends — so a draft is REPLACED by the answer, never duplicated by it.
                var draftBaseline: MessageContent?

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .thought(let thoughtText, let id, let sourceNodeID):
                        // 1. Handle Thoughts (Update Headline + Append to History using structured ID)
                        agentMessage.agentState = .thinking(.reasoning)
                        let thoughtEvent = TimelineEvent.thought(id: id, text: thoughtText)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(thoughtEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Thought → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(thoughtEvent)) {
                            agentMessage.appendTimelineEvent(thoughtEvent)
                        }

                    case .reasoning(let text, let id, let sourceNodeID):
                        // Model-authored monologue; persisted as `.reasoning` so consumers can tell it from `.thought`.
                        agentMessage.agentState = .thinking(.reasoning)
                        let reasoningEvent = TimelineEvent.reasoning(id: id, text: text)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(reasoningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Reasoning → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(reasoningEvent)) {
                            agentMessage.appendTimelineEvent(reasoningEvent)
                        }

                    case .toolCall(let name, let params, let sourceNodeID, let stepId):
                        agentMessage.agentState = .acting(.tool(name: name))
                        // Live agent tabs (badge-only): announce a STARTING file write so
                        // the Code Viewer can open/update a background tab.
                        if let payload = AgentLiveWriteEvent.began(toolName: name, params: params, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.began, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        let toolEvent = TimelineEvent.toolExecution(
                            ToolExecutionData(id: UUID(), name: name, params: params, output: nil, isSuccess: nil, isExecuting: true, stepId: stepId)
                        )
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(toolEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] ToolCall '\(name)' → node timeline [\(nodeID)], count=\(wfState.nodeTimelines[nodeID]?.count ?? 0)")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(toolEvent)) {
                            agentMessage.appendTimelineEvent(toolEvent)
                        }
                        // [G1 Piece 1] Boundary flush — a tool just started; persist so an interrupted
                        // run shows it ran (and, when this is the parked tool, that it was in flight).
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    // Permission request goes to the unified `InteractionCenter`; the banner carries which node is asking.
                    case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID, let sourceNodeName):
                        agentMessage.agentState = .interaction(.permission(toolName: toolName))
                        // Park marker plus the operationID join key, flushed immediately so a restart can re-raise the HITL.
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        // Provenance-aware tier: native map for native names, declared annotations for MCP tools, `.moderate` on collision.
                        let riskResolution = ToolRiskResolver.resolve(toolName: toolName)
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .toolConfirmation(PendingToolConfirmation(
                                id: operationID,
                                toolName: toolName,
                                params: params,
                                risk: riskResolution.risk,
                                arguments: JSONValue.parseStructured(params),
                                riskIsServerDeclared: riskResolution.serverDeclared
                            )),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    // [ASK_USER] Clarification request → unified InteractionCenter.
                    case .requestClarification(let question, let operationID, let sourceNodeID, let options, let multiline, let sourceNodeName):
                        agentMessage.agentState = .interaction(.clarification)
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .clarification(PendingClarification(id: operationID, question: question, options: options, multiline: multiline)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    // [E1] Workflow Gate request → unified InteractionCenter as a `.gate` interaction.
                    case .requestGate(let prompt, let options, let operationID, let deadline, let sourceNodeID, let inputText, let highlights, let sourceNodeName):
                        agentMessage.agentState = .interaction(.gate)
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .gate(PendingGate(id: operationID, prompt: prompt, options: options, deadline: deadline, inputText: inputText, highlights: highlights)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    case .toolSucceeded(let output, let durationMs, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        // ANY successful tool may have changed files — see `WorkspaceActivity`.
                        WorkspaceActivity.post(reason: "tool \(output.toolName) succeeded")
                        if let payload = AgentLiveWriteEvent.completed(toolName: output.toolName, params: output.params, isSuccess: true, preWriteContent: output.preWriteContent, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.completed, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        // Card-nested rows first (plan step / reflection attempt); fall back
                        // to the top-level / workflow-node completion path.
                        if !(capabilityCardsEnabled && sourceNodeID == nil
                             && capabilityRouter.completeTool(output: output, failureCategory: nil, durationMs: durationMs)) {
                            Self.completeToolTimelineEvent(
                                output: output,
                                failureCategory: nil,
                                durationMs: durationMs,
                                sourceNodeID: sourceNodeID,
                                agentMessage: agentMessage,
                                workflowExecutionState: workflowExecutionState
                            )
                        }
                        // [G1 Piece 1] Boundary flush — capture the completed tool's output durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .toolFailed(let output, let category, let suggestion, let sourceNodeID):
                        agentMessage.agentState = .thinking(.reflecting)
                        if let payload = AgentLiveWriteEvent.completed(toolName: output.toolName, params: output.params, isSuccess: false, preWriteContent: output.preWriteContent, conversationID: conversationID) {
                            NotificationCenter.default.post(name: AgentLiveWriteEvent.completed, object: nil,
                                                            userInfo: [AgentLiveWriteEvent.payloadKey: payload])
                        }
                        if !(capabilityCardsEnabled && sourceNodeID == nil
                             && capabilityRouter.completeTool(output: output, failureCategory: category, durationMs: nil)) {
                            Self.completeToolTimelineEvent(
                                output: output,
                                failureCategory: category,
                                durationMs: nil,
                                sourceNodeID: sourceNodeID,
                                agentMessage: agentMessage,
                                workflowExecutionState: workflowExecutionState
                            )
                        }
                        // [G1 Piece 1] Boundary flush — capture the failed tool's outcome durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        if let s = suggestion {
                            logger.debug("[TOOL_FAILED] \(output.toolName) [\(category.rawValue)] suggestion: \(s)")
                        }


                    case .draftText(let draft):
                        // Provisional step text, set directly: it is cumulative and may be withdrawn, so it is not merged or persisted.
                        if draft.isEmpty {
                            if let baseline = draftBaseline {
                                setMessageContent(agentMessage, baseline, isRegeneration: isRegeneration)
                                draftBaseline = nil
                            }
                        } else if let current = messageContent(agentMessage, isRegeneration: isRegeneration) {
                            let baseline = draftBaseline ?? current
                            draftBaseline = baseline
                            setMessageContent(agentMessage, ChatMessage.draftDisplayContent(baseline: baseline, draft: draft),
                                              isRegeneration: isRegeneration)
                        }

                    case .content(let textChunk):
                        // A showing draft is the preview of this very text: put the bubble back
                        // the way it was before the draft, then append as usual.
                        if let baseline = draftBaseline {
                            setMessageContent(agentMessage, baseline, isRegeneration: isRegeneration)
                            draftBaseline = nil
                            // Render this chunk now: the bubble just lost the draft and would blink empty until the next throttle tick.
                            lastUpdateTime = .distantPast
                        }
                        // 3. Handle Final Text (Buffered)
                        if agentMessage.agentState != .thinking(.finalizing) {
                            agentMessage.agentState = .thinking(.finalizing)
                        }
                        
                        tokenBuffer += textChunk
                        tokensReceivedInWindow += textChunk.count

                        // Flush on time only: a token-count escape hatch defeats the throttle for fast local producers.
                        // Latency stays within `adaptiveInterval`; the further behind the UI, the more tokens coalesce per render.
                        let elapsed = -lastUpdateTime.timeIntervalSinceNow
                        if elapsed >= adaptiveInterval {
                            self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                            // [G1 Piece 1] Coalesced flush — persist streamed prose at most every
                            // `inFlightFlushInterval`, so a long final answer isn't lost if interrupted.
                            await self.flushInFlight(agentMessage, conversationID: conversationID)

                            // Adapts the interval to token throughput: 0.05s for fast local models, 0.2s for slow remote APIs.
                            if elapsed > 0 {
                                let charsPerSecond = Double(tokensReceivedInWindow) / elapsed
                                if charsPerSecond > 500 {
                                    adaptiveInterval = 0.05   // Fast: flush frequently for smooth UX
                                } else if charsPerSecond > 100 {
                                    adaptiveInterval = 0.1    // Normal: balanced default
                                } else {
                                    adaptiveInterval = 0.2    // Slow: batch more to reduce rerenders
                                }
                            }

                            tokenBuffer = ""
                            tokensReceivedInWindow = 0
                            lastUpdateTime = Date()
                        }
                        
                    case .error(let structuredError):
                        // Remembers the failure text for the workflow settle; used only when the engine's terminal outcome is `.failed`.
                        lastErrorEventMessage = structuredError.message
                        // The error card below replaces whatever the bubble shows, draft included;
                        // forget the draft so a later withdrawal cannot restore over the card.
                        draftBaseline = nil
                        // Surfaces the failure as a distinct error card with category icon and suggestion, so it does not read as agent prose.
                        logger.error("Stream Error Event [\(structuredError.category.rawValue)]: \(structuredError.message)")
                        agentMessage.content = MessageContent.error(
                            title: structuredError.title,
                            details: structuredError.message,
                            category: structuredError.category,
                            suggestion: structuredError.suggestion
                        )
                        agentMessage.invalidateMarkdownCache()
                        if let agentResponse = agentMessage.agentResponse,
                           agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                            agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex].content = agentMessage.content
                        }

                    case .warning(let category, let message, _, let sourceNodeID):
                        let warningEvent = TimelineEvent.warning(id: UUID(), category: category, text: message)
                        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
                            wfState.appendNodeTimelineEvent(warningEvent, for: nodeID)
                            logger.debug("[WF_ROUTE] Warning[\(category.rawValue)] → node timeline [\(nodeID)]")
                        } else if !(capabilityCardsEnabled && capabilityRouter.route(warningEvent)) {
                            agentMessage.appendTimelineEvent(warningEvent)
                        }
                        logger.warning("Stream Warning [\(category.rawValue)]: \(message)")

                    // MARK: Workflow Orchestration Events
                    case .workflowNodeStarted(let nodeID, let profileName, let idx, let total):
                        agentMessage.agentState = .acting(.subtask(current: idx, total: total))
                        logger.info("[WF_EVENT] NodeStarted: '\(profileName)' [\(nodeID)] (\(idx)/\(total))")
                        workflowExecutionState?.handleNodeStarted(nodeID: nodeID, profileName: profileName, index: idx, total: total)

                    case .workflowNodeCompleted(let nodeID, let profileName, let summary, let nodeHasWarnings):
                        let completedId = UUID()
                        // `summary` carries the node's full output; keep the aggregate thought log to a brief milestone.
                        let summaryPreview = summary.count > 200 ? String(summary.prefix(200)) + "…" : summary
                        agentMessage.appendTimelineEvent(.thought(id: completedId, text: "✅ \(profileName): \(summaryPreview)"))
                        // Logs the summary length, not the node's output text: this line reaches the unified OS log.
                        logger.info("[WF_EVENT] NodeCompleted: '\(profileName)' [\(nodeID)] summary=\(summary.count) chars")
                        workflowExecutionState?.handleNodeCompleted(nodeID: nodeID, profileName: profileName, summary: summary, hasWarnings: nodeHasWarnings)

                    case .workflowNodeFailed(let nodeID, let profileName, let error, let suggestion):
                        let failedId = UUID()
                        agentMessage.appendTimelineEvent(.thought(id: failedId, text: "❌ \(profileName): \(error)"))
                        logger.info("[WF_EVENT] NodeFailed: '\(profileName)' [\(nodeID)] error=\(error)")
                        workflowExecutionState?.handleNodeFailed(nodeID: nodeID, profileName: profileName, error: error, suggestion: suggestion)

                    case .workflowNodeSkipped(let nodeID, let profileName, let reason, let ranBeforeSkip):
                        // Logged at `.info` because skips are high-volume; uses the stable `reason.rawValue`, not localized `displayText`.
                        // Only `.byUser` keeps its subtree live; a pre-dispatch skip is labelled 'Not run' on screen.
                        let skipRowWord = ranBeforeSkip ? "Skipped" : "Not run"
                        let skipDownstream = reason.keepsDownstreamAlive
                            ? "downstream receives this node's INPUT unchanged"
                            : "every edge below it is dead, so its whole subtree is skipped too"
                        logger.info("[WF_EVENT] NodeSkipped: '\(profileName)' [\(nodeID)] reason=\(reason.rawValue) ranBeforeSkip=\(ranBeforeSkip). CONSEQUENCE: the node's row settles as '\(skipRowWord)' and contributes no output of its own; \(skipDownstream).")
                        workflowExecutionState?.handleNodeSkipped(nodeID: nodeID, profileName: profileName, reason: reason, ranBeforeSkip: ranBeforeSkip)

                    case .workflowNodeCancelled(let nodeID, let profileName):
                        // Logged at `.notice`: a cancel is rare and user-initiated, matching the emitter side.
                        logger.notice("[WF_EVENT] NodeCancelled: '\(profileName)' [\(nodeID)]. CONSEQUENCE: the node's row settles as 'Cancelled' (not failed) with any partial output discarded; no output port is activated, so nothing downstream of it runs.")
                        workflowExecutionState?.handleNodeCancelled(nodeID: nodeID, profileName: profileName)

                    case .workflowNodeRetryScheduled(let nodeID, let profileName, let attemptsRemaining):
                        // The row keeps showing the last failure; this records that the engine has not given up,
                        // so a Stop during back-off settles it as cancelled.
                        logger.notice("[WF_EVENT] NodeRetryScheduled: '\(profileName)' [\(nodeID)], \(attemptsRemaining) attempt(s) left. CONSEQUENCE: the node's row stays 'Failed' for the back-off (it is not retrying yet, and may never), but a Stop pressed now settles it as Cancelled rather than as a genuine failure.")
                        workflowExecutionState?.handleNodeRetryScheduled(nodeID: nodeID, profileName: profileName, attemptsRemaining: attemptsRemaining)

                    case .workflowProgress(let completed, let total):
                        logger.info("[WF_EVENT] Progress: \(completed)/\(total)")
                        workflowExecutionState?.handleProgress(completed: completed, total: total)

                    case .workflowRunFinished(let hadGenuineFailure):
                        // Separate from `agentMessage.terminalOutcome`, which drives the chat bubble and must not change here.
                        logger.info("[WF_EVENT] RunFinished: hadGenuineFailure=\(hadGenuineFailure)")
                        workflowExecutionState?.completedDespiteNodeFailure = hadGenuineFailure

                    // MARK: Capability Events (Planning, Self-Reflection, Delegation)

                    case .planGenerated(let subtasks):
                        let count = subtasks.count
                        agentMessage.agentState = .thinking(.planning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanGenerated(subtasks)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planGenerated, detail: "Planned \(count) subtask\(count == 1 ? "" : "s")"
                            ))
                        }

                    case .planApproved(let subtasks):
                        agentMessage.agentState = .thinking(.planning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanApproved(subtasks)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planGenerated, detail: "Plan approved (\(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s"))"
                            ))
                        }

                    case .requestPlanReview(let subtasks, let operationID, let sourceNodeID, let sourceNodeName):
                        agentMessage.agentState = .interaction(.planReview)
                        // Park plus immediate boundary flush, as every other HITL case does.
                        // Without the marker a plan-review park reloads as `.streaming` and the local model stays pinned while the banner waits.
                        agentMessage.lifecycleState = .parkedHITL(operationID: operationID)
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)
                        if capabilityCardsEnabled {
                            capabilityRouter.handlePlanReviewRequested()
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .planReviewRequested,
                                detail: "Plan with \(subtasks.count) subtask\(subtasks.count == 1 ? "" : "s") awaiting approval"
                            ))
                        }
                        await self.enqueueHITL(
                            operationID: operationID,
                            kind: .planReview(PendingPlanReview(id: operationID, subtasks: subtasks)),
                            conversationID: conversationID,
                            profileType: config.profile.profileType,
                            workflowState: workflowExecutionState,
                            sourceNodeID: sourceNodeID,
                            sourceNodeName: sourceNodeName,
                            profileID: config.profile.id,
                            traceContext: traceContext
                        )

                    case .subtaskStarted(let id, let index, let total, let description):
                        agentMessage.agentState = .acting(.subtask(current: index, total: total))
                        if capabilityCardsEnabled {
                            capabilityRouter.handleSubtaskStarted(id: id, description: description)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .subtaskStarted, detail: "Subtask \(index)/\(total): \(description)"
                            ))
                        }
                        // [G1 Piece 1] Boundary flush — persist the step transition durably.
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .subtaskCompleted(let id, let index, let total, let summary, let outcome, let durationMs):
                        if capabilityCardsEnabled {
                            capabilityRouter.handleSubtaskCompleted(id: id, summary: summary, outcome: outcome, durationMs: durationMs)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .subtaskCompleted, detail: "Subtask \(index)/\(total): \(summary)"
                            ))
                        }
                        await self.flushInFlight(agentMessage, conversationID: conversationID, immediate: true)

                    case .reflectionTrialStarted(let trial, let maxTrials):
                        agentMessage.agentState = .thinking(.reasoning)
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialStarted(trial: trial, maxTrials: maxTrials)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionTrialStarted, detail: "Trial \(trial) of \(maxTrials)"
                            ))
                        }

                    case .reflectionEvaluating(let trial):
                        agentMessage.agentState = .thinking(.reflecting)
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialEvaluating(trial: trial)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionEvaluating, detail: "Evaluating trial \(trial)"
                            ))
                        }

                    case .reflectionRetrying(let trial, let critique):
                        agentMessage.agentState = .thinking(.reflecting)
                        if capabilityCardsEnabled {
                            // Full critique — the card is the critique's home now; the old
                            // 80-char milestone truncation lost the evaluator's reasoning.
                            capabilityRouter.handleTrialRejected(trial: trial, critique: critique)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionRetrying, detail: "Retry: \(String(critique.prefix(80)))"
                            ))
                        }

                    case .reflectionAccepted(let trial):
                        if capabilityCardsEnabled {
                            capabilityRouter.handleTrialAccepted(trial: trial)
                        } else {
                            agentMessage.appendTimelineEvent(.capabilityMilestone(
                                id: UUID(), kind: .reflectionAccepted, detail: "Accepted on trial \(trial)"
                            ))
                        }

                    case .delegationStarted(let task):
                        let shortTask = String(task.prefix(60))
                        agentMessage.agentState = .acting(.tool(name: "call_agent"))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationStarted, detail: shortTask
                        ))

                    case .delegationCompleted(let summary):
                        let shortSummary = String(summary.prefix(80))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .delegationCompleted, detail: shortSummary
                        ))

                    // MARK: History Compaction Events
                    case .compactionCompleted(let turns, let preview, let checkpoint):
                        // Chip only: checkpoint persistence lives in `HistoryCompactionService`'s sink, because compaction can finish
                        // after this stream has ended, when this event is never delivered.
                        let shortPreview = String(preview.prefix(100))
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionCompleted,
                            detail: "History compacted \u{2014} \(turns) turns summarized: \(shortPreview)"
                        ))
                        logger.info("[COMPACTION] Completed chip shown \u{2014} checkpoint \(checkpoint.id.uuidString.prefix(8)), conversationID: \(conversationID.uuidString.prefix(8))")

                    case .compactionFailed(let reason):
                        // Best-effort chip from the background run. The run continues
                        // with uncompacted history, so this is a warning, not an error.
                        agentMessage.appendTimelineEvent(.capabilityMilestone(
                            id: UUID(), kind: .compactionFailed,
                            detail: "History compaction didn't finish (\(reason)) \u{2014} continuing with full history"
                        ))
                        logger.warning("[COMPACTION] Reported to user as failed \u{2014} \(reason), conversationID: \(conversationID.uuidString.prefix(8))")

                    // MARK: Multimodal Events
                    case .mediaProgress:
                        // Progress events are dropped: only the live step counter is lost, since the generation thought and artifact still
                        // reach the timeline.
                        break

                    case .artifactProduced(let artifact):
                        let mediaEvent = TimelineEvent.mediaGeneration(
                            id: UUID(),
                            toolName: artifact.label ?? artifact.kind.rawValue,
                            artifact: artifact,
                            isComplete: true
                        )
                        if !(capabilityCardsEnabled && capabilityRouter.route(mediaEvent)) {
                            agentMessage.appendTimelineEvent(mediaEvent)
                        }

                    // MARK: Token Usage
                    case .tokenUsage(let usage):
                        // Accumulate (don't overwrite): a multi-node workflow emits one
                        // event per node, so we want the run total, not just the last (D1).
                        agentMessage.tokenUsage = (agentMessage.tokenUsage ?? TokenUsage()).accumulated(with: usage)

                    // MARK: Terminal Outcome
                    case .executionFinished(let outcome, let reason):
                        agentMessage.terminalOutcome = outcome
                        agentMessage.terminalReason = reason
                        if capabilityCardsEnabled {
                            capabilityRouter.handleExecutionFinished(outcome: outcome)
                        }
                        logger.info("[STREAM_TERMINAL] outcome=\(outcome.rawValue), reason=\(reason ?? "nil")")
                    }
                }
                
                // Flush remaining text tokens
                if !tokenBuffer.isEmpty {
                    self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                }
                
                logger.info("[STREAM_LOOP_END] Finished — traceID: \(traceContext.traceID), messageID: \(agentMessage.id.uuidString.prefix(8)), profileType: \(profileType)")

                // Why: Pass `Task.isCancelled` through: a workflow Stop ends this loop without throwing, so no catch arm sees it.
                // Forwards the stream's end to the workflow execution state.
                if let wfState = workflowExecutionState {
                    let finalText = agentMessage.content.textContent ?? ""
                    let stopped = Task.isCancelled
                    logger.info("[WF_EVENT] StreamEnd: cancelled=\(stopped), \(finalText.count) chars, nodeTimelines=\(wfState.nodeTimelines.count) nodes tracked")
                    logger.debug("[WF_EVENT] FinalOutput preview: \(String(finalText.prefix(300)))")
                    // An engine-declared run failure must reach the workflow state as an error, not become `finalOutput`.
                    // Keyed off `.executionFinished(.failed)`; inner nodes also emit `.error` on runs a recovery branch completes.
                    if !stopped, agentMessage.terminalOutcome == .failed, wfState.workflowError == nil {
                        let reason = lastErrorEventMessage ?? agentMessage.terminalReason ?? String(localized: "The workflow failed.")
                        wfState.handleError(reason)
                        logger.info("[WF_EVENT] Run FAILED per the engine's terminal outcome — settled workflowError (\(reason.count) chars) before StreamEnd. CONSEQUENCE: the record freezes .failed with record.error set, the UI renders the failure as an error rather than as the run's answer, and in-flight node/tool rows are settled instead of spinning forever.")
                    }
                    wfState.handleStreamEnd(finalText: finalText, cancelled: stopped)
                    if stopped {
                        logger.info("[WF_EVENT] Run STOPPED by user — state latched wasCancelled. CONSEQUENCE: the frozen record persists .cancelled with its in-flight node settled .cancelled, instead of a red 'Failed' reporting the user's own action back as an error.")
                    }
                }

                // Stop race: the consumer can be cancelled before `.executionFinished(.cancelled)` arrives,
                // leaving a nil outcome that the safety net would record as `.completed`; stamp the outcome here.
                if Task.isCancelled, agentMessage.terminalOutcome == nil {
                    agentMessage.terminalOutcome = .cancelled
                    agentMessage.terminalReason = agentMessage.terminalReason ?? "Cancelled by user"
                }
                // Close any open capability cards so a persisted card never claims to
                // still be executing (mirrors the terminalOutcome safety net above).
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: agentMessage.terminalOutcome ?? .completed)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)

            } catch is CancellationError {
                logger.info("[STREAM_CANCELLED] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8))")
                workflowExecutionState?.handleError("Cancelled", cancelled: true)
                if agentMessage.terminalOutcome == nil {
                    agentMessage.terminalOutcome = .cancelled
                    agentMessage.terminalReason = agentMessage.terminalReason ?? "Cancelled by user"
                }
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: .cancelled)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
            } catch {
                logger.error("[STREAM_ERROR] traceID: \(agentMessage.traceID ?? "?"), messageID: \(agentMessage.id.uuidString.prefix(8)), error: \(error.localizedDescription)")
                workflowExecutionState?.handleError(error.localizedDescription)
                if capabilityCardsEnabled {
                    capabilityRouter.handleExecutionFinished(outcome: .failed)
                }
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: error)
            }
            
            }
            }
            // The run is over (finalized above): the ceiling has nothing left to stop.
            ceilingTask?.cancel()

            self.removeTask(for: agentMessage.id)
            onComplete()
        }
        }
        }
        }
        }
        
        activeTasks[agentMessage.id] = streamTask
        
        return agentMessage
    }
    
    /// Mutates the matching executing `.toolExecution` timeline event into its completed state.
    /// Routes to the workflow node's per-node timeline when `sourceNodeID` is present,
    /// else falls back to the message's root timeline. `failureCategory == nil` means success.
    static func completeToolTimelineEvent(
        output: ToolOutput,
        failureCategory: ToolFailureCategory?,
        durationMs: Int?,
        sourceNodeID: UUID?,
        agentMessage: ChatMessage,
        workflowExecutionState: WorkflowExecutionState?
    ) {
        // Bounds what enters the timeline: an uncapped output is re-encoded on every flush and decoded on every load.
        // Truncation is explicit, so the user and a resumed run's LLM history both see the marker.
        let cappedOutput = ToolExecutionData.cappedOutput(output.output)
        if cappedOutput.count != output.output.count {
            logger.warning("[TOOL_OUTPUT] '\(output.toolName)' returned \(output.output.count) chars — truncated to \(ToolExecutionData.maxPersistedOutputLength) for the timeline. The full text reached the model on THIS run; a resumed run sees the truncation marker instead.")
        }

        let updater: (inout ToolExecutionData) -> Void = { data in
            // Refresh params to what ACTUALLY executed — when the user edits args in the HITL banner
            // (A3), output.params carries the corrected values; the card was built from the originals.
            data.params = output.params
            data.output = cappedOutput
            data.isSuccess = output.isSuccess
            data.failureCategory = failureCategory
            data.durationMs = durationMs
            data.isExecuting = false
            data.preWriteContent = output.preWriteContent
            data.postWriteContent = output.postWriteContent
            // Derived once here while the snapshots are in hand; the episodic formatter would otherwise re-diff every write per
            // request.
            data.effect = ActionEffect.from(toolExecution: data)
            // Same reasoning, same seam: parsed once here rather than re-scanned on every
            // prompt build. Nil for every tool that doesn't annotate a status.
            data.exitCode = ShellExitStatus.parse(cappedOutput)
        }

        if let wfState = workflowExecutionState, let nodeID = sourceNodeID {
            if let idx = wfState.nodeTimelines[nodeID].flatMap({
                ToolRowMatcher.index(in: $0, for: output)
            }) {
                if case .toolExecution(var data) = wfState.nodeTimelines[nodeID]![idx] {
                    updater(&data)
                    wfState.nodeTimelines[nodeID]![idx] = .toolExecution(data)
                    logger.debug("[WF_ROUTE] Tool '\(output.toolName)' completed → node [\(nodeID)] success=\(output.isSuccess) category=\(failureCategory?.rawValue ?? "nil")")
                }
            } else {
                logger.warning("[TIMELINE] '\(output.toolName)' finished in node [\(nodeID)] but no executing row has its params. CONSEQUENCE: no row is completed — completing a guessed row would show another call's result on it.")
            }
            return
        }

        if let index = ToolRowMatcher.index(in: agentMessage.timelineEvents, for: output) {
            if case .toolExecution(var data) = agentMessage.timelineEvents[index] {
                updater(&data)
                agentMessage.timelineEvents[index] = .toolExecution(data)
                EditPatchStore.recordIfCode(data, in: agentMessage)
            }
        } else if agentMessage.timelineEvents.contains(where: {
            if case .toolExecution(let data) = $0 { return data.isExecuting && data.name == output.toolName }
            return false
        }) {
            logger.warning("[TIMELINE] '\(output.toolName)' finished but no executing row of that name has its params. CONSEQUENCE: no row is completed — completing a guessed row would show another call's result on it.")
        }
    }

    /// Enqueues a HITL request into the unified `InteractionCenter`, with a source-attributed origin
    /// (interface, workflow node identity, banner title).
    func enqueueHITL(
        operationID: UUID,
        kind: PendingInteraction,
        conversationID: UUID,
        profileType: ProfileType,
        workflowState: WorkflowExecutionState?,
        sourceNodeID: UUID?,
        /// Producer-supplied display name, defaulted so existing call sites are unaffected.
        /// See the resolution comment below for why the id alone is not enough.
        sourceNodeName: String? = nil,
        profileID: UUID?,
        traceContext: TraceContext
    ) async {
        // Every caller awaits a persistence flush first, and the request may be resolved during it;
        // showing its banner now would leave one nobody can answer.
        if await ExecutionSuspensionService.shared.wasResolved(operationID) {
            logger.notice("[HITL] op \(operationID.uuidString.prefix(8)) was resolved before its banner could be shown (conversation \(conversationID.uuidString.prefix(8))). CONSEQUENCE: no banner is raised and no trace record is opened; the run has already moved on.")
            return
        }
        guard let interactionCenter else {
            // A park with no center means the run waits on an interaction NOBODY can
            // ever answer — that must never be silent.
            logger.error("[HITL] enqueue DROPPED — no InteractionCenter wired (op: \(operationID.uuidString.prefix(8)), conversation: \(conversationID.uuidString.prefix(8))). The run will hang parked.")
            return
        }

        let isWorkflow = workflowState != nil && sourceNodeID != nil
        let interface: HITLOrigin.Interface = isWorkflow
            ? .workflow
            : (profileType == .code ? .code : .chat)

        // Prefers a name the producer supplied: for a request forwarded out of a sub-workflow,
        // `sourceNodeID` names an inner node that `nodeResults` does not know.
        let nodeName: String? = sourceNodeName ?? sourceNodeID.flatMap { id in
            workflowState?.nodeResults.first(where: { $0.nodeID == id })?.profileName
        }

        let kindLabel: String = {
            switch kind {
            case .toolConfirmation: return "Permission required"
            case .clarification:    return "Question"
            case .planReview:       return "Plan review"
            case .gate:             return "Decision required"
            }
        }()
        let title = nodeName.map { "\($0) · \(kindLabel)" } ?? kindLabel

        // Logged here, not at function entry, so it can reuse `kindLabel`.
        logger.log("[HITL] Parked op \(operationID.uuidString.prefix(8)) — \(kindLabel), conversation: \(conversationID.uuidString.prefix(8)), interface: \(interface.rawValue), profile: \(profileType.rawValue), node: \(nodeName ?? "none"). Awaiting user.")

        let origin = HITLOrigin(
            interface: interface,
            conversationID: conversationID,
            nodeID: sourceNodeID,
            nodeName: nodeName,
            title: title,
            profileID: profileID,
            // `traceContext.messageID` is the agent message this run streams into: the key the mirror uses to post only this run's
            // items.
            runMessageID: traceContext.messageID
        )
        interactionCenter.enqueue(PendingHITL(id: operationID, origin: origin, kind: kind))

        // Records the raise for the trace span emitted on resolve, covering chat, code and all workflow HITL including gates.
        let kindType: String
        let kindToolName: String?
        switch kind {
        case .toolConfirmation(let c): kindType = "permission";    kindToolName = c.toolName
        case .clarification:           kindType = "clarification"; kindToolName = nil
        case .planReview:              kindType = "plan_review";   kindToolName = nil
        case .gate:                    kindType = "gate";          kindToolName = nil
        }

        // Sample the raise instant ONCE, synchronously, so the C1 span and C2 audit share the exact
        // same timestamp and neither drifts to whenever its deferred Task happens to run.
        let raisedAt = Date()

        hitlTraceInfo[operationID] = HITLTraceRecord(
            context: traceContext, raisedAt: raisedAt, type: kindType, toolName: kindToolName
        )

        // [HITL/C2] Durable audit row, written at RAISE for EVERY HITL (incl. gates). A request still
        // pending at quit/crash survives as resolvedAt=nil, which the launch reconcile stamps `interrupted`.
        Task { await TraceRecorder.shared.recordHITLRaised(
            operationID: operationID.uuidString,
            conversationID: conversationID.uuidString,
            interface: interface.rawValue,
            type: kindType,
            toolName: kindToolName,
            nodeName: nodeName,
            title: title,
            raisedAt: raisedAt,
            // v8 join keys: the audit row now names its run exactly, so the Run
            // Report stops guessing approvals into runs by time window.
            traceID: traceContext.traceID,
            spanID: traceContext.spanID
        ) }
    }

    /// [HITL/C1] In-flight HITL requests awaiting resolution, for the userInteraction trace span.
    private struct HITLTraceRecord {
        let context: TraceContext
        let raisedAt: Date
        let type: String
        let toolName: String?
    }
    @ObservationIgnored private var hitlTraceInfo: [UUID: HITLTraceRecord] = [:]

    /// Emits a `userInteraction` trace span when a HITL resolves, with the decision and wait duration.
    private func emitHITLTraceSpan(operationID: UUID?, outcome: String) {
        guard let opID = operationID, let rec = hitlTraceInfo.removeValue(forKey: opID) else { return }
        let waitMs = Int(Date().timeIntervalSince(rec.raisedAt) * 1000)
        let context = rec.context
        let type = rec.type
        let tool = rec.toolName
        let detailed = "\(outcome) · \(waitMs)ms"
        Task { await TraceRecorder.shared.emitUserInteraction(span: context, type: type, toolName: tool, outcome: detailed) }
    }

    /// The content the bubble is showing — the selected variant's when regenerating.
    private func messageContent(_ agentMessage: ChatMessage, isRegeneration: Bool) -> MessageContent? {
        guard isRegeneration else { return agentMessage.content }
        guard let response = agentMessage.agentResponse,
              response.variants.indices.contains(response.selectedVariantIndex) else { return nil }
        return response.variants[response.selectedVariantIndex].content
    }

    /// Replaces (does not merge) what the bubble shows. Used only for `.draftText` previews.
    private func setMessageContent(_ agentMessage: ChatMessage, _ content: MessageContent, isRegeneration: Bool) {
        if isRegeneration {
            guard let response = agentMessage.agentResponse,
                  response.variants.indices.contains(response.selectedVariantIndex) else { return }
            agentMessage.agentResponse?.variants[response.selectedVariantIndex].content = content
        } else {
            agentMessage.content = content
            agentMessage.agentResponse?.variants[0].content = content
        }
        agentMessage.invalidateMarkdownCache()
    }

    private func updateMessageContent(_ agentMessage: ChatMessage, with newTextChunk: String, isRegeneration: Bool) {
        // Merge decision lives in `ChatMessage.resolveStreamedChunkMerge`: prose streaming after an `.error` card starts the
        // answer fresh and demotes the failure to a timeline event.
        if isRegeneration {
            guard let agentResponse = agentMessage.agentResponse,
                  agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) else {
                return
            }
            var targetVariant = agentResponse.variants[agentResponse.selectedVariantIndex]
            if let merged = ChatMessage.resolveStreamedChunkMerge(current: targetVariant.content, chunk: newTextChunk) {
                targetVariant.content = merged.content
                agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex] = targetVariant
                if let demoted = merged.demotedError {
                    agentMessage.appendTimelineEvent(demoted)
                }
            }
        } else {
            if let merged = ChatMessage.resolveStreamedChunkMerge(current: agentMessage.content, chunk: newTextChunk) {
                agentMessage.content = merged.content
                agentMessage.agentResponse?.variants[0].content = merged.content
                if let demoted = merged.demotedError {
                    agentMessage.appendTimelineEvent(demoted)
                }
            }
        }
        // Invalidates cached markdown blocks so the next body evaluation reparses; pairs with `getOrCreateMarkdownBlocks()`.
        agentMessage.invalidateMarkdownCache()
    }
    
    /// Whether any stream is live for `conversationID` right now; drives the sidebar's `StreamingPulseIndicator`.
    /// Streaming is a live-process property, so the observable `activeStreams` is the source.
    func hasActiveStream(inConversation conversationID: UUID) -> Bool {
        activeStreams.values.contains { $0.conversationId == conversationID }
    }

    /// Every live run, reduced to the fields the foreground decision needs.
    /// The authoritative answer to 'what is running'; reading it in a view body registers on `activeStreams`.
    func liveRunSnapshot() -> [ForegroundRunResolver.LiveRun] {
        activeStreams.values.map { message in
            let parked: Bool
            if case .parkedHITL = message.lifecycleState { parked = true } else { parked = false }
            return ForegroundRunResolver.LiveRun(
                messageID: message.id,
                conversationID: message.conversationId,
                // `.distantPast` only if the two maps ever diverge; it degrades the tie-break to
                // "loses to everything", never the candidacy itself.
                startedAt: streamStartedAt[message.id] ?? .distantPast,
                isParked: parked,
                // Taken from admission, the one place that knows: a queued run's message looks exactly like a working one.
                isQueued: admission.isWaiting(message.id)
            )
        }
    }

    public func cancelStream(for messageId: UUID) {
        guard let taskToCancel = activeTasks[messageId] else {
            logger.warning("Attempted to cancel a stream for message ID \(messageId.uuidString), but no active task was found.")
            return
        }
        
        logger.info("Cancelling stream task for message ID: \(messageId.uuidString)")
        taskToCancel.cancel()
        // A queued run is suspended in `ConversationAdmission` and ignores cancellation, so withdraw the waiter
        // to let it exit through its own cancellation branch. Harmless for a run that is not waiting.
        if let conversationID = activeStreams[messageId]?.conversationId {
            admission.forget(messageID: messageId, inConversation: conversationID)
        }
    }

    /// Cancels any active streams for a conversation, e.g. on deletion, so a run parked on a HITL does not strand.
    /// Cancellation cascades to the suspension's handler (deny / nil) and then finalizes.
    public func cancelStreams(forConversation conversationID: UUID) {
        let messageIDs = activeStreams.filter { $0.value.conversationId == conversationID }.map(\.key)
        for messageID in messageIDs {
            cancelStream(for: messageID)
        }
        // A parked waiter holds a continuation that nothing else will resume — see the method.
        admission.releaseAll(inConversation: conversationID)
    }
    
    
    /// Durably persists the in-flight agent message so an interrupted run survives with its partial timeline.
    /// Upserts by id; boundary flushes pass `immediate: true`, the token path coalesces behind `inFlightFlushInterval`.
    /// No-ops once the task is cancelled, so a late flush cannot re-insert a row being deleted.
    private func flushInFlight(_ message: ChatMessage, conversationID: UUID, immediate: Bool = false) async {
        if Task.isCancelled { return }
        if !immediate, let last = lastInFlightFlush[message.id], -last.timeIntervalSinceNow < Self.inFlightFlushInterval {
            return
        }
        lastInFlightFlush[message.id] = Date()
        await persistenceService.addMessage(message, toConversation: conversationID)
    }

    /// The pending "waiting for the local model" banner per run, so the wait's end can cancel it.
    @ObservationIgnored private var localQueueBanners: [UUID: Task<Void, Never>] = [:]
    /// The newest wording of each waiting run's notice — the delayed banner shows THIS, and a position
    /// change rewrites it (phase 7).
    @ObservationIgnored private var localQueueNotices: [UUID: String] = [:]
    /// Runs whose queue banner is on screen, so a position change updates it in place.
    @ObservationIgnored private var localQueueBannerShown: Set<UUID> = []

    /// Announces that a run started waiting for the local model, at its start or to retake the lock after a HITL answer.
    /// Shown on screen and to a remote chat, since a run waiting on another conversation looks hung.
    private func localWaitBegan(_ agentMessage: ChatMessage, conversationID: UUID,
                                startedBy: MessageSource, position: Int) {
        agentMessage.agentState = .thinking(.awaitingLocalModel)
        let holder = inferenceCoordinator.holderManifest
        let notice = Self.localQueueNotice(
            holder: holder,
            holderTitle: holder?.conversationID.flatMap { persistenceService.getConversation(withId: $0)?.userDefinedTitle },
            position: position)
        let delegates = liveMirrorDelegates
        logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) shows as WAITING for the local model (position \(position), holder \(holder.map { "\($0.runID.uuidString.prefix(8)) (\($0.origin))" } ?? "none")); \(delegates.count) mirror delegate(s) told. CONSEQUENCE: the banner follows if the wait lasts \(Self.localQueueBannerDelay).")
        for delegate in delegates {
            delegate.activeStreamManager(self, didQueueForLocalModel: agentMessage, notice: notice,
                                         startedBy: startedBy, for: conversationID)
        }
        localQueueNotices[agentMessage.id] = notice
        // The banner only for a wait that LASTS: a run admitted a second later should not flash one.
        localQueueBanners[agentMessage.id]?.cancel()
        localQueueBanners[agentMessage.id] = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.localQueueBannerDelay)) != nil, let self else { return }
            logger.notice("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) is still waiting for the local model after \(Self.localQueueBannerDelay) — banner shown in conversation \(conversationID.uuidString.prefix(8)).")
            self.localQueueBannerShown.insert(agentMessage.id)
            self.postLocalQueueBanner(agentMessage.id, conversationID: conversationID)
        }
    }

    /// The queue banner — plain status, not dismissible (it goes when the wait does), above ambient
    /// advisories so a fit hint cannot hide it (phase 7).
    private func postLocalQueueBanner(_ messageID: UUID, conversationID: UUID) {
        guard let notice = localQueueNotices[messageID] else { return }
        AdvisoryCenter.shared.post(Advisory(
            conversationID: conversationID, category: .localModelBusy, message: notice,
            actionLabel: nil, action: nil,
            dedupeKey: "\(conversationID.uuidString)|localModelBusy|\(messageID.uuidString)",
            tone: .info, dismissible: false, priority: Advisory.runStatePriority))
    }

    /// The line moved: the run's notice (and its banner, when shown) says where it stands now.
    private func localPositionChanged(_ agentMessage: ChatMessage, conversationID: UUID, position: Int) {
        let holder = inferenceCoordinator.holderManifest
        localQueueNotices[agentMessage.id] = Self.localQueueNotice(
            holder: holder,
            holderTitle: holder?.conversationID.flatMap { persistenceService.getConversation(withId: $0)?.userDefinedTitle },
            position: position)
        logger.debug("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) is now number \(position) in line — notice updated\(self.localQueueBannerShown.contains(agentMessage.id) ? " and its banner rewritten" : "").")
        if localQueueBannerShown.contains(agentMessage.id) {
            postLocalQueueBanner(agentMessage.id, conversationID: conversationID)
        }
    }

    /// The pending "waiting for this conversation's run" banner per run (phase 7).
    @ObservationIgnored private var conversationQueueBanners: [UUID: Task<Void, Never>] = [:]

    /// A run is queued behind its OWN conversation's current run (`ConversationAdmission`). After the
    /// same short delay as the local-model wait, the banner says so — plain status, not dismissible.
    private func conversationQueueBegan(_ agentMessage: ChatMessage, conversationID: UUID) {
        logger.info("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) is queued behind conversation \(conversationID.uuidString.prefix(8))'s current run. CONSEQUENCE: shown as 'Waiting its turn'; the banner follows if the wait lasts \(Self.localQueueBannerDelay).")
        conversationQueueBanners[agentMessage.id]?.cancel()
        conversationQueueBanners[agentMessage.id] = Task { @MainActor in
            guard (try? await Task.sleep(for: Self.localQueueBannerDelay)) != nil else { return }
            logger.notice("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) still waits behind conversation \(conversationID.uuidString.prefix(8))'s current run — banner shown.")
            AdvisoryCenter.shared.post(Advisory(
                conversationID: conversationID, category: .conversationQueue,
                message: Self.conversationQueueNotice,
                actionLabel: nil, action: nil,
                dedupeKey: "\(conversationID.uuidString)|conversationQueue|\(agentMessage.id.uuidString)",
                tone: .info, dismissible: false, priority: Advisory.runStatePriority))
        }
    }

    /// The conversation wait ended — admitted or cancelled.
    private func conversationQueueEnded(_ agentMessage: ChatMessage, conversationID: UUID) {
        guard let banner = conversationQueueBanners.removeValue(forKey: agentMessage.id) else { return }
        banner.cancel()
        logger.debug("[ADMISSION] Run \(agentMessage.id.uuidString.prefix(8)) no longer waits behind its conversation — banner (if shown) cleared.")
        AdvisoryCenter.shared.clear(category: .conversationQueue, conversationID: conversationID)
    }

    nonisolated static let conversationQueueNotice =
        "Your message is queued behind this conversation's current run and starts by itself when that run finishes."

    // MARK: Asking before a run starts

    /// The run is held until its user chooses Proceed or Stop. The banner asks at once (no delay — it
    /// has a deadline), with a live countdown to the auto-deny.
    private func localConfirmationNeeded(_ agentMessage: ChatMessage, conversationID: UUID,
                                         concerns: [RunConcern], deadline: Date) {
        agentMessage.agentState = .thinking(.awaitingConfirmation)
        let message = Self.confirmationNotice(concerns)
        logger.notice("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) is ASKING its user to proceed: \(concerns.map(\.description).joined(separator: "; ")). CONSEQUENCE: banner with Proceed and Stop shown; auto-denied at \(deadline.formatted(date: .omitted, time: .standard)) with no answer.")
        AdvisoryCenter.shared.post(Advisory(
            conversationID: conversationID, category: .runNeedsConfirmation, message: message,
            actionLabel: "Proceed", action: .proceedRun(messageID: agentMessage.id),
            dedupeKey: "\(conversationID.uuidString)|runNeedsConfirmation|\(agentMessage.id.uuidString)",
            secondaryActionLabel: "Stop", secondaryAction: .stopRun(messageID: agentMessage.id),
            tone: .warning, deadline: deadline, deadlineLabel: "Auto-denied in",
            dismissible: false, priority: Advisory.runQuestionPriority))
    }

    /// The user chose Proceed: the question goes; the run starts, or its queue status follows.
    private func localConfirmed(_ agentMessage: ChatMessage, conversationID: UUID) {
        logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)): Proceed chosen — question cleared in conversation \(conversationID.uuidString.prefix(8)).")
        AdvisoryCenter.shared.clear(category: .runNeedsConfirmation, conversationID: conversationID)
        if agentMessage.agentState == .thinking(.awaitingConfirmation) {
            agentMessage.agentState = .thinking(.reasoning)
        }
    }

    /// The banner's Proceed (main window and QuickAccess).
    func proceedHeldRun(messageID: UUID) {
        let accepted = inferenceCoordinator.proceed(runID: messageID)
        logger.info("[LOCAL-COORD] Proceed pressed for run \(messageID.uuidString.prefix(8)) — \(accepted ? "accepted" : "too late, nothing to do").")
    }

    /// What the asking banner says: the concern and what may happen. No advice.
    nonisolated static func confirmationNotice(_ concerns: [RunConcern]) -> String {
        let what = concerns.map { $0.description.prefix(1).uppercased() + $0.description.dropFirst() }.joined(separator: ". ")
        return "\(what). It may run very slowly or fail."
    }

    /// The wait ended (admitted or withdrawn): the banner goes, and the label stops saying "waiting".
    private func localWaitEnded(_ agentMessage: ChatMessage, conversationID: UUID) {
        logger.debug("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) is no longer waiting for the local model — its banner (if shown) is cleared in conversation \(conversationID.uuidString.prefix(8)).")
        localQueueBanners.removeValue(forKey: agentMessage.id)?.cancel()
        localQueueNotices.removeValue(forKey: agentMessage.id)
        localQueueBannerShown.remove(agentMessage.id)
        AdvisoryCenter.shared.clear(category: .localModelBusy, conversationID: conversationID)
        AdvisoryCenter.shared.clear(category: .runNeedsConfirmation, conversationID: conversationID)
        if agentMessage.agentState == .thinking(.awaitingLocalModel) || agentMessage.agentState == .thinking(.awaitingConfirmation) {
            agentMessage.agentState = .thinking(.reasoning)
        }
    }

    /// Stops a run that has used more than `limit` of compute; returns without action when the run ends first.
    /// Stamps timed out before cancelling, so finalize does not write 'Cancelled by user'.
    private func enforceGlobalCeiling(_ limit: TimeInterval, scope: UUID, on agentMessage: ChatMessage) async {
        do {
            try await ComputeTimeoutSentinel.sleepUntilComputeExceeded(
                limit: limit,
                scope: scope,
                logTag: "LOCAL-COORD",
                subject: "Run \(agentMessage.id.uuidString.prefix(8)) (global ceiling)",
                consequence: "the run is stopped and recorded as timed out (scope: global); time spent awaiting a human or waiting for the local model was excluded. The local lock passes to the next run.")
        } catch is AgentExecutionError {
            // Only a run still live: a sentinel firing in the instant after its run finalized must not
            // rewrite a finished message's outcome.
            guard activeStreams[agentMessage.id] != nil else {
                logger.info("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) reached the global ceiling just as it finished. CONSEQUENCE: nothing is changed — its recorded outcome stands.")
                return
            }
            agentMessage.terminalOutcome = .timedOut
            agentMessage.terminalReason = Self.globalCeilingMessage(limit: limit)
            cancelStream(for: agentMessage.id)
            let parks = await ExecutionSuspensionService.shared.cancel(scope: scope)
            logger.notice("[LOCAL-COORD] Run \(agentMessage.id.uuidString.prefix(8)) STOPPED by the global ceiling (\(ToolExecutionMediator.describe(limit)) of compute) — stamped TIMED OUT, task cancelled, \(parks.count) park(s) in its scope cancelled. CONSEQUENCE: the run ends as timed out and the local lock passes to the next run.")
        } catch {
            return   // cancelled: the run finished first
        }
    }

    /// A run withdrawn before doing any work (Stop, deadline or deleted conversation while waiting), stamped like a
    /// cancelled run body.
    /// Finalized without an error: a `CancellationError` would record a failed run with a 'Response Error' card.
    static func markWithdrawnBeforeStart(_ message: ChatMessage, workflow: WorkflowExecutionState?) {
        workflow?.handleError("Cancelled", cancelled: true)
        if message.terminalOutcome == nil {
            message.terminalOutcome = .cancelled
            message.terminalReason = message.terminalReason ?? "Cancelled by user"
        }
    }

    /// The wording of a global-ceiling stop.
    nonisolated static func globalCeilingMessage(limit: TimeInterval) -> String {
        "Run stopped: it reached the \(ToolExecutionMediator.describe(limit)) maximum run time set in Settings → General. Time spent waiting for your approval or for the local model was not counted."
    }

    /// How long a run waits for the local model before its conversation shows the banner.
    static let localQueueBannerDelay: Duration = .seconds(5)

    /// What a run waiting for the local model tells the user and a remote chat: who holds the model and where this run
    /// stands.
    /// Plain status, no advice.
    nonisolated static func localQueueNotice(holder: InferenceRunManifest?, holderTitle: String?, position: Int) -> String {
        let models = holder?.localModels.map(\.modelID).joined(separator: ", ") ?? ""
        let model = models.isEmpty ? "The local model" : "The local model (\(models))"
        let title = holderTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let place: String
        if case .intelligence(let feature)? = holder?.origin {
            place = "\(feature) (a background task)"
        } else {
            place = title.map { "a run in “\($0)”" } ?? "a run in another conversation"
        }
        let line = position <= 1 ? "next in line" : "number \(position) in line"
        return "\(model) is in use by \(place). This run is \(line) and starts by itself when that run finishes."
    }

    /// The execution-timeout wording shared by chat, Code and the scheduler.
    nonisolated static func executionTimeoutMessage(limit: TimeInterval) -> String {
        "Run stopped: it exceeded its \(ToolExecutionMediator.describe(limit)) execution limit. Time spent waiting for your approval was not counted."
    }

    private func finalizeMessage(_ message: ChatMessage, conversationID: UUID, error: Error?) async {
        message.isStreaming = false
        // A run ending (success, error or Stop) is when its file changes are complete.
        WorkspaceActivity.post(reason: "run finished")
        // A finalized run (success, error or Stop) is marked `.final`, so only a process death leaves a `.streaming` /
        // `.parkedHITL` row.
        message.lifecycleState = .final
        lastInFlightFlush.removeValue(forKey: message.id)
        message.agentState = .idle
        // No center drain here: a normally finalized stream has no parked HITL, and cancel paths resolve by operation id.
        // A coarse `resolveAll(conversationID:)` would clear a concurrent stream's parked HITL.

        // Per-conversation 'Allow for this chat' grants are not cleared here: they persist for the conversation's lifetime
        // and are dropped when it is deleted (`ConversationManagementCoordinator.drainLiveExecution`).

        // Terminal-outcome safety net: if no executor emitted `.executionFinished`, infer the outcome from how the run ended.
        // The resolver also inspects content, so an error card is never stamped `.completed`; an execution limit is timed out.
        if message.terminalOutcome == nil,
           let agentError = error as? AgentExecutionError,
           case .executionTimeout(_, let limit) = agentError.reason {
            message.terminalOutcome = .timedOut
            message.terminalReason = Self.executionTimeoutMessage(limit: limit)
        }
        if message.terminalOutcome == nil {
            let fallback = ChatMessage.resolveFallbackOutcome(
                threwError: error,
                content: message.currentAgentContent ?? message.content
            )
            message.terminalOutcome = fallback.outcome
            if message.terminalReason == nil {
                message.terminalReason = fallback.reason
            }
            if error == nil, fallback.outcome == .failed {
                logger.warning("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — no .executionFinished received; inferred .failed from error-card content (previously recorded .completed) (ASM-4).")
            }
        }

        // Closes any tool row still spinning at end of run, so a cancel or failure mid-tool does not persist `isExecuting ==
        // true`.
        let closedRows = message.closeDanglingToolRowsReporting(outcome: message.terminalOutcome)
        if !closedRows.isEmpty {
            logger.warning("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — closed \(closedRows.count) dangling tool row(s) at finalize (outcome: \(message.terminalOutcome?.rawValue ?? "nil")); a persisted row must never claim to still be executing (TL-1).")
        }

        // Settles the live Code viewer tab of every abandoned file write; Stop and provider throws post no completion.
        // A no-op on a clean finalize; a write that opened no tab (empty or oversized) still gets a harmless payload.
        for row in closedRows {
            guard let payload = AgentLiveWriteEvent.completed(
                toolName: row.name,
                params: row.params,
                isSuccess: false,
                preWriteContent: nil,
                conversationID: conversationID
            ) else { continue }
            NotificationCenter.default.post(
                name: AgentLiveWriteEvent.completed, object: nil,
                userInfo: [AgentLiveWriteEvent.payloadKey: payload]
            )
            logger.warning("[CodeViewer] messageID: \(message.id.uuidString.prefix(8)) — the run ended without a completion event for the live write of '\(payload.fileName)'; posting a failed completion now. CONSEQUENCE: if that file has a live tab it settles as rejected (the proposal never reached disk) instead of claiming the agent is still writing for the rest of the session; if no tab was opened for it — an empty or over-cap write, which `began` refuses — the post is a no-op and the handler logs that at debug.")
        }

        if let traceID = message.traceID {
            // Derives the trace status from how the run ended: a thrown error wins, otherwise the executor's `terminalOutcome`.
            // `terminalReason` carries the cause for non-thrown failures and is sanitized in `endTrace`.
            let traceStatus = TraceStatus.resolve(thrownError: error != nil, terminalOutcome: message.terminalOutcome)
            let endErrorSummary = error?.localizedDescription ?? message.terminalReason
            logger.info("[TRACE_END] traceID: \(traceID), status: \(traceStatus.rawValue), messageID: \(message.id.uuidString.prefix(8))")
            await TraceRecorder.shared.endTrace(traceID: traceID, status: traceStatus, error: endErrorSummary)
            if let usage = message.tokenUsage {
                await TraceRecorder.shared.recordTokenUsage(traceID: traceID, usage: usage)
            }
        }
        
        if let error = error {
            // Renders typed retrieval failures with their category icon and remediation, like the streaming `.error` path.
            let errorCard: MessageContent
            if let fre = error as? FileRetrievalError {
                let se = fre.structuredError
                errorCard = .error(title: se.title, details: se.message, category: se.category, suggestion: se.suggestion)
            } else {
                if let agentError = error as? AgentExecutionError,
                   case .executionTimeout(_, let limit) = agentError.reason {
                    errorCard = .error(title: "Timed out", details: Self.executionTimeoutMessage(limit: limit))
                } else if let refusal = error as? LocalInferenceRefusal {
                    errorCard = .error(title: refusal.title, details: refusal.details)
                } else {
                    errorCard = .error(title: "Response Error", details: error.localizedDescription)
                }
            }

            // Keeps prose the user watched stream and demotes the error to a timeline warning; with no prose the error card
            // replaces it.
            let resolved = ChatMessage.resolveThrownFinalContent(
                streamed: message.currentAgentContent ?? message.content,
                errorCard: errorCard
            )
            message.content = resolved.content
            if let demoted = resolved.demotedError {
                message.appendTimelineEvent(demoted)
                let kept = resolved.content.textContent?.count ?? 0
                logger.log("[STREAM_FINALIZE] messageID: \(message.id.uuidString.prefix(8)) — preserved \(kept) chars of partial streamed prose; terminal error demoted to timeline (ASM-2).")
            }

            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = resolved.content
            }
        } else {
            // Display content: streamed text if any, else a generated image (image runs stream no text), else a 'stopped'
            // placeholder.
            let resolvedContent = ChatMessage.resolveFinalizedContent(
                streamed: message.currentAgentContent,
                imageArtifact: message.lastCompletedImageArtifact
            )
            message.content = resolvedContent
            // Keeps the selected variant in sync so `currentAgentContent` does not return a stale empty variant.
            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = resolvedContent
            }
        }
        
        // Persist final message
        await persistenceService.addMessage(message, toConversation: conversationID)
        
        // [RAG UPGRADE] Event-Driven Vectorization
        // Fire-and-forget: Index the final message into the vector database without blocking the UI.
        let persistence = persistenceService
        // Snapshot now on the main actor: the detached indexer must not read the live message, which a Redo can rewrite.
        let indexable = IndexableMessage(message)
        Task.detached(priority: .background) {
            // Brief pause to ensure UI settles and CoreData write completes
            try? await Task.sleep(nanoseconds: 500_000_000)
            // The conversation may have been deleted meanwhile (that is what cancelled this run);
            // indexing now would put deleted content back into the vector store.
            let stillExists = await MainActor.run { persistence.getConversation(withId: conversationID) != nil }
            guard stillExists else {
                logger.notice("[RAG] Not indexing message \(message.id.uuidString.prefix(8)) — conversation \(conversationID.uuidString.prefix(8)) was deleted. CONSEQUENCE: nothing from it re-enters the vector store.")
                return
            }
            await RAGIndexingService.shared.indexSingleMessage(indexable)
        }
        
        activeStreams.removeValue(forKey: message.id)
        liveRunQuestionIDs.removeValue(forKey: message.id)   // in lockstep with activeStreams
        streamStartedAt.removeValue(forKey: message.id)
        // Admit after the removal, never before: `isConversationBusy` reads `activeStreams`, so the next run would park
        // again with nothing left to wake it.
        admission.admitNext(inConversation: conversationID)
        // Every run end comes through here (finished, failed, cancelled); idempotent for a run that
        // never registered (cancelled while queued behind its conversation).
        inferenceCoordinator.unregister(runID: message.id)
        // The run's "allow for this run" grants end with it. Hygiene only: they are keyed by this run's id, so the next run
        // could not match them anyway.
        Task { await SessionToolApprovals.shared.endRun(conversationID: conversationID, runID: message.id) }
        for delegate in liveMirrorDelegates {
            delegate.activeStreamManager(self, didEndStream: message)
        }

        // Dispatch notification if app is in background
        let notifConversationID = conversationID
        let hasError = error != nil
        guard let notificationTitle = Self.completionNotificationTitle(outcome: message.terminalOutcome,
                                                                      hasError: hasError) else {
            logger.info("[NOTIFY] No completion notification for run \(message.id.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) — it was cancelled. CONSEQUENCE: nothing is delivered on any channel; whoever stopped it (Stop, closing the orb, a deleted conversation) already knows.")
            return
        }
        let summaryText: String = {
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                return String(text.prefix(100))
            default:
                return hasError ? "An error occurred." : "Response complete."
            }
        }()

        Task.detached(priority: .utility) {
            // Suppress when the user is viewing: the app is frontmost or the non-activating QuickAccess panel is key.
            let userIsViewing = await MainActor.run { NSApp.isActive || (AppDelegate.shared?.isQuickAccessPanelKey ?? false) }
            guard !userIsViewing else { return }

            let payload = AppNotificationPayload(
                title: notificationTitle,
                body: summaryText,
                conversationID: notifConversationID
            )
            await NotificationDispatcher.shared.dispatch(payload)
        }
    }
    
    
    /// The title of the 'run finished' notification, or nil for a run that must not announce itself. Pure.
    /// A cancelled run is not announced: someone stopped it on purpose.
    nonisolated static func completionNotificationTitle(outcome: ExecutionOutcome?, hasError: Bool) -> String? {
        if outcome == .cancelled { return nil }
        return hasError || outcome == .failed ? "Query Failed" : "Query Completed"
    }

    private func removeTask(for messageId: UUID) {
        if activeTasks.removeValue(forKey: messageId) != nil {
            logger.debug("Cleaned up and removed completed task for message ID: \(messageId.uuidString)")
        }
    }
}

// The send path's chokepoint as a seam; both members already have the required shapes.
extension ActiveStreamManager: MessageStreamStarting {}
