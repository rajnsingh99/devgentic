// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendProfileDetailView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// MARK: - Backend Profile Detail View

/// Detail editor for a unified `BackendProfileModel`; wrapped by `ProfileDetailContainerView`.
struct BackendProfileDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    /// The app view model, present only to source the shared `WorkflowCanvasState` for a workflow profile.
    /// Injected at the app root, so it is available even though this view is reached through the Profiles destination.
    @Environment(MainApplicationViewModel.self) private var mainViewModel

    /// Set when this profile's stored blob could not be decoded; holds the surviving columns for the warning.
    /// `@State`, refreshed in `.task(id:)` and never read from `body`, because the query primes a JSON decode.
    @State private var unreadable: BackendProfileStore.UnreadableProfileInfo?
    @State private var showingDiscardAlert = false

    /// True when the profile has an API key but the Keychain would not hand it over (locked, or an access prompt denied).
    /// Without it the key field shows empty, like a profile with no key. Same `@State`-not-`body` rule as `unreadable`.
    @State private var providerKeyUnreadable = false

    var body: some View {
        VStack(spacing: 0) {
            // Above the switch so it covers every profile type: a corrupted Agent decodes to the `.bot` placeholder and routes to
            // `BotConfigDetailView`, where its tools and capabilities are not rendered at all, so nothing looks missing.
            if let unreadable {
                unreadableConfigurationWarning(unreadable)
            }
            if providerKeyUnreadable {
                unreadableProviderKeyWarning
            }

            Group {
                switch editBuffer.draft.profileType {
                case .bot:
                    BotConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
                case .agent:
                    AgentConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
                case .workflow:
                    // `editGuard` is the only way canvas dirt reaches the sidebar's navigation guard; `canvasState` must come from
                    // `MainApplicationViewModel.workflowCanvasState(for:)`, so every surface edits one state object per workflow.
                    WorkflowCanvasView(
                        profile: $editBuffer.draft,
                        onDelete: onDelete,
                        editGuard: profileService.canvasEditGuard,
                        canvasState: mainViewModel.workflowCanvasState(for: editBuffer.draft.id)
                    )
                case .imageGen:
                    ImageGenConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
                case .code:
                    // Code mode uses the dedicated Code interface, not profile-based config.
                    // This case should not be reachable, but handle gracefully.
                    Text("Code sessions are configured via the Code interface.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: editBuffer.draft.id) {
            unreadable = BackendProfileStore.shared.unreadableProfiles()
                .first { $0.id == editBuffer.draft.id }
            providerKeyUnreadable = BackendProfileStore.shared.isProviderKeyUnreadable(for: editBuffer.draft.id)
        }
        // Two alerts, because the reasons have opposite correct actions: a profile from a newer build is intact but unreadable
        // here, so its alert offers no destructive button.
        .alert(
            unreadable?.reason == .undecodable
                ? "Discard the unreadable configuration?"
                : "This profile is from a newer version",
            isPresented: $showingDiscardAlert
        ) {
            if unreadable?.reason == .undecodable {
                Button("Discard and Reconfigure", role: .destructive) { discardUnreadableConfiguration() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            if case .writtenByNewerBuild(let storedVersion) = unreadable?.reason {
                Text(
                    "\(unreadable?.displayName ?? "This profile") was saved by a newer version of "
                    + "Devgentic (configuration format \(storedVersion); this build reads up to "
                    + "\(ProfileBlobGate.currentVersion)). Its settings are intact and untouched — "
                    + "update Devgentic to use it again.\n\nDo not reconfigure it here: saving on this "
                    + "version would replace the newer settings permanently."
                )
            } else {
                Text(
                    "This profile was saved as \(unreadable?.wasSummary ?? "an earlier configuration"), but "
                    + "this version can't read it. Discarding replaces it with a fresh, empty profile of the "
                    + "same type — the original settings are gone for good and a future version will no "
                    + "longer be able to recover them."
                )
            }
        }
    }

    /// Warns without blocking; it is deliberately not a save gate, so the user knows they are overwriting recoverable data.
    /// The type must be visible: the row still says Agent while the form shows Bot.
    @ViewBuilder
    private func unreadableConfigurationWarning(_ info: BackendProfileStore.UnreadableProfileInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("This profile's configuration could not be read")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                if !info.wasSummary.isEmpty {
                    Text("It was saved as \(info.wasSummary). The fields below are a blank placeholder, not your settings.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                Text("Your original data is preserved. Saving now replaces it permanently.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 8)

            TactileButton(
                title: "Discard and Reconfigure",
                icon: "arrow.triangle.2.circlepath",
                variant: .destructive,
                size: .compact
            ) {
                showingDiscardAlert = true
            }
        }
        .padding(.horizontal, ViewLayout.containerPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(theme.warningColor.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.warningColor.opacity(0.35)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Warning. This profile's configuration could not be read. It was saved as "
            + "\(info.wasSummary). Your original data is preserved; saving now replaces it permanently."
        )
    }

    /// Warns without blocking, like the configuration warning above.
    private var unreadableProviderKeyWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.slash")
                .foregroundColor(theme.warningColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("This profile's API key couldn't be read from the Keychain")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text("Your key is still stored — it is not lost, and you don't need to enter it again. The Keychain may be locked, or access was denied after an update. Choose Always Allow if macOS asks, then try again.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 8)

            TactileButton(
                title: "Try Again",
                icon: "arrow.clockwise",
                variant: .secondary,
                size: .compact
            ) {
                retryProviderKeyRead()
            }
        }
        .padding(.horizontal, ViewLayout.containerPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(theme.warningColor.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.warningColor.opacity(0.35)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Warning. This profile's API key couldn't be read from the Keychain. The key is still "
            + "stored; you don't need to enter it again."
        )
    }

    private func retryProviderKeyRead() {
        let id = editBuffer.draft.id
        guard BackendProfileStore.shared.retryProviderKeyRead(for: id) else {
            toastManager.show("The Keychain still won't release this key. See the log for details.", style: .error)
            return
        }
        providerKeyUnreadable = false
        // Reload the draft only when it holds no edits, since `load` would destroy them; a dirty draft is safe to save because
        // the model's sticky clear-suppression refuses to treat the missing key as the user clearing it.
        if !editBuffer.isDirty, let fresh = try? BackendProfileStore.shared.fetchProfile(byId: id) {
            editBuffer.load(fresh)
            toastManager.show("API key restored.", style: .success)
        } else {
            toastManager.show("API key is readable again. Save or revert your edits to see it.", style: .success)
        }
    }

    private func discardUnreadableConfiguration() {
        guard let unreadable else { return }
        let didDiscard = BackendProfileStore.shared.discardUnreadableConfiguration(
            for: unreadable.id, reason: "user chose Discard and Reconfigure in the profile editor"
        )
        guard didDiscard else {
            // A toast is still needed: the user accepted a destructive confirmation and a lingering banner reads as a frozen button.
            // The wording names no cause, since benign and hard failures look the same from here; the log carries the difference.
            toastManager.show(
                "Could not reset this profile's configuration. See the log for details.",
                style: .error
            )
            return
        }
        self.unreadable = nil
        profileService.loadProfiles()
    }
}

// MARK: - Profile Row View
struct ProfileRowView: View {
    let profile: BackendProfileModel
    let isSelected: Bool
    var isFocused: Bool = false
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    /// Persists a new name; returns false when the rename was refused, which keeps the field open with the user's text.
    let onRename: (String) -> Bool

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var editableName = ""
    @FocusState private var isRenameFieldFocused: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ProfileTypeIcon(
                type: profile.profileType,
                size: 18,
                color: color(for: profile.profileType),
                isHovered: isHovering
            )
            .frame(width: 24)

            if isRenaming {
                renameField
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text(profile.profileType.localizedTitle)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering || isFocused)
        .overlay(alignment: .trailing) {
            if isHovering && !isRenaming {
                HoverActionButton(
                    icon: "trash",
                    tint: .red.opacity(0.8),
                    action: onDelete
                )
                .accessibilityLabel("Delete \(profile.displayName)")
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .contentShape(Rectangle())
        .pointingHandCursor(enabled: !isRenaming)
        // `accessibilityLabel(_: String)` does not localize; the `Text` overload does, and a
        // nested `Text` keeps the type name translatable inside the composed phrase.
        .accessibilityLabel(Text("\(profile.displayName), \(Text(profile.profileType.localizedTitle))"))
        .onTapGesture {
            if !isRenaming { onSelect() }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    /// The inline name editor: Return or the save button commits, Escape cancels.
    private var renameField: some View {
        HStack(spacing: 6) {
            TextField("", text: $editableName, prompt: Text("Profile name").foregroundColor(.secondary.opacity(0.7)))
                .textFieldStyle(.plain)
                .font(theme.fontFootnote.weight(.medium))
                .focused($isRenameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand(perform: cancelRename)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(theme.surfaceOverlayStrong)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HoverActionButton(
                icon: "checkmark",
                tint: theme.accentColor,
                action: { commitRename() }
            )
            .disabled(trimmedEditableName.isEmpty)
            .help("Save name")
            .accessibilityLabel("Save name")
        }
        .onChange(of: isRenameFieldFocused) { _, focused in
            // Clicking elsewhere commits, as Finder does; a refused name is dropped rather than re-grabbing focus the user moved.
            guard !focused, isRenaming else { return }
            if !commitRename(refocusOnFailure: false) { cancelRename() }
        }
    }

    private var trimmedEditableName: String {
        editableName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginRename() {
        editableName = profile.displayName
        isRenaming = true
        // Deferred one turn: the field does not exist until this state change renders.
        DispatchQueue.main.async { isRenameFieldFocused = true }
    }

    /// Returns whether the field closed with the name saved (or unchanged).
    @discardableResult
    private func commitRename(refocusOnFailure: Bool = true) -> Bool {
        guard isRenaming, !trimmedEditableName.isEmpty else { return false }
        if trimmedEditableName == profile.displayName || onRename(trimmedEditableName) {
            isRenaming = false
            return true
        }
        if refocusOnFailure { isRenameFieldFocused = true }
        return false
    }

    private func cancelRename() {
        isRenaming = false
        editableName = ""
    }

    private func iconName(for type: ProfileType) -> String {
        type.iconName
    }

    private func color(for type: ProfileType) -> Color {
        type.displayColor
    }
}

// MARK: - Duplicate Profile Sheet

/// A lightweight sheet that lets the user choose a name before duplicating a profile.
struct DuplicateProfileSheet: View {
    let sourceProfile: BackendProfileModel
    let existingProfileNames: [String]
    let onConfirm: (BackendProfileSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var displayName: String = ""

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        let lower = trimmedName.lowercased()
        return !lower.isEmpty && existingProfileNames.contains(where: { $0.lowercased() == lower })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.system(.title3))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Profile")
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                    Text("From '\(sourceProfile.displayName)'")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Name field
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile Name")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)

                TextField("Enter a name for the duplicate", text: $displayName)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isDuplicateName ? theme.warningColor : theme.dividerColor, lineWidth: 1)
                    )

                if isDuplicateName {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption))
                        Text("A profile named '\(trimmedName)' already exists.")
                            .font(.system(.caption))
                    }
                    .foregroundColor(theme.warningColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                TactileButton(
                    title: "Cancel",
                    variant: .secondary,
                    size: .regular
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                TactileButton(
                    title: "Duplicate",
                    icon: "doc.on.doc",
                    variant: .primary,
                    size: .regular,
                    isDisabled: trimmedName.isEmpty
                ) {
                    onConfirm(sourceProfile.duplicated(as: trimmedName))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420)
        .background(theme.primaryBackground)
        .onAppear {
            displayName = "\(sourceProfile.displayName) (Copy)"
        }
    }
}

