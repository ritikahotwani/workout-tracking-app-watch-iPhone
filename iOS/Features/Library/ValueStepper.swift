import SwiftUI

/// Stepper that VoiceOver reads as one adjustable element with units: "Rest, 90 seconds".
struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    /// Short unit shown on screen ("s"); `spokenUnit` is read by VoiceOver ("seconds").
    var unit = ""
    var spokenUnit = ""

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title, value: unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                .monospacedDigit()
        }
        // One adjustable element with a spoken unit, instead of the label plus two +/- buttons.
        .accessibilityRepresentation {
            Stepper(title, value: $value, in: range, step: step)
                .accessibilityValue(spokenUnit.isEmpty ? "\(value)" : "\(value) \(spokenUnit)")
        }
    }
}

extension ValueStepper {
    static func rest(_ title: String = "Rest", value: Binding<Int>) -> ValueStepper {
        ValueStepper(title: title, value: value, range: 0...600, step: 15, unit: "s", spokenUnit: "seconds")
    }
}
