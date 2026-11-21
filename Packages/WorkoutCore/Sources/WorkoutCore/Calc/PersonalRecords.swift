import Foundation

public enum PRType: String, Codable, CaseIterable, Sendable {
    case heaviestWeight, bestE1RM, bestRepsAtWeight, bestSessionVolume
}

/// Best-ever values for one exercise. nil = no qualifying history.
public struct PRBaseline: Codable, Equatable, Sendable {
    public var heaviestKg: Double?
    public var bestE1RM: Double?
    /// Key: `PersonalRecords.weightKey(kg)`.
    public var bestRepsByWeight: [Double: Int]
    public var bestSessionVolume: Double?

    public init(heaviestKg: Double? = nil, bestE1RM: Double? = nil, bestRepsByWeight: [Double: Int] = [:],
                bestSessionVolume: Double? = nil) {
        self.heaviestKg = heaviestKg
        self.bestE1RM = bestE1RM
        self.bestRepsByWeight = bestRepsByWeight
        self.bestSessionVolume = bestSessionVolume
    }
}

public enum PersonalRecords {
    /// kg rounded to 0.01, so 80 and 80.0000001 share a key.
    public static func weightKey(_ kg: Double) -> Double { (kg * 100).rounded() / 100 }

    /// Baseline for one exercise's sets (caller filters by exercise). Sets with reps ≤ 0 are ignored.
    public static func baseline(for sets: [SetRecord]) -> PRBaseline {
        var b = PRBaseline()
        for s in sets where s.reps > 0 {
            if s.weightKg > 0 { b.heaviestKg = max(b.heaviestKg ?? 0, s.weightKg) }
            if let e = s.e1RM { b.bestE1RM = max(b.bestE1RM ?? 0, e) }
            if s.weightKg >= 0 {
                let k = weightKey(s.weightKg)
                b.bestRepsByWeight[k] = max(b.bestRepsByWeight[k] ?? 0, s.reps)
            }
        }
        let best = Volume.bySession(sets).values.max() ?? 0
        if best > 0 { b.bestSessionVolume = best }
        return b
    }

    /// Baselines for every exercise present in `sets`.
    public static func baselines(_ sets: [SetRecord]) -> [UUID: PRBaseline] {
        Dictionary(grouping: sets, by: \.exerciseID).mapValues(baseline(for:))
    }
}

public enum PRDetector {
    /// PRs hit by `new`, compared against prior sessions (`baseline`) plus earlier sets of this
    /// session (`sessionSoFar`, excluding `new`; other exercises are ignored).
    /// A category with no prior value never fires, so a first-ever set isn't badged.
    public static func check(new: SetRecord, baseline: PRBaseline, sessionSoFar: [SetRecord]) -> Set<PRType> {
        guard new.reps > 0 else { return [] }
        let earlier = sessionSoFar.filter { $0.exerciseID == new.exerciseID }
        let today = PersonalRecords.baseline(for: earlier)
        var hits: Set<PRType> = []

        func beats(_ value: Double?, _ priors: Double?...) -> Bool {
            guard let value, let best = priors.compactMap({ $0 }).max() else { return false }
            return value > best
        }

        if new.weightKg > 0, beats(new.weightKg, baseline.heaviestKg, today.heaviestKg) { hits.insert(.heaviestWeight) }
        if beats(new.e1RM, baseline.bestE1RM, today.bestE1RM) { hits.insert(.bestE1RM) }

        let key = PersonalRecords.weightKey(new.weightKg)
        if new.weightKg >= 0,
           beats(Double(new.reps), baseline.bestRepsByWeight[key].map(Double.init), today.bestRepsByWeight[key].map(Double.init)) {
            hits.insert(.bestRepsAtWeight)
        }

        // Fires only on the set that crosses the previous best, not on every set after.
        if let best = baseline.bestSessionVolume, new.volume > 0 {
            let before = Volume.total(earlier)
            if before <= best, before + new.volume > best { hits.insert(.bestSessionVolume) }
        }
        return hits
    }
}
