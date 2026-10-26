// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SimplePromptWindowManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "SimplePromptWindow")

// MARK: - Window Manager

// Why: its own `NSWindowDelegate`: the red button bypasses `closeWindow()`, so a stale `window` would leak the
// closed NSWindow and its hosting view, and the next `showEditor` would abandon it.
/// Manages a single floating NSWindow for the simple prompt editor; one instance per consuming view.
/// `@MainActor` because every AppKit touch must happen on the main thread.
@MainActor
final class SimplePromptWindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Spawns or brings the editor window to the front.
    /// `botName` is a binding, not a `String`: the hosting view's root is built once, so a plain value would stay frozen.
    func showEditor(
        text: Binding<String>,
        botName: Binding<String>,
        themeManager: ThemeManager,
        contextWindow: Int? = nil
    ) {
        let theme = themeManager.currentTheme

        // `isVisible` is false while miniaturized, so reuse the existing window regardless of visibility;
        // the identity guard in `windowWillClose` keeps that safe.
        if let existingWindow = window {
            existingWindow.styleMask.insert(.fullSizeContentView)
            existingWindow.titleVisibility = .hidden
            existingWindow.titlebarAppearsTransparent = true
            existingWindow.titlebarSeparatorStyle = .none
            existingWindow.isMovableByWindowBackground = false
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)
            existingWindow.contentView = NSHostingView(
                rootView: makeHost(text: text, botName: botName,
                                   themeManager: themeManager, contextWindow: contextWindow)
            )
            existingWindow.title = Self.title(for: botName.wrappedValue)
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            logger.info("[PROFILE] Re-presented the floating prompt editor for '\(botName.wrappedValue)'.")
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        newWindow.center()
        newWindow.title = Self.title(for: botName.wrappedValue)
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.titlebarSeparatorStyle = .none
        newWindow.isMovableByWindowBackground = false
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = NSHostingView(
            rootView: makeHost(text: text, botName: botName,
                               themeManager: themeManager, contextWindow: contextWindow)
        )
        newWindow.level = .floating
        newWindow.delegate = self

        newWindow.isOpaque = false
        newWindow.backgroundColor = NSColor(theme.primaryBackground)
        newWindow.minSize = NSSize(width: 540, height: 420)

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        logger.info("[PROFILE] Opened the floating prompt editor for '\(botName.wrappedValue)' "
                    + "(context window: \(contextWindow.map(String.init) ?? "unknown")).")
    }

    private func makeHost(
        text: Binding<String>,
        botName: Binding<String>,
        themeManager: ThemeManager,
        contextWindow: Int?
    ) -> SimplePromptEditorHost {
        SimplePromptEditorHost(
            themeManager: themeManager,
            text: text,
            botName: botName,
            contextWindow: contextWindow,
            onClose: { [weak self] in self?.closeWindow() },
            // Driving the title from the host's own re-render means keeping it current is not the caller's job.
            onTitleChange: { [weak self] newName in self?.updateTitle(botName: newName) }
        )
    }

    func closeWindow() {
        // `window?.close()` triggers `windowWillClose`, which clears the reference and logs.
        window?.close()
        window = nil
    }

    /// Updates the floating window's title without rebuilding the content view (so the editor keeps focus).
    /// No-op when the window isn't open, so callers can fire it on every keystroke.
    /// `internal`: `CreateScheduledTaskView` drives it explicitly because its title is derived, not a plain binding.
    func updateTitle(botName: String) {
        // Update even while miniaturized (`isVisible` is false then), or a rename would leave a stale title.
        guard let window else { return }
        window.title = Self.title(for: botName)
    }

    private static func title(for botName: String) -> String {
        String(localized: "System Instructions: \(botName)")
    }

    // MARK: - NSWindowDelegate

    /// Fires for every close (red button, ⌘W, the Done button, app termination), so the manager
    /// never retains a dead window and its hosting view.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Identity check: clearing unconditionally would let a close from any window this object delegated for drop the live
            // window's reference, after which its own close goes untracked and leaks.
            guard let closing = notification.object as? NSWindow, closing === window else {
                logger.error(
                    "[PROFILE] A prompt-editor window closed that is NOT the one currently tracked. "
                    + "CONSEQUENCE: ignored, so the live editor keeps its window reference; if this "
                    + "appears, an orphan survived the reuse path."
                )
                return
            }
            logger.info("[PROFILE] Floating prompt editor closed; releasing its window and hosting view.")
            closing.delegate = nil
            window = nil
        }
    }
}

// MARK: - Themed Host

/// Wrapper that watches the @Observable ThemeManager and re-applies the
/// `\.appTheme` environment whenever the active theme changes — keeping
/// the floating-window editor in lockstep with the parent app's theme.
private struct SimplePromptEditorHost: View {
    @Bindable var themeManager: ThemeManager
    @Binding var text: String
    @Binding var botName: String
    var contextWindow: Int?
    var onClose: () -> Void
    /// Called when the host re-renders under a new name, so the window title can follow (A75).
    var onTitleChange: (String) -> Void

    var body: some View {
        SimplePromptEditorView(
            text: $text,
            botName: $botName,
            contextWindow: contextWindow,
            onClose: onClose
        )
        .environment(\.appTheme, themeManager.currentTheme)
        .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
        .environment(themeManager)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
        .onChange(of: botName) { _, newName in onTitleChange(newName) }
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

// MARK: - Editor UI

struct SimplePromptEditorView: View {
    @Binding var text: String
    /// A binding so a profile rename reaches the detached window — see `showEditor`.
    @Binding var botName: String
    /// Context window size in tokens for the active model. `nil` if unknown.
    var contextWindow: Int?
    var onClose: () -> Void
    @Environment(\.appTheme) private var theme

    // Local state to drive real-time UI updates in the detached window
    @State private var localText: String = ""

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

            // Subheader Context Banner
            subHeaderView

            // Inset Tactile Editor Card
            editorCanvasView

            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 0.5)

            // Tactile Footer
            footerView
        }
        .frame(minWidth: 540, minHeight: 420)
        .background(theme.primaryBackground)
        .onAppear {
            localText = text
        }
        .onChange(of: localText) { _, newValue in
            if text != newValue {
                text = newValue
            }
        }
        .onChange(of: text) { _, newValue in
            if localText != newValue {
                localText = newValue
            }
        }
        .onExitCommand {
            onClose()
        }
        .background(
            Button("") { onClose() }
                .keyboardShortcut("w", modifiers: .command)
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

                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(botName)
                            .font(theme.fontHeadline.weight(.bold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text("BOT")
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

            // Telemetry Capsule & Actions
            HStack(spacing: 10) {
                telemetryPill

                TactileIconButton(
                    icon: "xmark",
                    tooltip: "Close Window",
                    variant: .subtle,
                    size: 26
                ) {
                    onClose()
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
        HStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor.opacity(0.8))

            Text("Defines the core persona, tone, and behavioral instructions for \(botName).")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)

            Spacer()
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
                theme: theme,
                allowsToolMentions: false
            )
            .padding(8)

            if localText.isEmpty {
                Text("Enter system instructions for \(botName) here...")
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
                .fill(theme.successColor)
                .frame(width: 6, height: 6)

            Text("Changes live-sync to the active configuration")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)

            Spacer()

            TactileButton(
                title: "Done",
                icon: "checkmark",
                variant: .primary,
                size: .compact
            ) {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.primaryBackground)
    }
}
