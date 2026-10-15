import Charts
import SwiftUI

/// Which limit window the history shows.
enum HistoryWindow: String, CaseIterable {
    case session, weekly
}

extension SettingsKey {
    static let historyWindow = "historyWindow"
}

/// A column heading in the combined page, styled like the meter titles.
struct ColumnTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// How the limit has filled up over the current window and where the pace leads, and how the
/// pace moved. Follows the panel's Left/Used and Overall/Sensitive switches.
struct UsageOutlook: View {
    let store: UsageStore
    let amount: AmountShown
    let paceMethod: PaceMethod
    @AppStorage(SettingsKey.historyWindow) private var selection = HistoryWindow.session

    var body: some View {
        let session = store.meters.first { $0.unit == .perHour }
        let weekly = store.meters.first { $0.id == "weekly_all" } ?? store.meters.first { $0.unit == .perDay }
        let meter = (selection == .weekly ? weekly : session) ?? store.headline

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ColumnTitle("Limit outlook")
                Spacer()
                if session != nil, weekly != nil {
                    Segmented(selection: $selection, options: [(.session, "5-hour"), (.weekly, "Weekly")])
                        .help("Which limit window to show")
                }
            }

            if let meter {
                let points = store.trajectory(for: meter, method: paceMethod)
                let domain = Self.domain(for: meter, points: points)
                let pace = store.pace(for: meter, method: paceMethod)

                AmountHistoryChart(meter: meter, points: points, pace: pace, amount: amount, domain: domain)
                RelativeHistoryChart(points: points, method: paceMethod, domain: domain)

                if let first = points.first, first.t.timeIntervalSince(domain.lowerBound) > 10 * 60 {
                    Text("Recorded since \(Format.clock(first.t)). The app only records while it runs.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No usage recorded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    /// The meter's window, from opening to reset; or the recorded span when the window is unknown.
    static func domain(for meter: Meter, points: [History.PacePoint]) -> ClosedRange<Date> {
        if let resetsAt = meter.resetsAt, let window = meter.window {
            return resetsAt.addingTimeInterval(-window)...resetsAt
        }
        let start = points.first?.t ?? Date().addingTimeInterval(-3600)
        return start...max(Date(), start.addingTimeInterval(3600))
    }

    /// Hourly (daily for the week) ticks, leaving out those whose label would hang past an edge.
    static func ticks(for domain: ClosedRange<Date>) -> [Date] {
        let length = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return clockTicks(in: domain, every: length > 86400 ? 86400 : 3600).filter {
            $0.timeIntervalSince(domain.lowerBound) > length * 0.04 && domain.upperBound.timeIntervalSince($0) > length * 0.14
        }
    }

    static func tickFormat(for domain: ClosedRange<Date>) -> Date.FormatStyle {
        domain.upperBound.timeIntervalSince(domain.lowerBound) > 86400
            ? .dateTime.weekday(.abbreviated)
            : .dateTime.hour().minute()
    }
}

/// Tracks the pointer over a chart's plot area as a time on its x axis.
struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let domain: ClosedRange<Date>
    @Binding var hover: Date?

    var body: some View {
        GeometryReader { geometry in
            let frame = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hover = proxy.value(atX: location.x - frame.minX, as: Date.self)
                            .map { min(max($0, domain.lowerBound), domain.upperBound) }
                    case .ended:
                        hover = nil
                    }
                }
        }
    }
}

// MARK: - Left or used

/// What's left (or used) over the window: the recorded readings, where the current pace leads,
/// and the even pace that reaches the limit exactly at reset.
struct AmountHistoryChart: View {
    let meter: Meter
    let points: [History.PacePoint]
    let pace: Pace
    let amount: AmountShown
    let domain: ClosedRange<Date>
    @State private var hover: Date?

    var body: some View {
        let projection = self.projection
        VStack(alignment: .leading, spacing: 6) {
            Text(readout(projection: projection))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Chart {
                // The last 10% before the limit, like the dial's red stripe.
                RectangleMark(xStart: .value("Opened", domain.lowerBound), xEnd: .value("Reset", domain.upperBound),
                              yStart: .value("Stripe", amount.value(90)), yEnd: .value("Limit", amount.value(100)))
                    .foregroundStyle(.red.opacity(0.08))

                LineMark(x: .value("Time", domain.lowerBound), y: .value("Percent", amount.value(0)), series: .value("Line", "even"))
                    .foregroundStyle(.green.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                LineMark(x: .value("Time", domain.upperBound), y: .value("Percent", amount.value(100)), series: .value("Line", "even"))
                    .foregroundStyle(.green.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                ForEach(points, id: \.t) { point in
                    LineMark(x: .value("Time", point.t), y: .value("Percent", amount.value(point.used)),
                             series: .value("Line", "recorded"))
                        .foregroundStyle(meter.levelTint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.stepEnd)
                }

                if let projection {
                    ForEach([projection.from, projection.to], id: \.t) { point in
                        LineMark(x: .value("Time", point.t), y: .value("Percent", amount.value(point.used)),
                                 series: .value("Line", "projection"))
                            .foregroundStyle(pace.status.tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
                    }
                }

                if let last = points.last {
                    PointMark(x: .value("Time", last.t), y: .value("Percent", amount.value(last.used)))
                        .foregroundStyle(.background)
                        .symbolSize(90)
                    PointMark(x: .value("Time", last.t), y: .value("Percent", amount.value(last.used)))
                        .foregroundStyle(meter.levelTint)
                        .symbolSize(40)
                }

                if let hover {
                    RuleMark(x: .value("Time", hover))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: UsageOutlook.ticks(for: domain)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: UsageOutlook.tickFormat(for: domain))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { if let percent = value.as(Double.self) { Text(Format.percent(percent)) } }
                }
            }
            .chartOverlay { ChartHoverLayer(proxy: $0, domain: domain, hover: $hover) }
            .frame(height: 120)
            .accessibilityLabel(readout(projection: projection))

            HStack(spacing: 10) {
                LineKey(color: meter.levelTint, label: "Recorded")
                if projection != nil { LineKey(color: pace.status.tint, label: "At this pace", isDashed: true) }
                LineKey(color: .green.opacity(0.8), label: "Even pace", width: 1)
            }
        }
    }

    /// From the last reading to the limit (or to reset, if the pace doesn't get there first).
    private var projection: (from: History.PacePoint, to: History.PacePoint)? {
        guard let last = points.last, let rate = pace.rate, rate > 0.05, !pace.reached else { return nil }
        let start = History.PacePoint(t: last.t, used: last.used, relative: nil)
        if let limitAt = pace.limitAt {
            return (start, .init(t: min(limitAt, domain.upperBound), used: 100, relative: nil))
        }
        guard let projected = pace.projectedAtReset, let resetsAt = meter.resetsAt else { return nil }
        return (start, .init(t: resetsAt, used: projected, relative: nil))
    }

    private func readout(projection: (from: History.PacePoint, to: History.PacePoint)?) -> String {
        let title = "\(amount.rawValue.capitalized) · \(meter.title)"
        guard let hover else { return title }
        let length = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let even = Format.percent(amount.value(hover.timeIntervalSince(domain.lowerBound) / length * 100))
        let time = Format.clock(hover)
        if let projection, hover > projection.from.t {
            let span = projection.to.t.timeIntervalSince(projection.from.t)
            let fraction = span > 0 ? min(1, hover.timeIntervalSince(projection.from.t) / span) : 1
            let used = projection.from.used + (projection.to.used - projection.from.used) * fraction
            return "\(time) · at this pace \(Format.percent(amount.value(used))) \(amount.rawValue) · even \(even)"
        }
        guard let reading = points.last(where: { $0.t <= hover }) else { return "\(time) · not recorded · even \(even)" }
        return "\(time) · \(Format.percent(amount.value(reading.used))) \(amount.rawValue) · even \(even)"
    }
}

// MARK: - Relative pace

/// The relative pace as it read over the window: 100% (SET) runs out exactly at reset,
/// above it is the red zone.
struct RelativeHistoryChart: View {
    let points: [History.PacePoint]
    let method: PaceMethod
    let domain: ClosedRange<Date>
    @Environment(\.colorScheme) private var scheme
    @State private var hover: Date?

    var body: some View {
        let readings = points.compactMap { point in point.relative.map { (t: point.t, value: $0) } }
        let peak = readings.map(\.value).max() ?? 0
        let scale = [200.0, 400, 800, 1200, 2000, 4000].first { $0 >= peak * 1.1 } ?? 4000
        let line = SeriesPalette.color(0, scheme)

        VStack(alignment: .leading, spacing: 6) {
            Text(readout(readings))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Chart {
                RectangleMark(xStart: .value("Opened", domain.lowerBound), xEnd: .value("Reset", domain.upperBound),
                              yStart: .value("SET", 100), yEnd: .value("Top", scale))
                    .foregroundStyle(.red.opacity(0.06))
                RuleMark(y: .value("SET", 100))
                    .foregroundStyle(.green.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text("SET")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                ForEach(readings, id: \.t) { reading in
                    LineMark(x: .value("Time", reading.t), y: .value("Pace", min(reading.value, scale)))
                        .foregroundStyle(line)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let last = readings.last {
                    PointMark(x: .value("Time", last.t), y: .value("Pace", min(last.value, scale)))
                        .foregroundStyle(.background)
                        .symbolSize(90)
                    PointMark(x: .value("Time", last.t), y: .value("Pace", min(last.value, scale)))
                        .foregroundStyle(line)
                        .symbolSize(40)
                }

                if let hover {
                    RuleMark(x: .value("Time", hover))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...scale)
            .chartXAxis {
                AxisMarks(values: UsageOutlook.ticks(for: domain)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: UsageOutlook.tickFormat(for: domain))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, scale / 2, scale]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { if let percent = value.as(Double.self) { Text(Format.percent(percent)) } }
                }
            }
            .chartOverlay { ChartHoverLayer(proxy: $0, domain: domain, hover: $hover) }
            .frame(height: 90)
            .accessibilityLabel(readout(readings))
        }
    }

    private func readout(_ readings: [(t: Date, value: Double)]) -> String {
        let title = "Relative pace · \(method == .overall ? "Overall" : "Sensitive")"
        guard let hover else { return readings.isEmpty ? "\(title) · measuring…" : title }
        guard let reading = readings.last(where: { $0.t <= hover }) else { return "\(Format.clock(hover)) · not recorded" }
        return "\(Format.clock(hover)) · \(Format.percent(reading.value)) pace"
    }
}

/// A short stroke of a line's color beside its name, for chart legends.
struct LineKey: View {
    let color: Color
    let label: String
    var isDashed = false
    var width: CGFloat = 2

    var body: some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 12, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: isDashed ? [3, 2] : []))
            .frame(width: 12, height: 2)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
