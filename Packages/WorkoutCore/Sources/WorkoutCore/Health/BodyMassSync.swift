import Foundation
import SwiftData

/// A Health body-mass sample reduced to what we store. Health-free so the merge is testable.
public struct BodyMassSample: Equatable, Sendable {
    public var uuid: UUID
    public var date: Date
    public var weightKg: Double

    public init(uuid: UUID, date: Date, weightKg: Double) {
        self.uuid = uuid
        self.date = date
        self.weightKg = weightKg
    }
}

public enum BodyMassImport {
    /// Merges one anchored-query batch into `existing` (entries with a `healthKitSampleID`).
    /// Updates/soft-deletes existing entries in place and returns the new entries to insert.
    /// - Samples we wrote (an `.app` entry already holds the UUID) are never re-imported.
    /// - Entries deleted in-app stay deleted.
    /// - A sample deleted in Health soft-deletes its entry, whoever wrote it.
    public static func apply(added: [BodyMassSample], deleted: Set<UUID>, to existing: [BodyWeightEntry]) -> [BodyWeightEntry] {
        var bySample = Dictionary(existing.compactMap { e in e.healthKitSampleID.map { ($0, e) } }) { first, _ in first }
        var inserts: [BodyWeightEntry] = []
        for sample in added where !deleted.contains(sample.uuid) {
            if let entry = bySample[sample.uuid] {
                guard entry.source == .health, entry.deletedAt == nil,
                      entry.weightKg != sample.weightKg || entry.date != sample.date else { continue }
                entry.weightKg = sample.weightKg
                entry.date = sample.date
                entry.touch()
            } else {
                let entry = BodyWeightEntry(date: sample.date, weightKg: sample.weightKg,
                                            healthKitSampleID: sample.uuid, source: .health)
                bySample[sample.uuid] = entry
                inserts.append(entry)
            }
        }
        for uuid in deleted {
            if let entry = bySample[uuid], entry.deletedAt == nil { entry.markDeleted() }
        }
        return inserts
    }
}

#if canImport(HealthKit)
import HealthKit

/// Best-effort Health sync for body weight (PLAN §4). Logging keeps working when Health is
/// unavailable or denied (e.g. macOS, where HealthKit compiles but has no data).
@MainActor
public final class BodyMassSync {
    public static let shared = BodyMassSync()

    private let store = HKHealthStore()
    private let type = HKQuantityType(.bodyMass)
    private let anchorKey = "bodyMassAnchor"
    private var isImporting = false

    private var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Share + read `bodyMass`. Prompts only the first time.
    public func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [type], read: [type])
    }

    /// Writes `entry` to Health (kg) and stores the sample UUID on it.
    /// The UUID is set before the write so a concurrent import can't echo it back.
    public func save(_ entry: BodyWeightEntry) async throws {
        guard isAvailable else { return }
        try await requestAuthorization()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: entry.weightKg),
                                      start: entry.date, end: entry.date)
        entry.healthKitSampleID = sample.uuid
        entry.touch()
        try entry.modelContext?.save()
        do {
            try await store.save(sample)
        } catch {
            entry.healthKitSampleID = nil
            entry.touch()
            try? entry.modelContext?.save()
            throw error
        }
    }

    /// Deletes the sample we wrote for `entry`. No-op for entries imported from Health.
    public func delete(_ entry: BodyWeightEntry) async throws {
        guard isAvailable, entry.source == .app, let id = entry.healthKitSampleID else { return }
        _ = try await store.deleteObjects(of: type, predicate: HKQuery.predicateForObject(with: id))
    }

    /// Imports body-mass changes since the last persisted anchor.
    public func importChanges(into context: ModelContext) async throws {
        guard isAvailable, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        try await requestAuthorization()

        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: type)], anchor: loadAnchor())
        let result = try await descriptor.result(for: store)
        let kg = HKUnit.gramUnit(with: .kilo)
        let added = result.addedSamples.map {
            BodyMassSample(uuid: $0.uuid, date: $0.startDate, weightKg: $0.quantity.doubleValue(for: kg))
        }
        let deleted = Set(result.deletedObjects.map(\.uuid))

        let existing = try context.fetch(FetchDescriptor<BodyWeightEntry>(predicate: #Predicate { $0.healthKitSampleID != nil }))
        for entry in BodyMassImport.apply(added: added, deleted: deleted, to: existing) { context.insert(entry) }
        try context.save()
        // Only advance the anchor once the batch is stored.
        let data = try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: anchorKey)
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}
#endif
