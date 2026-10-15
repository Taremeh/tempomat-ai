import SwiftUI

/// What a dial shows, in its own units.
struct DialReading {
    var value: Double?              // needle
    var scale: Double               // full-scale value
    var labels: [String]            // five labels: 0, ¼, ½, ¾ and full scale
    var marker: Double?             // triangle on the rim
    var markerColor: Color
    var zone: ClosedRange<Double>?  // red stripe on the rim
    var tint: Color                 // filled arc up to the needle
    var reading: String             // big number
    var caption: String             // under the number
    var pill: String?
    var pillColor: Color

    /// Speedometer: 100% is the pace that runs out exactly at reset; past it is the red zone.
    static func relative(meter: Meter, pace: Pace) -> DialReading {
        let relative = pace.relative
        let scale = [200.0, 400, 800, 1200, 2000, 4000].first { $0 >= (relative ?? 0) * 1.1 } ?? 4000
        let unit = meter.unit
        let pill = pace.rate.map { rate in
            "\(Format.rate(unit.display(rate))) \(unit.label)"
                + (pace.setpoint.map { " · SET \(Format.rate(unit.display($0)))" } ?? "")
        }
        return DialReading(value: relative, scale: scale,
                           labels: (0...4).map { Format.rate(scale * Double($0) / 4) },
                           marker: 100, markerColor: .green, zone: 100...scale,
                           tint: pace.status.tint,
                           reading: relative.map(Format.percent) ?? "–", caption: "relative pace",
                           pill: pill, pillColor: .green)
    }

    /// Fuel gauge: what's left in the tank (or burned), with a marker where the pace leads by reset.
    static func total(meter: Meter, pace: Pace, shown: AmountShown) -> DialReading {
        let value = shown.value(meter.percent)
        let projected = pace.projectedAtReset.map(shown.value)
        let moves = projected.map { abs($0 - value) >= 1 } ?? false
        return DialReading(value: value, scale: 100,
                           labels: shown == .left ? ["E", "25", "50", "75", "F"] : ["0", "25", "50", "75", "100"],
                           marker: moves ? projected : nil, markerColor: pace.status.tint,
                           zone: shown == .left ? 0...10 : 90...100,
                           tint: meter.levelTint,
                           reading: Format.percent(value), caption: shown == .left ? "left" : "used",
                           pill: moves ? projected.map { "\(Format.percent($0)) at reset" } : nil,
                           pillColor: pace.status.tint)
    }
}

/// A round instrument: needle, filled arc, red stripe, marker and a digital readout below the hub.
struct Dial: View {
    let reading: DialReading

    nonisolated static let startAngle = 150.0
    nonisolated static let sweep = 240.0
    private static let side: CGFloat = 220
    private static let band: CGFloat = 12
    private static let bandInset: CGFloat = 16   // band centre at radius 94
    private static let stripeInset: CGFloat = 3  // red stripe centre at radius 107

    var body: some View {
        let fraction = clamp(reading.value ?? 0)
        let zone = reading.zone.map { (clamp($0.lowerBound), clamp($0.upperBound)) }
        let marker = reading.marker.map(clamp)

        ZStack(alignment: .top) {
            ZStack {
                arc(from: 0, to: 1, inset: Self.bandInset)
                    .stroke(.primary.opacity(0.09), style: .init(lineWidth: Self.band, lineCap: .round))
                arc(from: 0, to: fraction, inset: Self.bandInset)
                    .stroke(reading.tint.gradient, style: .init(lineWidth: Self.band, lineCap: .round))
                    .opacity(reading.value == nil ? 0 : 1)
                if let zone {
                    arc(from: zone.0, to: zone.1, inset: Self.stripeInset)
                        .stroke(.red.opacity(0.75), style: .init(lineWidth: 4, lineCap: .butt))
                }

                Canvas { context, size in
                    drawTicks(in: &context, size: size)
                    if let marker { drawMarker(in: &context, size: size, fraction: marker) }
                }

                Needle(fraction: fraction)
                    .fill(Color.primary)
                    .opacity(reading.value == nil ? 0.3 : 1)
                Circle().fill(.primary).frame(width: 12, height: 12)
                Circle().fill(reading.tint).frame(width: 5, height: 5)
            }
            .frame(width: Self.side, height: Self.side)
            .animation(.spring(duration: 0.9, bounce: 0.25), value: fraction)
            .animation(.easeInOut(duration: 0.6), value: marker)
            .accessibilityHidden(true)

            readout
                .offset(y: Self.side / 2 + 22)
        }
        .frame(width: Self.side, height: Self.side / 2 + 92, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value / reading.scale)) }

    private var readout: some View {
        VStack(spacing: 1) {
            Text(reading.reading)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(reading.caption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            if let pill = reading.pill {
                Text(pill)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.pillColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(reading.pillColor.opacity(0.14), in: Capsule())
                    .padding(.top, 3)
            }
        }
    }

    private func arc(from: Double, to: Double, inset: CGFloat) -> some Shape {
        let length = Self.sweep / 360
        return Circle()
            .inset(by: inset)
            .trim(from: from * length, to: max(from, to) * length)
            .rotation(.degrees(Self.startAngle))
    }

    // MARK: Drawing

    private static func point(_ fraction: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = Angle.degrees(startAngle + sweep * fraction).radians
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func drawTicks(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = size.width / 2 - Self.bandInset - Self.band / 2 - 4
        for i in 0...20 {
            let fraction = Double(i) / 20
            let major = i % 5 == 0
            var tick = Path()
            tick.move(to: Self.point(fraction, radius: outer, center: center))
            tick.addLine(to: Self.point(fraction, radius: outer - (major ? 8 : 4), center: center))
            context.stroke(tick, with: .color(.primary.opacity(major ? 0.55 : 0.25)),
                           style: .init(lineWidth: major ? 1.5 : 1, lineCap: .round))
            if major, i / 5 < reading.labels.count {
                let label = Text(reading.labels[i / 5])
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                context.draw(label, at: Self.point(fraction, radius: outer - 19, center: center))
            }
        }
    }

    private func drawMarker(in context: inout GraphicsContext, size: CGSize, fraction: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rim = size.width / 2
        let angle = Angle.degrees(Self.startAngle + Self.sweep * fraction).radians
        let tangent = CGPoint(x: -sin(angle), y: cos(angle))
        let tip = Self.point(fraction, radius: rim - Self.bandInset - Self.band / 2 + 2, center: center)
        let base = Self.point(fraction, radius: rim + 2, center: center)
        var marker = Path()
        marker.move(to: tip)
        marker.addLine(to: CGPoint(x: base.x + tangent.x * 5, y: base.y + tangent.y * 5))
        marker.addLine(to: CGPoint(x: base.x - tangent.x * 5, y: base.y - tangent.y * 5))
        marker.closeSubpath()
        context.fill(marker, with: .color(reading.markerColor))
    }
}

private struct Needle: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let angle = Angle.degrees(Dial.startAngle + Dial.sweep * fraction).radians
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let tip = CGPoint(x: center.x + direction.x * (radius - 28), y: center.y + direction.y * (radius - 28))
        let tail = CGPoint(x: center.x - direction.x * 14, y: center.y - direction.y * 14)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: center.x + normal.x * 3, y: center.y + normal.y * 3))
        path.addLine(to: tail)
        path.addLine(to: CGPoint(x: center.x - normal.x * 3, y: center.y - normal.y * 3))
        path.closeSubpath()
        return path
    }
}

extension Pace.Status {
    var tint: Color {
        switch self {
        case .cruising: .green
        case .overPace: .orange
        case .limitReached: .red
        case .unknown: .secondary
        }
    }
}

extension Meter {
    /// The server grades each row; we only map its grade to a colour.
    var severityTint: Color {
        switch severity {
        case "critical": .red
        case "warning": .orange
        default: .accentColor
        }
    }

    /// The same grade as a fuel-level colour.
    var levelTint: Color {
        switch severity {
        case "critical": .red
        case "warning": .orange
        default: .green
        }
    }
}

enum Format {
    static func rate(_ value: Double) -> String {
        value < 10 && value.rounded() != value ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "16:40" today, "Thu 19:00" on other days.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "45m", "3h 40m", "2d 5h".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
