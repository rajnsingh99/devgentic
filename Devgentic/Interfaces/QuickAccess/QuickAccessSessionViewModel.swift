// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessSessionViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import SwiftData
import os

/// Drives the floating quick-access panel through the app's real streaming stack, with a panel-local history view model
/// on the shared stream manager and a panel-local backend configuration.
@Observable @MainActor
final class QuickAccessSessionViewModel {

    // MARK: - Reused shared UI state

    /// The panel's own transcript VM — a SECOND ChatHistoryViewModel instance bound to the
    /// SHARED ActiveStreamManager, so live streams merge in but the message list is
    /// panel-local and never touches the main window's currentChatMessages.
    let chatHistoryViewModel: ChatHistoryViewModel

    /// Panel-local search VM. Cheap; the shared bubble views require it in the environment.
    let searchViewModel = ChatSearchViewModel()

    /// Panel-local profile selection, separate from the main window's `BackendConfiguration`.
    let backendConfiguration = BackendConfiguration()

    // MARK: - Injected graph (all reached through the one shared MainApplicationViewModel)

    @ObservationIgnored private weak var mainAppViewModel: MainApplicationViewModel?

    /// The narrow stream-starting seam (start a run, cancel the one it started) rather than the concrete manager.
    @ObservationIgnored private let activeStreamManager: any MessageStreamStarting

    /// The persistence protocol rather than the concrete store, so tests can substitute a double.
    @ObservationIgnored private let persistence: ChatPersistenceProtocol
    @ObservationIgnored private let logger = DGLogger(category: "QuickAccessSessionViewModel")

    // MARK: - Session state

    private(set) var conversationID: UUID?

    /// Non-nil while a panel-originated stream is in flight; drives the Send/Stop toggle.
    /// Panel-local so it never clobbers a concurrent main-window stream.
    private(set) var streamingMessageID: UUID?
    /// [C1] The conversation the in-flight stream belongs to. stop() drains THIS conversation's
    /// HITL suspension — not whichever conversation the panel currently shows (the user may have
    /// switched to another via the recents menu while the stream was still running).
    private(set) var streamingConversationID: UUID?
    /// Set synchronously on accepting a send, covering the async gap before `streamingMessageID` is known.
    /// Without it a second submit in that gap would start a duplicate stream on the conversation.
    private(set) var isPreparingSend = false
    var isSending: Bool { streamingMessageID != nil || isPreparingSend }

    // Why: `openConversation` sets `conversationID` inside this task and the load assigns `currentChatMessages`;
    // a send that overtook it would file the turn wrongly or have its user row wiped.
    /// The in-flight transcript load; `send()` awaits it before building its turn.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// [C10] Observes external SwiftData writes so the panel transcript refreshes when another
    /// surface (main window / ChatOps / scheduler) appends to the panel's conversation.
    @ObservationIgnored private var didSaveObserver: NSObjectProtocol?
    @ObservationIgnored private var externalRefreshTask: Task<Void, Never>?
    /// [L7] When the last external-refresh reload ran — floors the reload rate so a stream of
    /// unrelated app-wide saves (e.g. a main-window run persisting tokens while the panel sits
    /// open on a different, idle conversation) can't reload on every single save.
    @ObservationIgnored private var lastExternalReload: Date = .distantPast

    // MARK: - Init

    /// Profile types a chat-style quick-entry panel may use; excludes workflow, code and imageGen profiles.
    static let allowedProfileTypes: Set<ProfileType> = [.bot, .agent]

    // Why: any prompt decoration must travel as `promptOverride`, not by mutating this message,
    // or the displayed row and the model's copy drift apart.
    /// Builds the panel's user turn: one message that is persisted, displayed and handed to the send path.
    /// Sends no `promptOverride` and no history slice; history is derived by `ActiveStreamManager`.
    /// `static` so the contract is testable without constructing a `MainApplicationViewModel`.
    static func panelTurn(
        query: String,
        conversationID: UUID,
        files: [FileSystemItem],
        fileProcessorService: FileProcessorService,
        deliveryMode: AttachmentDeliveryMode? = nil
    ) async -> ChatMessage {
        let userMessage = await MessagingCoordinator.makeUserMessage(
            conversationID: conversationID,
            query: query,
            files: files,
            fileProcessorService: fileProcessorService,
            deliveryMode: deliveryMode
        )
        userMessage.messageSource = .quickAccess   // [Q2] attribute panel traffic
        return userMessage
    }

    init(mainAppViewModel: MainApplicationViewModel,
         persistence: ChatPersistenceProtocol = ChatPersistenceStore.shared) {
        self.mainAppViewModel = mainAppViewModel
        // Not injectable: `ChatHistoryViewModel.init` requires the concrete manager, so an injected spy would
        // diverge from the panel's own transcript.
        self.activeStreamManager = mainAppViewModel.activeStreamManager
        self.persistence = persistence
        self.chatHistoryViewModel = ChatHistoryViewModel(
            persistenceService: persistence,
            activeStreamManager: mainAppViewModel.activeStreamManager
        )
        self.backendConfiguration.selectedProfileID = Self.resolveDefaultProfileID(mainAppViewModel: mainAppViewModel)

        // Refreshes the transcript on external writes to the panel's conversation (see `scheduleExternalRefresh`).
        // `queue: .main` guarantees main-thread delivery, so `assumeIsolated` is safe.
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleExternalRefresh() }
        }
    }

    deinit {
        if let didSaveObserver { NotificationCenter.default.removeObserver(didSaveObserver) }
    }

    /// Resolves the panel's default profile to a chat-type profile, never a workflow or code profile.
    /// Order: remembered QuickAccess profile, the main window's selection if chat-type, first bot, first agent.
    private static func resolveDefaultProfileID(mainAppViewModel: MainApplicationViewModel) -> UUID? {
        // [Q6] Targeted fetches on the common path (remembered / main-window selection) instead of
        // materializing every profile on each summon; the full fetch runs only on first-run fallback.
        func chatTypeID(_ id: UUID?) -> UUID? {
            guard let id, let p = try? BackendProfileStore.shared.fetchProfile(byId: id),
                  allowedProfileTypes.contains(p.profileType) else { return nil }
            return id
        }
        // 1. Remembered QuickAccess profile (if it still exists and is a chat type).
        if let remembered = UserDefaults.standard.string(forKey: GlobalConstants.quickAccessProfileID),
           let id = chatTypeID(UUID(uuidString: remembered)) {
            return id
        }
        // 2. The main window's current selection, ONLY if it is a chat type.
        if let id = chatTypeID(mainAppViewModel.backendConfiguration.selectedProfileID) {
            return id
        }
        // 3. First bot, then first agent — needs the full list, only reached on first run or when
        //    neither a remembered nor a selected chat profile resolves.
        let profiles = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []
        return profiles.first(where: { $0.profileType == .bot })?.id
            ?? profiles.first(where: { $0.profileType == .agent })?.id
    }

    /// Memoizes the selected profile so repeated reads per render don't hit SwiftData each time.
    /// Reads `selectedProfileID` first so views re-render on change; the store fetch runs only when the id changes.
    @ObservationIgnored private var cachedProfile: (id: UUID, snapshot: BackendProfileModel?)?

    var selectedProfile: BackendProfileModel? {
        guard let id = backendConfiguration.selectedProfileID else { return nil }
        if let cached = cachedProfile, cached.id == id { return cached.snapshot }
        let snapshot = try? BackendProfileStore.shared.fetchProfile(byId: id)
        cachedProfile = (id, snapshot)
        return snapshot
    }

    /// Persist the panel's current profile choice so it sticks across panel sessions.
    func rememberSelectedProfile() {
        if let id = backendConfiguration.selectedProfileID {
            UserDefaults.standard.set(id.uuidString, forKey: GlobalConstants.quickAccessProfileID)
        }
    }

    // MARK: - Session lifecycle

    /// Called when the panel appears; resolves the persisted QuickAccess conversation and loads its transcript.
    /// Creates no conversation (deferred to the first send); the load is kept as `loadTask` for `send()` to await.
    func prepareSession(resume: Bool = true) {
        loadTask = Task { @MainActor [weak self] in
            await self?.performPrepare(resume: resume)
        }
    }

    private func performPrepare(resume: Bool) async {
        // A timed-out (non-resumable) open starts a fresh session by dropping the current-conversation pointer;
        // the old conversation stays in history.
        guard resume else {
            startNewSession()
            return
        }
        if let existing = conversationID {
            await chatHistoryViewModel.loadConversation(id: existing)
            return
        }
        if let existing = resolveExistingConversationID() {
            conversationID = existing
            adoptConversationProfileIfChatType(existing)
            await chatHistoryViewModel.loadConversation(id: existing)
        }
    }

    /// When adopting an existing conversation (e.g. a transfer handed over from the main
    /// window), use its persisted profile if it is a chat type — otherwise keep the panel's
    /// default. Keeps "continue this chat in the panel" on the same backend it was using.
    private func adoptConversationProfileIfChatType(_ id: UUID) {
        guard let sd = persistence.getConversation(withId: id),
              let boundID = sd.backendEntityId,
              let profile = try? BackendProfileStore.shared.fetchProfile(byId: boundID),
              Self.allowedProfileTypes.contains(profile.profileType) else { return }
        backendConfiguration.selectedProfileID = boundID
    }

    /// Starts a fresh QuickAccess session: rotates off the current conversation so the next
    /// send creates a new one. Any in-flight stream keeps running on its own conversation
    /// (it still finalizes + persists via ActiveStreamManager).
    func startNewSession() {
        conversationID = nil
        streamingMessageID = nil
        streamingConversationID = nil
        isPreparingSend = false
        chatHistoryViewModel.currentChatMessages = []
        UserDefaults.standard.removeObject(forKey: GlobalConstants.quickAccessOverlayConversationId)
    }

    /// [QA revival P2c] Switch the panel to an existing conversation (from the recents menu).
    /// Non-blocking: stores the load as `loadTask` so send() can await it (C3).
    func openConversation(_ id: UUID) {
        loadTask = Task { @MainActor [weak self] in
            await self?.performOpen(id)
        }
    }

    private func performOpen(_ id: UUID) async {
        conversationID = id
        UserDefaults.standard.set(id.uuidString, forKey: GlobalConstants.quickAccessOverlayConversationId)
        adoptConversationProfileIfChatType(id)
        await chatHistoryViewModel.loadConversation(id: id)
    }

    /// Returns the most recent non-empty conversations for the recents menu, up to `limit`.
    func recentConversations(limit: Int = 5) -> [(id: UUID, title: String)] {
        persistence.recentConversations(limit: limit)
    }

    /// Coalesces a reload after external SwiftData writes, only while the panel is idle.
    /// During its own stream the live state already reflects reality and a reload would fight it.
    private func scheduleExternalRefresh() {
        guard let convID = conversationID, streamingMessageID == nil, !isPreparingSend else { return }
        externalRefreshTask?.cancel()
        externalRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Debounces save bursts (400ms) and floors reloads to one per second so unrelated saves can't reload constantly;
            // each save reschedules, so the trailing reload still sees the final state.
            let sinceLast = Date().timeIntervalSince(self.lastExternalReload)
            try? await Task.sleep(for: .seconds(max(0.4, 1.0 - sinceLast)))
            guard !Task.isCancelled,
                  self.streamingMessageID == nil, !self.isPreparingSend,
                  self.conversationID == convID else { return }
            self.lastExternalReload = Date()
            await self.chatHistoryViewModel.loadConversation(id: convID)
        }
    }

    // MARK: - Send / stop

    /// Outcome of a send attempt, so the view can react to a refusal (keep the draft, surface
    /// feedback) instead of silently discarding the user's text/attachments. [H2]
    enum SendOutcome {
        case accepted
        /// A panel stream is already in flight (or being prepared).
        case rejectedBusy
        /// No usable chat profile is selected/resolvable (first run, or a remembered profile was
        /// deleted). The view should prompt the user to pick one rather than eat the message.
        case rejectedNoProfile
        /// Nothing to send.
        case rejectedEmpty
        /// The shared graph is unavailable (should not happen in practice).
        case rejectedUnavailable
    }

    @discardableResult
    func send(_ rawText: String, files: [FileSystemItem] = []) -> SendOutcome {
        let query = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow send with text OR attachments (e.g. an image for a vision model).
        guard !(query.isEmpty && files.isEmpty) else { return .rejectedEmpty }
        // Re-entry guard: rejects while a stream is in flight or being prepared; `isPreparingSend` closes the async gap.
        guard streamingMessageID == nil, !isPreparingSend else { return .rejectedBusy }
        guard let mainVM = mainAppViewModel else {
            logger.error("send aborted — main view model unavailable.")
            return .rejectedUnavailable
        }
        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("send aborted — no profile selected or profile not found in store.")
            return .rejectedNoProfile
        }

        // Reserves the in-flight slot synchronously, before the awaits below, so a second submit is rejected as busy.
        isPreparingSend = true

        Task { @MainActor in
            // Clear the prepare reservation once setup finishes (streamingMessageID has taken
            // over by then, so isSending stays continuously true) or if we bail early.
            defer { isPreparingSend = false }

            // Waits for any in-flight resume/open load so the conversation identity and visible transcript are settled.
            await loadTask?.value

            let title = query.isEmpty ? (files.first?.name ?? String(localized: "Attachment")) : query
            let convID = ensureConversation(titleFrom: title, profileID: config.profile.id)
            // Bind the profile so restart-resume (G1), ChatOps, and the sidebar all resolve it.
            persistence.updateBackendForConversation(id: convID, backendEntityId: config.profile.id)

            // Built through `panelTurn` so the persisted row and the row handed to the send path are one object.
            let userMessage = await Self.panelTurn(
                query: query,
                conversationID: convID,
                files: files,
                fileProcessorService: mainVM.messagingCoordinator.fileProcessor,
                deliveryMode: AttachmentDeliveryMode.resolve(for: config.profile)
            )
            await persistence.addMessage(userMessage, toConversation: convID)
            chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)

            // History is not built here: `ActiveStreamManager` derives it from the store.
            // `currentChatMessages` is a pagination window, not the conversation, and must not be substituted.

            // Identity for the completion guard: `onComplete` fires on every termination, so a stopped older stream's late
            // completion must not nil a newer stream's state. Filled right after the call.
            var thisStreamID: UUID?
            // Workflow bookkeeping; always nil today because `allowedProfileTypes` excludes workflow profiles.
            // Kept so the call shape matches every other `startMessageStream` site.
            let workflowTicket = WorkflowRunBootstrap.begin(
                config: config,
                conversationID: convID,
                userInput: query,
                registry: mainVM,
                origin: .quickAccess
            )
            let agentMessage = activeStreamManager.startMessageStream(
                withConfig: config,
                userMessage: userMessage,
                // Spelled out because a protocol witness carries no default arguments.
                promptOverride: nil,
                files: files,
                updating: nil,
                workflowExecutionState: workflowTicket?.state,
                resumeState: nil,
                onComplete: { [weak self] in
                    DispatchQueue.main.async {
                        // Finalize before the identity guard: a stopped older stream's record must still be frozen,
                        // or it stays `.running` on disk until the next launch reconciles it.
                        workflowTicket?.finalize()
                        guard let self, self.streamingMessageID == thisStreamID else { return }
                        self.streamingMessageID = nil
                        self.streamingConversationID = nil
                    }
                }
            )
            agentMessage.messageSource = .quickAccess // [Q2] attribute panel traffic
            thisStreamID = agentMessage.id
            streamingMessageID = agentMessage.id
            streamingConversationID = convID   // [C1] stop() drains THIS conversation, not the viewed one
            chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
        }
        return .accepted
    }

    /// Stop the in-flight panel stream, and drain any HITL-parked suspension so it returns
    /// immediately rather than waiting indefinitely.
    func stop() {
        guard let id = streamingMessageID else { return }
        activeStreamManager.cancelStream(for: id)
        // Drains the suspension for the conversation the stream belongs to, not the one the panel currently shows,
        // which could force-resolve an unrelated HITL-parked run.
        if let convID = streamingConversationID {
            Task { await ExecutionSuspensionService.shared.cancel(for: convID) }
        }
        streamingMessageID = nil
        streamingConversationID = nil
    }

    // MARK: - HITL (in-panel)

    /// The shared HITL queue (one instance, owned by MainApplicationViewModel). Optional
    /// because the main VM ref is weak.
    var interactionCenter: InteractionCenter? { mainAppViewModel?.interactionCenter }

    /// The single pending interaction for THIS panel's conversation (strict FIFO), or nil.
    /// Reads InteractionCenter.pending, so a view referencing this re-renders when the queue
    /// changes — including when another surface (main window) answers the same request.
    var pendingInteraction: PendingHITL? {
        guard let convID = conversationID, let center = interactionCenter else { return nil }
        return center.current(for: convID)
    }

    // All answers route through MessagingCoordinator's wrappers so panel HITL decisions are audit-logged and share
    // the main window's answer path; they are keyed by operationID with no main-window selection side effects.

    /// Routes a HITL decision to the view model, or logs an error and reports that it went nowhere.
    /// Funnelling every decision here keeps a missing view-model reference from silently dropping a user decision.
    /// Gate cancel has no wrapper and goes through `submitHITLDirect`, which logs it the same way.
    private func submitHITL(_ decision: String,
                            operationID: UUID,
                            detail: String,
                            _ submit: (MainApplicationViewModel) -> Void) {
        guard let vm = mainAppViewModel else {
            logger.error("[HITL] \(decision) for op \(operationID.uuidString.prefix(8)) went NOWHERE — the QuickAccess panel outlived its MainApplicationViewModel. CONSEQUENCE: the user's decision was DISCARDED, the run stays parked forever waiting on an answer that will never arrive, and the banner keeps showing as if it were still actionable. conversationID: \(conversationID?.uuidString.prefix(8) ?? "none")")
            return
        }
        logger.notice("[HITL] \(decision) op \(operationID.uuidString.prefix(8)) from the QuickAccess panel\(detail.isEmpty ? "" : " — " + detail). conversationID: \(conversationID?.uuidString.prefix(8) ?? "none")")
        submit(vm)
    }

    /// Logs and attributes a decision that reaches its service directly (gate cancel, which has no view-model wrapper).
    /// It is still a user decision that must be visible in the log alongside the others.
    private func submitHITLDirect(_ decision: String,
                                  operationID: UUID,
                                  detail: String,
                                  _ submit: @escaping () async -> Void) {
        logger.notice("[HITL] \(decision) op \(operationID.uuidString.prefix(8)) from the QuickAccess panel\(detail.isEmpty ? "" : " — " + detail). conversationID: \(conversationID?.uuidString.prefix(8) ?? "none")")
        Task { await submit() }
    }

    // Why: the executor consults `SessionToolApprovals` first; a grant registered after the resume arrives too late.
    /// Approves a tool confirmation; with `allowForChat`, registers a durable per-conversation grant before resuming.
    func approveTool(_ pending: PendingHITL, allowForChat: Bool) {
        let opID = pending.id
        if allowForChat, case .toolConfirmation(let c) = pending.kind, let convID = conversationID {
            Task { @MainActor in
                await SessionToolApprovals.shared.allow(toolName: c.toolName, risk: c.risk, conversationID: convID)
                self.submitHITL("APPROVED", operationID: opID,
                                detail: "tool \(c.toolName), DURABLE grant for this conversation — subsequent calls to this tool will NOT ask again until the conversation ends") {
                    $0.submitToolApproval(operationID: opID, approved: true)
                }
            }
        } else {
            submitHITL("APPROVED", operationID: opID,
                       detail: "one-shot — the next request for the same tool asks again") {
                $0.submitToolApproval(operationID: opID, approved: true)
            }
        }
    }

    /// Approves a tool confirmation and allows matching calls for the rest of its run, through the same path as the main
    /// window's banner.
    func allowToolForRun(_ pending: PendingHITL, approval: RunApproval) {
        let detail: String = {
            let tool: String = { if case .toolConfirmation(let c) = pending.kind { return c.toolName }; return "?" }()
            if case .exactCall = approval {
                return "tool \(tool), run grant for THIS EXACT CALL — the identical call will not ask again until the run ends"
            }
            return "tool \(tool), run grant for ANY ARGUMENTS — this tool will not ask again until the run ends"
        }()
        submitHITL("APPROVED", operationID: pending.id, detail: detail) {
            $0.allowToolForRun(pending, approval: approval)
        }
    }

    func denyTool(_ pending: PendingHITL) {
        submitHITL("DENIED", operationID: pending.id,
                   detail: "the tool does not run and the agent is told the user refused") {
            $0.submitToolApproval(operationID: pending.id, approved: false)
        }
    }

    func submitClarification(_ pending: PendingHITL, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Logs length only: the answer is free text that re-enters the agent's context.
        submitHITL("Answered clarification", operationID: pending.id,
                   detail: "\(trimmed.count) character(s)\(trimmed.isEmpty ? " (empty — treated as no answer)" : ""); the run resumes with this text in context") {
            $0.submitClarificationResponse(operationID: pending.id, response: trimmed.isEmpty ? nil : trimmed)
        }
    }

    func resolvePlan(_ pending: PendingHITL, approved: Bool) {
        guard case .planReview(let plan) = pending.kind else {
            // Logged because the pending item can be replaced between render and tap, which otherwise looks like a dead button.
            logger.error("[HITL] Plan decision for op \(pending.id.uuidString.prefix(8)) IGNORED — the pending item is no longer a plan review. CONSEQUENCE: the click did nothing and the run stays parked; the request on screen changed underneath the user.")
            return
        }
        submitHITL("Plan \(approved ? "APPROVED" : "REJECTED")", operationID: pending.id,
                   detail: "\(plan.subtasks.count) subtask(s); \(approved ? "the run proceeds with this plan" : "the run is told the plan was rejected")") {
            $0.submitPlanReview(operationID: pending.id, editedPlan: approved ? plan.subtasks : nil)
        }
    }

    func chooseGate(_ pending: PendingHITL, option: String?) {
        // submitGateChoice takes a non-optional option; a nil choice (cancel) has no VM wrapper,
        // so route that straight to the suspension service.
        if let option {
            submitHITL("Gate answered", operationID: pending.id,
                       detail: "option '\(option)' — the workflow continues down that output port") {
                $0.submitGateChoice(operationID: pending.id, option: option)
            }
        } else {
            submitHITLDirect("Gate cancelled", operationID: pending.id,
                             detail: "no option chosen — the Gate is dismissed and none of its branches run") {
                await ExecutionSuspensionService.shared.resumeGate(for: pending.id, chosenOption: nil, resolvedBy: .quickAccess)
            }
        }
    }

    // MARK: - Conversation identity

    private func resolveExistingConversationID() -> UUID? {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: GlobalConstants.quickAccessOverlayConversationId),
              let id = UUID(uuidString: idString),
              persistence.getConversation(withId: id) != nil else {
            return nil
        }
        return id
    }

    /// Returns the current conversation, creating + persisting one on first send.
    private func ensureConversation(titleFrom query: String, profileID: UUID) -> UUID {
        if let existing = conversationID { return existing }
        if let existing = resolveExistingConversationID() {
            conversationID = existing
            return existing
        }
        let newConversation = Conversation(
            id: UUID(),
            timestamp: Date(),
            userDefinedTitle: query,
            backendEntityId: profileID
        )
        persistence.addConversation(from: newConversation)
        UserDefaults.standard.set(newConversation.id.uuidString,
                                  forKey: GlobalConstants.quickAccessOverlayConversationId)
        conversationID = newConversation.id
        return newConversation.id
    }
}
