// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InteractionBannerStack.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Captures the user's exact action on a HITL banner (approve / deny / always-allow / edits / skip).
/// These are the only places the user's intent is known with full context (tool name, edited values,
/// question), so logging here makes runtime behavior auditable from the logs.
private let bannerLogger = DGLogger(category: "InteractionBanner")

// MARK: - Host

/// The single above-input surface for human-in-the-loop requests in every interface.
/// Shows one request at a time in FIFO order via `InteractionCenter.current(for:)`, with a source header from `origin`.
/// Dismissal is driven entirely by the center's resolution; there is no optimistic timer.
struct InteractionBannerStack: View {
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// [HITL/E2] One-shot attention flash, driven by InteractionCenter.attentionPulse.
    @State private var pulse = false

    var body: some View {
        let selected = vm.selectedConversationID
        let current = selected.flatMap { vm.interactionCenter.current(for: $0) }
        // How many requests are queued for this conversation, so the user knows more banners are waiting.
        let queuedCount = selected.map { vm.interactionCenter.items(for: $0).count } ?? 0

        // The cross-conversation "N others awaiting input" chip is `CrossConversationInputChip`, at the top of the chat area.
        // This bottom stack is only the banner for the currently focused conversation.
        return VStack(spacing: 6) {
            if let pending = current {
                if queuedCount > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(.caption2, weight: .semibold))
                        Text("1 of \(queuedCount) requests awaiting your input")
                            .font(.system(.caption2, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(theme.warningColor.opacity(0.9))
                    .padding(.horizontal, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("1 of \(queuedCount) requests awaiting your input")
                }
                banner(for: pending)
                    // Reset per-item @State (typed answer, edited plan) when the FIFO advances.
                    .id(pending.id)
                    // Reduce Motion keeps the attention cue but drops the movement: the
                    // shadow flash still draws the eye, the scale bounce and slide don't.
                    .scaleEffect(pulse && !reduceMotion ? 1.025 : 1.0)
                    .shadow(color: theme.warningColor.opacity(pulse ? 0.55 : 0), radius: pulse ? 14 : 0)
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
            }
        }
        // Match the composer's content lane exactly — this stack sits directly above it.
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
        .padding(.bottom, 6)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82),
                   value: current?.id)
        // Announces immediately: the banner's slide-in and flash are invisible to VoiceOver,
        // and execution is halted until the request is answered.
        .onChange(of: current?.id, initial: true) { _, _ in
            guard let pending = current else { return }
            let base = Self.announcement(for: pending)
            let text = queuedCount > 1 ? "\(base). 1 of \(queuedCount) requests awaiting input." : base
            AccessibilityAnnouncer.announce(text, urgency: .immediate)
        }
        // [HITL/E2] Flash the banner when the user taps an "awaiting input" node.
        .onChange(of: vm.interactionCenter.attentionPulse) { _, _ in
            guard current != nil else { return }
            let rise: Animation = reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.16, dampingFraction: 0.45)
            let fall: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.7)
            withAnimation(rise) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(fall) { pulse = false }
            }
        }
    }

    @ViewBuilder
    private func banner(for pending: PendingHITL) -> some View {
        switch pending.kind {
        case .toolConfirmation(let confirmation):
            PermissionInteractionBanner(pending: pending, confirmation: confirmation)
        case .clarification(let clarification):
            ClarificationInteractionBanner(pending: pending, clarification: clarification)
        case .planReview(let planReview):
            PlanReviewInteractionBanner(pending: pending, planReview: planReview)
        case .gate(let gate):
            GateInteractionBanner(pending: pending, gate: gate)
        }
    }

    /// Says what is being asked, not merely that something appeared — "the agent needs
    /// input" would leave the user hunting for what and where.
    static func announcement(for pending: PendingHITL) -> String {
        switch pending.kind {
        case .toolConfirmation(let confirmation):
            return String(localized: "Permission needed: \(confirmation.toolName). The agent is paused until you respond.")
        case .clarification:
            return String(localized: "The agent needs clarification before continuing.")
        case .planReview:
            return String(localized: "Plan review needed. The agent is paused until you approve or edit the plan.")
        case .gate(let gate):
            let deadline = gate.deadline != nil ? String(localized: " This will fail onto its error port if you don't respond.") : ""
            return String(localized: "Input needed: \(gate.prompt).\(deadline)")
        }
    }
}

// MARK: - Cross-conversation affordance

/// Floating, top-centered capsule for requests raised in other (unfocused, background, remote or scheduled) chats.
/// Distinct from the bottom banner; tapping navigates to the oldest waiting conversation.
struct CrossConversationInputChip: View {
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme

    var body: some View {
        let selected = vm.selectedConversationID
        let count = otherConversationCount(excluding: selected)
        return Group {
            if count > 0 {
                Button {
                    navigateToOtherConversation(excluding: selected)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(.caption2, weight: .semibold))
                        Text("\(count) other conversation\(count == 1 ? "" : "s") awaiting your input")
                            .font(.system(.caption, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(.caption2, weight: .semibold))
                    }
                    .foregroundColor(theme.warningColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .appSurface(
                        in: Capsule(),
                        elevation: .elevated,
                        strokeColor: theme.warningColor.opacity(0.3)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("\(count) other conversations awaiting your input. Activate to switch.")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: count)
    }

    /// Number of distinct OTHER conversations (not the focused one) with a pending HITL.
    private func otherConversationCount(excluding selected: UUID?) -> Int {
        Set(
            vm.interactionCenter.pending
                .lazy
                .filter { $0.origin.conversationID != selected }
                .map { $0.origin.conversationID }
        ).count
    }

    /// Navigate to the oldest other conversation that has a pending HITL. Routes through the VM so
    /// interfaceMode is aligned to the request's origin (correct dedicated view + sidebar) and the
    /// workflow edit-guard still fires for a dirty canvas.
    private func navigateToOtherConversation(excluding selected: UUID?) {
        guard let target = vm.interactionCenter.pending
            .first(where: { $0.origin.conversationID != selected })
        else { return }
        vm.navigateToPendingInteraction(
            conversationID: target.origin.conversationID,
            interface: target.origin.interface
        )
    }
}

// MARK: - Source-attribution helpers

/// SF Symbol for the originating interface — gives the banner header a glanceable origin cue (D2).
private func hitlInterfaceIcon(_ interface: HITLOrigin.Interface) -> String {
    switch interface {
    case .chat:      return "bubble.left.fill"
    case .code:      return "chevron.left.forwardslash.chevron.right"
    case .workflow:  return "point.3.connected.trianglepath.dotted"
    case .scheduled: return "clock.fill"
    }
}

/// Shared header row: interface icon + the origin title (e.g. "Security Agent · Question").
private struct InteractionHeader: View {
    let pending: PendingHITL
    let accent: Color
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: hitlInterfaceIcon(pending.origin.interface))
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(accent)
                .accessibilityHidden(true)

            Text(pending.origin.title)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(accent)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            InteractionAgeLabel(since: pending.timestamp)
        }
    }
}

/// [HITL ergonomics] Auto-updating "how long has this been waiting" label —
/// parks are deadline-free by design, so surface the age instead. `.relative`
/// keeps itself current without a timer.
private struct InteractionAgeLabel: View {
    let since: Date
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .medium))
            Text(since, style: .relative)
                .font(.system(.caption2, weight: .medium))
                .monospacedDigit()
        }
        .foregroundColor(theme.tertiaryText)
        .accessibilityLabel("Waiting for \(Text(since, style: .relative))")
    }
}

// MARK: - Permission Banner

private struct PermissionInteractionBanner: View {
    let pending: PendingHITL
    let confirmation: PendingToolConfirmation
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme

    @State private var isProcessing: Bool = false
    @State private var argsExpanded: Bool
    // A3: inline argument editing before approval.
    @State private var editing: Bool = false
    @State private var editedValues: [String: String] = [:]

    init(pending: PendingHITL, confirmation: PendingToolConfirmation) {
        self.pending = pending
        self.confirmation = confirmation
        // Destructive ops reveal their full arguments by default so what's at stake is visible.
        _argsExpanded = State(initialValue: confirmation.risk == .destructive)
    }

    /// A1: banner accent driven by the tool's risk tier. [Q3] Shared mapping via HITLRiskTier.color(in:).
    private var riskColor: Color { confirmation.risk.color(in: theme) }

    /// A1: pretty-printed structured arguments (nil if params weren't valid JSON or are empty).
    private var prettyArgs: String? {
        guard let args = confirmation.arguments else { return nil }
        switch args {                                      // empty {} / [] → no expand affordance
        case .object(let d) where d.isEmpty: return nil
        case .array(let a) where a.isEmpty:  return nil
        default: break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(args),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private var hasInlineParams: Bool {
        !confirmation.params.isEmpty && confirmation.params != "{}"
    }

    /// A2: a parsed file operation, when this confirmation is a file-mutating tool.
    private var fileChange: FileChange? {
        FileChange.parse(
            toolName: confirmation.toolName,
            arguments: effectiveArguments)
    }

    /// Top-level string arguments the user can correct before approving.
    /// Every argument is editable; long or multi-line values get a multi-line editor.
    private var editableArgs: [(key: String, value: String)] {
        guard case .object(let dict)? = confirmation.arguments else { return [] }
        return dict.compactMap { (k, v) -> (key: String, value: String)? in
            if case .string(let s) = v { return (key: k, value: s) }
            return nil
        }.sorted { $0.key < $1.key }
    }

    /// Values that can't be read or corrected on one line.
    private func needsMultilineEditor(_ value: String) -> Bool {
        value.contains("\n") || value.count > 120
    }

    /// The arguments as they stand right now — the model's, with any edits applied. Drives
    /// the diff preview so it keeps describing what Allow will ACTUALLY do.
    private var effectiveArguments: JSONValue? {
        guard case .object(let original)? = confirmation.arguments else { return confirmation.arguments }
        guard !editedValues.isEmpty else { return confirmation.arguments }
        var result = original
        for (key, value) in editedValues { result[key] = .string(value) }
        return .object(result)
    }

    /// True once the user has actually changed something away from the model's proposal.
    private var hasPendingEdits: Bool {
        editableArgs.contains { arg in
            guard let edited = editedValues[arg.key] else { return false }
            return edited != arg.value
        }
    }

    private func discardEdits() {
        withAnimation(.easeInOut(duration: 0.15)) {
            editedValues.removeAll()
            editing = false
        }
    }

    private var hasEditableArgs: Bool { !editableArgs.isEmpty }

    /// A3: false if the user blanked a field that originally had a value — that would fail the tool's
    /// required-argument validation server-side (after the banner is gone), so block the approve.
    private var editsValid: Bool {
        guard editing else { return true }
        for arg in editableArgs where !arg.value.isEmpty {
            let edited = editedValues[arg.key] ?? arg.value
            if edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        }
        return true
    }

    /// A3: the full arguments object with the user's string edits applied (nil when not editing).
    private func buildEditedArguments() -> [String: JSONValue]? {
        guard editing, case .object(let original)? = confirmation.arguments else { return nil }
        var result = original
        for (key, value) in editedValues { result[key] = .string(value) }
        return result
    }

    private func toggleEditing() {
        if !editing {
            // Seed only un-edited keys so closing/reopening the editor preserves in-progress edits.
            for arg in editableArgs where editedValues[arg.key] == nil {
                editedValues[arg.key] = arg.value
            }
        }
        withAnimation(.easeInOut(duration: 0.15)) { editing.toggle() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: source title + waiting age + risk pill (A1)
            HStack(spacing: 7) {
                Image(systemName: hitlInterfaceIcon(pending.origin.interface))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(riskColor)
                    .accessibilityHidden(true)
                Text(pending.origin.title)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(riskColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                InteractionAgeLabel(since: pending.timestamp)
                riskPill
            }

            // Tool + arguments
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText)
                        .accessibilityHidden(true)
                    Text(confirmation.toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 4)
                    if hasEditableArgs {
                        Button { toggleEditing() } label: {
                            Image(systemName: editing ? "checkmark.circle.fill" : "pencil")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundColor(editing ? theme.successColor : theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(editing ? "Done editing arguments" : "Edit arguments")
                    }
                    if !editing, fileChange == nil, prettyArgs != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { argsExpanded.toggle() }
                        } label: {
                            Image(systemName: argsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(argsExpanded ? "Hide arguments" : "Show arguments")
                    }
                }

                if editing {
                    // The diff stays visible while editing and reads from the edited arguments, so it tracks what Allow will write.
                    if let fileChange {
                        FileChangePreviewView(change: fileChange)
                    }

                    // A3: inline-editable string arguments. Scroll-capped so a tool with
                    // many args can't push the chat input off-screen.
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(editableArgs, id: \.key) { arg in
                                let binding = Binding(
                                    get: { editedValues[arg.key] ?? arg.value },
                                    set: { editedValues[arg.key] = $0 }
                                )
                                if needsMultilineEditor(arg.value) {
                                    // File content and other multi-line values get a real multi-line editor, not a one-line field.
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(arg.key)
                                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                .foregroundColor(theme.tertiaryText)
                                            Text("\(binding.wrappedValue.count) chars · \(binding.wrappedValue.components(separatedBy: "\n").count) lines")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(theme.tertiaryText.opacity(0.8))
                                            Spacer(minLength: 0)
                                        }
                                        // Not a plain `TextEditor`: macOS would substitute curly quotes and em dashes
                                        // in a value that is a file about to be written.
                                        VerbatimTextEditor(
                                            text: binding,
                                            textColor: theme.primaryText
                                        )
                                            .frame(minHeight: 120, maxHeight: 260)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 4)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay.opacity(0.6)))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.warningColor.opacity(0.4), lineWidth: 1))
                                    }
                                } else {
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(arg.key)
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundColor(theme.tertiaryText)
                                            .frame(minWidth: 48, alignment: .leading)
                                        // Also substitution-free: short file content and paths with `--` land here too.
                                        VerbatimTextEditor(
                                            text: binding,
                                            textColor: theme.primaryText,
                                            isSingleLine: true
                                        )
                                            .frame(height: 20)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay.opacity(0.6)))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.warningColor.opacity(0.4), lineWidth: 1))
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 330)

                    HStack(spacing: 8) {
                        if hasPendingEdits {
                            Text("Edited — Allow will use your version")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.warningColor)
                        }
                        Spacer(minLength: 0)
                        // Restores the model's proposal after edits; toggling the editor preserves edits,
                        // so otherwise only Deny and re-run would undo them.
                        Button(action: discardEdits) {
                            Text(hasPendingEdits ? "Discard edits" : "Cancel")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(hasPendingEdits
                              ? String(localized: "Restore the arguments the model proposed")
                              : String(localized: "Close the editor"))
                    }

                    if !editsValid {
                        Text("A field you edited can't be left empty.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.errorColor)
                    }
                } else if let fileChange {
                    // A2: file-mutating tools get a diff / source→destination preview.
                    FileChangePreviewView(change: fileChange)
                } else if let pretty = prettyArgs, argsExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(pretty)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                } else if hasInlineParams {
                    Text(confirmation.params)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.surfaceOverlay.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(riskColor.opacity(confirmation.risk == .destructive ? 0.4 : 0.0), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Spacer()
                if isProcessing {
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(height: 28)
                } else {
                    HITLActionButton(label: "Deny", icon: "xmark", style: .ghost, isDisabled: false, keyboardShortcut: .cancelAction) {
                        decide(approved: false)
                    }

                    // Standing approvals sit in one menu so the banner keeps two buttons. Each option is offered only where it applies.
                    if !standingOptions.isEmpty {
                        standingApprovalMenu
                    }

                    // Allow has no Return shortcut: the chat input claims Return window-wide, so it could approve mid-sentence.
                    // Approve is click-only; Esc denies.
                    HITLActionButton(
                        label: confirmation.risk == .destructive ? "Allow anyway" : "Allow",
                        icon: "checkmark",
                        style: .primary(color: confirmation.risk == .destructive ? theme.errorColor : theme.successColor),
                        isDisabled: !editsValid   // A3: block approving with a required field emptied
                    ) {
                        decide(approved: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .appSurface(in: .rect(cornerRadius: 16), elevation: .elevated)
    }

    // MARK: Standing approvals

    /// Which standing approvals this request may offer; an exact-call grant covers the user's edits when editing.
    private var standingOptions: StandingApprovalOptions {
        StandingApprovalOptions(for: pending, editedArguments: buildEditedArguments())
    }

    private var standingApprovalMenu: some View {
        let options = standingOptions
        return Menu {
            if let canonical = options.exactCallArguments {
                Button {
                    allowForRun(.exactCall(canonicalArguments: canonical))
                } label: {
                    Label("Allow this exact call for this run", systemImage: "checkmark.seal")
                }
            }
            if options.canAllowToolForRun {
                Button {
                    allowForRun(.anyArguments)
                } label: {
                    Label("Allow \(confirmation.toolName) for this run", systemImage: "checkmark.circle")
                }
            }
            if options.canAllowForChat {
                if options.canAllowExactCallForRun || options.canAllowToolForRun { Divider() }
                Button {
                    allowForThisConversation()
                } label: {
                    Label("Allow for this chat", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        } label: {
            Label("Allow…", systemImage: "checkmark.circle")
                .font(.system(.caption, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!editsValid)
        .help("Approve this request and keep approving matching ones")
        .accessibilityLabel("More ways to allow")
    }

    private func allowForRun(_ approval: RunApproval) {
        guard !isProcessing else { return }
        withAnimation { isProcessing = true }
        vm.allowToolForRun(pending, approval: approval, editedArguments: buildEditedArguments())
    }

    /// Trusts this tool for the rest of this conversation (persisted, scoped to this chat), then approves the request.
    /// Inside a workflow the grant is narrowed to the node that raised it; `origin.nodeID` is nil outside workflows.
    private func allowForThisConversation() {
        guard !isProcessing else { return }
        let tool = confirmation.toolName
        let conversationID = pending.origin.conversationID
        let nodeID = pending.origin.nodeID
        let edited = buildEditedArguments()   // capture @State on MainActor before hopping off it
        let scope = nodeID.map { "node \($0)" } ?? "conversation"
        bannerLogger.info("[HITL/UI] '\(tool)' ALLOW-FOR-CHAT by user — persisted to the \(scope)-scoped allowlist [conv \(conversationID)]")
        withAnimation { isProcessing = true }
        // Register the grant BEFORE the approval resume so the tool's next call in this run
        // already observes it — ordered by construction, not by Task timing.
        Task { @MainActor in
            await SessionToolApprovals.shared.allow(toolName: tool, risk: confirmation.risk, conversationID: conversationID, nodeID: nodeID)
            vm.submitToolApproval(operationID: pending.id, approved: true, editedArguments: edited)
        }
    }

    /// The one string both the visible pill and VoiceOver read, including the "(server-declared)" qualifier.
    /// The qualifier matters: a server-declared `.destructive` tier rests on an MCP server's unverified self-report.
    private var riskLabelText: String {
        confirmation.riskIsServerDeclared == true
            ? "\(confirmation.risk.label) (server-declared)"
            : confirmation.risk.label
    }

    private var riskPill: some View {
        HStack(spacing: 3) {
            Image(systemName: confirmation.risk.icon)
                .font(.system(size: 9, weight: .bold))
            Text(riskLabelText)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(riskColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(riskColor.opacity(0.12)))
        .accessibilityLabel("Risk: \(riskLabelText)")
    }

    private func decide(approved: Bool) {
        guard !isProcessing else { return }   // press-time guard (no double-fire before re-render)
        let edited = approved ? buildEditedArguments() : nil
        logDecision(approved: approved, edited: edited)
        withAnimation { isProcessing = true }
        // A3: apply the user's inline edits on approval. Dismissal is driven by InteractionCenter.resolve.
        vm.submitToolApproval(operationID: pending.id, approved: approved, editedArguments: edited)
    }

    /// Logs the user's banner decision with full context — denial, plain approval, or approval with the
    /// specific old→new argument edits — so the run log shows what the user actually did.
    private func logDecision(approved: Bool, edited: [String: JSONValue]?) {
        let tool = confirmation.toolName
        guard approved else {
            bannerLogger.info("[HITL/UI] '\(tool)' DENIED by user [op \(pending.id)]")
            return
        }
        if let edited, case .object(let original)? = confirmation.arguments {
            // Log only WHICH args were edited — the executed values already appear at the dispatch log,
            // and argument values can hold secrets/paths/commands we don't want to duplicate into logs.
            let changedKeys = edited.keys.sorted().filter { original[$0]?.stringValue != edited[$0]?.stringValue }
            if !changedKeys.isEmpty {
                bannerLogger.info("[HITL/UI] '\(tool)' APPROVED with edits to [\(changedKeys.joined(separator: ", "))] [op \(pending.id)]")
                return
            }
        }
        bannerLogger.info("[HITL/UI] '\(tool)' APPROVED by user [op \(pending.id)]")
    }
}

// MARK: - Clarification Banner

private struct ClarificationInteractionBanner: View {
    let pending: PendingHITL
    let clarification: PendingClarification
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme

    @State private var userInput: String = ""
    @State private var isSubmitting: Bool = false
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    private var hasOptions: Bool { !(clarification.options ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                InteractionHeader(pending: pending, accent: theme.streamingIndicator)
                Text("⎋ skip")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }

            Text(clarification.question)
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if let options = clarification.options, !options.isEmpty {
                // A5: one-tap choice buttons — answering picks an option directly. Capped + scrollable
                // so a long option list can't push the chat input off-screen.
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            optionChip(option)
                        }
                    }
                }
                .frame(maxHeight: 150)
                HStack(spacing: 8) { Spacer(); skipButton }
            } else if clarification.multiline {
                // A5: multi-line answer.
                TextEditor(text: $userInput)
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.primaryText)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 120)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isFocused ? theme.streamingIndicator.opacity(0.45) : theme.dividerColor.opacity(0.4), lineWidth: 1)
                    )
                HStack(spacing: 8) { Spacer(); skipButton; sendButton }
            } else {
                HStack(spacing: 8) {
                    TextField("Type your answer...", text: $userInput)
                        .textFieldStyle(.plain)
                        .font(theme.fontSubheadline)
                        .foregroundColor(theme.primaryText)
                        .focused($isFocused)
                        .onSubmit { if canSend { submit() } }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFocused ? theme.streamingIndicator.opacity(0.45) : theme.dividerColor.opacity(0.4), lineWidth: 1)
                        )
                    skipButton
                    sendButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .appSurface(in: .rect(cornerRadius: 16), elevation: .elevated)
        .onAppear { if !hasOptions { isFocused = true } }  // no field to focus in options mode
    }

    private var skipButton: some View {
        HITLActionButton(label: "Skip", icon: "arrow.uturn.left", style: .ghost, isDisabled: isSubmitting, keyboardShortcut: .cancelAction) {
            skip()   // B1: Esc — the "⎋ skip" hint is now real
        }
    }

    private var sendButton: some View {
        HITLActionButton(label: "Send", icon: "arrow.up", style: .primary(color: theme.streamingIndicator), isDisabled: !canSend) {
            submit()
        }
    }

    private func optionChip(_ option: String) -> some View {
        Button { send(option) } label: {
            Text(option)
                .font(.system(.caption, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.streamingIndicator.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !isSubmitting)
        .disabled(isSubmitting)
        .help(option)                              // full text on hover when truncated
        .accessibilityLabel("Answer: \(option)")
    }

    private func submit() { send(userInput) }

    private func send(_ text: String) {
        guard !isSubmitting else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation { isSubmitting = true }
        bannerLogger.info("[ASK_USER/UI] answered (\(trimmed.count) chars) [op \(pending.id)]")
        vm.submitClarificationResponse(operationID: pending.id, response: trimmed)
    }

    private func skip() {
        guard !isSubmitting else { return }
        withAnimation { isSubmitting = true }
        bannerLogger.info("[ASK_USER/UI] SKIPPED by user [op \(pending.id)]")
        vm.submitClarificationResponse(operationID: pending.id, response: nil)
    }
}

// MARK: - Gate Banner (E1 — per-option routing)

/// Renders a workflow Gate HITL: the prompt, a live countdown to the failure deadline, and one
/// button per configured option. Picking an option routes the workflow to that option's output port.
private struct GateInteractionBanner: View {
    let pending: PendingHITL
    let gate: PendingGate
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme
    @State private var isSubmitting = false
    /// Which countdown thresholds have already been spoken — the timer ticks every second,
    /// so without this the banner would repeat itself forever.
    @State private var announcedThresholds: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InteractionHeader(pending: pending, accent: theme.warningColor)

            Text(gate.prompt)
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if gate.deadline != nil {
                // Live countdown to the configured timeout; display only, not an auto-reject.
                // `WorkflowExecutor` enforces the timeout and fails the node with no option branch taken.
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    if let text = countdownText(now: context.date) {
                        Label(text, systemImage: "timer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.warningColor)
                            .accessibilityLabel(text)
                            // Speaks only at thresholds, since announcing every tick would talk over the app; the deadline must be perceivable.
                            .onChange(of: Int(max(0, gate.deadline?.timeIntervalSince(context.date) ?? 0))) { _, remaining in
                                announceCountdownIfNeeded(remaining)
                            }
                    }
                }
            }

            if let input = gate.inputText, !input.isEmpty {
                highlightedInput(input)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Array(gate.options.enumerated()), id: \.offset) { _, option in
                        gateButton(option)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .appSurface(in: .rect(cornerRadius: 16), elevation: .elevated)
    }

    private func countdownText(now: Date) -> String? {
        guard let deadline = gate.deadline else { return nil }
        let remaining = max(0, deadline.timeIntervalSince(now))
        if remaining <= 0 { return String(localized: "Timing out…") }
        let m = Int(remaining) / 60, s = Int(remaining) % 60
        return m > 0 ? String(format: String(localized: "Fails in %d:%02d"), m, s) : String(localized: "Fails in \(s)s")
    }

    /// Speaks the deadline at a few thresholds — enough warning to act, not a metronome.
    /// Each fires once: the timer ticks every second and re-entering would make the banner
    /// repeat itself indefinitely.
    private func announceCountdownIfNeeded(_ remaining: Int) {
        let thresholds = [30, 10]
        guard let crossed = thresholds.first(where: { remaining == $0 }),
              !announcedThresholds.contains(crossed) else { return }
        announcedThresholds.insert(crossed)
        AccessibilityAnnouncer.announce(
            String(localized: "\(crossed) seconds left to respond, or this node fails onto its error port."),
            urgency: .immediate
        )
    }

    /// One hue per option, shared by the button border and that rule's highlighted spans — the
    /// colour IS the association, so it must be derived from the option list identically in both
    /// places. Index-based rather than hashed so the pairing is stable and predictable.
    private static let optionHues: [Color] = [.green, .yellow, .cyan, .orange, .purple]

    private func hue(for option: String) -> Color {
        guard let idx = gate.options.firstIndex(of: option) else { return theme.warningColor }
        return Self.optionHues[idx % Self.optionHues.count]
    }

    /// The input the decision is about, with each rule's matched text painted in that rule's colour.
    /// Calls `SearchHighlighter.applyHighlights` once per rule; where rules overlap, the later pass wins.
    /// Offsets are character offsets against `gate.inputText` as the executor measured them.
    @ViewBuilder
    private func highlightedInput(_ input: String) -> some View {
        let attributed: AttributedString = {
            var attr = AttributedString(input)
            for option in gate.options {
                let offsets = gate.highlights
                    .filter { $0.label == option }
                    .map { SearchHighlighter.MatchOffset(start: $0.start, end: $0.end) }
                guard !offsets.isEmpty else { continue }
                let colour = hue(for: option).opacity(0.35)
                SearchHighlighter.applyHighlights(
                    to: &attr, offsets: offsets, activeIndex: nil, base: colour, active: colour)
            }
            return attr
        }()

        ScrollView(.vertical, showsIndicators: true) {
            Text(attributed)
                .font(.system(.caption))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 120)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.surfaceOverlay.opacity(0.35)))
        // Highlights exist only for a Router arbitration; a Gate node's input is up for approval, not routing.
        .accessibilityLabel(gate.highlights.isEmpty ? "Input awaiting your decision: \(input)" : "Input being routed: \(input)")
    }

    private func gateButton(_ option: String) -> some View {
        Button { choose(option) } label: {
            Text(option)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke((gate.highlights.isEmpty ? theme.warningColor : hue(for: option)).opacity(0.75), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !isSubmitting)
        .disabled(isSubmitting)
        .help(option)
        .accessibilityLabel("Choose: \(option)")
    }

    private func choose(_ option: String) {
        guard !isSubmitting else { return }
        withAnimation { isSubmitting = true }
        bannerLogger.info("[GATE/UI] chose '\(option)' [op \(pending.id)]")
        vm.submitGateChoice(operationID: pending.id, option: option)
    }
}

// MARK: - Plan Review Banner

private struct PlanReviewInteractionBanner: View {
    let pending: PendingHITL
    let planReview: PendingPlanReview
    @Environment(MainApplicationViewModel.self) private var vm
    @Environment(\.appTheme) private var theme

    @State private var editableSubtasks: [SubTask] = []
    @State private var isProcessing: Bool = false

    private var canApprove: Bool {
        !editableSubtasks.isEmpty &&
        !editableSubtasks.contains(where: { $0.description.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                InteractionHeader(pending: pending, accent: theme.streamingIndicator)
                Text("\(editableSubtasks.count) step\(editableSubtasks.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach($editableSubtasks) { $subtask in
                        let displayIndex = editableSubtasks.firstIndex(where: { $0.id == subtask.id })
                        PlanReviewInteractionSubtaskRow(
                            subtask: $subtask,
                            index: displayIndex ?? 0,
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    editableSubtasks.removeAll { $0.id == subtask.id }
                                }
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        // The default init mints a UUID id; a count-derived id could collide with an existing one after a delete.
                        editableSubtasks.append(SubTask(description: ""))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(.system(.caption2))
                        Text("Add Step").font(.system(.caption, weight: .medium))
                    }
                    .foregroundColor(theme.streamingIndicator.opacity(0.8))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer()

                if editableSubtasks != planReview.subtasks {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { editableSubtasks = planReview.subtasks }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise").font(.system(.caption2))
                            Text("Reset").font(.system(.caption, weight: .medium))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if isProcessing {
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(height: 28)
                } else {
                    HITLActionButton(label: "Reject", icon: "xmark", style: .ghost, isDisabled: false, keyboardShortcut: .cancelAction) {
                        reject()
                    }
                    HITLActionButton(label: "Approve & Run", icon: "play.fill", style: .primary(color: theme.successColor), isDisabled: !canApprove) {
                        approve()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .appSurface(in: .rect(cornerRadius: 16), elevation: .elevated)
        .onAppear { editableSubtasks = planReview.subtasks }
    }

    private func approve() {
        guard !isProcessing else { return }
        withAnimation { isProcessing = true }
        vm.submitPlanReview(operationID: pending.id, editedPlan: editableSubtasks)
    }

    private func reject() {
        guard !isProcessing else { return }
        withAnimation { isProcessing = true }
        vm.submitPlanReview(operationID: pending.id, editedPlan: nil)
    }
}

private struct PlanReviewInteractionSubtaskRow: View {
    @Binding var subtask: SubTask
    let index: Int
    let onDelete: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme.streamingIndicator.opacity(0.7))
                .frame(width: 18, alignment: .center)

            TextField("Subtask description", text: $subtask.description)
                .textFieldStyle(.plain)
                .font(.system(.caption))
                .foregroundColor(theme.primaryText)

            if let hints = subtask.toolHints, !hints.isEmpty {
                ForEach(hints, id: \.self) { hint in
                    Text(hint)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.surfaceOverlay.opacity(0.6)))
                }
            }

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(.caption))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("Delete step")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay.opacity(0.4)))
    }
}

// MARK: - Shared Action Button

private enum HITLButtonStyle {
    case ghost
    case primary(color: Color)
}

private struct HITLActionButton: View {
    let label: String
    let icon: String
    let style: HITLButtonStyle
    let isDisabled: Bool
    var keyboardShortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var isHovering = false

    private var isPrimaryContrast: Bool {
        if case .primary = style, buttonAccentStyle == .themeContrast {
            return true
        }
        return false
    }

    private var bgColor: Color {
        switch style {
        case .ghost:
            return isHovering ? theme.surfaceOverlay : Color.clear
        case .primary:
            if buttonAccentStyle == .themeContrast {
                // Style 2: High-contrast solid keycap
                if isDisabled {
                    return theme.isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.20)
                }
                return theme.isDark
                    ? (isHovering ? Color.white : Color.white.opacity(0.95))
                    : (isHovering ? Color.black : Color(red: 0.12, green: 0.12, blue: 0.14))
            }
            // Style 3: Tactile Glass Surface (translucent dark overlay)
            return isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay
        }
    }

    private var iconColor: Color {
        if isDisabled {
            return labelColor
        }
        switch style {
        case .ghost:
            return isHovering ? theme.primaryText : theme.secondaryText
        case .primary(let color):
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            // Style 3: Vibrant semantic/accent icon
            return color
        }
    }

    private var labelColor: Color {
        if isDisabled {
            if isPrimaryContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08).opacity(0.40) : Color.white.opacity(0.40)
            }
            return theme.secondaryText.opacity(0.45)
        }
        switch style {
        case .ghost:
            return isHovering ? theme.primaryText : theme.secondaryText
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            // Style 3: Clean primary white text
            return isHovering ? theme.primaryText : theme.primaryText.opacity(0.95)
        }
    }

    private var borderColor: Color {
        switch style {
        case .ghost:
            return isHovering ? theme.secondaryText.opacity(0.25) : theme.dividerColor.opacity(0.4)
        case .primary(let color):
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color.white.opacity(0.4) : Color.black.opacity(0.2)
            }
            // Style 3: Subtle border glowing with semantic color on hover
            return isDisabled ? color.opacity(0.15) : (isHovering ? color.opacity(0.65) : color.opacity(0.32))
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(label)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(labelColor)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(bgColor))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(borderColor, lineWidth: 1))
            .shadow(
                color: isHovering && !isDisabled && isPrimaryContrast
                    ? Color.black.opacity(0.30)
                    : (isHovering && !isDisabled ? semanticGlowColor.opacity(0.25) : Color.clear),
                radius: 3,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !isDisabled)
        .disabled(isDisabled)
        .keyboardShortcut(keyboardShortcut)   // B1: nil = no shortcut
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovering = h } }
        .scaleEffect(isHovering && !isDisabled ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
    }

    private var semanticGlowColor: Color {
        switch style {
        case .ghost: return Color.clear
        case .primary(let color): return color
        }
    }
}
