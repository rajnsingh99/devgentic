// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendProfileServiceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - Mock Store

private final class MockProfileStore: BackendProfileStoreProtocol {
    var profiles: [BackendProfileSnapshot] = []
    var saveCallCount = 0
    var deleteCallCount = 0
    var shouldThrowOnSave = false

    func fetchProfiles() throws -> [BackendProfileSnapshot] {
        return profiles
    }

    func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
        return profiles.first { $0.id == id }
    }

    /// Carries the caller-attribution parameters the protocol requires (the store logs them so a
    /// burst of saves names its trigger). The mock ignores them — it only counts calls.
    func saveProfile(_ snapshot: BackendProfileSnapshot,
                     callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
        saveCallCount += 1
        if shouldThrowOnSave {
            throw ProfileStoreError.saveFailed(underlying: NSError(domain: "test", code: 1))
        }
        if let idx = profiles.firstIndex(where: { $0.id == snapshot.id }) {
            profiles[idx] = snapshot
        } else {
            profiles.append(snapshot)
        }
        return []  // A34: a double has no advisories to report.
    }

    func deleteProfile(withId id: UUID) throws {
        deleteCallCount += 1
        profiles.removeAll { $0.id == id }
    }
}

// MARK: - Tests

@MainActor
final class BackendProfileServiceTests: XCTestCase {

    private var store: MockProfileStore!
    private var service: BackendProfileService!

    private func makeBot(name: String = "Bot", modelName: String = "llama3") -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: modelName)
            ))
        )
    }

    override func setUp() {
        store = MockProfileStore()
        store.profiles = [
            makeBot(name: "Alpha"),
            makeBot(name: "Beta")
        ]
        service = BackendProfileService(store: store)
    }

    // MARK: - Load

    func testLoadProfilesPopulatesArray() {
        XCTAssertEqual(service.profiles.count, 2)
        XCTAssertEqual(service.profiles[0].displayName, "Alpha")
    }

    // MARK: - Edit Buffer Lifecycle

    func testActivateEditBufferCreatesBuffer() {
        let id = service.profiles[0].id
        service.activateEditBuffer(for: id)

        XCTAssertNotNil(service.editBuffer)
        XCTAssertEqual(service.editBuffer?.draft.id, id)
        XCTAssertFalse(service.editBuffer?.isDirty ?? true)
    }

    func testActivateEditBufferForUnknownIDDoesNothing() {
        service.activateEditBuffer(for: UUID())
        XCTAssertNil(service.editBuffer)
    }

    func testDeactivateEditBufferClearsBuffer() {
        service.activateEditBuffer(for: service.profiles[0].id)
        XCTAssertNotNil(service.editBuffer)

        service.deactivateEditBuffer()
        XCTAssertNil(service.editBuffer)
    }

    func testSwitchingProfileReplacesBuffer() {
        let id1 = service.profiles[0].id
        let id2 = service.profiles[1].id

        service.activateEditBuffer(for: id1)
        XCTAssertEqual(service.editBuffer?.draft.id, id1)

        service.activateEditBuffer(for: id2)
        XCTAssertEqual(service.editBuffer?.draft.id, id2)
    }

    // MARK: - Save Through Buffer

    func testSaveProfileUpdatesList() throws {
        let id = service.profiles[0].id
        service.activateEditBuffer(for: id)

        service.editBuffer?.draft.displayName = "Renamed"
        try service.saveProfile(service.editBuffer!.draft)
        service.editBuffer?.markSaved()

        XCTAssertEqual(service.profiles.first(where: { $0.id == id })?.displayName, "Renamed")
        XCTAssertFalse(service.editBuffer?.isDirty ?? true)
        XCTAssertEqual(store.saveCallCount, 1)
    }

    func testSaveNewProfileAppends() throws {
        let newProfile = makeBot(name: "Gamma")
        try service.saveProfile(newProfile)

        // Service reloads from store for new profiles
        XCTAssertTrue(service.profiles.contains(where: { $0.displayName == "Gamma" }))
    }

    // MARK: - Delete

    func testDeleteProfileClearsBufferIfActive() throws {
        let id = service.profiles[0].id
        service.activateEditBuffer(for: id)

        try service.deleteProfile(withId: id)

        XCTAssertNil(service.editBuffer, "Deleting the active profile should clear the edit buffer")
        XCTAssertFalse(service.profiles.contains(where: { $0.id == id }))
    }

    func testDeleteProfilePreservesBufferForOtherProfile() throws {
        let id1 = service.profiles[0].id
        let id2 = service.profiles[1].id

        service.activateEditBuffer(for: id1)
        try service.deleteProfile(withId: id2)

        XCTAssertNotNil(service.editBuffer)
        XCTAssertEqual(service.editBuffer?.draft.id, id1)
    }

    // MARK: - Dirty Tracking Integration

    func testEditBufferDirtyStateReflectsEdits() {
        service.activateEditBuffer(for: service.profiles[0].id)
        XCTAssertFalse(service.editBuffer!.isDirty)

        service.editBuffer!.draft.displayName = "Changed"
        XCTAssertTrue(service.editBuffer!.isDirty)

        service.editBuffer!.revert()
        XCTAssertFalse(service.editBuffer!.isDirty)
    }

    // MARK: - Rename

    func testRenamePersistsTrimmedName() throws {
        let id = service.profiles[0].id
        try service.renameProfile(withId: id, to: "  Gamma  ")

        XCTAssertEqual(store.profiles.first(where: { $0.id == id })?.displayName, "Gamma")
        XCTAssertEqual(service.profiles.first(where: { $0.id == id })?.displayName, "Gamma")
    }

    func testRenameRefusesEmptyName() {
        let id = service.profiles[0].id
        XCTAssertThrowsError(try service.renameProfile(withId: id, to: "   "))
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertEqual(store.profiles.first(where: { $0.id == id })?.displayName, "Alpha")
    }

    func testRenameRefusesAnotherProfilesNameCaseInsensitively() {
        let id = service.profiles[0].id
        XCTAssertThrowsError(try service.renameProfile(withId: id, to: "beta"))
        XCTAssertEqual(store.saveCallCount, 0)
    }

    func testRenameAllowsChangingOnlyTheCaseOfItsOwnName() throws {
        let id = service.profiles[0].id
        try service.renameProfile(withId: id, to: "ALPHA")
        XCTAssertEqual(store.profiles.first(where: { $0.id == id })?.displayName, "ALPHA")
    }

    /// The open editor must take the new name, or its stale draft lights Save and the next save reverts the rename.
    func testRenameOfOpenProfileUpdatesDraftWithoutDirtyingIt() throws {
        let id = service.profiles[0].id
        service.activateEditBuffer(for: id)

        try service.renameProfile(withId: id, to: "Gamma")

        XCTAssertEqual(service.editBuffer?.draft.displayName, "Gamma")
        XCTAssertFalse(service.editBuffer?.isDirty ?? true)
    }

    /// Unsaved editor work survives a sidebar rename, and saving it afterwards keeps the new name.
    func testRenameOfOpenProfileKeepsUnsavedEditsAndTheirSaveKeepsTheName() throws {
        let id = service.profiles[0].id
        service.activateEditBuffer(for: id)
        let editedDetails = makeBot(modelName: "qwen3").details
        service.editBuffer!.draft.details = editedDetails

        try service.renameProfile(withId: id, to: "Gamma")

        XCTAssertTrue(service.editBuffer!.isDirty)
        XCTAssertEqual(store.profiles.first(where: { $0.id == id })?.details, makeBot().details)

        try service.saveProfile(service.editBuffer!.draft)
        let saved = store.profiles.first(where: { $0.id == id })
        XCTAssertEqual(saved?.displayName, "Gamma")
        XCTAssertEqual(saved?.details, editedDetails)
    }

    func testRenameOfAnotherProfileLeavesOpenDraftAlone() throws {
        service.activateEditBuffer(for: service.profiles[0].id)
        try service.renameProfile(withId: service.profiles[1].id, to: "Gamma")
        XCTAssertEqual(service.editBuffer?.draft.displayName, "Alpha")
    }
}
