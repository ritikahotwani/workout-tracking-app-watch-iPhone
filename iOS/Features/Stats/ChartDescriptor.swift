import Accessibility
import Foundation
import SwiftUI
import WorkoutCore

/// One dated series → audio graph + summary sentence for VoiceOver. Used by every chart in Progress.
struct DatedPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct DatedChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let valueName: String
    let points: [DatedPoint]
    var isLine = false
    let valueText: @Sendable (Double) -> String

    var summary: String {
        guard let first = points.first, let last = points.last, let best = points.max(by: { $0.value < $1.value })
        else { return "No data yet." }
        let verb = last.value > first.value ? "rose" : last.value < first.value ? "fell" : "held"
        return "\(title) \(verb) from \(valueText(first.value)) on \(day(first.date)) to \(valueText(last.value)) on "
            + "\(day(last.date)). Highest \(valueText(best.value)) on \(day(best.date))."
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let xs = points.map { $0.date.timeIntervalSince1970 }
        let x = AXNumericDataAxisDescriptor(
            title: "Date", range: (xs.min() ?? 0)...(xs.max() ?? 1), gridlinePositions: []
        ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }
        let y = AXNumericDataAxisDescriptor(
            title: valueName, range: 0...max(1, points.map(\.value).max() ?? 1), gridlinePositions: [],
            valueDescriptionProvider: valueText)
        let series = AXDataSeriesDescriptor(name: title, isContinuous: isLine,
                                            dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value) })
        return AXChartDescriptor(title: title, summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }

    private func day(_ d: Date) -> String { d.formatted(.dateTime.day().month(.wide)) }
}

/// Last `count` week or month starts, oldest first, with zero for empty buckets.
func filledBuckets(_ values: [Date: Double], component: Calendar.Component, count: Int = 12,
                   calendar: Calendar = .isoWeeks) -> [DatedPoint] {
    guard let current = calendar.dateInterval(of: component, for: .now)?.start else { return [] }
    return (0..<count).reversed().compactMap { i in
        calendar.date(byAdding: component, value: -i, to: current).map { DatedPoint(date: $0, value: values[$0] ?? 0) }
    }
}
