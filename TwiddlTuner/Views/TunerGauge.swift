import SwiftUI

struct TunerGauge: View {
    let cents: Double?
    let activeColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let range = -50.0...50.0

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let clamped = min(range.upperBound, max(range.lowerBound, cents ?? 0))
                let position = width * CGFloat((clamped - range.lowerBound) / 100)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 2)
                        .offset(y: 20)

                    ForEach([-50, -25, 0, 25, 50], id: \.self) { value in
                        let x = width * CGFloat(Double(value + 50) / 100)
                        Capsule()
                            .fill(value == 0 ? Color.white.opacity(0.65) : Color.white.opacity(0.22))
                            .frame(width: value == 0 ? 2 : 1, height: value == 0 ? 22 : 10)
                            .position(x: x, y: 21)
                    }

                    if cents != nil {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(activeColor)
                            .frame(width: 4, height: 42)
                            .shadow(color: activeColor.opacity(0.5), radius: 10)
                            .position(x: position, y: 21)
                            .animation(reduceMotion ? nil : .linear(duration: 0.06), value: position)
                    }
                }
            }
            .frame(height: 42)

            HStack {
                Text("−50")
                Spacer()
                Text("0")
                Spacer()
                Text("+50")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.36))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tuning offset")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let cents else { return "No note" }
        if abs(cents) <= 3 { return "In tune" }
        if cents < 0 { return String(format: "%.1f cents flat", abs(cents)) }
        return String(format: "%.1f cents sharp", cents)
    }
}
