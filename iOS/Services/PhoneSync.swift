import Foundation
import SwiftData
import WatchConnectivity
import WorkoutCore

/// iPhone side of WatchConnectivity (PLAN §3.1). Sends library, routines, units and per-exercise snapshots
/// as the application context; merges sessions and body weight the watch queues with `transferUserInfo`.
@MainActor
final class PhoneSync: NSObject, WCSessionDelegate {
    private let container: ModelContainer
    /// Above this the context goes as a file (the application-context limit is ~65 KB).
    private let contextLimit = 60_000

    init(container: ModelContainer) {
        self.container = container
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Pushes the latest library + snapshot to the watch. Cheap to call often: only the latest state is delivered.
    func sendContext() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let ctx = container.mainContext
        do {
            // Soft-deleted rows are included so deletions reach the watch through LWW.
            let payload = ConnectivityPayload(
                kind: .context,
                exercises: try ctx.fetch(FetchDescriptor<Exercise>()).map(ExerciseDTO.init),
                routines: try ctx.fetch(FetchDescriptor<Routine>()).map(RoutineDTO.init),
                routineExercises: try ctx.fetch(FetchDescriptor<RoutineExercise>()).map(RoutineExerciseDTO.init),
                weightUnit: UserDefaults.standard.string(forKey: "weightUnit"),
                distanceUnit: UserDefaults.standard.string(forKey: "distanceUnit"),
                snapshots: ExerciseSnapshot.make(from: try Queries.loggedSets(in: ctx)))
            let data = try payload.encoded()
            if data.count > contextLimit {
                for transfer in session.outstandingFileTransfers { transfer.cancel() }  // only the newest matters
                let url = URL.temporaryDirectory.appending(path: "context-\(UUID().uuidString).json")
                try data.write(to: url)
                session.transferFile(url, metadata: nil)
            } else {
                try session.updateApplicationContext([ConnectivityPayload.key: data])
            }
        } catch {
            print("Sending watch context failed: \(error)")
        }
    }

    private func merge(_ payload: ConnectivityPayload) {
        let ctx = container.mainContext
        do {
            try payload.merge(into: ctx, markForPush: true)  // marked so they back up to Supabase
            try ctx.save()
        } catch {
            print("Merging watch data failed: \(error)")
            return
        }
        didMergeWatchData()
    }

    /// Runs after watch rows are merged and saved. Integration hook for the Supabase backup.
    var onMerge: (() -> Void)?

    func didMergeWatchData() {
        onMerge?()  // back up merged watch rows to Supabase
        sendContext()  // refresh the watch's snapshot with the merged session
    }

    // MARK: WCSessionDelegate (called off the main actor)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error { print("WCSession activation failed: \(error)") }
        Task { @MainActor in self.sendContext() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.sendContext() }  // e.g. watch app just installed
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()  // switched to another watch
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[ConnectivityPayload.key] as? Data else { return }
        do {
            let payload = try ConnectivityPayload.decode(data)
            Task { @MainActor in self.merge(payload) }
        } catch {
            print("Undecodable watch payload: \(error)")
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
