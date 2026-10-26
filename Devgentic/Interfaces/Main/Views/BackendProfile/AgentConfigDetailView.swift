// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import UniformTypeIdentifiers

private let logger = DGLogger(category: "AgentConfigDetail")

// MARK: - Localized Titles

/// Presentation helpers for `ModelCognitiveCapability` in the agent configuration screen.
extension ModelCognitiveCapability {
    /// User-facing name, kept separate from `rawValue` so labels reach the String Catalog extractor; `rawValue` is for
    /// persistence and logging only. Declared here so the model layer keeps its `Foundation`-only imports.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .none:            return "None"
        case .singleAction:    return "Single Action"
        case .parallelActions: return "Parallel Actions"
        }
    }
}

struct AgentConfigDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    /// When non-nil, the leading button becomes a cancel (xmark) that invokes this closure, typically `dismiss()` from a
    /// modal host. Also hides the trash icon, since modal editors do not allow profile deletion.
    var onCancel: (() -> Void)? = nil
    /// When true, renders without DynamicIslandBar, outer ScrollView, and navigation guards
    /// for embedding directly within composite containers like ProfileNodeInspectorView.
    var isEmbedded: Bool = false
    @Environment(BackendProfileService.self) var profileService
    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle

    // Shared advanced config manager (replaces 5 @State config vars + isLoading flag)
    @State private var configManager = ProviderAdvancedConfigManager()

    // Owns this view's floating prompt editor — per-instance, not a singleton,
    // so opening the editor here doesn't trample any other view's editor.
    @State private var promptWindowManager = AdvancedPromptWindowManager()

    // Tool Library (now navigated via router)

    // Prompt Library for the inline editor
    @State private var promptLibraryVM = PromptEditViewModel()

    // Deletion State
    @State private var showingDeleteAlert = false

    // Unsaved-changes guard on back navigation.
    @State private var showingBackAlert = false

    /// Advisory findings from the last save, shown until dismissed or the next save. Cleared on every save so it always
    /// describes the current profile state.
    @State private var saveAdvisories: [ProfileValidationError] = []

    // File Importer State
    @State private var showingKnowledgeImporter = false
    /// Why the last "Add File" did nothing, shown inline; nil when there is nothing to report.
    @State private var knowledgeImportError: String?

    // Guide
    @State private var showingAgentGuide = false

    /// Inline validation error for the System Instructions field: set when Save is attempted with an empty field, cleared
    /// when editing resumes.
    @State private var instructionsError: String? = nil


    // [PHASE 1 REFACTOR]: Enriched Default Persona
    private let defaultSystemPersona = """
    You are Devgentic, a specialized macOS System Agent and Senior DevOps Engineer.

    ## CORE BEHAVIORS
    1. **Prudence**: Always verify file existence before modification. Use `ls` or `stat` first.
    2. **Unix Philosophy**: Prefer chaining small, standard tools (grep, sed, awk) over complex, fragile scripts.
    3. **Transparency**: Explain your plan briefly before executing destructive actions.

    ## SAFETY PROTOCOLS
    1. **NON-INTERACTIVE ONLY**: You operate in a non-interactive shell. Do NOT use interactive commands like `nano`, `vim`, `top`, or `sudo` without `-n`.
    2. **DESTRUCTIVE ACTIONS**: Double-check absolute paths before executing `rm -rf` or file deletions.

    ## ERROR HANDLING
    - If a command fails, do NOT immediately retry the exact same command.
    - Analyze the error code/message.
    - Formulate a hypothesis (e.g., "Missing permissions", "Path incorrect").
    - Try a corrective action (e.g., "Check permissions", "Find correct path").
    """

    // MARK: - Convenience Accessors

    private var profile: Binding<BackendProfileModel> {
        $editBuffer.draft
    }

    // MARK: - Computed Bindings

    private var providerConfig: Binding<ProviderConfig> {
        // Captures the buffer, not `self`: capturing `editBuffer` through `self` copies the view's `@State` window manager
        // and closes a retain cycle with long-lived windows.
        let buffer = editBuffer
        return Binding<ProviderConfig>(
            get: {
                switch buffer.draft.details {
                case .bot(let config): return config.llmConfig
                case .agent(let config): return config.llmConfig
                case .code(let config): return config.llmConfig
                case .imageGen(let config): return config.llmConfig
                case .workflow: return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                if case .agent(var config) = buffer.draft.details {
                    config.llmConfig = newConfig
                    buffer.draft.details = .agent(config)
                } else if case .code(var config) = buffer.draft.details {
                    config.llmConfig = newConfig
                    buffer.draft.details = .code(config)
                }
            }
        )
    }

    private var capabilitiesBinding: Binding<AgentCapabilities> {
        let buffer = editBuffer
        return Binding<AgentCapabilities>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.capabilities }
                return AgentCapabilities()
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.capabilities = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    /// The profile's legacy single retry knob — what `Auto` in Error Recovery / Loop Safety
    /// actually resolves to (register A70). Read-only: there is no UI for it, but its value is what
    /// those "Auto (N)" labels must state.
    private var legacyRetryPolicy: RetryPolicy? {
        if case .agent(let config) = editBuffer.draft.details { return config.retryPolicy }
        return nil
    }

    private var maxIterationsBinding: Binding<Int?> {
        let buffer = editBuffer
        return Binding<Int?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.maxIterations }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.maxIterations = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var executionTimeoutBinding: Binding<TimeInterval?> {
        let buffer = editBuffer
        return Binding<TimeInterval?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.executionTimeout }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.executionTimeout = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var resilienceOverridesBinding: Binding<ResilienceOverrides?> {
        let buffer = editBuffer
        return Binding<ResilienceOverrides?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.resilienceOverrides }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.resilienceOverrides = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var errorRecoveryBinding: Binding<ErrorRecovery?> {
        let buffer = editBuffer
        return Binding<ErrorRecovery?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.errorRecovery }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.errorRecovery = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var historyStrategyBinding: Binding<HistoryStrategy> {
        let buffer = editBuffer
        return Binding<HistoryStrategy>(
            get: {
                if case .agent(let config) = buffer.draft.details {
                    return config.historyStrategy ?? .recentHistory
                }
                return .recentHistory
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.historyStrategy = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        let buffer = editBuffer
        return Binding<String>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.instructions ?? "" }
                return ""
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.instructions = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        let buffer = editBuffer
        return Binding<[KnowledgeSource]>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.knowledgeSources ?? [] }
                return []
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.knowledgeSources = newValue.isEmpty ? nil : newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var toolsBinding: Binding<[Tool]> {
        let buffer = editBuffer
        return Binding<[Tool]>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.tools }
                return []
            },
            set: { newTools in
                if case .agent(var config) = buffer.draft.details {
                    config.tools = newTools
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    // MARK: - Body
    var body: some View {
        Group {
            if isEmbedded {
                embeddedContent
            } else {
                standaloneContent
            }
        }
        .task {
            // Instructions are not auto-populated: the user types their own or taps "Use Default Persona", so small models do
            // not run with zero guidance by accident.
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .agent)

            // Gives the service a way to commit the floating editor on ⌘Q. Captures the manager, never the view struct;
            // `commitChanges` is nil while no window is open, so the hook is a safe no-op.
            profileService.commitPendingPromptEdits = { [weak promptWindowManager] in
                promptWindowManager?.commitChanges?()
            }
        }
        .onDisappear {
            // Cleanup: Close the floating window if the user leaves the panel entirely
            // Committing close: navigating away must not destroy unsaved editor text.
            promptWindowManager.closeWindowCommittingChanges()
            profileService.commitPendingPromptEdits = nil
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .agent)
        }
        .advancedConfigSync(configManager: configManager, providerConfig: providerConfig, profileService: profileService)
    }

    private var embeddedContent: some View {
        VStack(spacing: 20) {
            formSections
        }
    }

    private var standaloneContent: some View {
        VStack(spacing: 0) {
            // When `onCancel` is set (workflow modal), the leading button is an xmark that dismisses the sheet; otherwise it
            // keeps the chevron and `handleBackTap`.
            DynamicIslandBar(
                title: editBuffer.draft.displayName,
                icon: "cpu",
                onBack: handleBackTap,
                leadingSymbol: onCancel != nil ? "xmark" : "chevron.left"
            ) {
                actionButtons
            }

            // Outside the ScrollView, directly under the pinned island bar that holds Save, so the advisory reaches the user
            // regardless of scroll position.
            SaveAdvisoryBanner(advisories: saveAdvisories) {
                withAnimation { saveAdvisories = [] }
            }
            .padding(.horizontal, ViewLayout.containerPadding)
            .padding(.top, 8)
            .frame(maxWidth: ViewLayout.maxContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)

            ScrollView {
                VStack(spacing: 32) {
                    formSections
                }
                .padding(ViewLayout.containerPadding)
                .padding(.bottom, ViewLayout.containerPadding)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Delete '\(editBuffer.draft.displayName)'?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                do {
                    try profileService.deleteProfile(withId: editBuffer.draft.id)
                    // Without this the container re-evaluates, finds no edit buffer and shows "Profile Not Found" after a confirmed
                    // deletion.
                    router.returnToChat()
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The deletion message names the real consequences and is shared by all four delete entry points.
            Text(ProfileReferenceIndex.deletionMessage(
                for: editBuffer.draft, in: profileService.profiles))
        }
        // An Ollama preset is not applied automatically on a model change, which would wipe user customization; "Apply
        // Optimal" in Advanced Configuration is opt-in.
        .unsavedChangesBackGuard(
            isDirty: editBuffer.isDirty,
            showingAlert: $showingBackAlert,
            onDiscard: { editBuffer.revert() },
            onLeave: { leaveEditor() }
        )
    }

    @ViewBuilder
    private var formSections: some View {
        // 1. Identity Header
        if !isEmbedded {
            identitySection
        }

        // 2. Inference Engine (Provider)
        inferenceEngineSection

        // 3. Agent Capabilities (composable toggles + tools)
        capabilitiesSection

        // 4. System Instructions & Identity
        instructionsSection

        // 5. Skills
        skillsSection

        // 6. Knowledge
        knowledgeSection

        // 7. Execution
        executionSection

        // 8. Advanced Configuration
        advancedConfigSection

        // Profile applicability note
        if !isEmbedded {
            applicabilityNote
        }
    }

    private var identitySection: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [theme.accentColor.opacity(0.22), theme.accentColor.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(theme.accentColor.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: theme.accentColor.opacity(0.2), radius: 8)

                AgentRobotIcon(size: 28, color: theme.accentColor, isFilled: true)
            }

            VStack(alignment: .leading) {
                TextField("", text: profile.displayName, prompt: Text("Agent Name").foregroundColor(theme.placeholderText))
                    .font(theme.fontTitle2)
                    .fontWeight(.bold)
                    .textFieldStyle(.plain)
                    .foregroundColor(theme.primaryText)

                Text("Define your agent's personality, logic, and tools.")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()

            Button(action: { showingAgentGuide = true }) {
                Image(systemName: "questionmark.circle")
                    .font(theme.fontTitle3)
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Agent configuration guide")
            .accessibilityLabel("Agent configuration guide")
        }
        .padding(.bottom, 8)
        .sheet(isPresented: $showingAgentGuide) {
            AgentConfigGuideView()
        }
    }

    private var inferenceEngineSection: some View {
        SettingsCard(title: "Inference Engine", icon: "cpu", theme: theme) {
            ProviderConfigSection(
                providerConfig: providerConfig,
                profileID: editBuffer.draft.id,
                profileType: .agent,
                onProviderChanged: { _, newProvider in
                    providerConfig.wrappedValue.cognitiveCapability =
                        ProfileCapabilityFilter.defaultCognitiveCapability(for: .agent, provider: newProvider)
                }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var capabilitiesSection: some View {
        SettingsCard(title: "Capabilities", icon: "brain.head.profile", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                AgentCapabilitiesSection(capabilities: capabilitiesBinding)

                Divider()

                // Tools
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        HStack(spacing: 10) {
                            Image(systemName: "hammer.fill")
                                .font(theme.fontBody)
                                .foregroundColor(theme.secondaryText)
                                .frame(width: 24, alignment: .center)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tools")
                                    .font(theme.fontFootnote.weight(.semibold))
                                    .foregroundColor(theme.primaryText)
                                let count = toolsBinding.wrappedValue.filter { $0.isEnabled }.count
                                Text(count == 0 ? "No tools enabled" : "\(count) tool(s) active")
                                    .font(theme.fontCaption2)
                                    .foregroundColor(theme.secondaryText)
                            }
                        }

                        Spacer(minLength: 16)

                        GlassActionButton(title: "Manage Library", icon: "arrow.up.forward.app") {
                            router.navigate(to: .toolLibrary(profileID: editBuffer.draft.id))
                        }
                    }

                    if !toolsBinding.wrappedValue.filter({ $0.isEnabled }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(toolsBinding.wrappedValue.filter { $0.isEnabled }) { tool in
                                    let isContrast = buttonAccentStyle == .themeContrast
                                    HStack(spacing: 4) {
                                        Image(systemName: "wrench.fill")
                                            .font(theme.fontCaption2)
                                        Text(tool.name)
                                            .font(theme.fontCaption)
                                            .fontWeight(.medium)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(isContrast ? theme.surfaceOverlayStrong : theme.accentColor.opacity(0.1))
                                    .foregroundColor(isContrast ? theme.primaryText : theme.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isContrast ? theme.dividerColor.opacity(0.35) : theme.accentColor.opacity(0.2), lineWidth: 1)
                                    )
                                }
                            }
                        }
                        .padding(.leading, 34)
                    } else {
                        Text("Enable tools to give your agent agency.")
                            .font(theme.fontCaption)
                            .italic()
                            .foregroundColor(theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var instructionsSection: some View {
        SettingsCard(title: "System Instructions", icon: "text.quote", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                // Instructions Editor
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer()

                        TactileButton(
                            title: "Expand",
                            icon: "arrow.up.left.and.arrow.down.right",
                            variant: .secondary,
                            size: .compact
                        ) {
                            promptWindowManager.showEditor(
                                text: instructionsBinding,
                                agentName: $editBuffer.draft.displayName,
                                configuredTools: toolsBinding,
                                themeManager: themeManager,
                                contextWindow: providerConfig.wrappedValue.modelMetadata?.contextWindow
                            )
                        }

                        TactileButton(
                            title: "Default Persona",
                            icon: "sparkles",
                            variant: .secondary,
                            size: .compact
                        ) {
                            instructionsBinding.wrappedValue = defaultSystemPersona
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        TokenizingTextEditor(
                            text: instructionsBinding,
                            configuredTools: toolsBinding,
                            theme: theme,
                            promptLibraryVM: promptLibraryVM
                        )
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(theme.textBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(instructionsError != nil ? theme.errorColor : theme.dividerColor,
                                        lineWidth: instructionsError != nil ? 1.5 : 1)
                        )
                        .onChange(of: instructionsBinding.wrappedValue) { _, _ in
                            // Clear the validation error as soon as the user starts editing.
                            instructionsError = nil
                        }

                        if instructionsBinding.wrappedValue.isEmpty {
                            Text("Define persona, reasoning strategy, and tool guidelines...")
                                .font(theme.fontCode)
                                .foregroundColor(theme.placeholderText)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                    let instrCount = instructionsBinding.wrappedValue.count
                    let instrLimit = ProfileValidationLimits.maxInstructionsLength
                    Text("\(instrCount) characters · ~\(instrCount / 4) tokens")
                        .font(theme.fontCaption2)
                        .foregroundColor(
                            instrCount > instrLimit ? .red :
                            instrCount > Int(Double(instrLimit) * 0.9) ? .orange :
                            theme.secondaryText
                        )

                    // Inline validation error — same visual pattern as
                    // CreateScheduledTaskView's `inlineError(_:)` helper.
                    if let message = instructionsError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .accessibilityHidden(true)
                            Text(message)
                                .font(theme.fontCaption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(theme.errorColor)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    /// The skills summary and link to the library. Skills live in a global library and a profile stores a reference, so
    /// linking happens there rather than here.
    private var skillsSection: some View {
        SettingsCard(title: "Skills", icon: "puzzlepiece", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                // Header row
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Agent Skills")
                                .font(theme.fontFootnote.weight(.semibold))
                                .foregroundColor(theme.primaryText)

                            if !linkedSelections.isEmpty {
                                let enabledCount = linkedSelections.filter(\.isEnabled).count
                                let isContrast = buttonAccentStyle == .themeContrast
                                Text("\(enabledCount) active")
                                    .font(theme.fontCodeCaption.weight(.medium))
                                    .foregroundStyle(isContrast ? theme.primaryText : theme.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isContrast ? theme.surfaceOverlayStrong : theme.accentColor.opacity(0.12), in: Capsule())
                            }
                        }

                        Text(linkedSkillsSummary)
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    GlassActionButton(title: "Manage Skills", icon: "arrow.up.forward.app", isAccent: false) {
                        router.navigate(to: .skillLibrary(profileID: editBuffer.draft.id))
                    }
                }

                if linkedSelections.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "puzzlepiece")
                            .font(theme.fontBody)
                            .foregroundColor(theme.secondaryText.opacity(0.6))
                            .frame(width: 28, height: 28)
                            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("No skills linked yet")
                                .font(theme.fontCaption.weight(.medium))
                                .foregroundColor(theme.primaryText)
                            Text("Link skills from the library to teach this agent reusable workflows and capabilities.")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(theme.secondaryBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.dividerColor.opacity(0.2), lineWidth: 1)
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(linkedSelections) { selection in
                            SkillSelectionRow(
                                selection: selection,
                                theme: theme,
                                onOpenDetail: {
                                    router.navigate(to: .skillDetail(skillID: selection.skillID))
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var linkedSelections: [SkillSelection] {
        guard case .agent(let config) = editBuffer.draft.details else { return [] }
        return config.skillSelections ?? []
    }

    private var linkedSkillsSummary: String {
        let enabled = linkedSelections.filter(\.isEnabled).count
        guard !linkedSelections.isEmpty else {
            return "No skills linked. Skills are sets of instructions this agent loads on demand when a task matches one of them."
        }
        let pinned = linkedSelections.filter { $0.pinnedVersionID != nil }.count
        var summary = "\(enabled) skill\(enabled == 1 ? "" : "s") enabled of \(linkedSelections.count) linked."
        if pinned > 0 {
            summary += " \(pinned) pinned to a specific version, so an update to those skills will not reach this agent."
        }
        return summary
    }

    private var knowledgeSection: some View {
        SettingsCard(title: "Knowledge", icon: "book.closed.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {

                // Reference Documents
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reference Documents")
                                .font(theme.fontSubheadline.weight(.semibold))
                            Text("Add external documents the agent can use as context")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                        }

                        Spacer(minLength: 16)

                        GlassActionButton(title: "Add File", icon: "plus") {
                            showingKnowledgeImporter = true
                        }
                        .fileImporter(
                            isPresented: $showingKnowledgeImporter,
                            allowedContentTypes: [.item],
                            allowsMultipleSelection: true
                        ) { result in
                            knowledgeImportError = KnowledgeSourceImport.apply(
                                result, to: knowledgeSourcesBinding, profileKind: "agent")
                        }
                    }

                    // The reason "Add File" appeared to do nothing (register A60). Cleared as soon as the
                    // next import succeeds or is cancelled, so it never lingers past the attempt it describes.
                    if let knowledgeImportError {
                        Label(knowledgeImportError, systemImage: "exclamationmark.triangle")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !knowledgeSourcesBinding.wrappedValue.isEmpty {
                        // Rows + per-source "will be cut" warnings, from the backend's own plan.
                        KnowledgeSourceList(sources: knowledgeSourcesBinding, profile: editBuffer.draft, theme: theme)
                            .padding(.leading, 12)
                    } else {
                        Text("No reference documents added.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .italic()
                            .padding(.leading, 12)
                    }
                }

                Divider()

                // File Handling Strategy
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File Handling")
                            .font(theme.fontSubheadline.weight(.semibold))
                        Text("How attached files and knowledge sources are delivered to the model")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }

                    FileContextStrategyPicker(
                        strategy: $editBuffer.draft.fileContextStrategy,
                        profileType: .agent
                    )
                    .padding(.leading, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var executionSection: some View {
        SettingsCard(title: "Execution", icon: "bolt.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {

                // Limits
                VStack(alignment: .leading, spacing: 12) {
                    Text("Limits")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    ExecutionLimitsSection(
                        maxIterations: maxIterationsBinding,
                        executionTimeout: executionTimeoutBinding
                    )
                    .padding(.leading, 12)
                }

                Divider()

                // Error Recovery
                VStack(alignment: .leading, spacing: 12) {
                    Text("Error Recovery")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    ErrorRecoverySection(
                        resilienceOverrides: resilienceOverridesBinding,
                        errorRecovery: errorRecoveryBinding,
                        legacyRetryPolicy: legacyRetryPolicy
                    )
                    .padding(.leading, 12)
                }

                Divider()

                // Loop Safety circuit-breaker caps (repetition, clarification, idle, denial); a sibling group to Error Recovery that
                // applies in chat and when a workflow node executes this agent.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Loop Safety")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    LoopSafetySection(
                        resilienceOverrides: resilienceOverridesBinding,
                        legacyRetryPolicy: legacyRetryPolicy
                    )
                    .padding(.leading, 12)
                }

                Divider()

                // Conversation Memory
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conversation Memory")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                        .padding(.bottom, 2)

                    VStack(spacing: 8) {
                        ForEach(HistoryStrategy.allCases) { strategy in
                            let isSelected = historyStrategyBinding.wrappedValue == strategy

                            Button {
                                historyStrategyBinding.wrappedValue = strategy
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: strategy.icon)
                                        .font(theme.fontBody)
                                        .foregroundColor(isSelected ? .accentColor : theme.secondaryText)
                                        .frame(width: 22, alignment: .center)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(strategy.localizedTitle)
                                            .font(theme.fontFootnote.weight(.semibold))
                                            .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                                        Text(strategy.localizedDescription)
                                            .font(theme.fontCaption2)
                                            .foregroundColor(theme.tertiaryText)
                                            .lineSpacing(2.5)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer(minLength: 8)

                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .accentColor : theme.surfaceOverlayStrong)
                                        .font(theme.fontTitle3)
                                        .padding(.top, 2)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isSelected ? Color.accentColor.opacity(0.3) : theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var advancedConfigSection: some View {
        SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                advancedSettingsView
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var applicabilityNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(theme.fontCaption2)
            Text("This profile's settings apply when running standalone or as a node in a workflow.")
                .font(theme.fontCaption2)
        }
        .foregroundColor(theme.tertiaryText)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
    }

    // Why: flush in the tap action, not in the `isDirty:` value, which is computed during a view update; the floating prompt
    // editor otherwise looks clean while holding unwritten typing.
    /// Handles the back tap: flushes pending editor text before the dirty check, then leaves via `leaveEditor()`.
    private func handleBackTap() {
        profileService.flushPendingEditorText()
        if editBuffer.isDirty {
            showingBackAlert = true
        } else {
            leaveEditor()
        }
    }

    /// The single way out of this editor: checks `editBuffer.isDirty` for both hosts, and only the exit differs (dismiss
    /// the sheet or pop the router).
    private func leaveEditor() {
        if let onCancel {
            onCancel()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
        }
    }

    /// The model tier for the currently selected provider/model — used for skill warnings.
    private var currentModelTier: ModelTier? {
        if case .agent(let config) = editBuffer.draft.details {
            return config.llmConfig.cognitiveProfile.metadata?.tier
        }
        return nil
    }

    // MARK: - Subviews & Helpers

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if editBuffer.isDirty {
                IslandPillButton(
                    title: "Revert",
                    style: .secondary,
                    // No `.cancelAction`: Revert is destructive and discards edits without a prompt, so binding it to Esc would give a
                    // dirty editor a silent exit; Esc means close, governed by the unsaved-changes guard.
                    accessibilityLabel: "Revert unsaved changes"
                ) {
                    editBuffer.revert()
                    // The draft the advisory described has been discarded.
                    saveAdvisories = []
                    configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .agent)
                }

                IslandPillButton(
                    title: "Save",
                    style: .primary,
                    help: "Save profile changes (⌘S)",
                    accessibilityLabel: "Save profile changes",
                    keyboardShortcut: KeyboardShortcut("s", modifiers: .command)
                ) {
                    // Pre-flight: empty system instructions on a small model cause looping, so the save is blocked with an inline error.
                    // The rule and wording come from `ProfileValidator`.
                    if ProfileValidator.instructionsAreMissing(instructionsBinding.wrappedValue) {
                        instructionsError = ProfileValidator.missingInstructionsMessage
                        // The save is refused here, so a banner from an earlier save does not describe the profile state.
                        saveAdvisories = []
                        return
                    }
                    instructionsError = nil

                    do {
                        // Advisories are returned for display; the save succeeded either way, so the banner explains what may not work
                        // rather than reporting a failure.
                        saveAdvisories = try profileService.saveProfile(editBuffer.draft)
                        editBuffer.markSaved()
                        toastManager.show("Profile saved", style: .success)
                    } catch {
                        // Logged with profile id, type and error: the toast disappears in seconds, so this is the only durable record of a
                        // failed save.
                        logger.error(
                            "[PROFILE] Save FAILED for '\(editBuffer.draft.displayName)' "
                            + "(\(editBuffer.draft.id), agent): \(error.localizedDescription). "
                            + "CONSEQUENCE: the edit buffer stays dirty and the persisted profile is "
                            + "unchanged; the user's edits are still on screen but not on disk."
                        )
                        // Cleared on failure too: an advisory describes a profile that was saved, so it must not stay beside an error toast.
                        saveAdvisories = []
                        toastManager.show(error.localizedDescription, style: .error)
                    }
                }
            }

            // Trash is hidden in modal-cancel mode: workflow editing does not permit profile deletion, which would orphan
            // referencing nodes.
            if onCancel == nil {
                IslandIconButton(
                    symbol: "trash",
                    style: .destructive,
                    help: "Delete profile",
                    accessibilityLabel: "Delete this profile"
                ) {
                    showingDeleteAlert = true
                }
            }
        }
    }


    @ViewBuilder
    private var advancedSettingsView: some View {
        ProviderAdvancedSettingsView(
            configManager: configManager,
            provider: providerConfig.wrappedValue.apiProvider,
            thinkingEnabled: Binding(
                get: { providerConfig.wrappedValue.thinkingEnabled },
                set: { providerConfig.wrappedValue.thinkingEnabled = $0 }
            ),
            modelMetadata: providerConfig.wrappedValue.modelMetadata,
            modelName: providerConfig.wrappedValue.modelName,
            defaultProfile: .agent
        )
    }
}

// MARK: - SkillSelectionRow

private struct SkillSelectionRow: View {
    let selection: SkillSelection
    let theme: any Theme
    let onOpenDetail: () -> Void

    @State private var isHovered = false
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle

    var body: some View {
        Button(action: onOpenDetail) {
            HStack(spacing: 12) {
                // 32x32 rounded icon badge
                let isContrast = buttonAccentStyle == .themeContrast
                let activeColor = isContrast ? theme.primaryText : theme.accentColor
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((selection.isEnabled ? activeColor : theme.secondaryText).opacity(selection.isEnabled ? (isContrast ? 0.12 : 0.15) : 0.08))
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection.isEnabled ? activeColor : theme.secondaryText)
                }
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((selection.isEnabled ? activeColor : theme.dividerColor).opacity(selection.isEnabled ? 0.35 : 0.2), lineWidth: 0.5)
                )

                // Skill info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(selection.name)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundStyle(selection.isEnabled ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)

                        if selection.pinnedVersionID != nil {
                            HStack(spacing: 3) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                Text("Pinned")
                                    .font(theme.fontCodeCaption)
                            }
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.secondaryBackground, in: Capsule())
                            .overlay(Capsule().stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5))
                        }
                    }

                    if let versionID = selection.pinnedVersionID {
                        Text("Pinned to version \(versionID)")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("Follows latest version")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Spacer(minLength: 8)

                // Trailing indicators & arrow
                HStack(spacing: 8) {
                    if !selection.isEnabled {
                        Text("Disabled")
                            .font(theme.fontCodeCaption.weight(.medium))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.secondaryText.opacity(0.12), in: Capsule())
                            .overlay(
                                Capsule().stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.5)
                            )
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovered ? theme.accentColor : theme.secondaryText.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.secondaryBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.35),
                        lineWidth: isHovered ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(selection.name)\(selection.isEnabled ? "" : ", Disabled")\(selection.pinnedVersionID != nil ? ", Pinned" : "")")
        .accessibilityHint(selection.skillID != nil ? "Open skill details" : "Open skill library")
        .help(selection.skillID != nil ? "View details for '\(selection.name)'" : "Manage skills in library")
    }
}

