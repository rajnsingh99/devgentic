// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BotConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import UniformTypeIdentifiers

private let logger = DGLogger(category: "BotConfigDetail")

private let defaultBotPersona = """
You are a helpful, knowledgeable assistant.

## CORE BEHAVIORS
1. **Clarity**: Provide clear, well-structured responses.
2. **Accuracy**: Prioritize correctness. If uncertain, say so.
3. **Conciseness**: Be thorough but avoid unnecessary verbosity.
"""

/// The configuration screen for a bot profile: model and provider settings, system instructions, knowledge, and
/// save/revert/delete.
struct BotConfigDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    /// When non-nil, the dynamic-island leading button becomes a cancel (xmark)
    /// that invokes this closure (typically `dismiss()` from a modal host like
    /// `WorkflowProfileEditorView`). Also hides the trash icon.
    var onCancel: (() -> Void)? = nil
    /// When true, renders without DynamicIslandBar, outer ScrollView, and navigation guards
    /// for embedding directly within composite containers like ProfileNodeInspectorView.
    var isEmbedded: Bool = false
    @Environment(BackendProfileService.self) var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(MainViewRouter.self) private var router
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    // Shared advanced config manager (replaces 5 @State config vars + isLoading flag)
    @State private var configManager = ProviderAdvancedConfigManager()

    // Owns this view's floating prompt editor — per-instance, not a singleton.
    @State private var promptWindowManager = SimplePromptWindowManager()

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

    /// Inline validation error for the System Instructions field: set when Save is attempted with an empty field, cleared
    /// when editing resumes.
    @State private var instructionsError: String? = nil


    // MARK: - Convenience Accessors

    /// Shorthand for the draft being edited.
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
                switch buffer.draft.details {
                case .bot(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .bot(config)
                case .agent(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .agent(config)
                case .code(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .code(config)
                case .imageGen(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .imageGen(config)
                case .workflow:
                    break
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        let buffer = editBuffer
        return Binding<String>(
            get: {
                if case .bot(let config) = buffer.draft.details { return config.instructions ?? "" }
                return ""
            },
            set: { newValue in
                if case .bot(var config) = buffer.draft.details {
                    config.instructions = newValue
                    buffer.draft.details = .bot(config)
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        let buffer = editBuffer
        return Binding<[KnowledgeSource]>(
            get: {
                if case .bot(let config) = buffer.draft.details { return config.knowledgeSources ?? [] }
                return []
            },
            set: { newValue in
                if case .bot(var config) = buffer.draft.details {
                    config.knowledgeSources = newValue.isEmpty ? nil : newValue
                    buffer.draft.details = .bot(config)
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
            // Instructions are not auto-populated: the user types their own before saving, instead of silently shipping a
            // default they never read.
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .chat)
        }
        .onDisappear {
            // Closes the floating prompt editor if the user leaves the panel. A plain close is correct only here: this Simple
            // editor pushes every keystroke to the binding.
            promptWindowManager.closeWindow()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .chat)
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
            // See AgentConfigDetailView for the rationale — `onCancel` swaps
            // the leading chevron for an xmark and routes it to the modal host.
            DynamicIslandBar(
                title: editBuffer.draft.displayName,
                icon: "bubble.left.and.bubble.right.fill",
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

        // 3. Persona & Behavior
        personaSection

        // 4. File Handling Strategy & Knowledge
        fileHandlingSection

        // 5. Advanced Configuration
        advancedConfigSection
    }

    private var identitySection: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.22), Color.blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(Color.blue.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: Color.blue.opacity(0.2), radius: 8)

                Image(systemName: ProfileType.bot.iconNameFilled)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading) {
                TextField("", text: profile.displayName, prompt: Text("Bot Name").foregroundColor(theme.placeholderText))
                    .font(theme.fontTitle2)
                    .fontWeight(.bold)
                    .textFieldStyle(.plain)
                    .foregroundColor(theme.primaryText)

                Text("A straightforward LLM interface without agentic capabilities.")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private var inferenceEngineSection: some View {
        SettingsCard(title: "Inference Engine", icon: "server.rack", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                ProviderConfigSection(
                    providerConfig: providerConfig,
                    profileID: editBuffer.draft.id,
                    profileType: .bot,
                    onProviderChanged: { _, newProvider in
                        providerConfig.wrappedValue.cognitiveCapability =
                            ProfileCapabilityFilter.defaultCognitiveCapability(for: .bot, provider: newProvider)
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var personaSection: some View {
        SettingsCard(title: "Persona & Behavior", icon: "text.quote", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("System Instructions")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    TactileButton(
                        title: "Expand",
                        icon: "arrow.up.left.and.arrow.down.right",
                        variant: .secondary,
                        size: .compact
                    ) {
                        promptWindowManager.showEditor(
                            text: instructionsBinding,
                            // A binding, so renaming the bot retitles the detached
                            // window instead of leaving it on the old name (A75).
                            botName: profile.displayName,
                            themeManager: themeManager,
                            // Passes the profile's context window so the editor's "% of context" readout works.
                            contextWindow: providerConfig.wrappedValue.modelMetadata?.contextWindow
                        )
                    }
                }

                ZStack(alignment: .topLeading) {
                    TokenizingTextEditor(
                        text: instructionsBinding,
                        theme: theme,
                        allowsToolMentions: false
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
                        Text("Enter system instructions for your bot here...")
                            .font(theme.fontCode)
                            .foregroundColor(theme.placeholderText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                let charCount = instructionsBinding.wrappedValue.count
                let charLimit = ProfileValidationLimits.maxInstructionsLength
                Text("\(charCount) characters · ~\(charCount / 4) tokens")
                    .font(theme.fontCaption2)
                    .foregroundColor(
                        charCount > charLimit ? theme.errorColor :
                        charCount > Int(Double(charLimit) * 0.9) ? theme.warningColor :
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
                            .font(theme.fontCaption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(theme.errorColor)
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
                    configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .chat)
                }

                IslandPillButton(
                    title: "Save",
                    style: .primary,
                    help: "Save profile changes (⌘S)",
                    accessibilityLabel: "Save profile changes",
                    keyboardShortcut: KeyboardShortcut("s", modifiers: .command)
                ) {
                    // Pre-flight: a bot with empty instructions has no persona or guardrails, so the save is blocked with an inline
                    // error. The rule and wording come from `ProfileValidator`.
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
                            + "(\(editBuffer.draft.id), bot): \(error.localizedDescription). "
                            + "CONSEQUENCE: the edit buffer stays dirty and the persisted profile is "
                            + "unchanged; the user's edits are still on screen but not on disk."
                        )
                        // Cleared on failure too: an advisory describes a profile that was saved, so it must not stay beside an error toast.
                        saveAdvisories = []
                        toastManager.show(error.localizedDescription, style: .error)
                    }
                }
            }

            // Hidden in modal-cancel mode — see AgentConfigDetailView.
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
    private var fileHandlingSection: some View {
        SettingsCard(title: "Knowledge", icon: "book.closed.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                // Reference Documents
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reference Documents")
                                .font(theme.fontSubheadline.weight(.semibold))
                            Text("Add external documents the bot can use as context")
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
                                result, to: knowledgeSourcesBinding, profileKind: "bot")
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

                // Bot file handling is fixed to .directInjection (bots have no tools,
                // and contextualRAG is deprecated) — one option, so no picker.
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
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
            defaultProfile: .chat
        )
    }
}
