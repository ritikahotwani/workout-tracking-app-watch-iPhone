import Foundation
import SwiftData

/// Last-write-wins on `updatedAt` (PLAN §3.3). Ties keep local.
public enum LWW {
    public static func shouldApply(remoteUpdatedAt: Date, localUpdatedAt: Date?) -> Bool {
        guard let localUpdatedAt else { return true }
        return remoteUpdatedAt > localUpdatedAt
    }

    /// Inserts `dto` or overwrites the local row if remote is newer. Returns whether it was applied.
    /// Applied rows get `needsPush = markForPush` (true when the phone receives from the watch, false from Supabase).
    @discardableResult
    public static func upsert<D: SyncDTO>(_ dto: D, into context: ModelContext, markForPush: Bool) throws -> Bool {
        let id = dto.id
        var descriptor = FetchDescriptor<D.Model>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let local = try context.fetch(descriptor).first
        guard shouldApply(remoteUpdatedAt: dto.updatedAt, localUpdatedAt: local?.updatedAt) else { return false }
        let model = local ?? dto.makeModel()
        if local == nil { context.insert(model) } else { dto.apply(to: model) }
        model.needsPush = markForPush
        return true
    }
}
