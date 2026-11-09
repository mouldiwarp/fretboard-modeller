import AppKit
import SwiftUI

// Controls in the Mixdeck / IR Generator style: lamp-like latch buttons, recessed wells, LED readouts.

/// Small latching button that lights like a lamp when on.
struct LatchButton: View {
    let title: String
    let on: Bool
    var tint: Color = Theme.accent
    var height: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(10.5))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: height)
                .padding(.horizontal, 4)
                .foregroundStyle(on ? Theme.obsidian : Theme.text.opacity(0.8))
                .background(LampFace(on: on, tint: tint))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Button face: dark recessed face with a tinted rim, or a lit, glowing face when on.
struct LampFace: View {
    let on: Bool
    var tint: Color = Theme.accent
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [.white.opacity(on ? 0.35 : 0.04), .clear], startPoint: .top, endPoint: .center)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(on ? 0.9 : 0.28), lineWidth: 0.75))
            .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 5)
    }
}

/// Uppercase section caption with a gold hairline.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(Theme.caption(10))
                .tracking(1.2)
                .foregroundStyle(Theme.gold)
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(Theme.gold.opacity(0.25)).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Small uppercase steel caption used for field and readout labels.
struct FieldCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.caption(9.5))
            .tracking(0.8)
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
    }
}

/// Large lit transport-style button (Export).
struct BigLampButton: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.gold
    var lit = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                Text(title).font(Theme.caption(13)).tracking(1.4)
            }
            .foregroundStyle(lit && enabled ? Theme.obsidian : Theme.text.opacity(enabled ? 0.85 : 0.35))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(LampFace(on: lit && enabled, tint: enabled ? tint : Theme.steel, radius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Label on the left, recessed amber numeric entry and unit on the right.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String = "mm"

    var body: some View {
        HStack(spacing: 8) {
            FieldCaption(title)
            Spacer(minLength: 4)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.amber)
                .shadow(color: Theme.amber.opacity(0.55), radius: 2.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: 78)
                .gmWell()
            Text(unit)
                .font(Theme.caption(10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 20, alignment: .leading)
        }
    }
}

/// Integer stepper: amber readout with lamp − / + buttons.
struct LampStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            FieldCaption(title)
            Spacer(minLength: 4)
            LatchButton(title: "−", on: false, height: 20) { value = max(range.lowerBound, value - 1) }
                .frame(width: 26)
            LedReadout(text: "\(value)", size: 12).frame(minWidth: 30)
            LatchButton(title: "+", on: false, height: 20) { value = min(range.upperBound, value + 1) }
                .frame(width: 26)
        }
    }
}

/// A themed checkbox row.
struct LampCheck: View {
    let text: String
    @Binding var on: Bool
    var detail: String? = nil

    var body: some View {
        Button { on.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.track)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.gold.opacity(on ? 0.9 : 0.35), lineWidth: 0.75))
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.gold)
                            .shadow(color: Theme.gold.opacity(0.8), radius: 2)
                    }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(text).font(Theme.heading(11.5)).foregroundStyle(Theme.text.opacity(on ? 0.95 : 0.8))
                    if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.dim) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The app's mark: a tapered fretboard in gold line-art.
struct FretboardGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var board = Path()
            board.move(to: CGPoint(x: w * 0.30, y: 0))
            board.addLine(to: CGPoint(x: w * 0.70, y: 0))
            board.addLine(to: CGPoint(x: w, y: h))
            board.addLine(to: CGPoint(x: 0, y: h))
            board.closeSubpath()
            ctx.stroke(board, with: .color(Theme.gold), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            for f in [0.28, 0.52, 0.74] {
                let y = h * f, half = w * (0.2 + 0.3 * f)
                var p = Path()
                p.move(to: CGPoint(x: w / 2 - half, y: y)); p.addLine(to: CGPoint(x: w / 2 + half, y: y))
                ctx.stroke(p, with: .color(Theme.gold.opacity(0.8)), lineWidth: 1)
            }
        }
        .shadow(color: Theme.gold.opacity(0.7), radius: 3)
        .accessibilityHidden(true)
    }
}

/// Horizontal level slider: recessed track, gold fill, metal knob.
struct LevelSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = Theme.gold
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 14
            let usable = max(1, w - knob)
            let span = max(1e-9, range.upperBound - range.lowerBound)
            let frac = (value - range.lowerBound) / span
            let x = knob / 2 + usable * CGFloat(frac)
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let mid = size.height / 2
                    let track = CGRect(x: knob / 2, y: mid - 2.5, width: usable, height: 5)
                    ctx.fill(Path(roundedRect: track, cornerRadius: 2.5), with: .color(Theme.track))
                    ctx.stroke(Path(roundedRect: track, cornerRadius: 2.5), with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                    let fill = CGRect(x: knob / 2, y: mid - 1.5, width: max(0, x - knob / 2), height: 3)
                    ctx.fill(Path(roundedRect: fill, cornerRadius: 1.5), with: .color(tint))
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.2)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: knob * 0.75))
                    .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x - knob / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = Double((g.location.x - knob / 2) / usable)
                    value = min(range.upperBound, max(range.lowerBound, range.lowerBound + f * span))
                })
        }
        .frame(height: 18)
    }
}
