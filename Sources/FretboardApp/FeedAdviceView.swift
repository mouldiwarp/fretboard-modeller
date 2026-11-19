import SwiftUI
import FretboardKit

/// Chip-load readout with a red alert when the load would rub, overheat or overload the cutter.
struct FeedAdvice: View {
    var checks: [FeedCalculator.Check]
    var extra: [String] = []

    init(check: FeedCalculator.Check?, extra: [String] = []) { self.checks = check.map { [$0] } ?? []; self.extra = extra }
    init(checks: [FeedCalculator.Check], extra: [String] = []) { self.checks = checks; self.extra = extra }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                Text(checks.count > 1 ? "\(c.tool): " + c.summary : c.summary)
                    .font(Theme.heading(10.5)).foregroundStyle(c.level == .ok ? Theme.dim : Theme.danger)
            }
            ForEach(alerts, id: \.self) { a in
                HStack(alignment: .top, spacing: 6) {
                    LedDot(on: true, color: Theme.danger, size: 6).padding(.top, 3)
                    Text(a).font(Theme.heading(10.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var alerts: [String] { checks.compactMap(\.alert) + extra }
}

/// Flutes field plus a button that calculates the feeds for hardwood.
struct FeedCalculatorRow: View {
    @Binding var flutes: Int
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LampStepper(title: "Flutes", value: $flutes, range: 1...6)
            LatchButton(title: "CALCULATE FEEDS (HARDWOOD)", on: false, height: 24, action: action)
            Text("Sets the feeds from cutter size, flutes and spindle speed for a hardwood chip load. You can still override them on the G-code pages.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}
