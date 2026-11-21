import Foundation
import SwiftData
import WatchConnectivity
import WorkoutCore

/// Watch side of WatchConnectivity (PLAN §3.1). Applies the phone's library, units and snapshots, and queues
/// logged rows to the phone with `transferUserInfo`. The watch never talks to Supabase, so here `needsPush`
/// means "not yet sent to the phone".
@MainActor @Observable
final class WatchSync: NSObject, WCSessionDelegate {
    /// Phone-side history per exercise, merged with local history for prefill, last time and PRs.
    private(set) var snapshots: [UUID: ExerciseSnapshot] = [:]
    @ObservationIgnored private let container: ModelContainer
    private static let snapshotURL = URL.applicationSupportDirectory.appending(path: "snapshots.json")
    private static let lastContextKey = "lastContextSentAt"

    init(container: ModelContainer) {
        self.container = container
        super.init()
        if let data = try? Data(contentsOf: Self.snapshotURL),
           let list = try? JSONDecoder.sync.decode([ExerciseSnapshot].self, from: data) {
            snapshots = Self.index(list)
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Queues every unsent row: one userInfo per ended session (with its exercises and sets), one for body weights.
    /// Open sessions wait until they end. Delivery is queued by the system and survives being offline.
    func flush() {
        guard WCSession.default.activationState == .activated else { return }
        let ctx = container.mainContext
        do {
            let entries = try ctx.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { $0.needsPush }))
            let sets = try ctx.fetch(FetchDescriptor<SetEntry>(predicate: #Predicate { $0.needsPush }))
            let parentIDs = Array(Set(sets.map(\.sessionExerciseID)))
            let parents = try ctx.fetch(FetchDescriptor<SessionExercise>(predicate: #Predicate { parentIDs.contains($0.id) }))
            let sessionOf = Dictionary(parents.map { ($0.id, $0.sessionID) }, uniquingKeysWith: { a, _ in a })

            let dirty = try ctx.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.needsPush }))
            let ids = Array(Set(dirty.map(\.id) + entries.map(\.sessionID) + sets.compactMap { sessionOf[$0.sessionExerciseID] }))
            let sessions = try ctx.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { ids.contains($0.id) && $0.endedAt != nil }))
            for session in sessions {
                let es = entries.filter { $0.sessionID == session.id }
                let ss = sets.filter { sessionOf[$0.sessionExerciseID] == session.id }
                try send(ConnectivityPayload(kind: .session, sessions: [.init(session)], sessionExercises: es.map(SessionExerciseDTO.init),
                                             sets: ss.map(SetEntryDTO.init)),
                         rows: [session] + es + ss)
            }

            let weights = try ctx.fetch(FetchDescriptor<BodyWeightEntry>(predicate: #Predicate { $0.needsPush }))
            if !weights.isEmpty {
                try send(ConnectivityPayload(kind: .bodyWeight, bodyWeights: weights.map(BodyWeightEntryDTO.init)), rows: weights)
            }
            try ctx.save()
        } catch {
            print("Sending to iPhone failed: \(error)")
        }
    }

    /// Queues `payload` and marks `rows` sent. This runs synchronously on the main actor, so no edit can land between
    /// encoding and clearing (SyncEngine's `updatedAt` re-check guards an `await` that doesn't exist here).
    private func send(_ payload: ConnectivityPayload, rows: [any Syncable]) throws {
        WCSession.default.transferUserInfo([ConnectivityPayload.key: try payload.encoded()])
        for row in rows { row.needsPush = false }
    }

    private func apply(_ payload: ConnectivityPayload) {
        let defaults = UserDefaults.standard
        guard payload.kind == .context,
              payload.sentAt > (defaults.object(forKey: Self.lastContextKey) as? Date ?? .distantPast) else { return }
        let ctx = container.mainContext
        do {
            try payload.merge(into: ctx, markForPush: false)
            try ctx.save()
            if let unit = payload.weightUnit { defaults.set(unit, forKey: "weightUnit") }
            if let unit = payload.distanceUnit { defaults.set(unit, forKey: "distanceUnit") }
            snapshots = Self.index(payload.snapshots)
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder.sync.encode(payload.snapshots).write(to: Self.snapshotURL, options: .atomic)
            defaults.set(payload.sentAt, forKey: Self.lastContextKey)
        } catch {
            print("Applying iPhone context failed: \(error)")
        }
    }

    private static func index(_ list: [ExerciseSnapshot]) -> [UUID: ExerciseSnapshot] {
        Dictionary(list.map { ($0.exerciseID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: WCSessionDelegate (called off the main actor: decode here, apply on main)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { print("WCSession activation failed: \(error)") }
        receive(session.receivedApplicationContext[ConnectivityPayload.key] as? Data)  // in case it arrived while not running
        Task { @MainActor in self.flush() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext[ConnectivityPayload.key] as? Data)
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        receive(try? Data(contentsOf: file.fileURL))  // the file is deleted when this returns
    }

    private nonisolated func receive(_ data: Data?) {
        guard let data else { return }
        do {
            let payload = try ConnectivityPayload.decode(data)
            Task { @MainActor in self.apply(payload) }
        } catch {
            print("Undecodable iPhone payload: \(error)")
        }
    }
}
