// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendProfileService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI
import OSLog

private let logger = DGLogger(category: "BackendProfileService")

/// The central service for the Backend Profile UI: holds the profile list and persists changes.
/// Change tracking lives in `ProfileEditBuffer`; detail views call `saveProfile(_:)` only on an explicit save.
@Observable @MainActor
final class BackendProfileService {

    /// Every persisted profile row, including workflow-node-owned ones; reflects the last-persisted state.
    /// Do not bind a user-facing picker to this; use `sharedProfiles`.
    /// Unfiltered because the executor and node inspector resolve owned rows by id.
    var profiles: [BackendProfileModel] = []

    /// The profiles in the user's shared library: everything a picker may offer.
    /// Every surface that lets a user choose a profile reads this, so the rule lives in one place.
    var sharedProfiles: [BackendProfileModel] {
        profiles.filter { !$0.isNodeOwned }
    }

    /// The active edit buffer for the currently selected profile.
    /// Owned by the service so the panel view's navigation guard can check `editBuffer?.isDirty`.
    var editBuffer: ProfileEditBuffer?

    /// Dirty state of a workflow canvas hosted inside the profile editor.
    /// Owned here so the sidebar's navigation guard can see it: canvas geometry lives outside `editBuffer.draft`.
    let canvasEditGuard = WorkflowEditGuard()

    /// Called with a profile's ID after it is deleted, so owners of per-profile caches can prune.
    /// Ignored by observation: set once at launch.
    @ObservationIgnored var onProfileDeleted: ((UUID) -> Void)?

    /// Commits a floating prompt editor's pending text back into `editBuffer.draft`.
    /// Registered by `AgentConfigDetailView` while it is on screen, nil otherwise.
    /// Registered by the owner because quitting has no teardown to commit on.
    var commitPendingPromptEdits: (() -> Void)?

    /// Flushes any floating prompt editor's pending text into the draft; call before reading `hasUnsavedEditorChanges`.
    /// A separate call, not a property side effect, so view bodies never mutate the draft during an update pass.
    func flushPendingEditorText() {
        commitPendingPromptEdits?()
    }

    /// Whether anything in the profile editor has unsaved work: the field edit buffer or a hosted workflow canvas.
    /// Navigation guards must use this; text in a floating prompt editor is not visible until `flushPendingEditorText()`.
    var hasUnsavedEditorChanges: Bool {
        editBuffer?.isDirty == true || canvasEditGuard.hasUnsavedChanges
    }

    private let profileStore: BackendProfileStoreProtocol

    /// Initializes the service, optionally with a specific store for testing.
    /// On initialization, it immediately loads the profiles from persistence.
    init(store: BackendProfileStoreProtocol = BackendProfileStore.shared) {
        self.profileStore = store
        Self.noteConstruction(usingSharedStore: store is BackendProfileStore)
        loadProfiles()
    }

    /// How many services have been built on the real store this process. The app needs exactly
    /// one; tests build their own on in-memory stores and are not counted.
    private static var sharedStoreInstanceCount = 0

    /// Logs loudly when a second app-level service is constructed, since each does a full profile fetch and Keychain reads.
    private static func noteConstruction(usingSharedStore: Bool) {
        guard usingSharedStore else { return }
        sharedStoreInstanceCount += 1
        if sharedStoreInstanceCount == 1 {
            logger.info("[PROFILE] BackendProfileService created (the app's single instance).")
        } else {
            logger.error("[PROFILE] BackendProfileService created AGAIN — instance #\(sharedStoreInstanceCount) on the shared store. CONSEQUENCE: a redundant full profile fetch, plus a Keychain read per keyed profile, for an instance the UI may not use; views and the delete cascade can disagree about which list is current. Look for a new construction site, or a `@State` default re-evaluated by a re-created App struct.")
        }
    }

    // MARK: - Persistence Methods

    /// The last `loadProfiles()` failure, or nil when the list reflects a successful read.
    /// Lets the sidebar tell "no profiles" apart from "profiles could not be read".
    private(set) var lastLoadError: String?

    /// Fetches all profiles from the persistence layer and updates the published `profiles` array.
    func loadProfiles() {
        do {
            self.profiles = try profileStore.fetchProfiles()
            self.lastLoadError = nil
        } catch {
            self.lastLoadError = error.localizedDescription
            // Keep existing in-memory profiles rather than clearing on transient errors.
            let consequence = profiles.isEmpty
                ? "the sidebar is EMPTY and reads as a first run — the user's profiles are not gone, "
                  + "they were not read"
                : "the sidebar keeps the \(profiles.count) profile(s) already in memory, which may "
                  + "now be stale"
            logger.error(
                "[PERSISTENCE] loadProfiles failed: \(error.localizedDescription). "
                + "CONSEQUENCE: \(consequence)."
            )
        }
    }

    /// Saves a profile to the persistence layer and updates the in-memory array in place.
    /// Throws `ProfileStoreError` on validation or persistence failure.
    /// - Returns: advisory findings for the saved profile; empty in the common case.
    @discardableResult
    func saveProfile(_ profile: BackendProfileModel,
                     file: String = #fileID,
                     function: String = #function,
                     line: Int = #line) throws -> [ProfileValidationError] {
        // Forwards the caller's location so the store's log names the real trigger.
        let advisories = try profileStore.saveProfile(profile, callerFile: file, callerFunction: function, callerLine: line)

        // Update in-place to preserve sidebar ordering
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            // New profile — reload to get correct sort order
            loadProfiles()
        }
        // Knowledge sources need no save-time indexing: they are read fresh from disk on every request
        // and delivered as the <knowledge_base> prompt layer.
        return advisories
    }

    // Why: a rename is an out-of-band write while the editor may hold the profile open; the draft must take the new name too,
    // or its stale name lights Save and the next editor or canvas save reverts the rename.
    /// Renames a shared profile, writing from the store's copy so no other field is reverted.
    /// Throws `ProfileStoreError.validationFailed` for an empty name or one another shared profile already uses (case-insensitive).
    @discardableResult
    func renameProfile(withId id: UUID, to newName: String) throws -> BackendProfileModel {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileStoreError.validationFailed([
                ProfileValidationError(field: "displayName", message: "A profile name can't be empty.")
            ])
        }
        let lower = trimmed.lowercased()
        if sharedProfiles.contains(where: { $0.id != id && $0.displayName.lowercased() == lower }) {
            throw ProfileStoreError.validationFailed([
                ProfileValidationError(field: "displayName", message: "A profile named '\(trimmed)' already exists.")
            ])
        }
        guard var profile = freshProfile(id: id) else {
            logger.error(
                "[PROFILE] renameProfile found no profile \(id) in the store or in memory. "
                + "CONSEQUENCE: the rename to '\(trimmed)' is not applied."
            )
            throw ProfileStoreError.fetchFailed(
                underlying: NSError(domain: "BackendProfileService", code: 404,
                                    userInfo: [NSLocalizedDescriptionKey: "The profile no longer exists."])
            )
        }
        guard profile.displayName != trimmed else { return profile }

        let oldName = profile.displayName
        profile.displayName = trimmed
        try saveProfile(profile)
        if let buffer = editBuffer, buffer.draft.id == id {
            buffer.draft.displayName = trimmed
        }
        rebaseEditBuffer(to: profile)
        logger.info("[PROFILE] Renamed '\(oldName)' → '\(trimmed)' (\(id.uuidString.prefix(8))).")
        return profile
    }

    // Why: call only after a successful layout write; an empty or partial referenced set deletes every node's configuration.
    /// Deletes the private profile rows of nodes whose configuration no node on the workflow's canvas references.
    /// Pass `referencedProfileIDs` unioned with `WorkflowCanvasState.undoRecoverableProfileIDs`.
    /// - Returns: how many rows were collected (not currently consumed by callers).
    @discardableResult
    func reconcileOwnedProfiles(forWorkflow workflowID: UUID, referencedProfileIDs: Set<UUID>) -> Int {
        let owned: [BackendProfileModel]
        do {
            owned = try profileStore.fetchOwnedProfiles(forWorkflow: workflowID)
        } catch {
            logger.error(
                "[PROFILE] Could NOT list the node-owned profile rows for workflow \(workflowID): "
                + "\(error.localizedDescription). CONSEQUENCE: nothing is collected this save, so rows "
                + "for deleted nodes stay on disk — invisible to every picker, but real. The next "
                + "successful save reconciles them."
            )
            return 0
        }

        let orphans = owned.filter { !referencedProfileIDs.contains($0.id) }
        guard !orphans.isEmpty else { return 0 }

        var collected = 0
        for orphan in orphans {
            do {
                // Goes through the full delete so the row's Keychain entry goes with it —
                // `BackendProfileStore.deleteProfile` calls `ProviderKeyStore.delete(for:)`.
                try deleteProfile(withId: orphan.id)
                collected += 1
                logger.info(
                    "[PROFILE] Collected node-owned profile '\(orphan.displayName)' (\(orphan.id)) — "
                    + "no node on workflow \(workflowID)'s saved canvas references it (its owner was "
                    + "node \(orphan.ownerNodeID?.uuidString.prefix(8) ?? "?")). CONSEQUENCE: the row "
                    + "and its stored credential are gone — the node was deleted and saved, or was "
                    + "repointed away from this row."
                )
            } catch {
                logger.error(
                    "[PROFILE] Could NOT collect node-owned profile '\(orphan.displayName)' "
                    + "(\(orphan.id)) for workflow \(workflowID): \(error.localizedDescription). "
                    + "CONSEQUENCE: the row stays on disk, hidden from every picker; it is retried on "
                    + "the next successful save of this workflow."
                )
            }
        }
        return collected
    }

    /// Deletes a profile using its ID from the persistence layer and reloads the local array.
    /// Cascades to the matching `WorkflowLayoutSD` row (if any) — a no-op for non-workflow
    /// profiles since the layout store keys on profile ID and simply finds nothing to delete.
    func deleteProfile(withId id: UUID) throws {
        // Deletes the workflow's node-owned profile rows first, so a failure leaves the workflow intact for a retry.
        // A fetch failure aborts the delete; swallowing it would strand the rows and their Keychain credentials.
        let owned: [BackendProfileModel]
        do {
            owned = try profileStore.fetchOwnedProfiles(forWorkflow: id)
        } catch {
            logger.error(
                "[PROFILE] Delete ABORTED for workflow \(id): could not list its node-owned profile "
                + "rows (\(error.localizedDescription)). CONSEQUENCE: nothing is deleted — the "
                + "workflow, its layout and its nodes' private rows are all left intact. Deleting the "
                + "workflow now would strand those rows and their stored credentials with nothing "
                + "left that could ever find them."
            )
            throw error
        }

        if !owned.isEmpty {
            logger.info("[PROFILE] Deleting workflow \(id) cascades to \(owned.count) node-owned profile row(s). CONSEQUENCE: each node's private configuration and its stored credential are removed with the workflow that scoped them.")
            for row in owned {
                do {
                    try profileStore.deleteProfile(withId: row.id)
                } catch {
                    logger.error("[PROFILE] Could NOT delete node-owned profile '\(row.displayName)' (\(row.id)) while deleting workflow \(id): \(error.localizedDescription). CONSEQUENCE: the row is left on disk, hidden from every picker and no longer reachable from any canvas — an orphan needing manual cleanup.")
                }
            }
        }

        try profileStore.deleteProfile(withId: id)
        WorkflowLayoutStore.shared.delete(for: id)
        // Prunes the deleted profile's cached canvas state via a callback, so the quit-time drain cannot resurrect its layout.
        // A callback because this service cannot depend on the view model.
        onProfileDeleted?(id)
        if editBuffer?.draft.id == id {
            editBuffer = nil
        }
        loadProfiles()
    }

    // MARK: - Edit Buffer Management

    // Why: saving a stale snapshot writes the whole profile back and reverts changes made out of band.
    /// The profile as the store has it, falling back to the in-memory copy when the read fails.
    /// Any writer of a whole profile must start here, not from `profiles`: out-of-band writers do not refresh that array.
    func freshProfile(id: UUID) -> BackendProfileModel? {
        let cached = profiles.first(where: { $0.id == id })
        do {
            if let fresh = try profileStore.fetchProfile(byId: id) { return fresh }
        } catch {
            logger.error(
                "[PROFILE] Could not re-read profile \(id) from the store before a whole-profile "
                + "write: \(error.localizedDescription). CONSEQUENCE: falling back to the in-memory "
                + "copy, which may predate an out-of-band write (auto-healed thinking flag or "
                + "backfilled context window) — saving could revert it."
            )
        }
        return cached
    }

    // Why: reads the store, not the in-memory `profiles`, since several writers persist profiles without refreshing that array.
    /// Creates (or replaces) the edit buffer for the given profile ID; call when the user selects a profile in the sidebar.
    func activateEditBuffer(for id: UUID) {
        guard let profile = freshProfile(id: id) else {
            logger.error(
                "[PROFILE] activateEditBuffer found no profile \(id) in the store or in memory. "
                + "CONSEQUENCE: the previous edit buffer is cleared and the detail view renders its "
                + "not-found state rather than silently editing the wrong profile."
            )
            editBuffer = nil
            return
        }

        // Keep the list in step with what the editor is about to show, so the sidebar row and the
        // editor cannot disagree about the same profile.
        if let index = profiles.firstIndex(where: { $0.id == id }), profiles[index] != profile {
            profiles[index] = profile
        }

        editBuffer = ProfileEditBuffer(profile: profile)
        logProfileSelection(profileID: id)
    }

    /// Discards the current edit buffer.
    func deactivateEditBuffer() {
        editBuffer = nil
    }

    /// Re-baselines the open edit buffer after a facet of the profile was persisted elsewhere.
    /// Call after every out-of-band `saveProfile` for a profile the editor may have open; no-op for a different profile.
    func rebaseEditBuffer(to persisted: BackendProfileModel) {
        guard let buffer = editBuffer, buffer.draft.id == persisted.id else { return }
        buffer.rebase(onto: persisted)
    }

    // MARK: - Advanced Configuration Logic

    /// Encodes a specific `Codable` model into the `[String: JSONValue]` dictionary format.
    /// - Returns: The encoded dictionary, or `nil` if encoding fails.
    func encodeConfig<T: Codable>(from config: T) -> [String: JSONValue]? {
        do {
            let data = try JSONEncoder().encode(config)
            guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
                logger.warning("Failed to cast JSON object to [String: Any] during advanced config encode.")
                return nil
            }
            return dictionary.mapValues { JSONValue($0) ?? .null }
        } catch {
            logger.error("Failed to encode advanced configuration: \(error.localizedDescription)")
            return nil
        }
    }

    /// Decodes a `[String: JSONValue]` dictionary back into a specific `Codable` model type.
    /// - Returns: The decoded model, or `nil` if the dictionary is missing or decoding fails.
    /// - Parameter context: names the profile/provider being decoded, used only in the failure log.
    func decodeConfig<T: Codable>(
        from dictionary: [String: JSONValue]?,
        as type: T.Type,
        context: String = "unspecified profile"
    ) -> T? {
        guard let dictionary = dictionary else { return nil }

        let unwrappedDict = dictionary.mapValues { $0.rawValue }

        do {
            let data = try JSONSerialization.data(withJSONObject: unwrappedDict)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Callers fall back to defaults on nil, so the whole advanced panel is lost; the log says so and names the profile.
            logger.error(
                "[PROFILE] Advanced configuration for \(context) could not be decoded as "
                + "\(String(describing: T.self)): \(error.localizedDescription). Stored keys: "
                + "[\(dictionary.keys.sorted().joined(separator: ", "))]. CONSEQUENCE: the panel "
                + "falls back to app DEFAULTS and presents them as the user's settings; saving from "
                + "that state overwrites the stored configuration."
            )
            return nil
        }
    }

    // MARK: - Diagnostics / Logging

    /// Dumps the full resolved configuration of a profile: provider, model, endpoint, capability verdict, tool state,
    /// knowledge sources and advanced-config keys. Called once per profile activation, not per send.
    /// The API key is masked by `formatLLMConfig`; knowledge-source paths are included.
    func logProfileSelection(profileID: UUID) {
        guard let logOutput = profileSelectionSummary(profileID: profileID) else {
            logger.notice(
                "[PROFILE] Cannot log configuration for \(profileID): not in the loaded list. "
                + "CONSEQUENCE: this activation has no configuration record in the log."
            )
            return
        }

        logger.info("[PROFILE] \(logOutput)")
    }

    /// Builds the dump `logProfileSelection` emits, or nil when the profile is not loaded.
    /// Separate from the logging call so the content is testable.
    func profileSelectionSummary(profileID: UUID) -> String? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }

        var logOutput = "\n\n==================================================\n"
        logOutput += "PROFILE SELECTED: \(profile.displayName)\n"
        logOutput += "==================================================\n"
        logOutput += "ID: \(profile.id)\n"
        logOutput += "Type: \(profile.profileType.rawValue)\n"
        logOutput += "Last Selected: \(profile.lastSelected?.description ?? "Never")\n\n"

        switch profile.details {
        case .bot(let config):
            logOutput += "[BOT CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Instructions (Length): \(config.instructions?.count ?? 0) characters\n"

        case .agent(let config):
            logOutput += "[AGENT CONFIGURATION]\n"
            logOutput += "Capabilities: \(config.capabilities.summary)\n"
            logOutput += "Description: \(config.description ?? "None")\n"
            logOutput += "Instructions (Length): \(config.instructions?.count ?? 0) characters\n\n"

            logOutput += "[TOOLS (\(config.tools.filter({ $0.isEnabled }).count) Active)]\n"
            if config.tools.isEmpty {
                logOutput += "  - No tools configured.\n"
            } else {
                for tool in config.tools {
                    let status = tool.isEnabled ? "ON" : "OFF"
                    logOutput += "  [\(status)] \(tool.name) (Requires Confirmation: \(tool.requiresConfirmation))\n"
                }
            }
            logOutput += "\n"

            logOutput += "[KNOWLEDGE SOURCES (\(config.knowledgeSources?.count ?? 0) Active)]\n"
            if let sources = config.knowledgeSources, !sources.isEmpty {
                for source in sources {
                    logOutput += "  - [\(source.type.rawValue)] \(source.location)\n"
                }
            } else {
                logOutput += "  - No knowledge sources.\n"
            }
            logOutput += "\n"

            logOutput += "[LLM / PROVIDER CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)

        case .workflow:
            logOutput += "[WORKFLOW CONFIGURATION]\n"
            // The layout is the record of what a workflow contains. These counts are denormalized
            // columns, so this costs no blob decode.
            let counts = WorkflowLayoutStore.shared.storedCounts(for: profile.id)
            logOutput += "Nodes: \(counts.nodes), Edges: \(counts.edges), Notes: \(counts.annotations)\n"

        case .imageGen(let config):
            logOutput += "[IMAGE GENERATOR CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Negative Prompt: \(config.negativePrompt ?? "None")\n"
            logOutput += "Default Aspect Ratio: \(config.defaultAspectRatio?.rawValue ?? "Not set")\n"

        case .code(let config):
            logOutput += "[CODE SESSION CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Tools: \(config.tools.filter({ $0.isEnabled }).count) active\n"
            logOutput += "Max Iterations: \(config.maxIterations ?? AgentExecutionDefaults.maxIterations)\n"
        }

        logOutput += "==================================================\n\n"
        return logOutput
    }

    /// What tool-calling mode this config's runs use, and where that answer comes from.
    /// Local models are detected live (`LiveModelDetection`); the summary says when that differs from the stored copy.
    static func toolCallingSummary(for config: ProviderConfig) -> String {
        if config.apiProvider.usesCloudDefaults {
            return "native (\(config.apiProvider.rawValue) — not measured; cloud runs always offer native tools)"
        }
        guard !config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "not yet detected (no model selected)"
        }
        guard let detected = LiveModelDetection.detectedFromCache(config) else {
            return "\(config.cognitiveCapability.rawValue) (stored when the model was picked; not in the detection cache yet — the next run re-detects)"
        }
        guard detected.cognitiveCapability == config.cognitiveCapability else {
            return "\(detected.cognitiveCapability.rawValue) (detected now; the profile still stores \(config.cognitiveCapability.rawValue) until the model is next picked from the catalog and the profile saved — runs use the detected value)"
        }
        return "\(detected.cognitiveCapability.rawValue) (detected)"
    }

    private func formatLLMConfig(_ config: ProviderConfig) -> String {
        var str = "Provider: \(config.apiProvider.rawValue)\n"
        str += "Model Name: \(config.modelName)\n"
        str += "Base URL: \(config.baseURL ?? "Default (Not set)")\n"

        str += "Tool Calling: \(Self.toolCallingSummary(for: config))\n"

        if let key = config.apiKey, !key.isEmpty {
            let masked = key.count > 8 ? "\(key.prefix(4))...\(key.suffix(4))" : "****"
            str += "API Key: \(masked) (Masked for Security)\n"
        } else {
            str += "API Key: None\n"
        }

        if let adv = config.advancedConfiguration, !adv.isEmpty {
            str += "Advanced Config Keys: \(adv.keys.joined(separator: ", "))\n"
        } else {
            str += "Advanced Config: Default / None\n"
        }

        return str
    }
}
