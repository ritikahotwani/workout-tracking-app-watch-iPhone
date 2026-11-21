import Charts
import SwiftUI
import WorkoutCore

/// Weigh-ins as points plus the 7-day moving average line, over a selectable range.
struct WeightChart: View {
    /// Non-deleted entries, any order.
    let entries: [BodyWeightEntry]
    let unit: WeightUnit
    @State private var range: Range = .threeMonths

    enum Range: String, CaseIterable, Identifiable {
        case month = "1M", threeMonths = "3M", year = "1Y", all = "All"
        var id: Self { self }

        var start: Date? {
            let months = [Range.month: -1, .threeMonths: -3, .year: -12][self]
            return months.flatMap { Calendar.current.date(byAdding: .month, value: $0, to: .now) }
        }

        var spoken: String? {
            [Range.month: "1 month", .threeMonths: "3 months", .year: "1 year"][self]
        }
    }

    private struct Series {
        var points: [MovingAverage.Point]   // display unit, ascending
        var average: [MovingAverage.Point]
    }

    private var series: Series {
        let all = entries.map { MovingAverage.Point(date: $0.date, value: unit.fromKg($0.weightKg)) }
            .sorted { $0.date < $1.date }
        // Average over everything so the line is correct at the range's left edge, then clip.
        let average = MovingAverage.sevenDay(entries: all)
        let start = range.start.map { Calendar.current.startOfDay(for: $0) } ?? .distantPast
        return Series(points: all.filter { $0.date >= start }, average: average.filter { $0.date >= start })
    }

    var body: some View {
        let s = series
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if s.points.isEmpty {
                Text("No weigh-ins in this range").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart {
                    ForEach(s.points, id: \.date) {
                        PointMark(x: .value("Date", $0.date), y: .value("Weight", $0.value))
                            .symbolSize(20)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(s.average, id: \.date) {
                        LineMark(x: .value("Date", $0.date), y: .value("7-day average", $0.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.tint)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(minHeight: 200)
                .accessibilityChartDescriptor(Descriptor(points: s.points, average: s.average, unit: unit,
                                                         summary: summary(s)))
            }
        }
        .padding(.vertical, 4)
    }

    /// "Weight down 1.8 kilograms over 3 months, 7-day average 78.4 kilograms"
    private func summary(_ s: Series) -> String {
        guard let first = s.points.first, let last = s.points.last else { return "No weigh-ins" }
        let delta = last.value - first.value
        let period = range.spoken.map { "over \($0)" }
            ?? "since \(first.date.formatted(date: .long, time: .omitted))"
        let change = abs(delta) < 0.05 ? "Weight steady \(period)"
            : "Weight \(delta < 0 ? "down" : "up") \(unit.spoken(unit.toKg(abs(delta)))) \(period)"
        guard let avg = s.average.last else { return change }
        return "\(change), 7-day average \(unit.spoken(unit.toKg(avg.value)))"
    }

    private struct Descriptor: AXChartDescriptorRepresentable {
        let points: [MovingAverage.Point]
        let average: [MovingAverage.Point]
        let unit: WeightUnit
        let summary: String

        func makeChartDescriptor() -> AXChartDescriptor {
            let xs = points.map { $0.date.timeIntervalSince1970 }
            let ys = points.map(\.value) + average.map(\.value)
            let x = AXNumericDataAxisDescriptor(title: "Date", range: xs.min()!...xs.max()!, gridlinePositions: []) {
                Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted)
            }
            let y = AXNumericDataAxisDescriptor(title: "Weight", range: ys.min()!...ys.max()!, gridlinePositions: []) {
                unit.spoken(unit.toKg($0))
            }
            func data(_ p: [MovingAverage.Point]) -> [AXDataPoint] {
                p.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value) }
            }
            return AXChartDescriptor(title: "Body weight", summary: summary, xAxis: x, yAxis: y, additionalAxes: [],
                                     series: [AXDataSeriesDescriptor(name: "Weigh-ins", isContinuous: false, dataPoints: data(points)),
                                              AXDataSeriesDescriptor(name: "7-day average", isContinuous: true, dataPoints: data(average))])
        }
    }
}
