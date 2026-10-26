// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessHITLBanner.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// In-panel Human-in-the-Loop banner: a compact host for the QuickAccess panel's pending interaction (strict FIFO).
/// Answers via `ExecutionSuspensionService`, the same operationID-keyed path every surface uses, so an answer here
/// resolves the request everywhere. A self-contained themed card, readable over the translucent panel in either theme.
struct QuickAccessHITLBanner: View {
    let pending: PendingHITL
    let session: QuickAccessSessionViewModel

    @Environment(\.appTheme) private var theme
    @State private var clarificationText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let hint = keyboardHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .accessibilityHidden(true) // affordance hint; actions are already labeled
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
        // Reset per-item @State (typed answer) when the FIFO advances to a new request.
        .id(pending.id)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(theme.warningColor)
            Text(pending.origin.title)
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var headerIcon: String {
        switch pending.kind {
        case .toolConfirmation(let c): return c.risk.icon
        case .clarification: return "questionmark.bubble"
        case .planReview: return "list.bullet.rectangle"
        case .gate: return "arrow.triangle.branch"
        }
    }

    /// [M9] Discoverability hint for the panel-level keyboard shortcuts. ⌘Return approves the
    /// yes/no kinds; Escape always cancels/denies. Clarification & gate need typed/selected input,
    /// so only Escape is advertised there.
    private var keyboardHint: LocalizedStringKey? { // [M10] LocalizedStringKey so hints are extracted
        switch pending.kind {
        case .toolConfirmation, .planReview: return "⌘⏎ approve · esc cancel"
        case .clarification, .gate: return "esc to cancel"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch pending.kind {
        case .toolConfirmation(let confirmation): toolConfirmationView(confirmation)
        case .clarification(let clarification): clarificationView(clarification)
        case .planReview(let plan): planReviewView(plan)
        case .gate(let gate): gateView(gate)
        }
    }

    // MARK: - Tool confirmation

    @ViewBuilder
    private func toolConfirmationView(_ c: PendingToolConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(c.toolName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(c.risk.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(c.risk.color(in: theme))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(c.risk.color(in: theme).opacity(0.15)))
            }
            if !c.params.isEmpty {
                Text(c.params)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                actionButton("Deny", color: theme.secondaryText, filled: false) { session.denyTool(pending) }
                // The same standing approvals as the main window's banner, in one menu for this compact panel.
                let options = StandingApprovalOptions(for: pending)
                if !options.isEmpty {
                    standingApprovalMenu(c, options: options)
                }
                Spacer(minLength: 0)
                actionButton(c.risk == .destructive ? "Allow anyway" : "Approve",
                             color: c.risk == .destructive ? theme.errorColor : theme.successColor,
                             filled: true) {
                    session.approveTool(pending, allowForChat: false)
                }
            }
        }
    }

    private func standingApprovalMenu(_ c: PendingToolConfirmation, options: StandingApprovalOptions) -> some View {
        Menu {
            if let canonical = options.exactCallArguments {
                Button("Allow this exact call for this run") {
                    session.allowToolForRun(pending, approval: .exactCall(canonicalArguments: canonical))
                }
            }
            if options.canAllowToolForRun {
                Button("Allow \(c.toolName) for this run") {
                    session.allowToolForRun(pending, approval: .anyArguments)
                }
            }
            if options.canAllowForChat {
                if options.canAllowExactCallForRun || options.canAllowToolForRun { Divider() }
                Button("Allow for this chat") {
                    session.approveTool(pending, allowForChat: true)
                }
            }
        } label: {
            Text("Allow…")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Approve this request and keep approving matching ones")
        .accessibilityLabel("More ways to allow")
    }

    // MARK: - Clarification

    @ViewBuilder
    private func clarificationView(_ c: PendingClarification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.question)
                .font(theme.fontBody)
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let options = c.options, !options.isEmpty {
                // One-tap suggested answers.
                FlowRow(options: options) { option in
                    session.submitClarification(pending, text: option)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Type your answer…", text: $clarificationText, axis: c.multiline ? .vertical : .horizontal)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(c.multiline ? 4 : 1)
                        .onSubmit { session.submitClarification(pending, text: clarificationText) }
                    actionButton("Send", color: theme.accentColor, filled: true) {
                        session.submitClarification(pending, text: clarificationText)
                    }
                    .disabled(clarificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Plan review

    @ViewBuilder
    private func planReviewView(_ p: PendingPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // [M10] Automatic grammar agreement instead of a hand-rolled English "s" — pluralizes
            // correctly per locale via the string catalog.
            Text("Proposed plan — ^[\(p.subtasks.count) step](inflect: true)")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(p.subtasks.enumerated()), id: \.element.id) { index, task in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                        Text(task.description)
                            .font(.system(.caption))
                            .foregroundColor(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                actionButton("Reject", color: theme.secondaryText, filled: false) { session.resolvePlan(pending, approved: false) }
                Spacer(minLength: 0)
                actionButton("Approve plan", color: theme.successColor, filled: true) { session.resolvePlan(pending, approved: true) }
            }
        }
    }

    // MARK: - Gate

    @ViewBuilder
    private func gateView(_ g: PendingGate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(g.prompt)
                .font(theme.fontBody)
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            // A Router arbitration or a Gate node carries the text the decision is about in `inputText`; show it, or the panel
            // would ask for a decision without the input. Plain text: this compact panel has no room for colour-coded spans.
            if let input = g.inputText, !input.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(input)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 72)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.35)))
            }

            FlowRow(options: g.options) { option in
                session.chooseGate(pending, option: option)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    // [M10] LocalizedStringKey (not String) so the literal call-site labels ("Deny", "Approve", …)
    // are extracted into Localizable.xcstrings instead of shipping verbatim English.
    private func actionButton(_ title: LocalizedStringKey, color: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        QuickAccessBannerActionButton(
            title: title,
            color: color,
            filled: filled,
            action: action
        )
    }
}

private struct QuickAccessBannerActionButton: View {
    let title: LocalizedStringKey
    let color: Color
    let filled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var isContrastPrimary: Bool {
        filled && buttonAccentStyle == .themeContrast
    }

    private var backgroundColor: Color {
        if filled {
            if buttonAccentStyle == .themeContrast {
                if !isEnabled {
                    return theme.isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.20)
                }
                return theme.isDark
                    ? (isHovered ? Color.white : Color.white.opacity(0.95))
                    : (isHovered ? Color.black : Color(red: 0.12, green: 0.12, blue: 0.14))
            }
            // Style 3 (Tactile Glass)
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
        } else {
            return isHovered ? theme.surfaceOverlay : Color.clear
        }
    }

    private var foregroundColor: Color {
        if !isEnabled {
            if isContrastPrimary {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08).opacity(0.4) : Color.white.opacity(0.4)
            }
            return theme.secondaryText.opacity(0.45)
        }
        if filled {
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            // Style 3: Clean primary text
            return isHovered ? theme.primaryText : theme.primaryText.opacity(0.95)
        } else {
            return isHovered ? theme.primaryText : color
        }
    }

    private var strokeColor: Color {
        if filled {
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color.white.opacity(0.4) : Color.black.opacity(0.2)
            }
            // Style 3: Semantic stroke glowing on hover
            return isHovered ? color.opacity(0.65) : color.opacity(0.35)
        } else {
            return isHovered ? color.opacity(0.5) : color.opacity(0.25)
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(foregroundColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(backgroundColor))
                .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
                .shadow(
                    color: isHovered && isEnabled && isContrastPrimary
                        ? Color.black.opacity(0.25)
                        : (isHovered && isEnabled && filled ? color.opacity(0.25) : Color.clear),
                    radius: 3,
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: isEnabled)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovered = h } }
        .scaleEffect(isHovered && isEnabled ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
    }
}

/// Simple wrapping row of one-tap option chips (clarification suggestions / gate options).
private struct FlowRow: View {
    let options: [String]
    let onTap: (String) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        // Compact: a horizontally-scrolling row keeps the banner height bounded even with
        // many options, which matters in a small floating panel.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button(action: { onTap(option) }) {
                        Text(option)
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(theme.surfaceOverlay))
                            .overlay(Capsule().stroke(theme.accentColor.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }
}
