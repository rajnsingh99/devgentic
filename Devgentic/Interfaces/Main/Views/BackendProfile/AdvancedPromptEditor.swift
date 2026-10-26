// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvancedPromptEditor.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import Combine

private let logger = DGLogger(category: "AdvancedPromptEditor")

// MARK: - Window Manager

/// Manages a single floating NSWindow for the advanced prompt editor. One instance per consuming view (not a
/// singleton) so editors keep their own unsaved-changes callbacks. `@MainActor` because NSWindow requires it.
@MainActor
final class AdvancedPromptWindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Callbacks to the SwiftUI view, set by `AdvancedPromptEditorView.onAppear` for the editor that owns this instance.
    var checkChanges: (() -> Bool)?
    var saveChanges: (() -> Void)?
    var discardChanges: (() -> Void)?
    /// Writes the editor's pending text back to its bindings without closing.
    /// Used by `closeWindowCommittingChanges()` on navigation teardown.
    var commitChanges: (() -> Void)?

    /// Spawns or brings the editor window to the front.
    func showEditor(
        text: Binding<String>,
        agentName: Binding<String>,
        configuredTools: Binding<[Tool]>,
        themeManager: ThemeManager,
        contextWindow: Int? = nil
    ) {
        let theme = themeManager.currentTheme

        // Reuse an existing window instead of creating another.
        if let existingWindow = window {
            commitChanges?()

            existingWindow.styleMask.insert(.fullSizeContentView)
            existingWindow.titleVisibility = .hidden
            existingWindow.titlebarAppearsTransparent = true
            existingWindow.titlebarSeparatorStyle = .none
            existingWindow.isMovableByWindowBackground = false
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)

            existingWindow.contentView = NSHostingView(
                rootView: AdvancedPromptEditorHost(
                    themeManager: themeManager,
                    manager: self,
                    text: text,
                    agentName: agentName,
                    configuredTools: configuredTools,
                    contextWindow: contextWindow
                )
            )
            existingWindow.title = Self.title(for: agentName.wrappedValue)
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            logger.info("[PROFILE] Re-presented the floating instructions editor for '\(agentName.wrappedValue)'.")
            return
        }

        let editorView = AdvancedPromptEditorHost(
            themeManager: themeManager,
            manager: self,
            text: text,
            agentName: agentName,
            configuredTools: configuredTools,
            contextWindow: contextWindow
        )

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        newWindow.center()
        newWindow.title = Self.title(for: agentName.wrappedValue)
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.titlebarSeparatorStyle = .none
        newWindow.isMovableByWindowBackground = false
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = NSHostingView(rootView: editorView)
        newWindow.level = .floating

        newWindow.isOpaque = false
        newWindow.backgroundColor = NSColor(theme.primaryBackground)
        newWindow.minSize = NSSize(width: 660, height: 480)
        newWindow.delegate = self

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }

    /// Closes the window without committing anything.
    /// `NSWindow.close()` skips `windowShouldClose(_:)`, so only callers that already decided the text's fate may use this.
    func closeWindow() {
        window?.close()
        window = nil
    }

    /// Commits the editor's pending text back to its bindings, then closes; the teardown path for navigation (`onDisappear`).
    /// Commits rather than prompts: `NSAlert.runModal()` inside a SwiftUI update spins a nested modal loop mid-navigation.
    func closeWindowCommittingChanges() {
        commitChanges?()
        closeWindow()
    }

    static func title(for agentName: String) -> String { "System Instructions: \(agentName)" }

    /// Updates the floating window's title without rebuilding the content
    /// view (so the editor keeps focus). No-op when the window isn't open —
    /// callers can fire this on every name keystroke without checks.
    func updateTitle(agentName: String) {
        // Not gated on `isVisible`, which is false while miniaturized, so a rename still updates the title.
        guard let window else { return }
        window.title = Self.title(for: agentName)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        // NSWindowDelegate calls happen on the main thread but aren't
        // typed @MainActor — hop explicitly so the actor checker is happy.
        MainActor.assumeIsolated {
            if checkChanges?() == true {
                let alert = NSAlert()
                alert.messageText = "Unsaved Changes"
                alert.informativeText = "You have unsaved changes in the system instructions. Would you like to save them before closing?"
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Don't Save")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn { // Save
                    saveChanges?()
                    return true
                } else if response == .alertSecondButtonReturn { // Cancel
                    return false
                } else { // Don't Save
                    discardChanges?()
                    return true
                }
            }
            return true
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Identity check: only the close of the current window clears state, so a stray close notification cannot wipe a live
            // editor's reference and callbacks and destroy the typed prompt.
            guard let closing = notification.object as? NSWindow, closing === window else {
                logger.error(
                    "[PROFILE] A prompt-editor window closed that is NOT the one currently tracked. "
                    + "CONSEQUENCE: its close is ignored and the live editor keeps its callbacks; "
                    + "if this ever appears, an orphaned window survived the reuse path and the "
                    + "leak this guard exists to contain is back."
                )
                return
            }

            logger.info("[PROFILE] Floating instructions editor closed; releasing its window and hosting view.")
            closing.delegate = nil
            window = nil
            // Reset callbacks
            checkChanges = nil
            saveChanges = nil
            discardChanges = nil
            commitChanges = nil
        }
    }
}

// MARK: - Themed Host

/// Wrapper that watches the @Observable ThemeManager and re-applies the `\.appTheme` environment when the theme changes,
/// keeping the floating-window editor in step with the app.
private struct AdvancedPromptEditorHost: View {
    @Bindable var themeManager: ThemeManager
    var manager: AdvancedPromptWindowManager
    @Binding var text: String
    @Binding var agentName: String
    @Binding var configuredTools: [Tool]
    var contextWindow: Int? = nil

    var body: some View {
        AdvancedPromptEditorView(
            manager: manager,
            text: $text,
            agentName: agentName,
            configuredTools: $configuredTools,
            contextWindow: contextWindow
        )
        .environment(\.appTheme, themeManager.currentTheme)
        .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
        .environment(themeManager)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
        // Keeps the window title in step with the agent name.
        .onChange(of: agentName) { _, newName in manager.updateTitle(agentName: newName) }
    }
}

// MARK: - Window Drag Area

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggingView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - Models & State

/// Bundles the definition and source so we can easily add it to `configuredTools`.
struct AvailableTool: Identifiable, Equatable {
    var id: String { "\(source.id)-\(definition.name)" }
    let definition: ToolDefinition
    let source: ToolSource
    
    static func == (lhs: AvailableTool, rhs: AvailableTool) -> Bool {
        return lhs.id == rhs.id
    }
}

/// Manages the state of the active tool mention popover for keyboard navigation.
@Observable @MainActor
class MentionState {
    var selectedIndex: Int = 0
    var maxIndex: Int = 0
    var activeTools: [AvailableTool] = []
}

/// Manages the state of the active prompt mention popover for keyboard navigation.
@Observable @MainActor
class PromptMentionState {
    var selectedIndex: Int = 0
    var maxIndex: Int = 0
    var activePrompts: [DevPrompt] = []
}

// MARK: - Editor UI

struct AdvancedPromptEditorView: View {
    /// The manager that owns the floating window; callbacks are set on this instance so unsaved-changes prompts target
    /// the right document when several editors are open.
    var manager: AdvancedPromptWindowManager
    @Binding var text: String
    var agentName: String
    @Binding var configuredTools: [Tool]
    var contextWindow: Int? = nil
    @Environment(\.appTheme) private var theme
    
    // State for supporting components
    @State private var promptLibraryVM = PromptEditViewModel()
    @State private var showingSavePopover: Bool = false
    @State private var showingGuide: Bool = false
    
    // Tracking for unsaved changes
    @State private var localText: String = ""
    @State private var localTools: [Tool] = []
    
    @State private var initialText: String = ""
    @State private var initialTools: [Tool] = []
    
    private var hasUnsavedChanges: Bool {
        localText != initialText || localTools != initialTools
    }

    private var estimatedTokens: Int {
        max(1, localText.count / 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar with Drag Area and Traffic Light Clearance
            headerView

            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)

            // Subheader Context Banner & Quick Insertion
            subHeaderView

            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)

            // Workspace Area (Editor Canvas + Optional Slide-out Guide)
            HStack(spacing: 0) {
                editorCanvasView

                if showingGuide {
                    Rectangle()
                        .fill(theme.dividerColor.opacity(0.25))
                        .frame(width: 0.5)

                    PromptGuideView(
                        onInsertSnippet: { snippet in
                            insertText(snippet)
                        },
                        onClose: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                showingGuide = false
                            }
                        }
                    )
                    .frame(width: 290)
                    .background(theme.secondaryBackground.opacity(0.4))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)

            // Tactile Footer
            footerView
        }
        .frame(minWidth: 680, minHeight: 500)
        .background(theme.primaryBackground)
        .onAppear {
            localText = text
            localTools = configuredTools

            initialText = text
            initialTools = configuredTools

            manager.checkChanges = { [local = $localText, initial = $initialText,
                                      localTools = $localTools, initialTools = $initialTools] in
                local.wrappedValue != initial.wrappedValue
                    || localTools.wrappedValue != initialTools.wrappedValue
            }
            manager.saveChanges = { [weak manager, target = $text, tools = $configuredTools,
                                     local = $localText, localTools = $localTools] in
                target.wrappedValue = local.wrappedValue
                tools.wrappedValue = localTools.wrappedValue
                manager?.closeWindow()
            }
            manager.discardChanges = { [weak manager] in manager?.closeWindow() }
            manager.commitChanges = { [target = $text, tools = $configuredTools,
                                       local = $localText, localTools = $localTools] in
                target.wrappedValue = local.wrappedValue
                tools.wrappedValue = localTools.wrappedValue
            }
        }
        .onExitCommand {
            handleClose()
        }
        .background(
            Group {
                Button("") {
                    if hasUnsavedChanges {
                        saveAndClose()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("") {
                    handleClose()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        )
    }

    // MARK: - Header View
    private var headerView: some View {
        HStack(spacing: 12) {
            // Identity Cluster
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.8)
                        )

                    Image(systemName: "cpu.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agentName)
                            .font(theme.fontHeadline.weight(.bold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text("AGENT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(theme.surfaceOverlayStrong)
                            .clipShape(Capsule())
                    }

                    Text("System Instructions & Persona")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer(minLength: 16)

            // Telemetry Pill & Actions
            HStack(spacing: 10) {
                telemetryPill

                TactileIconButton(
                    icon: showingGuide ? "book.pages.fill" : "book.pages",
                    tooltip: showingGuide ? "Hide Prompt Guide" : "Show Prompt Guide",
                    variant: showingGuide ? .primary : .secondary,
                    size: 26
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        showingGuide.toggle()
                    }
                }

                TactileIconButton(
                    icon: "xmark",
                    tooltip: "Close Window",
                    variant: .subtle,
                    size: 26
                ) {
                    handleClose()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                theme.primaryBackground
                WindowDragArea()
            }
        )
    }

    // MARK: - Subheader View
    private var subHeaderView: some View {
        HStack(spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor.opacity(0.8))

            Text("Define core persona, protocols, and tool constraints.")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 12)

            // Quick Insertion Actions
            HStack(spacing: 6) {
                TactileButton(
                    title: "@ Tool",
                    icon: "wrench.fill",
                    variant: .subtle,
                    size: .compact
                ) {
                    insertShortcutSymbol("@")
                }

                TactileButton(
                    title: "# Prompt",
                    icon: "text.quote",
                    variant: .subtle,
                    size: .compact
                ) {
                    insertShortcutSymbol("#")
                }

                TactileButton(
                    title: "Save to Library",
                    icon: "plus.square.on.square",
                    variant: .secondary,
                    size: .compact
                ) {
                    promptLibraryVM.loadCreateDraft()
                    promptLibraryVM.text = localText
                    showingSavePopover = true
                }
                .popover(isPresented: $showingSavePopover, arrowEdge: .top) {
                    CreateEditPromptView()
                        .environment(promptLibraryVM)
                        .frame(minWidth: 480, idealWidth: 550, minHeight: 450, idealHeight: 500)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.35))
    }

    // MARK: - Inset Editor Canvas
    private var editorCanvasView: some View {
        ZStack(alignment: .topLeading) {
            TokenizingTextEditor(
                text: $localText,
                configuredTools: $localTools,
                theme: theme,
                promptLibraryVM: promptLibraryVM
            )
            .padding(8)
            .scrollContentBackground(.hidden)

            if localText.isEmpty {
                Text("Define persona, strategy, and guardrails for \(agentName)...")
                    .font(theme.fontCode)
                    .foregroundColor(theme.placeholderText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Telemetry Pill
    private var telemetryPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(contextStatusColor)
                .frame(width: 5, height: 5)

            Text("~ \(estimatedTokens.formatted()) tokens")
                .font(theme.fontCaption2.monospacedDigit())
                .foregroundColor(theme.primaryText)

            if let cw = contextWindow {
                let ratio = Double(estimatedTokens) / Double(cw)
                Text("•")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.tertiaryText)
                Text("\(Int(ratio * 100))% of \(formatContext(cw))")
                    .font(theme.fontCaption2.monospacedDigit())
                    .foregroundColor(contextStatusColor)
            }

            Text("•")
                .font(theme.fontCaption2)
                .foregroundColor(theme.tertiaryText)

            Text("\(localText.count.formatted()) chars")
                .font(theme.fontCaption2.monospacedDigit())
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var contextStatusColor: Color {
        guard let cw = contextWindow else { return theme.accentColor }
        let ratio = Double(estimatedTokens) / Double(cw)
        if ratio > 0.5 { return theme.errorColor }
        if ratio > 0.25 { return theme.warningColor }
        return theme.successColor
    }

    private func formatContext(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)k"
        } else {
            return "\(tokens)"
        }
    }

    // MARK: - Footer View
    private var footerView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(hasUnsavedChanges ? theme.warningColor : theme.successColor)
                .frame(width: 6, height: 6)

            Text(hasUnsavedChanges
                 ? "Unsaved modifications staged (click Save & Close or ⌘S)"
                 : "Changes apply to the active configuration on close")
                .font(theme.fontCaption2)
                .foregroundColor(hasUnsavedChanges ? theme.warningColor : theme.secondaryText)

            Spacer()

            if hasUnsavedChanges {
                TactileButton(
                    title: "Revert",
                    icon: "arrow.counterclockwise",
                    variant: .subtle,
                    size: .compact
                ) {
                    revertChanges()
                }

                TactileButton(
                    title: "Save & Close",
                    icon: "checkmark",
                    variant: .primary,
                    size: .compact
                ) {
                    saveAndClose()
                }
            } else {
                TactileButton(
                    title: "Done",
                    icon: "checkmark",
                    variant: .secondary,
                    size: .compact
                ) {
                    saveAndClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.primaryBackground)
    }

    // MARK: - Actions
    private func insertShortcutSymbol(_ symbol: String) {
        if localText.isEmpty || localText.hasSuffix("\n") || localText.hasSuffix(" ") {
            localText += symbol
        } else {
            localText += " " + symbol
        }
    }

    private func insertText(_ textToInsert: String) {
        if localText.isEmpty {
            localText = textToInsert
        } else if localText.hasSuffix("\n\n") {
            localText += textToInsert
        } else if localText.hasSuffix("\n") {
            localText += "\n" + textToInsert
        } else {
            localText += "\n\n" + textToInsert
        }
    }

    private func revertChanges() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            localText = initialText
            localTools = initialTools
        }
    }

    private func saveAndClose() {
        commitToBindings()
        manager.closeWindow()
    }

    private func handleClose() {
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "You have unsaved changes in the system instructions. Would you like to save them before closing?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                saveAndClose()
            } else if response == .alertThirdButtonReturn {
                manager.closeWindow()
            }
        } else {
            manager.closeWindow()
        }
    }

    /// The single write-back path from the editor's local state to the profile's bindings.
    private func commitToBindings() {
        text = localText
        configuredTools = localTools
    }
}

// MARK: - AppKit TextEditor & Autocomplete Wrapper

struct TokenizingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var configuredTools: [Tool]
    var theme: Theme
    var promptLibraryVM: PromptEditViewModel?
    var allowsToolMentions: Bool

    init(
        text: Binding<String>,
        configuredTools: Binding<[Tool]> = .constant([]),
        theme: Theme,
        promptLibraryVM: PromptEditViewModel? = nil,
        allowsToolMentions: Bool = true
    ) {
        self._text = text
        self._configuredTools = configuredTools
        self.theme = theme
        self.promptLibraryVM = promptLibraryVM
        self.allowsToolMentions = allowsToolMentions
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(theme.primaryText)
        textView.insertionPointColor = NSColor(theme.primaryText)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            // Block textDidChange delegate from firing during structural SwiftUI update
            context.coordinator.isUpdatingFromSwiftUI = true
            
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
            
            context.coordinator.isUpdatingFromSwiftUI = false
        }
        
        // Ensure theme colors are applied on update
        textView.textColor = NSColor(theme.primaryText)
        textView.insertionPointColor = NSColor(theme.primaryText)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: TokenizingTextEditor
        var popover: NSPopover?
        var promptPopover: NSPopover?
        
        var activeMentionRange: NSRange?
        var activePromptRange: NSRange?
        
        // Keyboard state tracking
        var mentionState = MentionState()
        var promptMentionState = PromptMentionState()
        
        // Flag to prevent loop-backs when updating from SwiftUI
        var isUpdatingFromSwiftUI = false

        init(_ parent: TokenizingTextEditor) {
            self.parent = parent
        }

        // MARK: - Dynamic Syntax Highlighting
        
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            
            let text = textStorage.string
            let fullRange = NSRange(location: 0, length: textStorage.length)
            
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(parent.theme.primaryText),
                .backgroundColor: NSColor.clear
            ]
            textStorage.setAttributes(defaultAttributes, range: fullRange)
            
            guard parent.allowsToolMentions else { return }

            // To properly highlight, we should highlight ANY configured tool to keep visuals in sync.
            let toolNames = parent.configuredTools.map { $0.name }
            guard !toolNames.isEmpty else { return }
            
            if let regex = try? NSRegularExpression(pattern: "`([^`]+)`") {
                let matches = regex.matches(in: text, range: fullRange)
                
                for match in matches {
                    guard match.numberOfRanges == 2 else { continue }
                    
                    if let swiftRange = Range(match.range(at: 1), in: text) {
                        let extractedName = String(text[swiftRange])
                        
                        if toolNames.contains(extractedName) {
                            let tokenAttributes: [NSAttributedString.Key: Any] = [
                                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                                .foregroundColor: NSColor(parent.theme.accentColor),
                                .backgroundColor: NSColor(parent.theme.accentColor).withAlphaComponent(0.15)
                            ]
                            textStorage.addAttributes(tokenAttributes, range: match.range)
                        }
                    }
                }
            }
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            textView.typingAttributes = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(parent.theme.primaryText),
                .backgroundColor: NSColor.clear
            ]
        }

        // MARK: - Keyboard Integration
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if popover?.isShown == true {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    mentionState.selectedIndex = max(0, mentionState.selectedIndex - 1)
                    return true
                } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    mentionState.selectedIndex = min(mentionState.maxIndex, mentionState.selectedIndex + 1)
                    return true
                } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if !mentionState.activeTools.isEmpty {
                        let selected = mentionState.activeTools[mentionState.selectedIndex]
                        insertTool(selected, in: textView)
                    }
                    return true
                } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    closePopover()
                    return true
                }
            }
            
            if promptPopover?.isShown == true {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    promptMentionState.selectedIndex = max(0, promptMentionState.selectedIndex - 1)
                    return true
                } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    promptMentionState.selectedIndex = min(promptMentionState.maxIndex, promptMentionState.selectedIndex + 1)
                    return true
                } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if !promptMentionState.activePrompts.isEmpty {
                        let selected = promptMentionState.activePrompts[promptMentionState.selectedIndex]
                        insertPrompt(selected, in: textView)
                    }
                    return true
                } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    closePromptPopover()
                    return true
                }
            }
            
            return false
        }
        
        // MARK: - Mention Logic
        
        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI else { return }
            guard let textView = notification.object as? NSTextView else { return }
            
            let newText = textView.string
            
            DispatchQueue.main.async {
                // Ensure we only write back if the text actually mutated, preventing circular structural re-renders
                if self.parent.text != newText {
                    self.parent.text = newText
                }
            }

            let selectedRange = textView.selectedRange()
            let textString = textView.string as NSString

            guard selectedRange.location > 0 else {
                closePopover()
                closePromptPopover()
                return
            }

            let textUpToCursor = textString.substring(to: selectedRange.location)
            let components = textUpToCursor.components(separatedBy: .whitespacesAndNewlines)
            guard let lastWord = components.last else {
                closePopover()
                closePromptPopover()
                return
            }

            if parent.allowsToolMentions && lastWord.hasPrefix("@") {
                closePromptPopover()
                let mentionLocation = selectedRange.location - lastWord.count
                activeMentionRange = NSRange(location: mentionLocation, length: lastWord.count)
                let query = String(lastWord.dropFirst())
                showPopover(for: query, in: textView)
            } else if lastWord.hasPrefix("#") {
                closePopover()
                let mentionLocation = selectedRange.location - lastWord.count
                activePromptRange = NSRange(location: mentionLocation, length: lastWord.count)
                let query = String(lastWord.dropFirst())
                showPromptPopover(for: query, in: textView)
            } else {
                closePopover()
                closePromptPopover()
            }
        }

        private func showPopover(for query: String, in textView: NSTextView) {
            // Step 1: Query against ALL available tools globally
            let allTools = UnifiedToolStore.shared.sources.flatMap { source in
                source.tools.map { AvailableTool(definition: $0, source: source) }
            }
            
            let filteredTools = query.isEmpty ? allTools : allTools.filter {
                $0.definition.name.localizedCaseInsensitiveContains(query) ||
                $0.definition.description.localizedCaseInsensitiveContains(query)
            }

            guard !filteredTools.isEmpty else {
                closePopover()
                return
            }
            
            // Sync Keyboard State
            mentionState.activeTools = filteredTools
            mentionState.maxIndex = max(0, filteredTools.count - 1)
            mentionState.selectedIndex = 0

            let listView = ToolMentionListView(state: mentionState) { [weak self] selectedTool in
                self?.insertTool(selectedTool, in: textView)
            }

            let controller = NSHostingController(rootView: listView)
            
            if popover == nil {
                popover = NSPopover()
                popover?.behavior = .transient
                popover?.animates = false
            }
            popover?.contentViewController = controller

            if let range = activeMentionRange,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                
                let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
                
                var targetRect = rect
                targetRect.origin.x += textView.textContainerOrigin.x
                targetRect.origin.y += textView.textContainerOrigin.y
                
                popover?.show(relativeTo: targetRect, of: textView, preferredEdge: .minY)
            }
        }

        private func closePopover() {
            popover?.close()
            activeMentionRange = nil
        }

        private func insertTool(_ availableTool: AvailableTool, in textView: NSTextView) {
            guard let range = activeMentionRange else { return }
            
            let replacement = "`\(availableTool.definition.name)` "
            
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            
            // Step 1: Auto-Sync to Library State
            DispatchQueue.main.async {
                let isAlreadyEnabled = self.parent.configuredTools.contains {
                    $0.name == availableTool.definition.name && $0.sourceId == availableTool.source.id
                }
                
                if !isAlreadyEnabled {
                    let newTool = Tool(
                        name: availableTool.definition.name,
                        description: availableTool.definition.description,
                        isEnabled: true,
                        requiresConfirmation: availableTool.definition.requiresConfirmation,
                        sourceId: availableTool.source.id,
                        parameters: availableTool.definition.parameters
                    )
                    self.parent.configuredTools.append(newTool)
                }
            }

            closePopover()
        }

        private func showPromptPopover(for query: String, in textView: NSTextView) {
            let allPrompts = PromptService.shared.getAllPrompts()
            
            let filteredPrompts = query.isEmpty ? allPrompts : allPrompts.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.text.localizedCaseInsensitiveContains(query)
            }

            guard !filteredPrompts.isEmpty else {
                closePromptPopover()
                return
            }
            
            // Sync Keyboard State
            promptMentionState.activePrompts = filteredPrompts
            promptMentionState.maxIndex = max(0, filteredPrompts.count - 1)
            promptMentionState.selectedIndex = 0

            let listView = PromptMentionListView(state: promptMentionState) { [weak self] selectedPrompt in
                self?.insertPrompt(selectedPrompt, in: textView)
            }
            .environment(\.appTheme, parent.theme)

            let controller = NSHostingController(rootView: listView)
            
            if promptPopover == nil {
                promptPopover = NSPopover()
                promptPopover?.behavior = .transient
                promptPopover?.animates = false
            }
            promptPopover?.contentViewController = controller

            if let range = activePromptRange,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                
                let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
                
                var targetRect = rect
                targetRect.origin.x += textView.textContainerOrigin.x
                targetRect.origin.y += textView.textContainerOrigin.y
                
                promptPopover?.show(relativeTo: targetRect, of: textView, preferredEdge: .minY)
            }
        }

        private func closePromptPopover() {
            promptPopover?.close()
            activePromptRange = nil
        }

        private func insertPrompt(_ prompt: DevPrompt, in textView: NSTextView) {
            guard let range = activePromptRange else { return }
            
            let replacement = prompt.text
            
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            
            closePromptPopover()
        }
    }
}

// MARK: - Popover UI Components

struct ToolMentionListView: View {
    @Bindable var state: MentionState
    let onSelect: (AvailableTool) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insert Tool")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.activeTools.enumerated()), id: \.element.id) { index, tool in
                            ToolMentionRow(
                                tool: tool,
                                isSelected: index == state.selectedIndex,
                                action: { onSelect(tool) }
                            )
                            .id(index)
                            Divider()
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { oldValue, newValue in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 320, height: min(CGFloat(state.activeTools.count * 48 + 40), 320))
    }
}

struct ToolMentionRow: View {
    let tool: AvailableTool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: "wrench.fill")
                    .foregroundColor(isSelected ? .white : theme.accentColor)
                    .font(theme.fontCaption)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.definition.name)
                        .font(theme.fontSubheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isSelected ? .white : theme.primaryText)
                    
                    Text(tool.definition.description.split(separator: "\n").first ?? "")
                        .font(theme.fontCaption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                
                // Add an indicator showing the source (Local vs MCP)
                Text(tool.source.serverName)
                    .font(.system(size: 9)) // Fixed size: intentional (badge/chip text)
                    .foregroundColor(isSelected ? .white.opacity(0.6) : theme.secondaryText.opacity(0.6))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? theme.accentColor : (isHovered ? theme.accentColor.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.definition.description)
        .onHover { hovered in
            isHovered = hovered
            if hovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct PromptMentionListView: View {
    @Bindable var state: PromptMentionState
    let onSelect: (DevPrompt) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insert Prompt")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.activePrompts.enumerated()), id: \.element.id) { index, prompt in
                            PromptMentionRow(
                                prompt: prompt,
                                isSelected: index == state.selectedIndex,
                                action: { onSelect(prompt) }
                            )
                            .id(index)
                            Divider()
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { oldValue, newValue in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 320, height: min(CGFloat(state.activePrompts.count * 48 + 40), 320))
    }
}

struct PromptMentionRow: View {
    let prompt: DevPrompt
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: "text.quote")
                    .foregroundColor(isSelected ? .white : theme.accentColor)
                    .font(theme.fontCaption)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(theme.fontSubheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isSelected ? .white : theme.primaryText)
                    
                    Text(prompt.text.split(separator: "\n").first ?? "")
                        .font(theme.fontCaption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? theme.accentColor : (isHovered ? theme.accentColor.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            isHovered = hovered
            if hovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Prompt Guide

struct PromptGuideView: View {
    var onInsertSnippet: ((String) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header with Close
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "book.pages.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accentColor)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Instructions Guide")
                                .font(theme.fontSubheadline.weight(.bold))
                                .foregroundColor(theme.primaryText)
                            Text("Persona, strategy & guardrails")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                        }
                    }

                    Spacer()

                    if let onClose {
                        TactileIconButton(
                            icon: "xmark",
                            tooltip: "Close Guide",
                            variant: .subtle,
                            size: 22
                        ) {
                            onClose()
                        }
                    }
                }
                .padding(.bottom, 4)

                guideSection(
                    title: "1. Persona",
                    description: "Set the identity, specialization, and communication tone.",
                    example: "# PERSONA\nYou are a Principal Swift Engineer specializing in clean macOS architecture and SwiftUI.",
                    snippetToInsert: "# PERSONA\nYou are an expert assistant specialized in software engineering and clear explanations.\n"
                )

                guideSection(
                    title: "2. Strategy",
                    description: "Outline the step-by-step reasoning cycle.",
                    example: "# STRATEGY\n1. Analyze codebase requirements.\n2. Propose changes before executing.\n3. Verify results thoroughly.",
                    snippetToInsert: "# STRATEGY\n1. Understand the goal and gather necessary context.\n2. Plan changes step by step.\n3. Execute with precision and verify integrity.\n"
                )

                guideSection(
                    title: "3. Guardrails",
                    description: "Specify hard constraints and safety boundaries.",
                    example: "# GUARDRAILS\n- Never execute destructive commands without confirmation.\n- Maintain documentation integrity.",
                    snippetToInsert: "# GUARDRAILS\n- Never perform irreversible modifications without explicit approval.\n- Preserve existing code comments and style conventions.\n"
                )

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.25))
                    .frame(height: 0.5)

                // Shortcuts Section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Interactive Shortcuts")
                        .font(theme.fontFootnote.weight(.bold))
                        .foregroundColor(theme.primaryText)

                    shortcutItem(
                        symbol: "@",
                        label: "Mention Tools",
                        description: "Type `@` to see and bind tools from your library directly into this agent."
                    )

                    shortcutItem(
                        symbol: "#",
                        label: "Prompt Snippets",
                        description: "Type `#` to search and insert reusable templates from your Prompt Library."
                    )
                }

                Spacer(minLength: 16)
            }
            .padding(16)
        }
    }

    private func guideSection(title: String, description: String, example: String, snippetToInsert: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(theme.fontFootnote.weight(.bold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if let onInsertSnippet {
                    Button {
                        onInsertSnippet(snippetToInsert)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text("Insert")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(theme.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Insert this template section into instructions")
                }
            }

            Text(description)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)

            Text(example)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundColor(theme.secondaryText.opacity(0.9))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.primaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
                )
        }
    }

    private func shortcutItem(symbol: String, label: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(symbol)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(theme.accentColor)
                .frame(width: 22, height: 22)
                .background(theme.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(theme.fontCaption2.weight(.bold))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(1.5)
            }
        }
    }
}
