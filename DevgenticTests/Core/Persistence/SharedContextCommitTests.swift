// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SharedContextCommitTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@Model final class PoisonChildSD {
    var n: Int
    init(n: Int) { self.n = n }
}

/// Fails validation while it has no children — on every save of the context it was inserted into.
@Model final class PoisonParentSD {
    var name: String
    @Relationship(deleteRule: .cascade, minimumModelCount: 1) var children: [PoisonChildSD] = []
    init(name: String) { self.name = name }
}

@MainActor
final class SharedContextCommitTests: XCTestCase {

    /// Held: a `ModelContext` whose container has been released traps on first use.
    private var container: ModelContainer?

    override func tearDown() async throws { container = nil }

    private func mainContext() throws -> ModelContext {
        let made = try ModelContainer(for: PoisonParentSD.self, PoisonChildSD.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = made
        return made.mainContext
    }

    private func pending(_ context: ModelContext) -> Int {
        context.insertedModelsArray.count + context.changedModelsArray.count + context.deletedModelsArray.count
    }

    func testThePoisonFailsEverySave() throws {
        let context = try mainContext()
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())
        context.insert(PoisonChildSD(n: 1))
        XCTAssertThrowsError(try context.save(), "an unrelated write must fail with it — that is the poisoning")
    }

    /// ⚠️⚠️ The platform fact the RAG-27 design rests on.
    func testRollbackAfterAFailedSaveDoesNotClearThePoison() throws {
        let context = try mainContext()
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())
        context.rollback()
        XCTAssertEqual(pending(context), 0, "SwiftData reports nothing pending after the rollback…")

        context.insert(PoisonChildSD(n: 1))
        XCTAssertThrowsError(try context.save(), "…yet the poison still fails the next save. If this now SUCCEEDS, rollback works on this SDK — revisit RAG-27.")
    }

    /// What rollback does to an in-memory edit differs by OS: macOS 26 leaves the edited value (99);
    /// macOS 27 restores the committed one (1). RAG-27 does not depend on which — it depends on the
    /// poison surviving the rollback (`testRollbackAfterAFailedSaveDoesNotClearThePoison`), which
    /// holds on both. So this pins the two known outcomes and fails on a THIRD, i.e. a new platform
    /// behaviour worth a look.
    func testRollbackAfterAFailedSaveLeavesTheEditedValueOnlyOnOlderSDKs() throws {
        let context = try mainContext()
        let kept = PoisonChildSD(n: 1)
        context.insert(kept)
        try context.save()

        kept.n = 99
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())
        context.rollback()
        let knownOutcomes: Set<Int> = [
            99, // macOS 26: the edit survives the rollback
            1,  // macOS 27: the rollback restores the committed value
        ]
        XCTAssertTrue(knownOutcomes.contains(kept.n),
                      "rollback left n == \(kept.n), a behaviour neither known SDK shows — revisit RAG-27")
    }

    /// Recovery exists — in a context the poison never entered.
    func testAFreshContextSavesWhileTheMainContextIsPoisoned() throws {
        let context = try mainContext()
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())

        let fresh = ModelContext(try XCTUnwrap(container))
        fresh.insert(PoisonChildSD(n: 3))
        XCTAssertNoThrow(try fresh.save())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoisonChildSD>()), 1, "the main context sees the fresh context's row")
    }
}
