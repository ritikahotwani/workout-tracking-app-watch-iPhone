import Foundation
import Testing
@testable import WorkoutCore

@MainActor @Suite struct BodyMassImportTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func insertsNewSamplesAsHealthEntries() {
        let a = BodyMassSample(uuid: UUID(), date: t0, weightKg: 80)
        let inserts = BodyMassImport.apply(added: [a, a], deleted: [], to: [])  // duplicate in batch
        #expect(inserts.count == 1)
        #expect(inserts[0].healthKitSampleID == a.uuid)
        #expect(inserts[0].source == .health)
        #expect(inserts[0].weightKg == 80)
        #expect(inserts[0].needsPush)
    }

    @Test func neverReimportsOurOwnSamples() {
        let ours = BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: UUID(), source: .app)
        ours.needsPush = false
        let echo = BodyMassSample(uuid: ours.healthKitSampleID!, date: t0, weightKg: 80.0001)
        #expect(BodyMassImport.apply(added: [echo], deleted: [], to: [ours]).isEmpty)
        #expect(ours.weightKg == 80)
        #expect(!ours.needsPush)
    }

    @Test func updatesChangedHealthEntryButNotDeletedOnes() {
        let live = BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: UUID(), source: .health)
        let gone = BodyWeightEntry(date: t0, weightKg: 81, healthKitSampleID: UUID(), source: .health, deletedAt: t0)
        let inserts = BodyMassImport.apply(
            added: [.init(uuid: live.healthKitSampleID!, date: t0, weightKg: 79),
                    .init(uuid: gone.healthKitSampleID!, date: t0, weightKg: 70)],
            deleted: [], to: [live, gone])
        #expect(inserts.isEmpty)
        #expect(live.weightKg == 79)
        #expect(gone.weightKg == 81)
        #expect(gone.deletedAt == t0)
    }

    @Test func healthDeletionSoftDeletes() {
        let ours = BodyWeightEntry(date: t0, weightKg: 80, healthKitSampleID: UUID(), source: .app)
        let theirs = BodyWeightEntry(date: t0, weightKg: 81, healthKitSampleID: UUID(), source: .health)
        let untouched = BodyWeightEntry(date: t0, weightKg: 82, healthKitSampleID: UUID(), source: .health)
        let inserts = BodyMassImport.apply(added: [], deleted: [ours.healthKitSampleID!, theirs.healthKitSampleID!, UUID()],
                                           to: [ours, theirs, untouched])
        #expect(inserts.isEmpty)
        #expect(ours.deletedAt != nil && ours.needsPush)
        #expect(theirs.deletedAt != nil)
        #expect(untouched.deletedAt == nil)
    }

    @Test func addedAndDeletedInSameBatchIsSkipped() {
        let s = BodyMassSample(uuid: UUID(), date: t0, weightKg: 80)
        #expect(BodyMassImport.apply(added: [s], deleted: [s.uuid], to: []).isEmpty)
    }
}
