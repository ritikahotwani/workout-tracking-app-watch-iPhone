import Foundation
import SwiftData
import Testing
@testable import WorkoutCore

@Suite struct ExerciseIDTests {
    @Test func nameKey() {
        #expect(Exercise.nameKey(for: "  Bench\t  PRESS \n") == "bench press")
    }

    @Test func builtInIDIsDeterministicUUIDv5() {
        let id = Exercise.builtInID(for: "Bench Press")
        #expect(id == Exercise.builtInID(for: "Bench Press"))
        #expect(id == Exercise.builtInID(for: " bench   press"))
        #expect(id != Exercise.builtInID(for: "Squat"))
        // Reference: Python uuid.uuid5(namespace, "bench press").
        #expect(id.uuidString.lowercased() == "45f76b0a-310a-5191-8ea6-203ecec244b0")
    }

    @Test func renameUpdatesKeyAndMarksDirty() {
        let e = Exercise(name: "Squat", needsPush: false)
        e.rename("Back  Squat")
        #expect(e.nameKey == "back squat")
        #expect(e.needsPush)
    }
}

@Suite struct LWWTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func rule() {
        #expect(LWW.shouldApply(remoteUpdatedAt: t0, localUpdatedAt: nil))
        #expect(LWW.shouldApply(remoteUpdatedAt: t0 + 1, localUpdatedAt: t0))
        #expect(!LWW.shouldApply(remoteUpdatedAt: t0 - 1, localUpdatedAt: t0))
        #expect(!LWW.shouldApply(remoteUpdatedAt: t0, localUpdatedAt: t0))
    }

    @MainActor @Test func upsertInMemory() throws {
        let container = try makeModelContainer(inMemory: true)
        let ctx = container.mainContext
        let local = Routine(name: "Chest", updatedAt: t0, needsPush: false)
        ctx.insert(local)
        try ctx.save()
        var dto = RoutineDTO(local)

        // Older loses, tie keeps local.
        dto.name = "Old"; dto.updatedAt = t0 - 10
        #expect(try !LWW.upsert(dto, into: ctx, markForPush: true))
        dto.updatedAt = t0
        #expect(try !LWW.upsert(dto, into: ctx, markForPush: true))
        #expect(local.name == "Chest" && !local.needsPush)

        // Newer wins and soft delete propagates.
        dto.name = "Chest Day"; dto.updatedAt = t0 + 10; dto.deletedAt = t0 + 10
        #expect(try LWW.upsert(dto, into: ctx, markForPush: true))
        #expect(local.name == "Chest Day" && local.deletedAt == t0 + 10 && local.needsPush)

        // Unknown id inserts.
        let fresh = SetEntryDTO(SetEntry(sessionExerciseID: UUID(), weightKg: 60, reps: 8, updatedAt: t0))
        #expect(try LWW.upsert(fresh, into: ctx, markForPush: false))
        let fetched = try ctx.fetch(FetchDescriptor<SetEntry>())
        #expect(fetched.count == 1 && fetched[0].id == fresh.id && fetched[0].weightKg == 60 && !fetched[0].needsPush)
        #expect(try ctx.fetch(FetchDescriptor<Routine>()).count == 1)
    }
}

@Suite struct DTOTests {
    // Exactly representable fraction so the millisecond ISO 8601 round trip is exact.
    let t = Date(timeIntervalSince1970: 1_800_000_000.25)

    func roundTrip<D: SyncDTO>(_ dto: D) throws -> (D, [String: Any]) {
        let data = try JSONEncoder.sync.encode(dto)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (try JSONDecoder.sync.decode(D.self, from: data), json)
    }

    @Test func setEntrySnakeCase() throws {
        let dto = SetEntryDTO(SetEntry(sessionExerciseID: UUID(), sortOrder: 2, weightKg: 82.5, reps: 5,
                                       restSeconds: 90, completedAt: t, createdAt: t, updatedAt: t, deletedAt: t))
        let (decoded, json) = try roundTrip(dto)
        #expect(decoded == dto)
        for key in ["id", "user_id", "created_at", "updated_at", "deleted_at", "session_exercise_id", "sort_order",
                    "weight_kg", "reps", "rest_seconds", "completed_at"] {
            #expect(json[key] != nil, "missing \(key)")
        }
        #expect(json["needs_push"] == nil && json["needsPush"] == nil)
        #expect(json["user_id"] is NSNull && json["distance_meters"] is NSNull)  // nil sent as explicit null
        #expect(json["updated_at"] as? String == "2027-01-15T08:00:00.250Z", "\(json["updated_at"] ?? "")")
    }

    @Test func allModelsRoundTrip() throws {
        let e = Exercise(name: "Rowing", muscleGroup: .cardio, kind: .cardio, cardioActivity: .rowing, createdAt: t, updatedAt: t)
        let (ed, ej) = try roundTrip(ExerciseDTO(e))
        #expect(ed == ExerciseDTO(e) && ej["cardio_activity"] as? String == "rowing" && ej["muscle_group"] as? String == "cardio")
        #expect(try roundTrip(RoutineDTO(Routine(name: "Legs", createdAt: t, updatedAt: t))).0.name == "Legs")
        let re = RoutineExerciseDTO(RoutineExercise(routineID: UUID(), exerciseID: UUID(), createdAt: t, updatedAt: t))
        #expect(try roundTrip(re).0 == re && roundTrip(re).1["routine_id"] != nil)
        let ws = WorkoutSessionDTO(WorkoutSession(startedAt: t, source: .watch, note: "tired", createdAt: t, updatedAt: t))
        #expect(try roundTrip(ws).0 == ws && roundTrip(ws).1["started_at"] != nil && roundTrip(ws).1["note"] as? String == "tired")
        let bare = WorkoutSessionDTO(WorkoutSession(startedAt: t, source: .phone, createdAt: t, updatedAt: t))
        #expect(try roundTrip(bare).1["note"] is NSNull)  // explicit null so clearing a note reaches the server
        let se = SessionExerciseDTO(SessionExercise(sessionID: UUID(), exerciseID: UUID(), note: "slow", createdAt: t, updatedAt: t))
        #expect(try roundTrip(se).0 == se && roundTrip(se).1["session_id"] != nil)
        let bw = BodyWeightEntryDTO(BodyWeightEntry(date: t, weightKg: 75, source: .health, createdAt: t, updatedAt: t))
        #expect(try roundTrip(bw).0 == bw && roundTrip(bw).1["weight_kg"] as? Double == 75)
    }

    @Test func decodesPostgresMicroseconds() throws {
        let json = #"{"id":"\#(UUID())","name":"Legs","sort_order":0,"created_at":"2026-11-21T10:00:00.123456+00:00","updated_at":"2026-11-21T10:00:00Z","deleted_at":null,"user_id":null}"#
        let dto = try JSONDecoder.sync.decode(RoutineDTO.self, from: Data(json.utf8))
        #expect(dto.updatedAt == (try Date("2026-11-21T10:00:00Z", strategy: .iso8601)))
    }

    @Test func applyIntoModel() {
        let e = Exercise(name: "Squat", needsPush: false)
        var dto = ExerciseDTO(e)
        dto.name = "Front  Squat"; dto.kind = "strength"; dto.deletedAt = t
        dto.apply(to: e)
        #expect(e.name == "Front  Squat" && e.nameKey == "front squat" && e.deletedAt == t && !e.needsPush)
    }
}
