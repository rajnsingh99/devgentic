// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileSidebarListView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The inline sidebar list of backend profiles; tapping one routes its detail into the main content via `MainViewRouter`.
struct ProfileSidebarListView: View {

    @Environment(BackendProfileService.self) private var profileService
    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    /// `ProfileType?` (nil = All) rather than a `String`, so the chip's display label is separate from its filter key
    /// and can be localized.
    @State private var selectedTypeFilter: ProfileType? = nil
    @State private var isAddingProfile = false
    @State private var showingDeleteAlert = false
    @State private var profileToDelete: BackendProfileModel? = nil
    @State private var profileToDuplicate: BackendProfileModel? = nil

    // Unsaved-changes navigation guard
    @State private var pendingProfileID: UUID? = nil
    @State private var showingDiscardAlert = false

    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var focusedProfileID: UUID? = nil

    private let typeFilters: [ProfileType?] = [nil] + ProfileType.allCases.filter { $0 != .code }

    /// Code profiles are hidden from the sidebar — managed by CodeSessionManager.
    private var filteredProfiles: [BackendProfileModel] {
        // Uses `sharedProfiles`, not `profiles`: a workflow node's owned configuration row never appears in the sidebar.
        // The `.code` exclusion (an internal profile type) is separate and also applies.
        var result = profileService.sharedProfiles.filter { $0.profileType != .code }

        // Type filter
        if let selectedTypeFilter {
            result = result.filter { $0.profileType == selectedTypeFilter }
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    /// The currently-displayed profile ID (derived from the router destination).
    private var activeProfileID: UUID? {
        if case .profileDetail(let id) = router.activeDestination { return id }
        if case .toolLibrary(let id) = router.activeDestination { return id }
        return nil
    }

    /// While the Tool Library is the active destination for a profile, this pane hosts the library's navigation.
    /// Derived from the router, not stored, so returning to the profile list follows from the destination changing.
    private var isShowingToolLibrary: Bool {
        if case .toolLibrary(let profileID) = router.activeDestination, profileID != nil { return true }
        return false
    }

    var body: some View {
        if isShowingToolLibrary {
            ToolNavigationPane(host: .profilesTab)
        } else {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SidebarHeaderView(
                title: "Profiles",
                buttonTitle: "New Profile",
                systemImage: "plus",
                shortcut: "⌘N",
                onAction: { isAddingProfile = true }
            )
            .keyboardShortcut("n", modifiers: [.command])
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            SidebarSearchBarView("Search profiles", text: $searchText)
                .focused($isSearchFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // Type filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(typeFilters, id: \.self) { filter in
                        CategoryChip(
                            title: filter?.localizedTitle ?? "All",
                            isSelected: selectedTypeFilter == filter,
                            action: { selectedTypeFilter = filter }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 10)

            // Stale-list banner: `loadProfiles()` keeps the in-memory list when a later fetch throws, so the sidebar may be stale.
            // Keyed on `sharedProfiles`, matching the list shown; "could not read" never renders like "nothing here".
            if let loadError = profileService.lastLoadError, !profileService.sharedProfiles.isEmpty {
                staleListBanner(loadError)
            }

            // Profile list
            if filteredProfiles.isEmpty {
                if profileService.sharedProfiles.isEmpty {
                    // A failed first load shows the load error, not a first-run empty state, so a user with a populated store is not
                    // offered "New Profile".
                    if let loadError = profileService.lastLoadError {
                        SidebarEmptyStateView(
                            title: "Couldn't Load Profiles",
                            subtitle: "\(loadError)\n\nYour profiles have not been deleted — they could not be read.",
                            buttonTitle: "Retry",
                            buttonIcon: "arrow.clockwise",
                            systemImage: "exclamationmark.triangle",
                            onAction: { profileService.loadProfiles() }
                        )
                    } else {
                        SidebarEmptyStateView(
                            title: "No Profiles",
                            subtitle: "Create an AI profile to get started.",
                            buttonTitle: "New Profile",
                            buttonIcon: "plus",
                            systemImage: "cpu",
                            onAction: { isAddingProfile = true }
                        )
                    }
                } else {
                    SidebarEmptyStateView(
                        title: "No matches",
                        subtitle: "No profiles found for \"\(searchText)\"",
                        buttonTitle: "Clear Search",
                        systemImage: "magnifyingglass",
                        onAction: { searchText = "" }
                    )
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(filteredProfiles) { profile in
                                ProfileRowView(
                                    profile: profile,
                                    isSelected: activeProfileID == profile.id,
                                    isFocused: isListFocused && focusedProfileID == profile.id,
                                    onSelect: {
                                        focusedProfileID = profile.id
                                        selectProfile(profile)
                                    },
                                    onDuplicate: {
                                        profileToDuplicate = profile
                                    },
                                    onDelete: {
                                        profileToDelete = profile
                                        showingDeleteAlert = true
                                    },
                                    onRename: { newName in
                                        renameProfile(profile, to: newName)
                                    }
                                )
                                .id(profile.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .scrollContentBackground(.hidden)
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        moveFocus(direction, proxy: proxy)
                    }
                    .onKeyPress(.return) {
                        if let id = focusedProfileID,
                           let profile = filteredProfiles.first(where: { $0.id == id }) {
                            selectProfile(profile)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.delete) {
                        if let id = focusedProfileID,
                           let profile = filteredProfiles.first(where: { $0.id == id }) {
                            profileToDelete = profile
                            showingDeleteAlert = true
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress { press in
                        if press.modifiers.contains(.command) {
                            if press.key == "d" {
                                if let id = focusedProfileID,
                                   let profile = filteredProfiles.first(where: { $0.id == id }) {
                                    profileToDuplicate = profile
                                    return .handled
                                }
                            } else if press.key == "f" {
                                isSearchFocused = true
                                return .handled
                            }
                        }
                        return .ignored
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView(
                existingProfileNames: profileService.sharedProfiles.map(\.displayName)
            ) { newProfile in
                // Deliberately not caught: the throw keeps the sheet open with the user's name and type intact.
                try profileService.saveProfile(newProfile)
                router.navigateToProfile(newProfile.id, activatingBufferOn: profileService)
            }
        }
        .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                // On a throw the user gets a toast and stays in the profile being edited, as the create/duplicate arms do.
                do {
                    try profileService.deleteProfile(withId: profile.id)
                    if activeProfileID == profile.id {
                        router.returnToChat()
                    }
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            // The message names the consequences beyond the profile itself (e.g. a scheduled task that depends on it),
            // since the warning is only useful before the delete.
            Text(ProfileReferenceIndex.deletionMessage(for: profile, in: profileService.profiles))
        }
        .sheet(item: $profileToDuplicate) { source in
            DuplicateProfileSheet(
                sourceProfile: source,
                existingProfileNames: profileService.sharedProfiles.map(\.displayName)
            ) { duplicate in
                do {
                    try profileService.saveProfile(duplicate)
                    router.navigateToProfile(duplicate.id, activatingBufferOn: profileService)
                    toastManager.show("Profile duplicated", style: .success)
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
        }
        .confirmationDialog("Unsaved Changes", isPresented: $showingDiscardAlert) {
            // Offered only when a canvas is dirty; the field editor has its own Save pill.
            if profileService.canvasEditGuard.hasUnsavedChanges {
                Button("Save Changes") {
                    profileService.canvasEditGuard.saveHook?()
                    if let id = pendingProfileID {
                        router.navigateToProfile(id, activatingBufferOn: profileService)
                    }
                    pendingProfileID = nil
                }
            }
            Button("Discard Changes", role: .destructive) {
                // Actually discards: navigating away alone does not reset a canvas, whose state outlives the row change.
                profileService.canvasEditGuard.discardHook?()
                if let id = pendingProfileID {
                    router.navigateToProfile(id, activatingBufferOn: profileService)
                }
                pendingProfileID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingProfileID = nil
            }
        } message: {
            Text("You have unsaved changes. Discard them?")
        }
        .onAppear {
            if focusedProfileID == nil {
                focusedProfileID = activeProfileID
            }
        }
        .onChange(of: activeProfileID) { _, newID in
            if let newID {
                focusedProfileID = newID
            }
        }
        .onChange(of: filteredProfiles.map(\.id)) { _, newIDs in
            if let id = focusedProfileID, !newIDs.contains(id) {
                focusedProfileID = newIDs.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProfile)) { _ in
            isAddingProfile = true
        }
        }
    }

    private func selectProfile(_ profile: BackendProfileModel) {
        profileService.flushPendingEditorText()
        if profileService.hasUnsavedEditorChanges && activeProfileID != profile.id {
            pendingProfileID = profile.id
            showingDiscardAlert = true
        } else {
            router.navigateToProfile(profile.id, activatingBufferOn: profileService)
        }
    }

    /// Returns false on a refused rename (empty, duplicate, or a failed write) so the row keeps its field open.
    private func renameProfile(_ profile: BackendProfileModel, to newName: String) -> Bool {
        do {
            try profileService.renameProfile(withId: profile.id, to: newName)
            return true
        } catch {
            toastManager.show(error.localizedDescription, style: .error)
            return false
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard !filteredProfiles.isEmpty else { return }
        let currentID = focusedProfileID ?? activeProfileID ?? filteredProfiles.first?.id
        guard let currentID,
              let currentIndex = filteredProfiles.firstIndex(where: { $0.id == currentID }) else {
            focusedProfileID = filteredProfiles.first?.id
            return
        }

        switch direction {
        case .up:
            let prevIndex = max(0, currentIndex - 1)
            let profile = filteredProfiles[prevIndex]
            focusedProfileID = profile.id
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(profile.id, anchor: .center)
            }
        case .down:
            let nextIndex = min(filteredProfiles.count - 1, currentIndex + 1)
            let profile = filteredProfiles[nextIndex]
            focusedProfileID = profile.id
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(profile.id, anchor: .center)
            }
        default:
            break
        }
    }

    /// Compact "this list may be stale" strip for a load failure that left profiles in memory.
    /// Not the full empty-state treatment: a usable list remains, so it warns and offers a retry.
    @ViewBuilder
    private func staleListBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(theme.warningColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("This list may be out of date")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.primaryText)
                Text(message)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button("Retry") { profileService.loadProfiles() }
                .buttonStyle(.plain)
                .font(theme.fontCaption)
                .foregroundColor(theme.accentColor)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.12))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
