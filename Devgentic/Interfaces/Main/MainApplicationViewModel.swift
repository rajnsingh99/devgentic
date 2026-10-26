// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MainApplicationViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import SwiftData
import Combine
import os
import AppKit
import AVFoundation


private let logger = DGLogger(category: "MainApplicationViewModel")

@Observable @MainActor
final class MainApplicationViewModel {

    // MARK: - Dependencies

    let backendConfiguration = BackendConfiguration()
    let explorerViewModel = ExplorerViewModel()

    // Dependencies are now injected and stored.
    @ObservationIgnored private(set) var activeStreamManager: ActiveStreamManager
    /// Single source of truth for pending HITL across all interfaces; views read it (it is itself @Observable) and the
    /// stream manager enqueues into it.
    @ObservationIgnored let interactionCenter = InteractionCenter()
    @ObservationIgnored private(set) var persistenceService: ChatPersistenceProtocol
    @ObservationIgnored private let fileProcessorService: FileProcessorService
    @ObservationIgnored private let chatHistoryViewModel: ChatHistoryViewModel

    /// Whether a send/stream is in flight, exposed because `chatHistoryViewModel` is private. Reading it registers
    /// observation, so a view that reads it re-renders when the stream starts and ends.
    var isSendInProgress: Bool { chatHistoryViewModel.isSending }

    // Code mode: builds the ephemeral profile for each send.
    @ObservationIgnored private(set) var codeSessionManager: CodeSessionManager?

    // MARK: - ChatOps
    // Lifecycle and bridge ownership live in `ChatOpsCoordinator`; the properties and methods here are thin forwards for
    // external callers.
    @ObservationIgnored private var chatOpsCoordinator: ChatOpsCoordinator!

    /// Owns the message-sending pipeline (local and remote sends, regeneration, cancellation, HITL resolutions,
    /// `createUserMessage` factory).
    @ObservationIgnored private(set) var messagingCoordinator: MessagingCoordinator!

    /// Owns conversation CRUD (create/select/pin/rename/delete/export + the
    /// conversation↔profile mapping). See `ConversationManagementCoordinator.swift`.
    @ObservationIgnored private(set) var conversationManagementCoordinator: ConversationManagementCoordinator!

    /// Owns load/persist for every UserDefaults-backed setting (streaming
    /// toggle, intelligence core, web search, interface mode). See
    /// `SettingsCoordinator.swift`.
    @ObservationIgnored private(set) var settingsCoordinator: SettingsCoordinator!

    /// Owns scheduled-task + ChatOps-bridge message flows that run outside the
    /// Mac UI's selected conversation. See `SchedulerCoordinator.swift`.
    @ObservationIgnored private(set) var schedulerCoordinator: SchedulerCoordinator!

    /// Owns the "what happens on conversation selection change" pipeline —
    /// observation, debounce, model unload, message load, backend rebind,
    /// workflow history fetch. See `ConversationSwitchCoordinator.swift`.
    @ObservationIgnored private var conversationSwitchCoordinator: ConversationSwitchCoordinator!
    /// Forwards to the Telegram bridge owned by `ChatOpsCoordinator`.
    var chatOpsBridge: ChatOpsBridge? { chatOpsCoordinator.telegramBridge }
    /// Forwards to the Discord bridge owned by `ChatOpsCoordinator`.
    var discordChatOpsBridge: DiscordChatOpsBridge? { chatOpsCoordinator.discordBridge }
    /// Forwards to the Slack bridge owned by `ChatOpsCoordinator`.
    var slackChatOpsBridge: SlackChatOpsBridge? { chatOpsCoordinator.slackBridge }

    // MARK: - Service & Store
    @ObservationIgnored var ollamaService = OllamaService.shared

    // MARK: - State Properties
    var conversations: [Conversation] = []
    var selectedConversationID: UUID?
    var isSidebarCollapsed: Bool = true
    var showContextArea: Bool = false
    var activeContextFilePath: String? = nil
    var attachedFiles: [FileSystemItem] = []
    // Why: computed over UserDefaults so the toggle shows what is used; an absent key reads as true, since
    // `bool(forKey:)` alone would invert the default.
    /// Whether the LLM response streams word by word; persisted in `UserDefaults`.
    var useStreamingResponse: Bool {
        get {
            access(keyPath: \.useStreamingResponse)
            guard UserDefaults.standard.object(forKey: AppSettings.useStreamingResponseKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: AppSettings.useStreamingResponseKey)
        }
        set {
            withMutation(keyPath: \.useStreamingResponse) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.useStreamingResponseKey)
            }
            logger.info("Saved 'useStreamingResponse' setting to UserDefaults: \(newValue)")
        }
    }

    // Intelligence Core

    // Why: computed over UserDefaults so the toggle and the gates share one state; an absent key reads as false, the
    // intended default.
    /// Master switch for the on-device Intelligence Core; persisted in `UserDefaults`, the key every consumer gate reads.
    var isIntelligenceCoreEnabled: Bool {
        get {
            access(keyPath: \.isIntelligenceCoreEnabled)
            return UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
        }
        set {
            withMutation(keyPath: \.isIntelligenceCoreEnabled) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.isIntelligenceCoreEnabledKey)
            }
            logger.info("[IC] Intelligence Core \(newValue ? "ENABLED" : "DISABLED"). CONSEQUENCE: every gate reads this key live — Briefing, User Personal, AgentConnect, BackendOrchestration and the Welcome widgets all follow immediately.")
            // Switching off must release the model; holding an idle MLX model is expensive.
            if !newValue {
                Task { await IntelligenceCoreService.shared.unloadNow(caller: .unknown) }
            }
        }
    }

    /// The run the composer is talking about: what Stop targets, and whether the send button shows Send or Stop. Derived,
    /// never stored. Only the conversation on screen can stop a run; nil while a background scheduled or ChatOps run streams
    /// elsewhere is correct.
    var streamingMessageID: UUID? {
        ForegroundRunResolver.foregroundRun(
            live: activeStreamManager.liveRunSnapshot(),
            selectedConversation: selectedConversationID
        )?.messageID
    }

    // MARK: - Interface Mode (User-Switchable)

    /// The interface mode — user-switchable via the floating mode picker.
    /// Workflow mode renders WorkflowDedicatedView; chat mode renders ChatHistoryView.
    /// Also controls sidebar filtering and backend picker profile types.
    enum InterfaceMode: String, CaseIterable {
        case chat = "Chat"
        case workflow = "Workflow"
        case code = "Code"

        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.text.bubble.right"
            case .workflow: return "point.3.connected.trianglepath.dotted"
            case .code: return "chevron.left.forwardslash.chevron.right"
            }
        }

        /// Profile types visible in the backend picker for this mode.
        var allowedProfileTypes: Set<ProfileType> {
            switch self {
            case .chat: return [.bot, .agent, .imageGen]
            case .workflow: return [.workflow]
            case .code: return [.code]
            }
        }
    }

    /// The active interface mode — persisted to UserDefaults for session continuity.
    var interfaceMode: InterfaceMode = .chat

    /// Resolved profile type — derived from the currently selected profile ID.
    var selectedProfileType: ProfileType? {
        guard let pid = backendConfiguration.selectedProfileID,
              let profile = (try? BackendProfileStore.shared.fetchProfiles())?.first(where: { $0.id == pid })
        else { return nil }
        return profile.profileType
    }

    /// Guards navigation away from a workflow canvas with unsaved edits. The active
    /// `WorkflowCanvasView` registers its dirty-state + save/discard hooks here; the
    /// navigation sites route their transition through `workflowEditGuard.attempt`.
    let workflowEditGuard = WorkflowEditGuard()

    /// Switches to the given interface mode, RESUMING where that mode was left (its conversation —
    /// and in Code its project — or its Home with the profile picked there). Drafts stay per mode.
    /// Routed through `workflowEditGuard` so leaving a dirty workflow canvas prompts Save/Discard/Cancel.
    func switchInterfaceMode(to mode: InterfaceMode) {
        guard mode != interfaceMode else { return }
        workflowEditGuard.attempt { [weak self] in
            self?.performInterfaceSwitch(to: mode)
        }
    }

    /// Navigates to a (possibly different-mode) conversation that has a pending HITL, aligning `interfaceMode` to the
    /// request's origin and routing through `workflowEditGuard` so leaving a dirty workflow canvas still prompts
    /// Save/Discard/Cancel.
    func navigateToPendingInteraction(conversationID: UUID, interface: HITLOrigin.Interface) {
        let targetMode: InterfaceMode = {
            switch interface {
            case .workflow:          return .workflow
            case .code:              return .code
            case .chat, .scheduled:  return .chat
            }
        }()
        workflowEditGuard.attempt { [weak self] in
            guard let self else { return }
            // performInterfaceSwitch nulls selectedConversationID, so set the mode first
            // (only when it actually differs) and select the target afterward.
            if self.interfaceMode != targetMode {
                self.performInterfaceSwitch(to: targetMode, resume: false)
            }
            self.selectedConversationID = conversationID
        }
    }

    /// Where each mode was left — see `ModeResumeMemory`.
    @ObservationIgnored private var modeResume = ModeResumeMemory()
    /// Modes entered at least once this app session (Code's first entry resets; see below).
    @ObservationIgnored private var modesVisited: Set<InterfaceMode> = []

    /// - Parameter resume: land where `mode` was last left. `false` for callers that select
    ///   their own target right after (`navigateToPendingInteraction`) — resuming first would
    ///   select, and start loading, a conversation only to replace it.
    private func performInterfaceSwitch(to mode: InterfaceMode, resume: Bool = true) {
        let leaving = interfaceMode
        modeResume.leave(leaving, at: .init(conversationID: selectedConversationID,
                                            profileID: backendConfiguration.selectedProfileID))
        modesVisited.insert(leaving)
        let firstVisit = !modesVisited.contains(mode)
        modesVisited.insert(mode)

        let spot = resume
            ? modeResume.resume(mode) { [persistenceService] in persistenceService.getConversation(withId: $0) != nil }
            : ModeResumeMemory.Spot()

        interfaceMode = mode
        // Mode and selection change in the same pass so the composer sees one draft-key change; drafts are keyed per mode.
        selectedConversationID = spot.conversationID
        // A resumed conversation brings its own profile (loaded on selection); Home gets back the
        // profile that was picked on it.
        backendConfiguration.selectedProfileID = spot.profileID
        chatHistoryViewModel.currentChatMessages = []
        settingsCoordinator.didChangeInterfaceMode(mode)
        // Code's first entry in a session lands on a clean Home, since the Code profile can still carry the last launch's
        // folder; later entries resume.
        if mode == .code, firstVisit, resume, spot.conversationID == nil {
            codeSessionManager?.resetSession()
        }
        syncExplorerToInterfaceMode()
        logger.info("Switched interface mode \(leaving.rawValue) → \(mode.rawValue) — \(spot.conversationID.map { "resumed conversation \($0.uuidString.prefix(8))" } ?? "Home\(spot.profileID != nil ? " with its profile" : "")")\(firstVisit ? " (first visit this session)" : "").")
    }

    // MARK: - Workflow Execution State
    /// Live workflow execution state keyed by conversation ID.
    var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]

    /// Persistent run history keyed by conversation ID.
    var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]

    /// Live canvas editing state keyed by workflow profile ID (not conversation), so edits survive the Canvas/Execution view
    /// flip and conversation switches. In memory only; the quit path drains it (see `persistDirtyWorkflowCanvases`).
    @ObservationIgnored private var workflowCanvasStates: [UUID: WorkflowCanvasState] = [:]

    // Why: a mirror, never the authority: the quit gate must read `unsavedWorkflowCanvasProfileIDs`, which pulls from
    // live state and cannot miss a push.
    /// Profiles whose cached canvas holds unsaved edits: the observable mirror of that fact, pushed from views.
    private(set) var dirtyWorkflowCanvasIDs: Set<UUID> = []

    /// Pushed by `WorkflowCanvasView` whenever its canvas's dirty flag changes, and on mount.
    func setWorkflowCanvasDirty(_ dirty: Bool, for profileID: UUID) {
        if dirty {
            dirtyWorkflowCanvasIDs.insert(profileID)
        } else {
            dirtyWorkflowCanvasIDs.remove(profileID)
        }
    }

    /// The canvas state for a workflow profile, created on first use and reused thereafter.
    func workflowCanvasState(for profileID: UUID) -> WorkflowCanvasState {
        if let existing = workflowCanvasStates[profileID] { return existing }
        let created = WorkflowCanvasState(profileID: profileID)
        workflowCanvasStates[profileID] = created
        return created
    }

    /// Profiles whose cached canvas holds edits that are not on disk. Not `workflowEditGuard.hasUnsavedChanges`: that guard
    /// mirrors only the canvas currently on screen, while these states outlive the view.
    var unsavedWorkflowCanvasProfileIDs: [UUID] {
        workflowCanvasStates.filter { $0.value.hasUnsavedChanges }.map(\.key)
    }

    /// What a bulk canvas drain did, per profile: `failed` (plausibly transient, worth retrying), `refused` (refused by
    /// design, will refuse identically on retry), and `persisted` (already written, so an on-screen `saveHook` would be a
    /// redundant second write).
    struct CanvasDrainResult {
        /// Profiles whose layout reached disk.
        let persisted: [UUID]
        /// [WF-PE2] Profiles refused BY DESIGN — `.refusedUnreadable`/`.refusedNewerVersion` — with
        /// the outcome carried so a caller can build an accurate, per-reason message. A non-empty
        /// value must NOT be treated the same as `failed`: retrying can never succeed for these.
        let refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)]
        /// Profiles whose layout could NOT be written for a plausibly-transient reason — a non-empty
        /// value must block the exit and invite a retry.
        let failed: [UUID]

        init(persisted: [UUID], refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)] = [], failed: [UUID]) {
            self.persisted = persisted
            self.refused = refused
            self.failed = failed
        }
    }

    /// Writes every dirty cached canvas to disk and returns the profiles it could not persist; store write first, owned-row
    /// reconcile once the bytes are down, `markSaved()` once both succeeded. Exit points must treat a non-empty `failed` as
    /// a refusal to continue.
    @discardableResult
    func persistDirtyWorkflowCanvases(profileService: BackendProfileService) -> CanvasDrainResult {
        let dirty = workflowCanvasStates.filter { $0.value.hasUnsavedChanges }
        guard !dirty.isEmpty else { return CanvasDrainResult(persisted: [], failed: []) }

        var persisted: [UUID] = []
        var refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)] = []
        var failed: [UUID] = []
        for (profileID, state) in dirty {
            // Through the guarded accessor, not `currentLayout()`. The dictionary key and the
            // state's own id agree by construction today, and this is what keeps that true.
            guard let layout = state.layout(forProfile: profileID) else {
                failed.append(profileID)
                continue
            }
            let outcome = WorkflowLayoutStore.shared.save(layout, for: profileID)

            // Refused-by-design is not a failure: it refuses identically on every retry, so it is bucketed apart from `failed`,
            // which stays for plausibly-transient cases that a caller must block on.
            if outcome.isRefusedByDesign {
                refused.append((profileID, outcome))
                logger.notice(
                    "[WF_CANVAS] Exit-time save REFUSED (by design) for workflow \(profileID): \(String(describing: outcome)). "
                    + "CONSEQUENCE: \(layout.nodes.count) node(s) and \(layout.edges.count) edge(s) stay "
                    + "in-memory-only; this will refuse identically on retry, so the caller must offer "
                    + "an explicit choice rather than cancel-and-ask-to-retry."
                )
                continue
            }

            guard outcome.didPersist else {
                failed.append(profileID)
                logger.error(
                    "[WF_CANVAS] Exit-time save FAILED for workflow \(profileID): \(String(describing: outcome)). "
                    + "CONSEQUENCE: \(layout.nodes.count) node(s) and \(layout.edges.count) edge(s) are "
                    + "still only in memory; the caller must cancel the exit rather than discard them."
                )
                continue
            }

            // Same ordering and refusal rule as the canvas's own save: past `outcome.didPersist`, and a state loaded from a failed
            // read cannot be trusted to name every node this workflow has.
            if state.lastLoadDidFail {
                logger.error("[WF_CANVAS] Exit-time owned-row reconcile REFUSED for workflow \(profileID): its canvas was loaded from a failed read. CONSEQUENCE: rows for deleted nodes are left on disk rather than risking deletion of configurations whose nodes still exist.")
            } else {
            profileService.reconcileOwnedProfiles(
                forWorkflow: profileID,
                // Same union as the canvas save — see `undoRecoverableProfileIDs`. A cached state
                // reaching the quit drain can still hold an undo stack.
                referencedProfileIDs: Set(layout.nodes.compactMap(\.profileID))
                    .union(state.undoRecoverableProfileIDs)
            )
            }

            // No profile re-save: this drain has no editor draft to flush and runs over cached states whose views may not be
            // mounted.

            state.markSaved()
            // The drain runs over states whose views may not be mounted, so no `onChange` will fire
            // to clear the mirror — do it here or the tab dot outlives the save.
            dirtyWorkflowCanvasIDs.remove(profileID)
            persisted.append(profileID)
            logger.info(
                "[WF_CANVAS] Exit-time save: workflow \(profileID) persisted "
                + "(\(layout.nodes.count) node(s), \(layout.edges.count) edge(s))."
            )
        }
        return CanvasDrainResult(persisted: persisted, refused: refused, failed: failed)
    }

    // Why: a dirty canvas of a deleted workflow would otherwise be re-inserted at quit as an orphaned
    // `WorkflowLayoutSD` row.
    /// Drops the cached canvas state for a profile that is gone; wired from `BackendProfileService.onProfileDeleted`. Silent
    /// when nothing is cached, which is the ordinary case.
    func discardWorkflowCanvasState(for profileID: UUID) {
        dirtyWorkflowCanvasIDs.remove(profileID)
        guard let state = workflowCanvasStates.removeValue(forKey: profileID) else { return }
        if state.hasUnsavedChanges {
            logger.notice(
                "[WF_CANVAS] Discarded the cached canvas for DELETED workflow \(profileID), which had "
                + "UNSAVED edits. CONSEQUENCE: those edits are gone — which is correct, the user "
                + "deleted the workflow — and the quit-time drain can no longer re-create its layout "
                + "row as an orphan."
            )
        }
    }

    // MARK: - Query History Properties
    private(set) var queryHistory: [String] = []
    @ObservationIgnored private var currentHistoryIndex: Int = -1
    
    enum QueryNavigationDirection {
        case up, down
    }
    
    private let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yy"
        return formatter
    }()

    // MARK: - Computed Properties
    var currentConversationTitle: String {
        guard let selectedID = selectedConversationID,
              let conversationSD = persistenceService.getConversation(withId: selectedID) else {
            return "Devgentic"
        }
        return conversationSD.toRowStruct().displayTitle
    }

    // MARK: - Initialization
    /// - Parameter bootstrapChatOps: whether to start the ChatOps bridges; defaults to true. Tests pass false to construct
    /// deliberately; `ChatOpsCoordinator.bootstrap()` still refuses outright under XCTest, which is what makes construction
    /// safe.
    init(
        persistenceService: ChatPersistenceProtocol = ChatPersistenceStore.shared,
        fileProcessorService: FileProcessorService = FileProcessorService(),
        bootstrapChatOps: Bool = true,
        activeStreamManager: ActiveStreamManager,
        chatHistoryViewModel: ChatHistoryViewModel
    ) {
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.activeStreamManager = activeStreamManager
        self.chatHistoryViewModel = chatHistoryViewModel

        // Hands the shared interaction queue to the stream manager; the view model owns it and the manager holds the
        // back-reference.
        activeStreamManager.interactionCenter = interactionCenter

        // Claims presentation for out-of-band HITL: MCP sampling/elicitation requests arrive with no stream in scope, so they
        // cannot use ActiveStreamManager's injected reference. The main window owns this; QuickAccess does not claim it.
        HITLPresenter.claim(interactionCenter)

        logger.info("MainApplicationViewModel initialized.")

        // Settings load is first so other coordinators see the correct persisted
        // values (e.g. `interfaceMode`, `useStreamingResponse`) during their setup.
        settingsCoordinator = SettingsCoordinator(viewModel: self)
        settingsCoordinator.load()

        // Conversation CRUD lives in its own coordinator (Gap C extraction).
        conversationManagementCoordinator = ConversationManagementCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            persistenceService: persistenceService,
            backendConfiguration: backendConfiguration
        )

        // Selection-change observer. Constructed AFTER `conversationManagementCoordinator`
        // because its debounced task calls into it for the backend rebind.
        conversationSwitchCoordinator = ConversationSwitchCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            persistenceService: persistenceService
        )

        // Messaging pipeline lives in its own coordinator. Constructed before
        // ChatOps so remote bridges can reach it immediately.
        messagingCoordinator = MessagingCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            activeStreamManager: activeStreamManager,
            persistenceService: persistenceService,
            fileProcessorService: fileProcessorService,
            backendConfiguration: backendConfiguration
        )

        // Scheduler / remote-bridge message flow; it takes the static `MessagingCoordinator.makeUserMessage`, so construction
        // order is free.
        schedulerCoordinator = SchedulerCoordinator(
            viewModel: self,
            persistenceService: persistenceService,
            activeStreamManager: activeStreamManager,
            fileProcessorService: fileProcessorService,
            runRegistry: self
        )

        // ChatOps lifecycle lives in its own coordinator, built here (it needs `self` as a back-reference) and bootstrapped
        // with the always-on sync service plus any enabled bridges.
        chatOpsCoordinator = ChatOpsCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            activeStreamManager: activeStreamManager
        )
        if bootstrapChatOps {
            chatOpsCoordinator.bootstrap()
        } else {
            logger.info("[CHATOPS] bootstrap skipped — the caller asked for a view model without ChatOps. CONSEQUENCE: no bridge is started and no remote message can reach this instance; the coordinator exists so start/stop can still be exercised explicitly.")
        }
    }

    // MARK: - Code Session

    // Why: the identity check is a tripwire: binding the wrong instance is silent (the Code system prompt just stops
    // being applied), so a swap after the first bind is logged.
    /// Late-injected by DevgenticApp from `body`, not from `init()`.
    func configureCodeSession(_ manager: CodeSessionManager) {
        if let existing = codeSessionManager, existing !== manager {
            logger.error("[CODE] configureCodeSession REPLACED the bound manager (\(ObjectIdentifier(existing).debugDescription) → \(ObjectIdentifier(manager).debugDescription)). CONSEQUENCE: more than one CodeSessionManager is live, so the instance the views mutate may not be the one the send path reads — which silently drops the Code system prompt. Find the second construction site.")
        }
        self.codeSessionManager = manager
        // The Explorer's folder buttons pick the PROJECT while in Code — see ExplorerViewModel.Scope.
        explorerViewModel.chooseCodeProject = { [weak self] url in self?.chooseCodeFolder(url) }
        syncExplorerToInterfaceMode()
    }

    /// Points the shared Explorer at the folder the current mode owns: the Code session's project (none on Home), or Chat's
    /// own remembered folder in every other mode. Called on every event that can change either side.
    func syncExplorerToInterfaceMode() {
        if interfaceMode == .code {
            explorerViewModel.showCodeProject(codeSessionManager?.projectPath)
        } else {
            explorerViewModel.showChatFolder()
        }
    }

    /// Refreshes the code profile's instructions and sets it as the selected profile for send; called before each send in
    /// Code mode. Returns `false` when the session is not ready, so the caller refuses the send and tells the user.
    @discardableResult
    func prepareCodeProfileForSend() -> Bool {
        guard let csm = codeSessionManager else {
            logger.error("[CODE] prepareCodeProfileForSend: no CodeSessionManager bound. CONSEQUENCE: the send is refused — without it there is no project root and no Code system prompt, so the model would run as a generic assistant over the whole filesystem.")
            return false
        }
        guard csm.isConfigured else {
            logger.error("[CODE] prepareCodeProfileForSend: session not configured (model: '\(csm.modelName.isEmpty ? "none" : csm.modelName)', folder: \(csm.projectPath?.path ?? "none")). CONSEQUENCE: the send is refused. Previously it proceeded without the Code system prompt, leaving the model with no project root.")
            return false
        }
        csm.refreshInstructionsOnProfile()
        backendConfiguration.selectedProfileID = csm.codeProfileID
        logger.info("[CODE] Code profile prepared for send (profile ID: \(csm.codeProfileID?.uuidString ?? "nil"))")
        return true
    }

    // MARK: - ChatOps Lifecycle (forwards to ChatOpsCoordinator)
    // One-line forwards to `ChatOpsCoordinator`, kept on the view model for `ChatOpsSettingsView`.

    func startChatOps()        { chatOpsCoordinator.startTelegram() }
    func stopChatOps()         { chatOpsCoordinator.stopTelegram() }
    func startDiscordChatOps() { chatOpsCoordinator.startDiscord() }
    func stopDiscordChatOps()  { chatOpsCoordinator.stopDiscord() }
    func startSlackChatOps()   { chatOpsCoordinator.startSlack() }
    func stopSlackChatOps()    { chatOpsCoordinator.stopSlack() }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        NotificationCenter.default.removeObserver(self)
        // `conversationSwitchCoordinator` owns the former `conversationLoadTask`
        // and observation stream; they unwind via its own deinit.
    }
    
    // MARK: - Settings (forwards to SettingsCoordinator)
    // Forwards to `SettingsCoordinator`, which owns the load and persist paths, for the SwiftUI settings views.

    // MARK: - Message Sending (forwards to MessagingCoordinator)
    // Forwards to `MessagingCoordinator`; SwiftUI views call this directly through a closure passed down from
    // `MainApplicationView`.

    func sendMessage(attributedString: NSAttributedString, withConfig config: BackendRequestConfig) {
        messagingCoordinator.sendMessage(attributedString: attributedString, withConfig: config)
    }

    // MARK: - Query History Navigation

    /// Appends a query to history without allowing external callers to corrupt
    /// the array. Used by `MessagingCoordinator.sendMessage` (the `private(set)`
    /// on `queryHistory` prevents direct mutation from outside the VM).
    func appendToQueryHistory(_ query: String) {
        queryHistory.append(query)
    }

    func getQueryFromHistory(direction: QueryNavigationDirection) -> String? {
        if queryHistory.isEmpty { return nil }

        if currentHistoryIndex == -1 {
            if direction == .up {
                currentHistoryIndex = queryHistory.count - 1
                return queryHistory[currentHistoryIndex]
            }
            return nil // Can't go down from "new" input state
        }

        if direction == .up {
            if currentHistoryIndex > 0 {
                currentHistoryIndex -= 1
                return queryHistory[currentHistoryIndex]
            }
            return queryHistory[0] // Return the oldest item if already at the top
        } else { // direction == .down
            if currentHistoryIndex < queryHistory.count - 1 {
                currentHistoryIndex += 1
                return queryHistory[currentHistoryIndex]
            } else {
                // Navigated past the most recent query, back to a new input state
                currentHistoryIndex = -1
                return "" // Return empty string to clear the input field
            }
        }
    }

    func resetQueryHistoryIndex() {
        currentHistoryIndex = -1
    }
    
    // MARK: - Response Regeneration / Cancel / HITL / Remote Send
    // Thin forwards to `MessagingCoordinator`, called by SwiftUI views and the three ChatOps bridges.

    /// Why Redo / Retry is unavailable for `message`, or nil if it may run; the single source for the button's disabled
    /// state and the runtime refusal. Reading it from a view body registers on `activeStreams`, so the control re-enables
    /// when the run ends.
    func regenerationRefusal(for message: ChatMessage) -> RunAdmissionPolicy.Refusal? {
        messagingCoordinator.regenerationRefusal(for: message)
    }

    /// Why Resume is unavailable for `message`, or `nil` if it may run. Same rule as
    /// `regenerationRefusal` minus the attempt cap — a resume consumes no generation attempt.
    func resumeRefusal(for message: ChatMessage) -> RunAdmissionPolicy.Refusal? {
        RunAdmissionPolicy.admitResume(
            in: message.conversationId,
            live: activeStreamManager.liveRunSnapshot()
        )
    }

    func regenerateResponse(for agentMessage: ChatMessage) {
        messagingCoordinator.regenerateResponse(for: agentMessage)
    }

    /// [G1 Piece 2] Resume a run that was parked on a HITL when the app last closed.
    func resumeRun(for agentMessage: ChatMessage) {
        messagingCoordinator.resumeRun(for: agentMessage)
    }

    func cancelStreamingResponse() {
        messagingCoordinator.cancelStreamingResponse()
    }

    func submitToolApproval(operationID: UUID, approved: Bool, editedArguments: [String: JSONValue]? = nil) {
        messagingCoordinator.submitToolApproval(operationID: operationID, approved: approved, editedArguments: editedArguments)
    }

    // Why: the grant is registered before any resume, so a call raised the moment this one runs already sees it; queued
    // requests it covers are answered too, or parallel workflow nodes would each still need a click. One path for every
    // banner that offers it.
    /// Approves `pending` and allows matching calls for the rest of its run, in every node.
    func allowToolForRun(_ pending: PendingHITL, approval: RunApproval, editedArguments: [String: JSONValue]? = nil) {
        guard case .toolConfirmation(let confirmation) = pending.kind, let runID = pending.origin.runMessageID else {
            logger.error("[HITL] 'allow for this run' on op \(pending.id.uuidString.prefix(8)), which is not a tool confirmation raised inside a run. CONSEQUENCE: nothing was granted or approved; the banner stays until answered another way.")
            return
        }
        let conversationID = pending.origin.conversationID
        Task { @MainActor in
            await SessionToolApprovals.shared.allowForRun(
                approval, toolName: confirmation.toolName, risk: confirmation.risk,
                conversationID: conversationID, runID: runID)
            let covered = SessionToolApprovals.pendingCovered(
                by: approval, toolName: confirmation.toolName, conversationID: conversationID, runID: runID,
                in: interactionCenter.pending, excluding: pending.id)
            let kind = if case .exactCall = approval { "EXACT CALL" } else { "ANY ARGUMENTS" }
            logger.info("[HITL] '\(confirmation.toolName)' ALLOW-FOR-RUN (\(kind)) by user [op \(pending.id.uuidString.prefix(8)), run \(runID.uuidString.prefix(8))]\(covered.isEmpty ? "" : " — also approving \(covered.count) queued request(s) it covers")")
            submitToolApproval(operationID: pending.id, approved: true, editedArguments: editedArguments)
            for operationID in covered {
                submitToolApproval(operationID: operationID, approved: true)
            }
        }
    }

    func submitClarificationResponse(operationID: UUID, response: String?) {
        messagingCoordinator.submitClarificationResponse(operationID: operationID, response: response)
    }

    func submitPlanReview(operationID: UUID, editedPlan: [SubTask]?) {
        messagingCoordinator.submitPlanReview(operationID: operationID, editedPlan: editedPlan)
    }

    func submitGateChoice(operationID: UUID, option: String) {
        messagingCoordinator.submitGateChoice(operationID: operationID, option: option)
    }

    func submitRemoteMessage(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        messagingCoordinator.submitRemoteMessage(
            prompt: prompt,
            conversationID: conversationID,
            source: source,
            config: config
        )
    }

    // MARK: - Chat History Management (forwards to ConversationManagementCoordinator)
    // Thin forwards to `ConversationManagementCoordinator`, called by SwiftUI views and `MessagingCoordinator`.

    func startNewConversation() {
        conversationManagementCoordinator.startNewConversation()
    }

    func deselectConversationAndShowWelcome() {
        conversationManagementCoordinator.deselectConversationAndShowWelcome()
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        conversationManagementCoordinator.createAndSelectNewConversation()
    }

    // Code projects — bodies in `ConversationManagementCoordinator`.
    func chooseCodeFolder(_ url: URL) { conversationManagementCoordinator.chooseCodeFolder(url) }
    func startNewCodeSession(in url: URL) { conversationManagementCoordinator.startNewCodeSession(in: url) }
    func codeSendRefusal(openFolder: URL?) -> String? {
        conversationManagementCoordinator.codeSendRefusal(openFolder: openFolder)
    }

    /// Persists the backend profile selection on the given conversation; stays on the view model so `MessagingCoordinator`
    /// can reach it through its weak back-reference at send time.
    func updateBackendForCurrentConversation(conversationID: UUID, profileID: UUID?) {
        conversationManagementCoordinator.updateBackendForCurrentConversation(
            conversationID: conversationID,
            profileID: profileID
        )
    }

    func transferSelectedConversationToOverlay() {
        conversationManagementCoordinator.transferSelectedConversationToOverlay()
    }

    func togglePinStatus(for conversationId: UUID) {
        conversationManagementCoordinator.togglePinStatus(for: conversationId)
    }

    func deleteConversation(conversationID: UUID) {
        conversationManagementCoordinator.deleteConversation(conversationID: conversationID)
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        conversationManagementCoordinator.deleteMultipleConversations(ids: ids)
    }

    func renameConversation(conversationID: UUID, newTitle: String) {
        conversationManagementCoordinator.renameConversation(conversationID: conversationID, newTitle: newTitle)
    }

    func exportConversation(conversationID: UUID) {
        conversationManagementCoordinator.exportConversation(conversationID: conversationID)
    }

    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleContextArea() { withAnimation { showContextArea.toggle() } }
    
    func groupKey(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return self.groupDateFormatter.string(from: date)
    }
    
    @MainActor
    func addAttachedFile(fileItem: FileSystemItem) {
        if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
            attachedFiles.append(fileItem)
        }
    }

    @MainActor
    func addAttachedFiles(fileItems: [FileSystemItem]) {
        for fileItem in fileItems {
            if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
                attachedFiles.append(fileItem)
            }
        }
    }

    @MainActor
    func removeAttachedFile(fileItem: FileSystemItem) {
        attachedFiles.removeAll { $0.id == fileItem.id }
    }
    
    @MainActor
    func removeAttachedFile(byId fileId: URL) {
        attachedFiles.removeAll { $0.id == fileId }
    }

    @MainActor
    func clearAttachedFiles() {
        if !attachedFiles.isEmpty {
            attachedFiles.removeAll()
        }
    }
    
    // MARK: - Scheduler Support (forwards to SchedulerCoordinator)
    // Forwards to `SchedulerCoordinator`, called by `SchedulerService` and the three ChatOps bridges.

    @discardableResult
    func createConversationForScheduledTask(profileID: BackendProfileModel, title: String) -> UUID {
        schedulerCoordinator.createConversationForScheduledTask(profileID: profileID, title: title)
    }

    func sendScheduledMessage(
        prompt: String,
        config: BackendRequestConfig,
        conversationID: UUID,
        attachedFileURLs: [URL]
    ) async -> String {
        await schedulerCoordinator.sendScheduledMessage(
            prompt: prompt,
            config: config,
            conversationID: conversationID,
            attachedFileURLs: attachedFileURLs
        )
    }

    func runScheduledMessage(
        prompt: String,
        config: BackendRequestConfig,
        conversationID: UUID,
        attachedFileURLs: [URL],
        runLimit: TimeInterval? = nil
    ) async -> SchedulerCoordinator.ScheduledRunResult {
        await schedulerCoordinator.runScheduledMessage(
            prompt: prompt,
            config: config,
            conversationID: conversationID,
            attachedFileURLs: attachedFileURLs,
            runLimit: runLimit
        )
    }
}

// MARK: - ChatInputMainDelegate Conformance

extension MainApplicationViewModel: ChatInputMainDelegate { }

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
