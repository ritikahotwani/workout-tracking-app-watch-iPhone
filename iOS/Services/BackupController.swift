import AuthenticationServices
import Foundation
import Network
import Observation
import Supabase
import SwiftData
import WorkoutCore

/// Owns Supabase auth and the one `SyncEngine`, and decides when to back up (PLAN §3.2).
/// Syncs run off the main actor; nothing here blocks the UI.
@MainActor @Observable
final class BackupController {
    /// nil when Secrets.xcconfig isn't filled in (or in demo mode): backup is off.
    @ObservationIgnored let client: SupabaseClient?
    private(set) var userID: UUID?
    private(set) var isSyncing = false
    /// The first sync after sign-in, which pulls everything down (empty cursor = full pull).
    private(set) var isRestoring = false
    private(set) var lastBackupAt = UserDefaults.standard.object(forKey: "lastBackupAt") as? Date
    private(set) var lastErrorMessage: String?
    /// Signed in, but this iPhone holds another account's data: Settings asks before replacing it.
    private(set) var pendingAccountSwitch: UUID?

    var isConfigured: Bool { client != nil }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var soonTask: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var online: Bool?

    init(container: ModelContainer) {
        self.container = container
        // Demo/UI-test data is in memory only and must never reach a real account.
        client = DemoData.isEnabled ? nil : SupabaseClient.fromInfoPlist()
        engine = client.map { SyncEngine(container: container, remote: SupabaseRemoteStore(client: $0)) }
        userID = client?.auth.currentUser?.id
        if let userID { UserDefaults.standard.set(userID.uuidString, forKey: Self.lastUserKey) }

        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in self?.connectivityChanged(isOnline) }
        }
        if client != nil { monitor.start(queue: .global(qos: .utility)) }
    }

    /// Back up now: push local changes, then pull. If a sync is running, another follows it.
    func syncNow() {
        guard let engine, let userID else { return }
        if isSyncing { syncAgain = true; return }
        // Flush unsaved UI edits so they're in the store the engine reads.
        do { try container.mainContext.save() } catch { print("Save before backup failed: \(error)") }
        isSyncing = true
        Task {
            do {
                let result = try await Task.detached { try await engine.sync(userID: userID) }.value
                lastBackupAt = result.finishedAt
                UserDefaults.standard.set(result.finishedAt, forKey: "lastBackupAt")
                lastErrorMessage = nil
            } catch {
                lastErrorMessage = friendlyMessage(for: error)
                if case SyncError.signedOut = error { self.userID = client?.auth.currentSession?.user.id }
            }
            isSyncing = false
            isRestoring = false
            if syncAgain { syncAgain = false; syncNow() }
        }
    }

    /// For workout end and watch merges: backs up a moment later, coalescing bursts.
    func syncSoon() {
        soonTask?.cancel()
        soonTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { syncNow() }
        }
    }

    /// Supabase sign-in with the Apple identity token (nil when the Apple step failed), then restore.
    func signIn(idToken: String?, nonce: String) async {
        guard let client else { return }
        do {
            guard let idToken else { throw ASAuthorizationError(.failed) }
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce))
            let newID = session.user.id
            if let last = UserDefaults.standard.string(forKey: Self.lastUserKey).flatMap(UUID.init(uuidString:)),
               last != newID, (try? SyncEngine.hasRows(ownedBy: last, in: container.mainContext)) == true
            {
                pendingAccountSwitch = newID
                return
            }
            adopt(newID)
        } catch let error as URLError {
            lastErrorMessage = friendlyMessage(for: error)
        } catch {
            lastErrorMessage = "Couldn't sign in. Please try again."
        }
    }

    /// Account switch confirmed: wipes local rows (built-ins re-seeded), then restores `pendingAccountSwitch`.
    func replaceLocalData() async {
        guard let engine, let newID = pendingAccountSwitch else { return }
        pendingAccountSwitch = nil
        do {
            try SyncEngine.wipeLocalData(container.mainContext)
            await engine.clearCursors(userID: newID)
            adopt(newID)
        } catch {
            print("Wipe before account switch failed: \(error)")
            await signOut()
            lastErrorMessage = "Couldn't replace the data on this iPhone. Please try again."
        }
    }

    /// Account switch declined: keep the local data and sign back out.
    func cancelAccountSwitch() async {
        pendingAccountSwitch = nil
        await signOut()
    }

    private static let lastUserKey = "lastSignedInUserID"

    private func adopt(_ id: UUID) {
        userID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastUserKey)
        lastErrorMessage = nil
        isRestoring = true
        syncNow()
    }

    /// Signs out this device only. Local data stays; it just stops backing up.
    func signOut() async {
        try? await client?.auth.signOut(scope: .local)
        userID = nil
        lastErrorMessage = nil
    }

    private func connectivityChanged(_ isOnline: Bool) {
        defer { online = isOnline }
        if isOnline, online == false { syncNow() }  // back online; the first report at launch doesn't count
    }
}
