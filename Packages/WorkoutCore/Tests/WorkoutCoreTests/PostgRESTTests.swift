import Foundation
import Testing
import WorkoutCore

@Suite struct PostgRESTTests {
    @Test func cursorFilter() {
        let id = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000000F")!
        let ts = "2026-11-21T10:00:00.123456+00:00"
        let filter = SyncCursor(serverUpdatedAt: ts, id: id).postgrestFilter
        #expect(filter == "server_updated_at.gt.\"\(ts)\",and(server_updated_at.eq.\"\(ts)\",id.gt.0a1b2c3d-0000-4000-8000-00000000000f)")

        // supabase-swift's query escaping (Helpers/FoundationExtensions.swift `sbURLQueryAllowed`) sends `+` as %2B.
        let sdkAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: ":#[]@!$&'()*+,;="))
        let sent = filter.addingPercentEncoding(withAllowedCharacters: sdkAllowed)!
        #expect(sent.contains("123456%2B00%3A00") && !sent.contains("+"))
    }

    @Test func errorMapping() {
        #expect(SyncError(httpStatus: 401, postgresCode: nil) == .signedOut)
        #expect(SyncError(httpStatus: nil, postgresCode: "PGRST301") == .signedOut)
        #expect(SyncError(httpStatus: nil, postgresCode: "PGRST303") == .signedOut)  // JWT expired
        #expect(SyncError(httpStatus: nil, postgresCode: "42501") == .serverRejected)  // RLS
        #expect(SyncError(httpStatus: nil, postgresCode: "23514") == .serverRejected)  // check constraint
        #expect(SyncError(httpStatus: 400, postgresCode: nil) == .serverRejected)
        #expect(SyncError(httpStatus: 403, postgresCode: nil) == .serverRejected)
        #expect(SyncError(httpStatus: 500, postgresCode: nil) == nil)
        #expect(SyncError(httpStatus: 503, postgresCode: "PGRST000") == nil)
        #expect(SyncError(httpStatus: nil, postgresCode: nil) == nil)
    }
}
