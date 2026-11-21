import Foundation

/// Wall-clock active time with pauses taken out, for sessions without a Health workout.
public struct PauseClock: Sendable {
    public let start: Date
    private var pausedAt: Date?
    private var pausedBefore: TimeInterval = 0

    public init(start: Date) { self.start = start }

    public mutating func pause(at date: Date) {
        if pausedAt == nil { pausedAt = date }
    }

    public mutating func resume(at date: Date) {
        guard let pausedAt else { return }
        pausedBefore += max(0, date.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    /// Total paused time, including a pause still running at `date`.
    public func pausedSeconds(at date: Date) -> TimeInterval {
        pausedBefore + (pausedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    public func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(start) - pausedSeconds(at: date))
    }
}
