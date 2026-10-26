// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteMirrorService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

// Why: a test that retypes the predicate passes over a mirror that never applies it.
/// Which pending interactions belong to the run being mirrored.
/// A named function rather than an inline `filter`, so production and tests call the same predicate.
enum RemoteInteractionScope {

    // Why: treating nil as a mismatch would stop mirroring those prompts even for a run the remote user started.
    /// Returns the pending items raised by the run being mirrored, plus items raised outside any run.
    /// - Parameter runMessageID: the agent message of the run currently being mirrored.
    /// A nil `origin.runMessageID` passes (today only MCP elicitation, which has no run identity in scope).
    static func belongingToRun(_ runMessageID: UUID, in items: [PendingHITL]) -> [PendingHITL] {
        items.filter { $0.origin.runMessageID == runMessageID || $0.origin.runMessageID == nil }
    }
}

@MainActor
final class RemoteMirrorService: ActiveStreamMirrorDelegate {

    private let logger = DGLogger(category: "RemoteMirrorService")

    // MARK: - State

    /// Active remote sessions keyed by conversationID.
    private var remoteSessions: [UUID: RemoteSessionInfo] = [:]

    /// Tracks which HITL operationIDs have been mirrored to transport (prevents duplicates).
    private var mirroredOperations: Set<UUID> = []

    /// Maps operationID → transport message_id (for editing HITL messages after resolution).
    private var hitlMessageIDs: [UUID: String] = [:]

    /// A resolution that arrived while its prompt was still being posted, parked until the render window can apply it.
    /// Carries the real verdict, so a prompt answered mid-post is not rewritten as "Already answered on another surface".
    /// The interaction-center re-check stays as fallback when the observer Task has not yet run (see the render window).
    private var resolutionsDuringRender: [UUID: (statusText: String, kind: String)] = [:]

    /// One reminder per posted prompt, cancelled when the prompt resolves or the mirror tears down.
    private var reminderTasks: [UUID: Task<Void, Never>] = [:]

    /// How long a mirrored question may sit unanswered before one reminder goes to the remote chat.
    /// A reminder, not a deadline: the question stays open, since HITL is unbounded. `var` so tests can shorten it.
    var remoteReminderDelay: Duration = .seconds(10 * 60)

    /// Messages currently being observed via withObservationTracking.
    private var observedMessageIDs: Set<UUID> = []

    /// Conversations with a mirrored run in flight; written only when the consent gate admits a run.
    /// Separate from `remoteSessions`, an address book the resolution observers still need after the run ends.
    /// This set answers "is something being mirrored right now" and is per run.
    private var mirroringConversations: Set<UUID> = []

    /// Reference to ActiveStreamManager (set as delegate).
    private weak var activeStreamManager: ActiveStreamManager?

    /// Observers for HITL resolution notifications.
    private var permissionResolvedObserver: NSObjectProtocol?
    private var clarificationResolvedObserver: NSObjectProtocol?
    private var planReviewResolvedObserver: NSObjectProtocol?
    private var gateResolvedObserver: NSObjectProtocol?

    // MARK: - Init

    init(activeStreamManager: ActiveStreamManager) {
        self.activeStreamManager = activeStreamManager
        activeStreamManager.addMirrorDelegate(self)   // [D2] multicast — all active transports mirror
        setupHITLResolvedObservers()
    }

    deinit {
        if let obs = permissionResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = planReviewResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = gateResolvedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - ActiveStreamMirrorDelegate

    // Why: gate per run, not per conversation: a conversation once driven from chat must not mirror every later run in it.
    /// Starts mirroring a run only when a remote surface started it; this is the per-run consent gate.
    /// A non-matching source, including unattributed `.localUI`, refuses to mirror, so other runs are never posted out.
    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage,
                             startedBy: MessageSource, for conversationID: UUID) {
        guard let session = remoteSessions[conversationID] else { return }
        guard startedBy == session.source else {
            admissionRefused(startedBy: startedBy, session: session, conversationID: conversationID)
            return
        }
        guard !observedMessageIDs.contains(message.id) else { return }
        // Recorded so `isMirroring` can answer about this run.
        mirroringConversations.insert(conversationID)

        // Logged here, once per admitted run, rather than in the re-entrant `observeMessage` (re-armed on every flush),
        // where it would bury the mirror's real drop lines; `session` is in scope for provider correlation.
        logger.info("[Mirror] Mirroring the run in conversation \(conversationID.uuidString.prefix(8)) to \(session.source.rawValue). CONSEQUENCE: its answer, HITL prompts and failures all reach that chat; a conversation absent from this line produced no remote output at all.")
        observeMessage(message)
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        observedMessageIDs.remove(message.id)
        // [HITL/P5] Drop the final-response send-once key so the dedup Set doesn't grow unbounded.
        mirroredOperations.remove(message.id)
        // The run is over, so mirroring of this conversation ends; the session stays (see `remoteSessions`).
        // Only the notification double-post predicate is released here.
        mirroringConversations.remove(message.conversationId)
    }

    /// Tells the remote chat its run is waiting for the local model, so a slow answer reads as
    /// "second in line" rather than as a dead bridge. Same consent gate as `didStartStream`: only a
    /// run this session's own source started is reported to it.
    func activeStreamManager(_ manager: ActiveStreamManager, didQueueForLocalModel message: ChatMessage,
                             notice: String, startedBy: MessageSource, for conversationID: UUID) {
        guard let session = remoteSessions[conversationID] else { return }   // not a remote conversation
        guard startedBy == session.source else {
            logger.info("[Mirror] Run \(message.id.uuidString.prefix(8)) is waiting for the local model, but it was started by \(startedBy.rawValue), not this conversation's \(session.source.rawValue) session. CONSEQUENCE: the remote chat is not told — the same consent gate as mirroring.")
            return
        }
        guard let provider = session.source.remoteProvider else {
            logger.error("[Mirror] Run \(message.id.uuidString.prefix(8)): session source \(session.source.rawValue) has no remote provider. CONSEQUENCE: the local-model queue notice is not sent; the remote user sees no reply until the run starts.")
            return
        }
        Task { [weak self] in
            do {
                _ = try await session.transport.render(
                    .notice(Notice(tone: .info, icon: "⏳", body: notice)),
                    to: .channel(RemoteChannel(provider: provider, channelID: session.chatID)))
                self?.logger.info("[Mirror] Told \(session.source.rawValue) that run \(message.id.uuidString.prefix(8)) is waiting for the local model.")
            } catch {
                self?.logger.error("[Mirror] The local-model queue notice for run \(message.id.uuidString.prefix(8)) could not be sent to \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the remote user sees no reply until the run starts; the run itself is unaffected.")
            }
        }
    }

    /// Says out loud that a run in a session-bearing conversation was not mirrored.
    /// A refusal is invisible to the remote user; without this line it looks like a dead bridge.
    private func admissionRefused(startedBy: MessageSource, session: RemoteSessionInfo, conversationID: UUID) {
        logger.info("[Mirror] A run in conversation \(conversationID.uuidString.prefix(8)) was started by '\(startedBy.rawValue)' but this session belongs to '\(session.source.rawValue)', so it was NOT mirrored. CONSEQUENCE: its answer stays on the Mac and does not reach the remote chat — which is the point; before this gate existed, every later run in a conversation once driven from chat was posted to the third-party channel, whoever started it. A run you DID start remotely appearing here means its source was not stamped before startMessageStream.")
    }

    // MARK: - Session Registration

    /// Register a remote session for a conversation. Called when a remote message is submitted.
    func registerSession(conversationID: UUID, info: RemoteSessionInfo) {
        remoteSessions[conversationID] = info
        logger.info("[Mirror] Registered remote session for conversation \(conversationID) via \(info.source.rawValue).")
    }

    /// Whether a run in this conversation is being mirrored right now.
    /// The double-post guard: `ChatOpsNotificationChannel` stays quiet for a conversation the mirror is already streaming.
    /// Keyed on the per-run set, not on `remoteSessions`, so a locally-started run still gets a remote notification.
    func isMirroring(_ conversationID: UUID) -> Bool {
        mirroringConversations.contains(conversationID)
    }

    /// Unregisters a remote session; called when its conversation is deleted and on explicit cleanup.

    func unregisterSession(conversationID: UUID) {
        remoteSessions.removeValue(forKey: conversationID)
        logger.info("[Mirror] Unregistered remote session for conversation \(conversationID).")
    }

    // Why: release operation-keyed state with the sessions, or posted prompts keep live buttons nobody can resolve.
    /// Detaches this service when its owning transport stops: removes it from the stream manager's multicast
    /// and drops all sessions. Also releases per-operation state and logs how many posted prompts were abandoned.
    func teardown() {
        let abandonedPrompts = hitlMessageIDs.count
        let sessions = remoteSessions.count
        let observed = observedMessageIDs.count

        activeStreamManager?.removeMirrorDelegate(self)
        remoteSessions.removeAll()
        mirroringConversations.removeAll()
        hitlMessageIDs.removeAll()
        resolutionsDuringRender.removeAll()
        reminderTasks.values.forEach { $0.cancel() }
        reminderTasks.removeAll()
        mirroredOperations.removeAll()
        observedMessageIDs.removeAll()

        if abandonedPrompts > 0 {
            logger.warning("[Mirror] Torn down while \(abandonedPrompts) posted HITL prompt(s) were still live across \(sessions) session(s). CONSEQUENCE: those prompts keep their approve/deny buttons in the remote chat and NOTHING will ever rewrite them — the run they belong to is unreachable from that chat now. A user tapping one gets silence. This fires when ChatOps is switched off mid-run.")
        } else {
            logger.info("[Mirror] Torn down — \(sessions) session(s) and \(observed) observed run(s) released, no live prompts abandoned.")
        }
    }

    // MARK: - Unanswered-question reminder

    /// The reminder's text. The Mac already had a local "Still waiting for you" after 3 min; the
    /// remote operator — the person the question was actually sent to — heard nothing, ever.
    static func reminderText(waitingOn noun: String) -> String {
        "Still waiting for \(noun). Answer the message above, or send /cancel to stop the run."
    }

    private func scheduleReminder(for pending: PendingHITL, session: RemoteSessionInfo, provider: RemoteChannel.Provider) {
        reminderTasks[pending.id]?.cancel()
        let operationID = pending.id
        let delay = remoteReminderDelay
        reminderTasks[operationID] = Task { [weak self] in
            // Cancellation = the question was answered or the mirror went away: silence is correct.
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            self.reminderTasks[operationID] = nil
            // Still open? `hitlMessageIDs` loses the entry on every resolution path.
            guard self.hitlMessageIDs[operationID] != nil,
                  self.activeStreamManager?.interactionCenter?.item(withID: operationID) != nil else { return }
            do {
                _ = try await session.transport.render(
                    .notice(Notice(tone: .warning, icon: "⏰",
                                   body: Self.reminderText(waitingOn: pending.kind.staleNoun))),
                    to: .channel(RemoteChannel(provider: provider, channelID: session.chatID)))
                self.logger.info("[Mirror] Reminded \(session.source.rawValue) that operation \(operationID) is still waiting.")
            } catch {
                self.logger.error("[Mirror] The reminder for operation \(operationID) could not be sent to \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the remote operator is not reminded; the question stays open and answerable, and the Mac's own reminder is unaffected.")
            }
        }
    }

    // MARK: - HITL Response Routing (Transport → Agent)

    /// Which parked operation a remote message id belongs to, if any.
    /// The inverse of `hitlMessageIDs`: a reply names its message and this names the operation, no cursor or ordering.
    /// A linear scan on purpose: few prompts are parked per channel, and a second dictionary would need lockstep upkeep.
    func operationID(forRemoteMessageID messageID: String) -> UUID? {
        hitlMessageIDs.first { $0.value == messageID }?.key
    }

    /// What kind of prompt a parked operation is, for routing a typed reply rather than a button tap.
    /// A button carries its own verb; a reply carries only text, so the prompt it replies to decides the intent.
    /// Returns nil when the operation is already resolved, which callers must report distinctly from a wrong kind.
    func pendingInteraction(forOperation operationID: UUID) -> PendingInteraction? {
        activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind
    }

    /// The provider to record as having answered a prompt this service is resolving.
    /// Derived, not assumed: the resolution notification is global, so a resolution is ours only when the operation's
    /// conversation has a session here (one service per bridge, so all its sessions share one provider).
    private func resolutionSource(for operationID: UUID) -> MessageSource? {
        if let convID = activeStreamManager?.interactionCenter?.item(withID: operationID)?.origin.conversationID,
           let session = remoteSessions[convID] {
            return session.source
        }
        // The item can already be gone from the InteractionCenter when a resolution lands. Every session here belongs to this
        // service's own bridge, so any names the right provider; nil only when there are no sessions and so no claim.
        return remoteSessions.values.first?.source
    }

    /// Called when a remote transport receives an approve/deny button tap.
    /// Kind-aware: the same approve/deny affordance resolves a tool confirmation or a plan review (different continuations).
    func handleApproval(operationID: UUID, approved: Bool) async {
        let kind = activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind
        let source = resolutionSource(for: operationID)
        switch kind {
        case .planReview(let p):
            await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: approved ? p.subtasks : nil, resolvedBy: source)
        case .gate:
            // Gates resolve only via their per-option buttons (`handleGate`), never a bare approve/deny. If one arrives here,
            // do not guess an option (`options.first` could pick a destructive branch): log and leave it.
            logger.warning("[Mirror] Ignoring approve/deny for gate \(operationID) — gates resolve via option buttons.")
        case .toolConfirmation, .clarification, .none:
            await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved, resolvedBy: source)
        }
    }

    /// Called when a remote transport receives a clarification response.
    func handleClarification(operationID: UUID, text: String) async {
        let response: String? = text.isEmpty ? nil : text
        let source = resolutionSource(for: operationID)
        await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response, resolvedBy: source)
    }

    // (handlePlanReview removed — D1's kind-aware `handleApproval` now routes a remote plan-review
    // approve/reject straight to resumePlanReview; this duplicate had no callers. H1 cleanup.)

    /// [D1] Called when a remote transport receives a workflow Gate option tap. Maps the button's option
    /// INDEX back to its label (via the InteractionCenter) and resolves the gate, matching the Mac UI's
    /// `resumeGate(chosenOption:)`. A stale/unknown index cancels the gate (nil) rather than leaving it parked.
    func handleGate(operationID: UUID, optionIndex: Int) async {
        let source = resolutionSource(for: operationID)
        guard case .gate(let g)? = activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind,
              g.options.indices.contains(optionIndex) else {
            // Cancelling is right, since leaving the gate parked forever is worse, but it is a decision the user did not make:
            // the tapped button does not match the options in flight, so it is logged.
            logger.error("[CHATOPS] A remote gate tap for operation \(operationID) named option index \(optionIndex), which no longer matches a live gate. CONSEQUENCE: the gate is DISMISSED rather than resolved with the option the user tapped (the Gate node settles as cancelled: no option branch and no error branch runs), because the button outlived the options it was posted for.")
            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: nil, resolvedBy: source)
            return
        }
        await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: g.options[optionIndex], resolvedBy: source)
    }

    // MARK: - Message Observation

    /// Observe a ChatMessage using withObservationTracking and mirror relevant events.
    private func observeMessage(_ message: ChatMessage) {
        let messageID = message.id
        let conversationID = message.conversationId
        observedMessageIDs.insert(messageID)

        func observe() {
            withObservationTracking {
                // [HITL/P5] Track the unified InteractionCenter queue (single source of truth)
                // instead of the retired per-message pendingInteraction container.
                _ = self.activeStreamManager?.interactionCenter?.pending
                _ = message.isStreaming
                _ = message.agentState
                _ = message.content
            } onChange: {
                Task { @MainActor [weak self, weak message] in
                    guard let self, let message else { return }
                    guard self.observedMessageIDs.contains(messageID) else { return }
                    // Re-arm tracking before the async mirror send so a HITL enqueued during the send window (e.g. a second parallel
                    // workflow node) is still observed; tracking is one-shot and the dedup in `evaluateMessageState` makes it harmless.
                    self.observeMessage(message)
                    await self.evaluateMessageState(message, conversationID: conversationID)
                }
            }
        }
        observe()


    }

    /// Evaluates current message state and mirrors events to the remote transport.
    private func evaluateMessageState(_ message: ChatMessage, conversationID: UUID) async {
        guard let session = remoteSessions[conversationID] else { return }

        // Mirrors every un-mirrored HITL item of this run (a workflow can await on several nodes), filtered by
        // `origin.runMessageID` so a local run in the same conversation is not posted out; a nil run id is posted.
        let allPending = activeStreamManager?.interactionCenter?.items(for: conversationID) ?? []
        let pendingHITLs = RemoteInteractionScope.belongingToRun(message.id, in: allPending)

        let withheld = allPending.count - pendingHITLs.count
        if withheld > 0 {
            logger.warning("[Mirror] Withheld \(withheld) pending interaction(s) in conversation \(conversationID.uuidString.prefix(8)) from \(session.source.rawValue): they were raised by a different run than the one being mirrored (\(message.id.uuidString.prefix(8))). CONSEQUENCE: those prompts are answerable on the Mac banner only, which is correct — before this filter another run's tool name and parameters were posted to the remote channel purely because the two runs shared a conversation.")
        }

        for pending in pendingHITLs where !mirroredOperations.contains(pending.id) {
            let hitlType: HITLType
            switch pending.kind {
            case .toolConfirmation(let c):
                hitlType = .toolConfirmation(toolName: c.toolName, params: c.params)
            case .clarification(let c):
                // A5: the remote channel is free-text, so append the suggested options to the prompt
                // body (the model's choices are otherwise invisible on Slack/Discord/Telegram).
                let question = (c.options?.isEmpty == false)
                    ? c.question + "\n\nReply with one of: " + (c.options ?? []).joined(separator: " / ")
                    : c.question
                hitlType = .clarification(question: question)
            case .planReview(let p):
                hitlType = .planReview(subtaskDescriptions: p.subtasks.map(\.description))
            case .gate(let g):
                // Real gate prompt: one tappable button per option; a tap routes back through `hitl:gate:<opID>:<idx>`.
                // The input text (a Router's or a Gate node's) is folded into the prompt, since remote platforms cannot render the
                // highlight spans.
                let remotePrompt: String = {
                    guard let input = g.inputText, !input.isEmpty else { return g.prompt }
                    return "\(g.prompt)\n\n\(input)"
                }()
                hitlType = .gate(prompt: remotePrompt, options: g.options)
            }

            do {
                // [C8.5] One render path for everything a channel is shown. The transport returns
                // the posted message id, which is what lets a resolved prompt be edited in place.
                guard let provider = session.source.remoteProvider else {
                    logger.error("[Mirror] A remote session carries source \(session.source.rawValue), which is not a remote provider — the HITL prompt was NOT sent. CONSEQUENCE: the run stays parked with no prompt visible anywhere remote, and only the Mac banner can answer it.")
                    continue
                }
                // One render path for everything a channel is shown; the returned id lets a resolved prompt be edited in place.
                // Claimed before the await (overlapping passes could otherwise post the same prompt twice), released in the `catch`.
                mirroredOperations.insert(pending.id)
                let msgID = try await session.transport.render(
                    .prompt(operationID: pending.id, kind: hitlType),
                    to: .channel(RemoteChannel(provider: provider, channelID: session.chatID))
                )
                if let msgID {
                    // `render` is a network round-trip; a resolution landing inside it was missed by every observer, so re-check after.
                    // Reserving a placeholder before it would make observers act on a message id that does not exist yet.
                    if let resolved = resolutionsDuringRender.removeValue(forKey: pending.id) {
                        // The observer already delivered the real verdict while the post was in
                        // flight. Apply it now; a notification does not fire twice.
                        await editResolvedPrompt(session,
                                                 messageID: msgID,
                                                 to: resolved.statusText,
                                                 operationID: pending.id,
                                                 kind: resolved.kind)
                        // Released like any resolved operation — a claim never shed suppresses
                        // every later pass for this id and grows the dedup Set without bound.
                        mirroredOperations.remove(pending.id)
                        logger.info("[Mirror] Operation \(pending.id) was resolved while its \(resolved.kind) prompt was still being posted to \(session.source.rawValue); the posted message was rewritten with the actual outcome. CONSEQUENCE: none — the prompt shows what was decided and has no live buttons.")
                    } else if activeStreamManager?.interactionCenter?.item(withID: pending.id) == nil {
                        logger.error("[Mirror] Operation \(pending.id) resolved while its prompt was being posted to \(session.source.rawValue). CONSEQUENCE: the prompt is rewritten as resolved immediately and its correlation id is NOT stored — without this it would have kept live buttons for a decision already made, and later replies to it would have been routed to a suspension that no longer exists.")
                        await editResolvedPrompt(session,
                                                 messageID: msgID,
                                                 to: "✅ Already answered on another surface.",
                                                 operationID: pending.id,
                                                 kind: "HITL")
                        // Fallback path only: the prompt left the centre but this service's observer Task has not run, so the precise verdict
                        // is not here. Release the claim so that Task sees nothing posted and does nothing.
                        mirroredOperations.remove(pending.id)
                    } else {
                        hitlMessageIDs[pending.id] = msgID
                        scheduleReminder(for: pending, session: session, provider: provider)
                    }
                } else {
                    if let resolved = resolutionsDuringRender.removeValue(forKey: pending.id) {
                        logger.error("[Mirror] Operation \(pending.id) resolved while its \(resolved.kind) prompt was being posted to \(session.source.rawValue), but the transport returned no message id. CONSEQUENCE: the prompt CANNOT be rewritten — it keeps its buttons for a decision already made, and the outcome \"\(resolved.statusText)\" is discarded because there is no message to put it on.")
                    }
                    logger.error("[Mirror] The transport posted the HITL prompt for operation \(pending.id) but returned no message id. CONSEQUENCE: the prompt cannot be edited when it resolves, so its buttons stay live and the remote user can tap a decision that has already been made.")
                }
                logger.info("[Mirror] Sent HITL prompt to \(session.source.rawValue) for operation \(pending.id).")
            } catch {
                // Release the claim: the prompt was NOT posted, so the next pass must try again.
                mirroredOperations.remove(pending.id)
                // Nothing was posted, so a verdict parked for this prompt has nowhere to land — and
                // must not be applied to a LATER, unrelated re-post of the same operation.
                if let resolved = resolutionsDuringRender.removeValue(forKey: pending.id) {
                    logger.error("[Mirror] Operation \(pending.id) resolved while its \(resolved.kind) prompt was in flight to \(session.source.rawValue), and that post then FAILED. CONSEQUENCE: the remote chat never saw this prompt, so nothing misleading is on screen — but the outcome \"\(resolved.statusText)\" is not reported remotely either; only the Mac records it.")
                }
                logger.error("[Mirror] Failed to send HITL prompt for operation \(pending.id) to \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the run stays parked with no prompt visible remotely; the claim is released so the next observation pass re-sends it, and only the Mac banner can answer it until then.")
            }
        }

        // Mirror final response (stream complete)
        if !message.isStreaming && message.agentState == .idle && message.sender == .agent {
            let responseKey = message.id

            // No `default:` arm: every `MessageContent` case is named so a new case fails to compile here instead of silently
            // inheriting "Response complete.", which would report a failed run as a success.
            var responseText: String
            // Error cards already say how the run ended; checkpoints are not replies. Everything else
            // is annotated with the run's outcome below.
            var annotatesOutcome = true
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                responseText = text

            case .codeBlock(_, let code):
                responseText = code

            case .error(let title, let details, let category, let suggestion):
                // Sanitised because error text leaves the process to a third-party chat service; `TelemetrySanitizer.sanitize`
                // over-redacts rather than under-redacts. Normal responses are sent unsanitised; this call does not cover them.
                let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                var lines = ["⚠️ " + TelemetrySanitizer.sanitize(
                    (heading?.isEmpty == false ? heading! : "The run failed")
                )]
                let body = TelemetrySanitizer.sanitize(details)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { lines.append(body) }
                if let suggestion,
                   !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Suggestion: " + TelemetrySanitizer.sanitize(suggestion))
                }
                responseText = lines.joined(separator: "\n\n")
                annotatesOutcome = false
                logger.error("[Mirror] Mirroring a FAILED run to \(session.source.rawValue) for conversation \(conversationID) — category \(category?.rawValue ?? "unspecified"). CONSEQUENCE: the remote user is now told the run failed and why; before this they were told \"Response complete.\" and had no way to learn the answer was never coming.")

            case .mediaArtifact(let artifact):
                // The artifact cannot be sent (`ChatOpsTransport` has no attachment API), so it is described instead.
                let label = artifact.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let what = (label?.isEmpty == false) ? label! : artifact.kind.rawValue
                responseText = "🖼 The agent produced \(what). It can only be viewed on the Mac — this channel cannot carry attachments."
                logger.info("[Mirror] A media artifact was produced for conversation \(conversationID); a description was mirrored to \(session.source.rawValue). CONSEQUENCE: the remote user is told what exists but cannot see it, because no transport implements attachments.")

            case .checkpoint:
                // A compaction checkpoint is internal bookkeeping, never an answer. Believed unreachable here (observation begins at
                // `didStartStream`) but named rather than defaulted so it cannot become a spurious remote message.
                responseText = ""
                annotatesOutcome = false
                logger.info("[Mirror] A compaction checkpoint reached the mirror for conversation \(conversationID) and was NOT sent. CONSEQUENCE: nothing is posted remotely, which is correct — a checkpoint is not a reply. If this line ever appears, the reachability note beside it is wrong.")

            case .unknown(let type, _):
                // Readable JSON this build cannot model — see `MessageContent.unknown`.
                responseText = "The agent replied with content this version of Devgentic cannot display (\(type))."
                logger.error("[Mirror] Unmodellable content of type \(type) reached the mirror for conversation \(conversationID). CONSEQUENCE: the remote user is told the reply cannot be shown rather than being told the run completed normally.")
            }

            if annotatesOutcome {
                let annotated = Self.finalResponse(body: responseText, outcome: message.terminalOutcome,
                                                   reason: message.terminalReason)
                if annotated != responseText {
                    logger.notice("[Mirror] Mirroring a run that ended \(message.terminalOutcome?.rawValue ?? "?") to \(session.source.rawValue) for conversation \(conversationID) — its outcome is stated with the reply. CONSEQUENCE: the remote user is told the run did not finish normally; before this a timed-out or stopped run arrived as its partial text, read as a complete answer.")
                }
                responseText = annotated
            }

            // Emptiness is checked before the claim: `content` is observed, so a claim for a message with nothing to say would
            // suppress a body that arrives moments later.
            guard !responseText.isEmpty else { return }

            // Claim before the `await`: overlapping passes are real, and check-and-insert is atomic on `@MainActor`.
            // Release the claim if the send throws, or the dropped answer would suppress every later retry.
            guard !mirroredOperations.contains(responseKey) else { return }
            mirroredOperations.insert(responseKey)

            do {
                try await session.transport.sendChunkedMessage(chatID: session.chatID, text: responseText)
                logger.info("[Mirror] Sent full response to \(session.source.rawValue) for conversation \(conversationID).")
            } catch {
                mirroredOperations.remove(responseKey)
                logger.error("[Mirror] Failed to send response for conversation \(conversationID) to \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the agent's answer has NOT reached the remote chat. The send-once claim is released so the next observation pass retries — but if the stream has already ended no further pass occurs, and the answer is lost to the remote user with only this line to say so.")
            }
        }
    }

    // Why: the outcome lives outside the content: a stopped run writes no error card, so content alone looks complete.
    /// The text a finished run is mirrored with, given what its content renders to (`body`) and how it ended.
    /// A time-out or stop appends the sanitised reason to the partial text; a failure with prose appends a failure line.
    /// A failure with no prose returns an empty string; anything else returns `body` unchanged. Pure.
    nonisolated static func finalResponse(body: String, outcome: ExecutionOutcome?, reason: String?) -> String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sentence of its own, whatever the reason's source: "Cancelled by user" and most error
        // descriptions carry no full stop, and the line continues after them.
        let why = (trimmed?.isEmpty == false) ? Self.sentence(TelemetrySanitizer.sanitize(trimmed!)) : nil
        let notice: String
        switch outcome {
        case .timedOut:
            notice = "⏱ " + (why ?? "The run timed out before it finished.")
        case .cancelled:
            notice = "⏹ " + (why ?? "The run was stopped before it finished.")
        case .failed:
            guard !body.isEmpty else { return "" }
            notice = "⚠️ The run failed before it finished" + (why.map { ": \($0)" } ?? ".")
        case .completed, .completedWithWarnings, nil:
            return body
        }
        guard !body.isEmpty else { return notice }
        return body + "\n\n" + notice + " The text above is what it had written so far."
    }

    /// `text` ending in sentence punctuation — a full stop added when it has none.
    private nonisolated static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…)\"'”’".contains(last) else { return text }
        return text + "."
    }

    // MARK: - Cross-Surface HITL Resolution

    /// Rewrites a resolved HITL prompt in place, and says so when it cannot.
    /// The edit is what clears the buttons on every transport; a failed edit leaves live buttons on a decided prompt.
    /// - Parameter kind: which prompt this was, so the log names what stayed tappable (required, not defaulted).
    private func editResolvedPrompt(
        _ session: RemoteSessionInfo,
        messageID: String,
        to statusText: String,
        operationID: UUID,
        kind: String
    ) async {
        do {
            try await session.transport.editMessage(
                chatID: session.chatID,
                messageID: messageID,
                newText: statusText
            )
        } catch {
            logger.error("[Mirror] Failed to rewrite the resolved \(kind) prompt for operation \(operationID) on \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the remote message still shows its \(kind) buttons for a decision that has ALREADY been made. Tapping one now does nothing at all — the bridge acks it, no pending item matches, and the user gets no reply on any surface. The message id is dropped immediately after this call, so no later pass can repair it; the prompt misrepresents the run until the user scrolls past it.")
        }
    }


    // Why: observers fire on a global notification, so a hard-coded 'from Mac' would misreport answers given elsewhere.
    /// How the remote copy names whoever answered a prompt; an absent source (a deadline or force-cancel) prints nothing.
    /// Proper nouns, not localized, as in `RemoteConversationOrigin`.
    private static func attribution(for source: MessageSource?, in session: RemoteSessionInfo) -> String {
        guard let source else { return "" }
        if source == session.source { return " from this chat" }
        switch source {
        case .telegram:                       return " from Telegram"
        case .discord:                        return " from Discord"
        case .slack:                          return " from Slack"
        case .localUI, .quickAccess, .orb: return " from the Mac"
        // Neither was answered by a human, so naming a surface would be a lie: `.scheduled` fires from a timer and
        // `.backgroundTask` because a command finished.
        case .scheduled, .backgroundTask:     return ""
        }
    }

    /// What a resolution notification means for this mirror: rewritable, not ours, or stranded.
    /// `.notOurs` is silent (a Mac-only resolution); `.stranded` (ours, but the session is lost) is logged.
    /// `hitlMessageIDs` is checked first so `.notOurs` stays narrow and Mac-only resolutions do not flood the log.
    private enum PromptResolution {
        case rewritable(messageID: String, session: RemoteSessionInfo)
        case notOurs
        case stranded(messageID: String, reason: String)
    }

    private func promptResolution(operationID: UUID?, conversationID: UUID?) -> PromptResolution {
        guard let operationID, let messageID = hitlMessageIDs[operationID] else { return .notOurs }
        guard let conversationID else {
            return .stranded(messageID: messageID, reason: "the notification carried no conversation id")
        }
        guard let session = remoteSessions[conversationID] else {
            return .stranded(messageID: messageID, reason: "no remote session remains for conversation \(conversationID.uuidString.prefix(8)) — ChatOps was switched off, or the bridge was stopped, while this prompt was live")
        }
        return .rewritable(messageID: messageID, session: session)
    }

    /// The message id and session a resolved prompt can be rewritten through, or nil.
    /// Reports `.stranded` itself, so the four observers keep a one-line guard and cannot each forget the log.
    /// Both outcomes return nil: callers behave identically (stop) and only the logging differs.
    private func rewritableTarget(operationID: UUID?,
                                  conversationID: UUID?) -> (messageID: String, session: RemoteSessionInfo)? {
        switch promptResolution(operationID: operationID, conversationID: conversationID) {
        case .rewritable(let messageID, let session):
            return (messageID, session)
        case .notOurs:
            return nil
        case .stranded(let messageID, let reason):
            reportStranded(operationID, messageID: messageID, reason: reason)
            return nil
        }
    }

    private func reportStranded(_ operationID: UUID?, messageID: String, reason: String) {
        logger.warning("[Mirror] A resolved HITL prompt (op \(operationID?.uuidString.prefix(8) ?? "?"), remote message \(messageID)) cannot be rewritten: \(reason). CONSEQUENCE: its approve/deny buttons stay LIVE in the remote chat on a decision that has already been made — a tap does nothing and answers nobody. Before this line the case was indistinguishable from the ordinary 'not ours' bail and left no trace at all.")
    }

    /// Where a resolution should go: onto a posted prompt, or parked for one still being posted.
    private enum ResolutionTarget {
        case posted(messageID: String, session: RemoteSessionInfo)
        case midPost(session: RemoteSessionInfo)

        var session: RemoteSessionInfo {
            switch self {
            case .posted(_, let session), .midPost(let session): return session
            }
        }
    }

    /// Resolves the target of a resolution notification, including a prompt of ours that is still being posted.
    /// `rewritableTarget` says "not ours" until `transport.render` returns and records the id.
    /// `mirroredOperations` is claimed before the await, so claimed-but-no-id means the prompt is mid-post.
    private func resolutionTarget(operationID: UUID, conversationID: UUID?) -> ResolutionTarget? {
        if let posted = rewritableTarget(operationID: operationID, conversationID: conversationID) {
            return .posted(messageID: posted.messageID, session: posted.session)
        }
        guard hitlMessageIDs[operationID] == nil,              // not a stranded posted prompt
              mirroredOperations.contains(operationID),        // claimed → a post is in flight
              let conversationID,
              let session = remoteSessions[conversationID] else { return nil }
        return .midPost(session: session)
    }

    /// The one place every observer hands its verdict to — an edit now, or a rendezvous with the
    /// render window.
    private func applyResolution(_ target: ResolutionTarget, operationID: UUID,
                                 statusText: String, kind: String) async {
        switch target {
        case .posted(let messageID, let session):
            await editResolvedPrompt(session, messageID: messageID, to: statusText,
                                     operationID: operationID, kind: kind)
            hitlMessageIDs.removeValue(forKey: operationID)
            mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
        case .midPost(let session):
            resolutionsDuringRender[operationID] = (statusText, kind)
            logger.info("[Mirror] Operation \(operationID) resolved while its \(kind) prompt was still being posted to \(session.source.rawValue); the outcome is held for the post to apply. CONSEQUENCE: none if the post succeeds.")
        }
    }

    /// Reads the two facts every observer needs out of a resolution notification.
    private static func resolution(from notification: Notification) -> (outcome: String?, source: MessageSource?) {
        let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String
        let source = (notification.userInfo?[HITLResolvedKey.source] as? String)
            .flatMap(MessageSource.init(rawValue:))
        return (outcome, source)
    }

    /// When Mac UI resolves an HITL event, update the Telegram message to show it was handled.
    private func setupHITLResolvedObservers() {
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let approved = notification.userInfo?[HITLResolvedKey.approved] as? Bool
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let resolution = Self.resolution(from: notification)

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let approved,
                      let target = self.resolutionTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let session = target.session

                // A cancel is not a denial: `drainOperation` resolves a torn-down permission with `approved: false`, so the
                // `outcome` key ("cancelled") must be read, or a stopped run would render as "Tool denied".
                let statusText: String
                if resolution.outcome == "cancelled" {
                    statusText = "⏹ Tool request cancelled — the run was stopped."
                } else {
                    statusText = (approved ? "✅ Tool approved" : "❌ Tool denied")
                        + Self.attribution(for: resolution.source, in: session) + "."
                }

                await self.applyResolution(target, operationID: operationID,
                                           statusText: statusText, kind: "tool approval")
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let resolution = Self.resolution(from: notification)

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let target = self.resolutionTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let session = target.session

                let statusText: String
                switch resolution.outcome {
                case "cancelled":
                    statusText = "⏹ Clarification cancelled — the run was stopped."
                case "skipped":
                    statusText = "⏭ Clarification skipped"
                        + Self.attribution(for: resolution.source, in: session) + "."
                default:
                    statusText = "✅ Clarification answered"
                        + Self.attribution(for: resolution.source, in: session) + "."
                }
                await self.applyResolution(target, operationID: operationID,
                                           statusText: statusText, kind: "clarification")
            }
        }

        planReviewResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPlanReviewResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let resolution = Self.resolution(from: notification)

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let target = self.resolutionTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let session = target.session

                let statusText: String
                switch resolution.outcome {
                case "cancelled":
                    statusText = "⏹ Plan review cancelled — the run was stopped."
                case "rejected":
                    statusText = "❌ Plan rejected"
                        + Self.attribution(for: resolution.source, in: session) + "."
                default:
                    statusText = "✅ Plan approved"
                        + Self.attribution(for: resolution.source, in: session) + "."
                }
                await self.applyResolution(target, operationID: operationID,
                                           statusText: statusText, kind: "plan review")
            }
        }

        // [D1] Gate resolved (a choice was made on the Mac or remotely) → reflect the outcome and
        // drop the now-stale option buttons on the remote message.
        gateResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlGateResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let source = Self.resolution(from: notification).source

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let target = self.resolutionTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let session = target.session

                // A cancelled gate is not a decision, so it gets no ✅ and no attribution.
                let statusText: String
                // A gate that is not answered takes no option branch: a stopped run ends, an expired gate fails onto its error port.
                if outcome == nil || outcome == "cancelled" {
                    statusText = "⏹ Gate cancelled — the run was stopped; no option was chosen."
                } else if outcome == "expired" {
                    statusText = "⌛ Gate expired — nobody answered in time; the workflow took its error path."
                } else {
                    statusText = "✅ Gate decided: \(outcome ?? "")"
                        + Self.attribution(for: source, in: session) + "."
                }
                await self.applyResolution(target, operationID: operationID,
                                           statusText: statusText, kind: "gate")
            }
        }
    }
}
