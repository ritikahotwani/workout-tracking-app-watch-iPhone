import Foundation

// SDK-free PostgREST helpers for the app's Supabase `RemoteStore`, kept here so they're unit-tested.

extension SyncCursor {
    /// Filter for rows after this cursor in `(server_updated_at, id)` order, to pass to supabase-swift's `.or(_:)`,
    /// which wraps it in parentheses and percent-encodes it (so the timestamp's `+` is sent as `%2B`).
    /// The timestamp goes back verbatim and double-quoted so PostgREST compares it exactly.
    public var postgrestFilter: String {
        let ts = "\"\(serverUpdatedAt)\""
        return "server_updated_at.gt.\(ts),and(server_updated_at.eq.\(ts),id.gt.\(id.uuidString.lowercased()))"
    }
}

extension SyncError {
    /// Maps a failed PostgREST request to a `SyncError`; nil means rethrow the original error.
    /// PGRST301/302/303 are PostgREST's JWT errors (invalid, missing, expired; all HTTP 401).
    public init?(httpStatus: Int?, postgresCode: String?) {
        if ["PGRST301", "PGRST302", "PGRST303"].contains(postgresCode) || httpStatus == 401 {
            self = .signedOut
        } else if ["42501", "23514"].contains(postgresCode) || (400..<500).contains(httpStatus ?? 0) {
            self = .serverRejected
        } else {
            return nil
        }
    }
}
