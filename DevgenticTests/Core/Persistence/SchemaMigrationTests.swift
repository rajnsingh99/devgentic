// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SchemaMigrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
import CryptoKit
@testable import devgentic

final class SchemaMigrationTests: XCTestCase {

    // MARK: - Temp store plumbing

    /// A unique directory per test, removed in tearDown.
    private var workDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SchemaMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory, FileManager.default.fileExists(atPath: workDirectory.path) {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - G54: the entity set is what we think it is

    /// Membership guard. Omitting an entity from the schema is one of the drifts that makes an
    /// existing store un-openable, and it is invisible at compile time.
    ///
    /// ⚠️ If this fails because you deliberately added or removed an entity, that is a SCHEMA
    /// CHANGE: follow the V2 procedure in DevgenticSchemaVersions.swift before shipping.
    func testProductionSchemaRegistersExactlyTheExpectedEntities() {
        let expected: Set<String> = [
            "BackendProfile",
            "MCPToolItem",
            "MCPToolDefinitionModel",
            "PromptModel",
            "ScheduledTaskModel",
            "ConversationSD",
            "ChatMessageSD",
            "AttachedTextFileSD",
            "AttachedImageFileSD",
            "DownloadRecord",
            "WorkflowLayoutSD",
            "WorkflowRunRecordSD",
            // The skill library. Deliberately NOT related to BackendProfile — a profile
            // references a skill BY VALUE, one direction only, which keeps the relationship
            // closure (and so any future frozen copies) small.
            "SkillSD",
            "SkillVersionSD",
            "SkillFileSD",
        ]

        let actual = Set(DevgenticSchema.schema.entities.map(\.name))

        XCTAssertEqual(
            actual, expected,
            """
            The production entity set changed.
            Added:   \(actual.subtracting(expected).sorted())
            Removed: \(expected.subtracting(actual).sorted())
            """
        )
        XCTAssertEqual(DevgenticSchema.models.count, 15, "Entity count drifted from the documented 15.")
    }

    /// The `Schema` the app builds must equal the one built from the extracted model list.
    func testSchemaBuiltFromModelsIsStable() {
        // The versioned schema carries currentVersion's identifier; a bare Schema(models)
        // defaults to (1,0,0), so the comparison must supply the version explicitly.
        XCTAssertEqual(DevgenticSchema.schema, Schema(DevgenticSchema.models, version: DevgenticSchema.currentVersion.versionIdentifier))
        XCTAssertEqual(DevgenticSchema.schema.version, DevgenticSchema.currentVersion.versionIdentifier,
                       "Schema version drifted from the declared current version.")
    }

    // MARK: - G67: the OS-side collection-storage regression

    /// The deployment target is a persistence invariant, not just a compatibility setting.
    ///
    /// Apple changed how SwiftData persists COLLECTION attributes between macOS 26.0 and 26.1
    /// (Binary Data → Transformable / `NSSecureUnarchiveFromData`). A store written under 26.0 and
    /// opened under 26.1+ fails with `NSCocoaErrorDomain 134140`, **with no developer change** — so
    /// nothing in `DevgenticSchemaVersions` can prevent it. `PromptModel.tags: [String]?` is the
    /// app's only non-relationship collection attribute and is exactly that shape.
    ///
    /// Raising the floor to 26.1 means no store can ever be written under the old encoding. This
    /// test exists because that reasoning lives in a build setting, where it is invisible: someone
    /// lowering it back to widen compatibility would silently reopen a bricking path.
    /// The two SwiftPM harnesses must declare the SAME macOS floor as the app (register G59).
    ///
    /// ⚠️ Not a tidiness rule. `MCPHarness/` and `ToolHarness/` compile REAL app sources through
    /// symlinks, so a lower floor there means those exact files are compiled under DIFFERENT
    /// availability rules than the app compiles them under. The harmless failure is a source using a
    /// newer API breaking the harness build but not the app — a confusing error in the wrong place.
    /// The harmful one is quieter: a file guarded by `#available` can take a different branch, so a
    /// green harness run becomes evidence about a build nobody ships.
    ///
    /// Both manifests sat at `.macOS(.v14)` while the app was at 26.1 — twelve major versions apart —
    /// and nothing connected the numbers. This reads the manifests from disk via `#filePath`, which
    /// is the only way a test can see a sibling SwiftPM package's declaration.
    ///
    /// ⚠️ If a harness genuinely cannot build at the app's floor, the answer is to fix the harness,
    /// not to lower the number — the point is that they compile the same sources the same way.
    func testHarnessManifestsDeclareTheSameFloorAsTheApp() throws {
        // #filePath is DevgenticTests/Core/Persistence/SchemaMigrationTests.swift → up 4 to the repo.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Persistence
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root

        for harness in ["MCPHarness", "ToolHarness"] {
            let manifest = repoRoot.appending(path: "\(harness)/Package.swift")
            guard let source = try? String(contentsOf: manifest, encoding: .utf8) else {
                // Skipping rather than failing: the harnesses are optional working trees, and a
                // developer without them should not see a red suite. XCTSkip reports "not checked",
                // which is true — unlike a silent `return`, which would report a pass.
                throw XCTSkip("\(harness)/Package.swift is not present in this checkout.")
            }

            XCTAssertFalse(
                source.contains(".macOS(.v14)") || source.contains(".macOS(.v15)"),
                """
                \(harness) declares a macOS floor far below the app's 26.1.

                It compiles app sources through symlinks, so those files would be built under
                different availability rules than the app builds them under — and any `#available`
                branch could differ, making a green harness run evidence about a build nobody runs.
                Use `.macOS("26.1")`; the `.v26` enum case needs swift-tools-version 6.2 and these
                manifests are 6.0.
                """
            )
            XCTAssertTrue(
                source.contains(#".macOS("26.1")"#),
                "\(harness) must declare .macOS(\"26.1\") to match MACOSX_DEPLOYMENT_TARGET."
            )
        }
    }

    func testDeploymentTargetStaysAboveTheCollectionStorageRegression() throws {
        // ⚠️ The APP bundle, not the test bundle.
        //
        // This used to read `Bundle(for: SchemaMigrationTests.self)` — the xctest bundle — and only
        // fall back to the app's with `??`. The two targets carry INDEPENDENT
        // `MACOSX_DEPLOYMENT_TARGET` settings, so lowering only the APP's (the one that governs what
        // ships) left the test reading 26.1 from the test bundle and passing green while the shipped
        // binary was exposed. A guard that reads a value nobody ships is not a guard.
        //
        // `Bundle.main` under `TEST_HOST` IS devgentic.app; the identifier lookup is a belt-and-braces
        // fallback for any future host arrangement.
        let appBundle = try XCTUnwrap(
            Bundle(identifier: "app.devgentic.macos") ?? Bundle.main,
            "Could not resolve the app bundle — the deployment floor cannot be verified."
        )
        let raw = try XCTUnwrap(
            appBundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
            """
            LSMinimumSystemVersion is absent from the APP bundle (\(appBundle.bundleIdentifier ?? "nil")).
            Do NOT relax this to read the test bundle instead — that is the drift this guard exists to
            catch.
            """
        )

        let components = raw.split(separator: ".").compactMap { Int($0) }
        let major = components.first ?? 0
        let minor = components.count > 1 ? components[1] : 0

        XCTAssertTrue(
            major > 26 || (major == 26 && minor >= 1),
            """
            The APP's deployment target is \(raw); it must stay at macOS 26.1 or later.

            Below 26.1, SwiftData persists `[String]?` as Binary Data. A store written there and
            opened on 26.1+ fails with NSCocoaErrorDomain 134140 and the app cannot launch — an
            OS-side change no schema versioning can guard against. `PromptModel.tags` is exposed.
            If the floor must drop, move `tags` off the native array first (see
            DevgenticSchemaVersions.swift).
            """
        )
    }

    /// The exposed attribute is still the ONLY one of its shape. A second collection attribute
    /// would widen the surface the floor above is protecting.
    func testTagsRemainsTheOnlyNonRelationshipCollectionAttribute() {
        var collectionAttributes: [String] = []

        for entity in DevgenticSchema.schema.entities {
            for property in entity.properties where property is Schema.Attribute {
                let type = String(describing: property.valueType)
                // Native collection shapes SwiftData stores as transformable blobs.
                guard type.contains("Array<") || type.contains("Set<") || type.contains("Dictionary<") else { continue }
                collectionAttributes.append("\(entity.name).\(property.name): \(type)")
            }
        }

        XCTAssertEqual(
            collectionAttributes, ["PromptModel.tags: Optional<Array<String>>"],
            """
            The set of native collection attributes changed: \(collectionAttributes)

            Each one is exposed to OS-side changes in how SwiftData persists collections — the
            class of failure that produced NSCocoaErrorDomain 134140 between macOS 26.0 and 26.1.
            Prefer a hand-rolled blob (as `attachedFileURLsJSON` and `configData` already do), or
            confirm the deployment floor still covers the new attribute.
            """
        )
    }

    // MARK: - Step 3: V1 renders what it recorded; the VersionedSchema wrap is hash-neutral

    /// ⚠️⚠️ V1 MUST RENDER EXACTLY WHAT `SchemaBaselineV1` RECORDED — FOREVER, not only while it is
    /// current. Today this overlaps the drift test below (V1 IS the current version); it stops
    /// overlapping the day a V2 lands, and that is the day it matters. V1 lists its models by their
    /// LIVE classes, so a V2 that evolves one of them rewrites V1's shape too unless V1 is given
    /// frozen copies (rule 5b). This fails when that is forgotten.
    ///
    /// It exists from day one because on 2026-09-23 exactly that happened to two older versions
    /// whose baselines were on file but compared against nothing: every store stamped at them
    /// stopped opening, and no test went red. Each version gets this test the day it is frozen.
    func testV1RendersExactlyTheV1Baseline() {
        assertRenders(DevgenticSchemaV1.self, exactly: SchemaBaselineV1.descriptor, version: "V1")
    }

    private func assertRenders(_ version: any VersionedSchema.Type, exactly baseline: String,
                               version label: String, file: StaticString = #filePath, line: UInt = #line) {
        let rendered = DevgenticSchema.structuralDescriptor(for: Schema(versionedSchema: version))
        guard rendered != baseline else { return }
        let baselineLines = baseline.components(separatedBy: "\n")
        let currentLines = rendered.components(separatedBy: "\n")
        let removed = Set(baselineLines).subtracting(currentLines).sorted()
        let added = Set(currentLines).subtracting(baselineLines).sorted()
        XCTFail(
            """
            \(label) no longer renders its recorded shape — a store stamped at \(label) will not open.
            Usually a model it lists by its LIVE class evolved; give \(label) a frozen copy (rule 5b).
            Removed (\(removed.count)):
            \(removed.map { "  - \($0)" }.joined(separator: "\n"))
            Added (\(added.count)):
            \(added.map { "  + \($0)" }.joined(separator: "\n"))
            """,
            file: file, line: line
        )
    }

    /// The assertion that makes introducing `VersionedSchema` safe, and the permanent guard
    /// against it silently ceasing to be safe.
    ///
    /// Every store written before versioning was declared was described by a bare
    /// `Schema([types])`, whose `version` parameter defaults to `Schema.Version(1, 0, 0)` — exactly
    /// what `DevgenticSchemaV1` declares. So the versioned and unversioned forms must compare equal
    /// and hash identically.
    ///
    /// ⚠️ SCOPE, measured rather than assumed: this compares `Schema.hashValue` — Swift `Hashable`
    /// on the `Schema` value, which DOES incorporate `version`. That is NOT the same quantity as
    /// Core Data's entity version hash, which is derived from entity/property structure only and
    /// excludes both the version identifier and Swift default values.
    ///
    /// Consequently this test is a DRIFT DETECTOR, not a proof of bricking. Verified 2026-08-04 by
    /// temporarily setting V1's identifier to (2,0,0): these assertions failed, but a real 4.7 MB
    /// store still opened cleanly — because with one declared version and zero stages SwiftData
    /// never engages staged migration, leaving the identifier inert. It becomes load-bearing the
    /// moment a V2 exists, which is precisely when it is too late to discover a wrong value.
    func testVersionedSchemaIsHashIdenticalToUnversioned() {
        let unversioned = Schema(DevgenticSchemaV1.models)
        let versioned = Schema(versionedSchema: DevgenticSchemaV1.self)

        XCTAssertEqual(unversioned, versioned,
                       "Wrapping the entities in a VersionedSchema changed the Schema's identity.")
        XCTAssertEqual(unversioned.hashValue, versioned.hashValue,
                       "Schema.hashValue diverged between the versioned and unversioned forms.")
        XCTAssertEqual(unversioned.version, versioned.version)
    }

    /// `versionIdentifier` is not cosmetic: it must match the value SwiftData already recorded
    /// implicitly for stores written before versioning existed.
    ///
    /// ⚠️ A wrong value is currently INERT — see the scope note on the test above — so nothing at
    /// runtime would reveal it until a V2 lands and staged migration starts consulting it. This
    /// test is the only thing standing between a typo here and a `134504` on every store later.
    func testV1VersionIdentifierIsExactlyOneZeroZero() {
        XCTAssertEqual(
            DevgenticSchemaV1.versionIdentifier, Schema.Version(1, 0, 0),
            """
            V1's versionIdentifier must stay (1,0,0) — that is the implicit default every existing
            store already carries. A different value is harmless today and catastrophic once a
            second version exists.
            """
        )
    }

    /// The current schema must BE the newest declared version, or the app would open its store
    /// with a shape the migration plan does not describe.
    ///
    /// ⚠️ Asserts on `DevgenticSchema.schema` — the value `DevgenticApp` actually opens the container
    /// with — NOT on `DevgenticSchema.models`. The earlier form compared `models` against the plan,
    /// and since `models` was `DevgenticSchemaV1.models` and the plan was `[DevgenticSchemaV1.self]`,
    /// both sides were literally the same expression: the test could not fail. Worse, it guarded the
    /// wrong seam — `schema` named V1 independently, so after a V2 landed this would have gone green
    /// while the container still opened V1.
    func testCurrentSchemaMatchesNewestDeclaredVersion() throws {
        let newest = try XCTUnwrap(DevgenticMigrationPlan.schemas.last)
        XCTAssertEqual(
            Set(DevgenticSchema.schema.entities.map(\.name)),
            Set(Schema(versionedSchema: newest).entities.map(\.name)),
            """
            The schema the app OPENS drifted from the newest version in the migration plan. Repoint
            `DevgenticSchema.currentVersion` — see the V2 procedure in DevgenticSchemaVersions.swift.
            """
        )
        XCTAssertEqual(
            DevgenticSchema.schema.version, newest.versionIdentifier,
            "The opened schema's version does not match the newest declared version."
        )
    }

    /// `models` and `schema` must both track `currentVersion`, so repointing that one symbol is
    /// genuinely the whole V2 edit.
    ///
    /// This is the regression guard for the trap the audit found: the V2 procedure said to repoint
    /// `models`, but `models` had zero production readers while `schema` named `DevgenticSchemaV1`
    /// directly. Following the procedure would have left the container on V1 — the new entity never
    /// registered, staged migration never engaged, and `structuralFingerprint` unchanged so the
    /// destructive launch sweep ran on exactly the launch that changed the schema.
    func testProductionSchemaTracksTheDeclaredCurrentVersion() {
        XCTAssertEqual(
            Set(DevgenticSchema.models.map { String(describing: $0) }),
            Set(DevgenticSchema.currentVersion.models.map { String(describing: $0) }),
            "DevgenticSchema.models no longer derives from currentVersion."
        )
        XCTAssertEqual(
            DevgenticSchema.schema.version, DevgenticSchema.currentVersion.versionIdentifier,
            "DevgenticSchema.schema no longer derives from currentVersion — repointing currentVersion "
            + "would leave the opened container behind."
        )
        XCTAssertEqual(
            Set(DevgenticSchema.schema.entities.map(\.name)),
            Set(Schema(versionedSchema: DevgenticSchema.currentVersion).entities.map(\.name)),
            "The opened schema's entities differ from currentVersion's."
        )
    }

    /// ⚠️ Zero stages is CORRECT for a single version, not an omission — `MigrationStage` requires
    /// both a from- and a to-version, so with one version there is no stage to express. Inventing
    /// a fictitious V2 to have "a single stage" is what produces `134504` on every existing store.
    ///
    /// This test flips meaning the moment a V2 lands: n versions require n-1 stages.
    func testMigrationPlanStageCountMatchesVersionCount() {
        let versionCount = DevgenticMigrationPlan.schemas.count
        XCTAssertGreaterThan(versionCount, 0, "The migration plan declares no schema versions.")
        XCTAssertEqual(
            DevgenticMigrationPlan.stages.count, versionCount - 1,
            """
            \(versionCount) declared version(s) need exactly \(versionCount - 1) stage(s), but the
            plan has \(DevgenticMigrationPlan.stages.count).
            With ONE version `stages` must be []; a stage needs both a from- and a to-version.
            """
        )
    }

    /// ⚠️ `SchemaMigrationPlan.schemas` order is load-bearing and must ASCEND — a descending array
    /// fails deterministically with `SwiftDataError.backwardMigration`. Apple documents no such
    /// requirement, so nothing but this test would catch a mis-ordered append.
    func testMigrationPlanSchemasAreInAscendingVersionOrder() {
        let versions = DevgenticMigrationPlan.schemas.map { $0.versionIdentifier }
        let sorted = versions.sorted { lhs, rhs in
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        XCTAssertEqual(
            versions.map(String.init(describing:)), sorted.map(String.init(describing:)),
            "Migration plan schemas must be in ascending version order."
        )
        XCTAssertEqual(Set(versions.map(String.init(describing:))).count, versions.count,
                       "Duplicate version identifiers in the migration plan.")
    }

    /// The plan must actually open a real pre-versioning store. Belt-and-braces over the hash
    /// assertion above: that one compares metadata, this one exercises the container.
    func testStoreWrittenWithoutAPlanOpensWithTheMigrationPlan() throws {
        let storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)
        let conversationID = UUID()

        // Write with NO migration plan — the pre-Step-3 shape.
        try autoreleasepool {
            let configuration = ModelConfiguration(
                DevgenticSchema.configurationName,
                schema: Schema(DevgenticSchemaV1.models),
                url: storeURL
            )
            let container = try ModelContainer(
                for: Schema(DevgenticSchemaV1.models), configurations: configuration
            )
            let context = ModelContext(container)
            context.insert(ConversationSD(id: conversationID, userDefinedTitle: "Pre-plan store"))
            try context.save()
        }

        // Reopen WITH the plan, exactly as the app now does.
        let container = try Self.makeContainer(at: storeURL)
        let context = ModelContext(container)
        let conversations = try context.fetch(FetchDescriptor<ConversationSD>())
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, conversationID)
    }

    // MARK: - G1: structural drift guard

    /// The real guard. Core Data's model hash — the thing that decides whether an existing store
    /// still opens — derives from entity names plus, per property, its name, type, optionality and
    /// transient/unique flags. This test renders exactly those fields into a canonical string and
    /// compares it to a checked-in baseline, so ANY hash-perturbing edit fails here, in
    /// milliseconds, instead of at a user's launch.
    ///
    /// Swift default VALUES are deliberately absent from the descriptor: they do not participate
    /// in the hash (verified empirically), so adding one must NOT fail this test.
    ///
    /// ⚠️ When this fails, do not just paste the new value into the baseline. Read the diff and
    /// decide whether the change needs a migration stage — see the safety table in
    /// SWIFTDATA_MIGRATION_PLAN.md.
    func testSchemaStructureMatchesCheckedInBaseline() throws {
        let current = DevgenticSchema.structuralDescriptor(for: DevgenticSchema.schema)

        if ProcessInfo.processInfo.environment["DEVGENTIC_WRITE_SCHEMA_BASELINE"] != nil {
            // Regeneration escape hatch. Prints the descriptor for pasting into SchemaBaselineV1.swift.
            print("=== BEGIN SCHEMA DESCRIPTOR ===\n\(current)\n=== END SCHEMA DESCRIPTOR ===")
            // ⚠️ SKIP, not `return`. A bare return reports this test as PASSED — so the run that
            // regenerates the baseline also announces that the schema matches it, which is the one
            // moment that claim is least trustworthy. And the documented recipe tells developers to
            // set this variable, so the misleading green is on the normal path, not a corner case.
            // `XCTSkip` makes the suite say "not checked" instead of "checked and fine".
            throw XCTSkip(
                "Baseline regeneration mode — the drift check did NOT run. Paste the descriptor above "
                + "into SchemaBaselineV1.swift, then re-run WITHOUT TEST_RUNNER_DEVGENTIC_WRITE_SCHEMA_BASELINE "
                + "to actually verify it."
            )
        }

        guard !SchemaBaselineV1.descriptor.isEmpty else {
            return XCTFail(
                "SchemaBaselineV1.descriptor is empty. Regenerate it with:\n"
                + "  TEST_RUNNER_DEVGENTIC_WRITE_SCHEMA_BASELINE=1 xcodebuild test-without-building "
                + "-only-testing:devgenticTests/SchemaMigrationTests/testSchemaStructureMatchesCheckedInBaseline"
            )
        }

        guard current != SchemaBaselineV1.descriptor else { return }

        // Emit a line-level diff — a 13-entity descriptor is far too long to eyeball whole.
        let baselineLines = SchemaBaselineV1.descriptor.components(separatedBy: "\n")
        let currentLines = current.components(separatedBy: "\n")
        let removed = Set(baselineLines).subtracting(currentLines).sorted()
        let added = Set(currentLines).subtracting(baselineLines).sorted()

        XCTFail(
            """
            SCHEMA DRIFT — the persisted shape changed. An existing store may no longer open.

            Removed from the baseline (\(removed.count)):
            \(removed.map { "  - \($0)" }.joined(separator: "\n"))

            Added (\(added.count)):
            \(added.map { "  + \($0)" }.joined(separator: "\n"))

            Consult the safety table in SWIFTDATA_MIGRATION_PLAN.md. Adding an OPTIONAL property or
            a Swift default value is safe; adding a non-optional property without a default,
            renaming without @Attribute(originalName:), or changing a type is NOT.
            """
        )
    }

    // MARK: - G56: the mechanism actually works on disk

    /// First on-disk SwiftData test in the repo. Writes rows through the full 13-entity schema,
    /// fully closes the container, then reopens the same files with the same schema and asserts
    /// the rows survived. This is the harness every migration test below reuses.
    func testFullSchemaRoundTripsAcrossAContainerClose() throws {
        let storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)
        let conversationID = UUID()

        try autoreleasepool {
            let container = try Self.makeContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(ConversationSD(id: conversationID, userDefinedTitle: "Fixture chat"))
            context.insert(PromptModel(title: "Fixture prompt", text: "body",
                                       category: "general", isUserDefined: true, tags: ["alpha", "beta"]))
            context.insert(DownloadRecord(backend: .mlx, modelIdentifier: "fixture/model"))
            try context.save()
        }

        // Reopen from scratch — a fresh container over the same files.
        let reopened = try Self.makeContainer(at: storeURL)
        let context = ModelContext(reopened)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationSD>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PromptModel>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DownloadRecord>()), 1)

        let conversation = try XCTUnwrap(try context.fetch(FetchDescriptor<ConversationSD>()).first)
        XCTAssertEqual(conversation.id, conversationID)
        XCTAssertEqual(conversation.userDefinedTitle, "Fixture chat")

        // tags: [String]? is the app's only non-relationship collection attribute and the shape
        // implicated in Apple's OS-26.1 array-storage change (G67) — assert it round-trips.
        let prompt = try XCTUnwrap(try context.fetch(FetchDescriptor<PromptModel>()).first)
        XCTAssertEqual(prompt.tags, ["alpha", "beta"])
    }

    /// The store is FOUR artifacts, not one file (G27). A copy that takes only `.store` can be
    /// missing the newest rows, and `.externalStorage` payloads live outside the store entirely.
    /// This asserts the artifact set `DevgenticSchema.storeArtifactURLs` promises is the set that
    /// actually appears on disk, so recovery/export code can rely on it.
    func testStoreArtifactSetMatchesWhatSwiftDataWritesOnDisk() throws {
        let storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)

        try autoreleasepool {
            let container = try Self.makeContainer(at: storeURL)
            let context = ModelContext(container)
            // An externalStorage payload — large enough that Core Data spills it to _SUPPORT
            // rather than inlining it in the row.
            let blob = Data(repeating: 0xAB, count: 2 * 1024 * 1024)
            context.insert(AttachedImageFileSD(id: UUID(), name: "big.png", url: "file:///tmp/big.png",
                                               fileExtension: "png", binaryData: blob, size: Int64(blob.count)))
            try context.save()
        }

        let artifacts = DevgenticSchema.storeArtifactURLs(for: storeURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.store.path),
                      "Main store file missing.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.support.path),
                      """
                      The .externalStorage support directory did not appear at \(artifacts.support.path).
                      If SwiftData changed its naming, every copy/move/export path that relies on
                      storeArtifactURLs(for:) is now silently incomplete.
                      """)

        // The support directory must be derived from the store's BASE name — this is exactly why
        // renaming the store file alone strands the blobs (G29).
        XCTAssertEqual(artifacts.support.lastPathComponent, ".DevgenticSD_SUPPORT")
    }

    // MARK: - Step 5: the "Start Fresh" contract, end to end

    /// The full promise of the recovery affordance, exercised against real SwiftData containers:
    /// after moving a store aside, a NEW empty store can be created at the original path, AND the
    /// old data is still fully readable under the quarantined name.
    ///
    /// The second half is what makes the action reversible rather than a polite deletion — and it
    /// is only true because the `.externalStorage` sidecar is renamed in step with the store. If it
    /// were left behind, the fresh store would adopt and eventually prune the old blobs (G29).
    func testQuarantinedStoreIsReplaceableAndStillReadable() throws {
        let storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)
        let originalConversationID = UUID()

        try autoreleasepool {
            let container = try Self.makeContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(ConversationSD(id: originalConversationID, userDefinedTitle: "Before the reset"))
            let blob = Data(repeating: 0xCD, count: 2 * 1024 * 1024)  // forces external storage
            context.insert(AttachedImageFileSD(id: UUID(), name: "img.png", url: "file:///tmp/img.png",
                                               fileExtension: "png", binaryData: blob, size: Int64(blob.count)))
            try context.save()
        }

        let result = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-130000")

        // 1. A brand-new store can be created at the original path, and it is EMPTY.
        try autoreleasepool {
            let fresh = try Self.makeContainer(at: storeURL)
            let context = ModelContext(fresh)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationSD>()), 0,
                           "The fresh store is not empty — the old data leaked into it.")
        }

        // 2. The quarantined store still opens and still has everything.
        let recovered = try Self.makeContainer(at: result.quarantinedStoreURL)
        let recoveredContext = ModelContext(recovered)
        let conversations = try recoveredContext.fetch(FetchDescriptor<ConversationSD>())
        XCTAssertEqual(conversations.count, 1, "The quarantined data was not preserved.")
        XCTAssertEqual(conversations.first?.id, originalConversationID)

        // 3. The external blob travelled with it — the part a naive rename loses.
        let attachments = try recoveredContext.fetch(FetchDescriptor<AttachedImageFileSD>())
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.binaryData.count, 2 * 1024 * 1024,
                       "External-storage payload did not survive the quarantine rename.")
    }

    // MARK: - G64/G86: every entity needs a ROW, or "it still opens" proves nothing

    static let allEntitiesFixtureBaseName = "devgentic-all-entities-fixture"

    /// ⚠️ WHY EVERY ENTITY NEEDS A ROW.
    ///
    /// Core Data's mandatory-attribute validation (`NSCocoaErrorDomain 134110`) only fires for
    /// entities that have ROWS TO MIGRATE. The fixture this one replaced carried rows for just 4 of
    /// 12 entities, so a classic bricking change to any of the other eight opened it cleanly.
    ///
    /// MEASURED, not assumed: injecting `var g64Probe: String` (non-optional, no declaration default,
    /// with a DEFAULTED init parameter — the exact `ScheduledTaskModel` trap G64 describes) into
    /// `ScheduledTaskModel` left that fixture's open-test PASSING. Only the baseline diff caught it —
    /// and a baseline is a reviewable signal a developer can regenerate away, not a proof.
    ///
    /// ⚠️ Since the 2026-09-23 schema-history reset this is the ONLY store fixture of the current
    /// shape. Before the first post-release schema change, copy it aside as the previous-version
    /// fixture (procedure step 8 in DevgenticSchemaVersions.swift) — regenerating it in place then
    /// would leave nothing that proves an old store still opens.
    func testAllEntitiesFixtureOpensUnderCurrentSchema() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: Self.allEntitiesFixtureBaseName, withExtension: "store"),
            "All-entities fixture missing — regenerate with DEVGENTIC_WRITE_ALL_ENTITIES_FIXTURE=1."
        )

        // Copy out: opening a bundle resource in place would mutate a committed file.
        let working = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("all-entities-\(UUID().uuidString).store")
        try FileManager.default.copyItem(at: url, to: working)
        defer { try? FileManager.default.removeItem(at: working) }

        let container = try Self.makeContainer(at: working)
        let context = ModelContext(container)

        // Content, not just "it opened" — a store can open with every row silently degraded.
        let scheduled = try context.fetch(FetchDescriptor<ScheduledTaskModel>())
        XCTAssertEqual(scheduled.count, 1)
        // ⚠️ `ScheduledTaskModel.runLimitSeconds` (2026-09-27) was also added after this fixture was
        // written — the second in-place optional attribute on unreleased V1. A pre-change store must
        // open and read it as "no own limit".
        XCTAssertNil(scheduled.first?.runLimitSeconds)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChatMessageSD>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MCPToolItem>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MCPToolDefinitionModel>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkflowLayoutSD>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkflowRunRecordSD>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AttachedTextFileSD>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AttachedImageFileSD>()).count, 1)

        // ⚠️ `ConversationSD.projectPath` (2026-09-24) was added AFTER this fixture was written, as
        // an optional attribute on the still-unreleased V1. This is what proves a store written
        // before it — every developer store — still opens and reads the new field as "absent".
        let conversations = try context.fetch(FetchDescriptor<ConversationSD>())
        XCTAssertEqual(conversations.count, 1)
        XCTAssertNil(conversations.first?.projectPath)
    }

    /// Anti-vacuity guard for the test above: if the fixture ever loses its rows, that test would
    /// keep "passing" in spirit while proving nothing. Assert the coverage claim directly.
    func testAllEntitiesFixtureActuallyCoversEveryEntity() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: Self.allEntitiesFixtureBaseName, withExtension: "store")
        )
        let working = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coverage-\(UUID().uuidString).store")
        try FileManager.default.copyItem(at: url, to: working)
        defer { try? FileManager.default.removeItem(at: working) }

        let context = ModelContext(try Self.makeContainer(at: working))
        var empty: [String] = []
        if try context.fetch(FetchDescriptor<BackendProfile>()).isEmpty { empty.append("BackendProfile") }
        if try context.fetch(FetchDescriptor<ConversationSD>()).isEmpty { empty.append("ConversationSD") }
        if try context.fetch(FetchDescriptor<ChatMessageSD>()).isEmpty { empty.append("ChatMessageSD") }
        if try context.fetch(FetchDescriptor<AttachedTextFileSD>()).isEmpty { empty.append("AttachedTextFileSD") }
        if try context.fetch(FetchDescriptor<AttachedImageFileSD>()).isEmpty { empty.append("AttachedImageFileSD") }
        if try context.fetch(FetchDescriptor<PromptModel>()).isEmpty { empty.append("PromptModel") }
        if try context.fetch(FetchDescriptor<ScheduledTaskModel>()).isEmpty { empty.append("ScheduledTaskModel") }
        if try context.fetch(FetchDescriptor<DownloadRecord>()).isEmpty { empty.append("DownloadRecord") }
        if try context.fetch(FetchDescriptor<MCPToolItem>()).isEmpty { empty.append("MCPToolItem") }
        if try context.fetch(FetchDescriptor<MCPToolDefinitionModel>()).isEmpty { empty.append("MCPToolDefinitionModel") }
        if try context.fetch(FetchDescriptor<WorkflowLayoutSD>()).isEmpty { empty.append("WorkflowLayoutSD") }
        if try context.fetch(FetchDescriptor<WorkflowRunRecordSD>()).isEmpty { empty.append("WorkflowRunRecordSD") }
        if try context.fetch(FetchDescriptor<SkillSD>()).isEmpty { empty.append("SkillSD") }
        if try context.fetch(FetchDescriptor<SkillVersionSD>()).isEmpty { empty.append("SkillVersionSD") }
        if try context.fetch(FetchDescriptor<SkillFileSD>()).isEmpty { empty.append("SkillFileSD") }

        XCTAssertTrue(empty.isEmpty, """
            The all-entities fixture has NO ROWS for: \(empty.joined(separator: ", ")).
            134110 only fires for entities with rows to migrate, so a bricking change to those \
            entities would open this fixture cleanly and the guard would be silently useless. \
            Regenerate with DEVGENTIC_WRITE_ALL_ENTITIES_FIXTURE=1.
            """)
    }

    /// Regenerates the all-entities fixture. Env-gated — it writes a file that gets committed.
    ///
    /// Safe to regenerate while no build has shipped: its only job is "one row per entity, written by
    /// the schema current at generation time". After a release, see step 8 of the schema procedure
    /// FIRST — the file in the repo is then the only record of what a shipped store looks like.
    func testRegenerateAllEntitiesFixture() throws {
        guard ProcessInfo.processInfo.environment["DEVGENTIC_WRITE_ALL_ENTITIES_FIXTURE"] != nil else {
            throw XCTSkip("Set DEVGENTIC_WRITE_ALL_ENTITIES_FIXTURE=1 to regenerate.")
        }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("all-entities-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storeURL = output.appendingPathComponent("\(Self.allEntitiesFixtureBaseName).store")

        try autoreleasepool {
            let container = try Self.makeContainer(at: storeURL)
            let context = ModelContext(container)

            let conversation = ConversationSD(userDefinedTitle: "All-entities fixture")
            context.insert(conversation)

            let message = ChatMessageSD(
                id: UUID(), conversationId: conversation.id, timestamp: Date(), senderType: "user",
                traceID: nil, contentData: try JSONEncoder().encode(MessageContent.plainText("fixture")),
                agentResponseData: nil, timelineEventsData: nil
            )
            message.conversation = conversation
            context.insert(message)

            context.insert(AttachedTextFileSD(
                id: UUID(), name: "notes.txt", url: "/tmp/notes.txt",
                fileExtension: "txt", content: "fixture", size: 7
            ))
            context.insert(AttachedImageFileSD(
                id: UUID(), name: "shot.png", url: "/tmp/shot.png",
                fileExtension: "png", binaryData: Data([0x89, 0x50, 0x4E, 0x47]), size: 4
            ))

            context.insert(PromptModel(title: "Fixture prompt", text: "body", category: "general",
                                       isUserDefined: true, tags: ["fixture"]))
            context.insert(ScheduledTaskModel(displayName: "Fixture task"))
            context.insert(DownloadRecord(backend: .mlx, modelIdentifier: "fixture/model"))
            context.insert(BackendProfile(
                displayName: "Fixture Bot",
                details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
            ))

            let toolDef = MCPToolDefinitionModel(name: "fixture_tool", toolDescription: "does nothing")
            context.insert(MCPToolItem(serverName: "fixture-server", tools: [toolDef]))

            context.insert(WorkflowLayoutSD(workflowProfileID: UUID(), layout: .empty))
            context.insert(WorkflowRunRecordSD(record: WorkflowRunRecord(
                id: UUID(), conversationID: conversation.id, workflowProfileID: UUID(),
                workflowName: "Fixture Workflow", timestamp: Date(), userInput: "go",
                nodeResults: [], finalOutput: "done", variables: [:], status: .completed,
                duration: 1, error: nil
            )))

            // V6 skill library. Inserted as the FULL CHAIN skill -> version -> file, not three
            // orphans: both cascade relationships are part of the shape a migration has to carry,
            // and a fixture with no edges would open cleanly even if they were broken.
            //
            // The file's bytes are deliberately NON-UTF-8. `content` is the schema's second
            // `@Attribute(.externalStorage)` field, and binary is the case the V4/V5 loader silently
            // dropped — a fixture holding only text would not exercise what changed.
            let fixtureFile = SkillFileSD(
                relativePath: "reference/fixture.bin",
                content: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]),
                isExecutable: false
            )
            let fixtureVersion = SkillVersionSD(
                note: "Fixture seed.",
                skillDescription: "A skill that exists only to give these entities rows.",
                allowedTools: ["Read", "Bash(git status:*)"],
                body: "# fixture-skill\nDo the fixture thing.",
                files: [fixtureFile]
            )
            let fixtureSkill = SkillSD(
                name: "fixture-skill",
                origin: .imported,
                latestVersionID: fixtureVersion.id,
                versions: [fixtureVersion]
            )
            context.insert(fixtureSkill)

            try context.save()
        }

        let walPath = storeURL.path + "-wal"
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
        let walIsEmpty = (walSize ?? 0) == 0

        print("=== ALL-ENTITIES FIXTURE WRITTEN ===")
        print("  \(storeURL.path)")
        print(walIsEmpty
              ? "  -wal is empty (checkpointed) — commit the .store ALONE."
              : "  ⚠️ -wal holds \(walSize ?? 0) bytes NOT checkpointed — commit it too or lose the newest rows.")
        XCTAssertTrue(walIsEmpty, "Fixture WAL was not checkpointed — see above before committing.")
    }

    // MARK: - G9: uniqueness pre-flight

    /// ⚠️ Adding `@Attribute(.unique)` to an EXISTING column is not lightweight-safe. If any two rows
    /// already share a value the migration fails on the constraint violation and the container will
    /// not open — for a user whose data was fine a moment earlier, with the opaque `SwiftDataError`
    /// code 1. The app carries 12 such constraints and had no way to answer "would a 13th brick
    /// anyone?" before shipping it.
    func testDuplicateReportFindsARealDuplicateBeforeItBecomesAConstraint() throws {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dupe-\(UUID().uuidString).store")
        defer { for u in [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"),
                          URL(fileURLWithPath: storeURL.path + "-shm")] {
            try? FileManager.default.removeItem(at: u)
        } }

        try autoreleasepool {
            let context = ModelContext(try Self.makeContainer(at: storeURL))
            // `title` carries NO unique constraint today — exactly the shape someone might decide to
            // constrain tomorrow.
            context.insert(PromptModel(title: "Shared", text: "a", category: "general", isUserDefined: true))
            context.insert(PromptModel(title: "Shared", text: "b", category: "general", isUserDefined: true))
            context.insert(PromptModel(title: "Distinct", text: "c", category: "general", isUserDefined: true))
            try context.save()
        }

        let report = DevgenticSchema.duplicateReport(
            storeURL: storeURL,
            columns: [(table: "ZPROMPTMODEL", column: "ZTITLE")]
        )
        // Sizes ride along in the failure message: this test has failed in full runs only (never alone),
        // and whether the rows sat in the -wal or never reached the file is what tells the two causes apart.
        func size(_ suffix: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: storeURL.path + suffix)[.size]) as? Int) ?? -1
        }
        let storeState = "store=\(size("")) wal=\(size("-wal")) shm=\(size("-shm")) report=\(report.summary)"

        XCTAssertFalse(report.isClean, "Two prompts share a title — constraining it would brick this store. \(storeState)")
        XCTAssertEqual(report.offendingColumns["ZPROMPTMODEL.ZTITLE"], 1,
                       "One VALUE is duplicated (not two rows) — the report counts values, not rows.")
        XCTAssertTrue(report.summary.contains("ZPROMPTMODEL.ZTITLE"))
    }

    /// The order-sensitivity regression behind the 2026-08-31 batched-run flake of the test above.
    ///
    /// ⚠️ The report used to open the store `immutable=1` ONLY — a mode that reads the MAIN FILE
    /// and ignores the WAL. Its correctness therefore silently depended on the writing
    /// `ModelContainer` having fully deallocated at the `autoreleasepool` drain, because only the
    /// final close checkpoints the WAL into the main file. In a large batched run, anything that
    /// briefly kept the last context/container reference alive past the drain (async notification
    /// delivery, autorelease traffic in the shared app test host) left the just-written rows —
    /// on a fresh store, the whole schema — sitting in the `-wal`: the scan hit "no such table",
    /// skipped the column, and reported CLEAN. A false "safe to constrain" from the exact tool
    /// meant to stop a `.unique` addition from bricking user stores, surfacing as a test that
    /// failed only in batches.
    ///
    /// This test makes that hazard deterministic instead of timing-dependent: the container is
    /// deliberately STILL OPEN — the WAL deliberately un-checkpointed — while the report runs.
    /// Verified by mutation: with the immutable-only reader restored, this fails every time.
    func testDuplicateReportSeesRowsWhileTheWritingContainerIsStillOpen() throws {
        let storeURL = workDirectory.appendingPathComponent("live-dupe.store")

        let container = try Self.makeContainer(at: storeURL)
        let context = ModelContext(container)
        context.insert(PromptModel(title: "Live", text: "a", category: "general", isUserDefined: true))
        context.insert(PromptModel(title: "Live", text: "b", category: "general", isUserDefined: true))
        try context.save()

        // No autoreleasepool, no container teardown: the SQLite connection is open and the store's
        // committed state lives (at least partly) in the -wal, exactly like the running app's store.
        let report = DevgenticSchema.duplicateReport(
            storeURL: storeURL,
            columns: [(table: "ZPROMPTMODEL", column: "ZTITLE")]
        )
        XCTAssertEqual(
            report.offendingColumns["ZPROMPTMODEL.ZTITLE"], 1,
            """
            A store that is still open elsewhere must be scannable: its committed rows sit in the \
            WAL until checkpoint, and a WAL-blind scan reports a false clean on exactly the data \
            the pre-flight exists to protect.
            """
        )
        withExtendedLifetime(container) {}
    }

    /// A column with no duplicates must report clean — otherwise the pre-flight is noise and nobody
    /// runs it.
    func testDuplicateReportIsCleanWhenValuesAreDistinct() throws {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try autoreleasepool {
            let context = ModelContext(try Self.makeContainer(at: storeURL))
            context.insert(PromptModel(title: "One", text: "a", category: "general", isUserDefined: true))
            context.insert(PromptModel(title: "Two", text: "b", category: "general", isUserDefined: true))
            try context.save()
        }

        let report = DevgenticSchema.duplicateReport(
            storeURL: storeURL, columns: [(table: "ZPROMPTMODEL", column: "ZTITLE")]
        )
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.summary, "No duplicates on any candidate column.")
    }

    /// Identifiers are interpolated into SQL (they cannot be bound), so anything that is not a plain
    /// identifier must be REFUSED rather than executed.
    func testDuplicateReportRefusesNonIdentifierNames() throws {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guard-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try autoreleasepool {
            let context = ModelContext(try Self.makeContainer(at: storeURL))
            context.insert(PromptModel(title: "One", text: "a", category: "general", isUserDefined: true))
            try context.save()
        }

        let report = DevgenticSchema.duplicateReport(storeURL: storeURL, columns: [
            (table: "ZPROMPTMODEL; DROP TABLE ZPROMPTMODEL", column: "ZTITLE"),
            (table: "ZPROMPTMODEL", column: "ZTITLE = 1 OR 1"),
        ])
        XCTAssertTrue(report.isClean, "Malformed identifiers must be skipped, not executed.")

        // And the table is still there — the store was opened read-only and nothing ran.
        let context = ModelContext(try Self.makeContainer(at: storeURL))
        XCTAssertEqual(try context.fetch(FetchDescriptor<PromptModel>()).count, 1)
    }

    /// A missing store must not crash the pre-flight — it is a diagnostic, and a diagnostic that
    /// throws is worse than no diagnostic.
    func testDuplicateReportOnAMissingStoreIsCleanNotFatal() {
        let report = DevgenticSchema.duplicateReport(
            storeURL: URL(fileURLWithPath: "/nonexistent/nope.store"),
            columns: [(table: "ZPROMPTMODEL", column: "ZTITLE")]
        )
        XCTAssertTrue(report.isClean)
    }

    // MARK: - Step 6: the launch-sweep gate

    /// A fresh, isolated defaults domain so these never touch the developer's real preferences.
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "SchemaMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// ⚠️ THE trap this gate had to avoid. Swift seeds `Hashable` per process, so `Schema.hashValue`
    /// differs on every launch — using it would have made the gate fire every single time,
    /// permanently disabling retention while looking like it worked. The fingerprint is a SHA-256
    /// of a canonical descriptor precisely so it is stable.
    func testStructuralFingerprintIsStableAcrossCalls() {
        XCTAssertEqual(DevgenticSchema.structuralFingerprint, DevgenticSchema.structuralFingerprint)
        XCTAssertEqual(DevgenticSchema.structuralFingerprint.count, 64, "Expected a SHA-256 hex digest.")
    }

    /// The fingerprint must be derived from the schema's shape, or the gate is decorative.
    ///
    /// Ties the digest to the descriptor, which is separately proven to track the schema by
    /// `testSchemaStructureMatchesCheckedInBaseline` (demonstrated by injecting a real bricking
    /// change and watching it fail).
    func testStructuralFingerprintIsTheDigestOfTheDescriptor() {
        let expected = SHA256HexForTesting(
            DevgenticSchema.structuralDescriptor(for: DevgenticSchema.schema)
        )
        XCTAssertEqual(DevgenticSchema.structuralFingerprint, expected)
    }

    /// Different shape in, different fingerprint out.
    ///
    /// ⚠️ Note why this does NOT build a reduced `Schema` to compare against: `Schema(_:)` closes
    /// transitively over relationship DESTINATIONS, so dropping `WorkflowRunRecordSD` from the model
    /// list leaves it in the schema anyway — it is reachable from `ConversationSD.workflowRuns`. A
    /// test written that way passes vacuously. Measured, not assumed.
    func testDifferentDescriptorsProduceDifferentFingerprints() {
        let real = DevgenticSchema.structuralDescriptor(for: DevgenticSchema.schema)
        let altered = real.replacingOccurrences(of: "ENTITY PromptModel", with: "ENTITY PromptModelRenamed")

        XCTAssertNotEqual(real, altered, "Test setup failed to alter the descriptor.")
        XCTAssertNotEqual(SHA256HexForTesting(real), SHA256HexForTesting(altered))
    }

    /// The environment override still wins when it is set — that is what keeps a test host from
    /// sweeping a fixture store.
    func testEnvironmentOverrideBeatsTheFingerprint() throws {
        let defaults = try makeIsolatedDefaults()
        DevgenticSchema.recordSuccessfulOpen(defaults: defaults)
        XCTAssertEqual(
            DevgenticSchema.evaluateLaunchSweep(defaults: defaults, suppressedByEnvironment: true),
            .skippedByEnvironment
        )
    }

    private func SHA256HexForTesting(_ text: String) -> String {
        // Mirrors the production digest so the assertions above compare like with like.
        var hasher = SHA256()
        hasher.update(data: Data(text.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// First launch with no recorded fingerprint: DEFER. It is either a brand-new install (where the
    /// sweep is a no-op anyway) or the first launch of the build that added the gate — which may
    /// itself be a migration. The two are indistinguishable, so take the safe one.
    func testNoRecordedFingerprintDefersTheSweep() throws {
        let defaults = try makeIsolatedDefaults()
        guard case .deferSchemaChanged(let previous, _) = DevgenticSchema.evaluateLaunchSweep(defaults: defaults, suppressedByEnvironment: false) else {
            return XCTFail("Expected a deferral when nothing has been recorded.")
        }
        XCTAssertNil(previous)
    }

    /// The steady state: schema unchanged since the last clean open, so the sweep runs.
    func testMatchingFingerprintRunsTheSweep() throws {
        let defaults = try makeIsolatedDefaults()
        DevgenticSchema.recordSuccessfulOpen(defaults: defaults)
        XCTAssertEqual(DevgenticSchema.evaluateLaunchSweep(defaults: defaults, suppressedByEnvironment: false), .run)
    }

    /// A changed schema defers — this is the whole point. A lightweight migration can succeed
    /// structurally while degrading data, and sweeping then writes that state back as authoritative.
    func testChangedFingerprintDefersTheSweep() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("a-fingerprint-from-an-older-schema", forKey: DevgenticSchema.lastOpenedFingerprintKey)

        guard case .deferSchemaChanged(let previous, let current) =
                DevgenticSchema.evaluateLaunchSweep(defaults: defaults, suppressedByEnvironment: false) else {
            return XCTFail("A changed schema must defer the destructive sweep.")
        }
        XCTAssertEqual(previous, "a-fingerprint-from-an-older-schema")
        XCTAssertEqual(current, DevgenticSchema.structuralFingerprint)
    }

    /// ⚠️ The deferral must last exactly ONE launch. If recording were skipped on a deferral, the
    /// gate would latch and retention would never run again — unbounded history, silently.
    func testDeferralLastsExactlyOneLaunch() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("older-schema", forKey: DevgenticSchema.lastOpenedFingerprintKey)

        // Launch 1: schema changed -> defer, then record (as the launch path does).
        guard case .deferSchemaChanged = DevgenticSchema.evaluateLaunchSweep(defaults: defaults, suppressedByEnvironment: false) else {
            return XCTFail("Launch 1 should have deferred.")
        }
        DevgenticSchema.recordSuccessfulOpen(defaults: defaults)

        // Launch 2: same schema -> run.
        XCTAssertEqual(DevgenticSchema.evaluateLaunchSweep(defaults: defaults, suppressedByEnvironment: false), .run,
                       "The deferral latched — retention would never run again.")
    }

    func testRecordingPersistsTheCurrentFingerprint() throws {
        let defaults = try makeIsolatedDefaults()
        DevgenticSchema.recordSuccessfulOpen(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: DevgenticSchema.lastOpenedFingerprintKey),
                       DevgenticSchema.structuralFingerprint)
    }

    // MARK: - Helpers

    /// Opens a container over `storeURL` exactly as `DevgenticApp` does — same schema AND same
    /// migration plan, both by reference rather than by copy, so these tests cannot drift from
    /// production (G54). If the app's open call changes, change it here too.
    private static func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            DevgenticSchema.configurationName,
            schema: DevgenticSchema.schema,
            url: storeURL
        )
        return try ModelContainer(
            for: DevgenticSchema.schema,
            migrationPlan: DevgenticSchema.migrationPlan,
            configurations: configuration
        )
    }
}
