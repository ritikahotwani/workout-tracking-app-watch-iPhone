import Foundation
import Supabase
import WorkoutCore

extension SupabaseClient {
    /// Built from `SUPABASE_URL` / `SUPABASE_ANON_KEY` in Info.plist (set in Config/Secrets.xcconfig).
    /// nil while they're missing or still the example placeholders: backup is then off.
    static func fromInfoPlist() -> SupabaseClient? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let urlString = info["SUPABASE_URL"] as? String, let key = info["SUPABASE_ANON_KEY"] as? String,
              !urlString.contains("YOUR-PROJECT"), !key.isEmpty, key != "your-anon-key",
              let url = URL(string: urlString), url.scheme == "https", url.host != nil
        else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key, options: .init(
            db: .init(encoder: .sync, decoder: .sync),  // explicit nulls + ISO 8601 dates, as the DTOs expect
            auth: .init(emitLocalSessionAsInitialSession: true)
        ))
    }
}

/// `RemoteStore` over PostgREST. RLS limits every query to the signed-in user's rows.
struct SupabaseRemoteStore: RemoteStore {
    let client: SupabaseClient

    func upsert<D: SyncDTO>(_ rows: [D], table: String) async throws {
        try await mappingErrors {
            try await client.from(table).upsert(rows, onConflict: "user_id,id", returning: .minimal).execute()
        }
    }

    func fetch<D: SyncDTO>(_ type: D.Type, table: String, after cursor: SyncCursor?, limit: Int) async throws -> [RemoteRow<D>] {
        try await mappingErrors {
            var query = client.from(table).select("*")
            if let cursor { query = query.or(cursor.postgrestFilter) }
            return try await query.order("server_updated_at").order("id").limit(limit).execute().value
        }
    }

    @discardableResult private func mappingErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            _ = try await client.auth.session  // refreshes an expired token; throws when there's no session
        } catch let error as URLError {
            throw error
        } catch {
            throw SyncError.signedOut
        }
        do {
            return try await body()
        } catch let error as PostgrestError {
            throw SyncError(httpStatus: nil, postgresCode: error.code) ?? error
        } catch let error as HTTPError {
            throw SyncError(httpStatus: error.response.statusCode, postgresCode: nil) ?? error
        }
    }
}
