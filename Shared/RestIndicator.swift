import SwiftUI

/// Compact rest countdown that sits on the exercise page, so Log Set stays usable while resting. Callers set the font.
struct RestIndicator: View {
    let end: Date
    let total: TimeInterval
    let skip: () -> Void
    /// Minimum tap target: the watch row stays compact, the iPhone gets 44 pt.
    #if os(watchOS)
    private let tap: CGFloat = 0
    #else
    private let tap: CGFloat = 44
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, end.timeIntervalSince(context.date))
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: total > 0 ? remaining / total : 0)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: remaining)
                    }
                    .frame(width: 16, height: 16)
                    Text("Rest " + clock(remaining.rounded(.up))).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rest")
                .accessibilityValue("\(spokenDuration(remaining.rounded(.up))) remaining")
                Button("Skip", action: skip)
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .frame(minWidth: tap, minHeight: tap).contentShape(.rect)
                    .accessibilityLabel("Skip rest")
            }
            .frame(minHeight: tap)
        }
    }
}
