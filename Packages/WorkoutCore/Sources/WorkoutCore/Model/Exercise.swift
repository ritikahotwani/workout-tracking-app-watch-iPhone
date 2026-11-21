import CryptoKit
import Foundation
import SwiftData

@Model
public final class Exercise: Syncable {
    @Attribute(.unique) public var id: UUID
    public var userID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var needsPush: Bool

    public private(set) var name: String
    /// Lowercased, trimmed, whitespace-collapsed `name`; used for case-insensitive matching.
    public private(set) var nameKey: String
    public var muscleGroupRaw: String
    public var kindRaw: String
    public var cardioActivityRaw: String?
    public var isBuiltIn: Bool
    public var defaultRestSeconds: Int

    public init(
        id: UUID = UUID(), name: String, muscleGroup: MuscleGroup = .other, kind: ExerciseKind = .strength,
        cardioActivity: CardioActivity? = nil, isBuiltIn: Bool = false, defaultRestSeconds: Int = 90,
        userID: UUID? = nil, createdAt: Date = .now, updatedAt: Date = .now, deletedAt: Date? = nil,
        needsPush: Bool = true
    ) {
        self.id = id
        self.name = name
        self.nameKey = Exercise.nameKey(for: name)
        self.muscleGroupRaw = muscleGroup.rawValue
        self.kindRaw = kind.rawValue
        self.cardioActivityRaw = cardioActivity?.rawValue
        self.isBuiltIn = isBuiltIn
        self.defaultRestSeconds = defaultRestSeconds
        self.userID = userID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsPush = needsPush
    }

    /// Sets `name` without touching sync fields (used by sync apply).
    func setName(_ newName: String) {
        name = newName
        nameKey = Exercise.nameKey(for: newName)
    }

    public func rename(_ newName: String) {
        setName(newName)
        touch()
    }

    public var muscleGroup: MuscleGroup {
        get { MuscleGroup(rawValue: muscleGroupRaw) ?? .other }
        set { muscleGroupRaw = newValue.rawValue }
    }

    public var kind: ExerciseKind {
        get { ExerciseKind(rawValue: kindRaw) ?? .strength }
        set { kindRaw = newValue.rawValue }
    }

    public var cardioActivity: CardioActivity? {
        get { cardioActivityRaw.flatMap(CardioActivity.init(rawValue:)) }
        set { cardioActivityRaw = newValue?.rawValue }
    }

    public static func nameKey(for name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Fixed namespace for built-in exercise IDs. Never change: IDs must agree across devices and restores.
    public static let builtInNamespace = UUID(uuidString: "F091AA1C-1725-4AA7-9BB0-66849A21C0BE")!

    /// Deterministic UUIDv5 (RFC 4122, SHA-1) of the name's `nameKey`.
    public static func builtInID(for name: String) -> UUID {
        var data = withUnsafeBytes(of: builtInNamespace.uuid) { Data($0) }
        data.append(Data(nameKey(for: name).utf8))
        var b = Array(Insecure.SHA1.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50  // version 5
        b[8] = (b[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
