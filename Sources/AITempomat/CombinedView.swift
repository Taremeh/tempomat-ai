import SwiftUI

// MARK: - Floating cards

/// An opaque surface for cards that float over lanes and charts, so their text stays readable
/// (the panel's own background is translucent).
private struct CardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.985), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }

}

// MARK: - History: what each session burnt, over time

/// A session's tokens per minute in each slice of the window.
struct TokenBurn {
    let perMinute: [Double]
    let total: Int

    var peak: Double { perMinute.max() ?? 0 }

    /// The rate drawn at full thickness for a set of ribbons: the 95th percentile of their
    /// busy slices, so one short spike doesn't flatten everything else. Faster slices are capped.
    static func fullScale(_ burns: [TokenBurn]) -> Double {
        let rates = burns.flatMap(\.perMinute).filter { $0 > 0 }.sorted()
        guard !rates.isEmpty else { return 0 }
        return rates[min(rates.count - 1, Int(Double(rates.count) * 0.95))]
    }

    /// Thickness as a share of the lane, growing with the square root of the rate: twice as
    /// thick is four times the tokens, and a small burn next to a big one stays visible.
    static func thickness(_ rate: Double, fullScale: Double) -> Double {
        guard rate > 0, fullScale > 0 else { return 0 }
        return min(1, rate / fullScale).squareRoot()
    }

    init(perMinute: [Double], total: Int) {
        self.perMinute = perMinute
        self.total = total
    }

    init(_ session: FleetSession, window: ClosedRange<Date>, slices: Int, metric: TokenMetric) {
        let length = window.upperBound.timeIntervalSince(window.lowerBound)
        var sums = [Double](repeating: 0, count: slices)
        var total = 0
        for request in session.requests where window.contains(request.t) {
            let slice = min(slices - 1, Int(request.t.timeIntervalSince(window.lowerBound) / length * Double(slices)))
            let count = metric.count(request)
            sums[slice] += Double(count)
            total += count
        }
        let minutes = length / 60 / Double(slices)
        perMinute = sums.map { $0 / minutes }
        self.total = total
    }
}

/// The combined page's left column: every session as a ribbon along the time axis. Its length
/// is time, its thickness the tokens it burnt per minute, on one scale for all sessions.
struct AgentHistory: View {
    let fleet: FleetStore
    @AppStorage(SettingsKey.trajectoryRange) private var range = TrajectoryRange.threeHours
    private let metric = TokenMetric.all
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: String?
    private static let slices = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColumnTitle("History")
                Spacer()
                Segmented(selection: $range, options: TrajectoryRange.allCases.map { ($0, $0.rawValue) })
                    .help("How much history to show")
            }

            if let now = fleet.lastUpdated {
                if fleet.sessions.isEmpty {
                    Text("No Claude Code sessions are running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    content(now: now)
                }
            } else {
                Text("Looking for sessions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { fleet.startPolling() }
        .onDisappear { fleet.stopPolling() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let window = now.addingTimeInterval(-range.seconds)...now
        let sessions = fleet.sessions
        let burns = sessions.map { TokenBurn($0, window: window, slices: Self.slices, metric: metric) }
        let fullScale = TokenBurn.fullScale(burns)
        let unit = metric == .all ? "tokens" : "output tokens"

        Text("\(Format.tokens(burns.reduce(0) { $0 + $1.total })) \(unit) in the \(range.caption), \(counted(sessions.count, "session"))")
            .font(.caption)
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                let color = SeriesPalette.color(fleet.slots[session.id], scheme)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Capsule().fill(color).frame(width: 10, height: 3)
                        Text(session.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(Format.tokens(burns[index].total))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    BurnLane(turns: session.turns, burn: burns[index], fullScale: fullScale, color: color, window: window)
                }
                .padding(.vertical, 1)
                .background(hovered == session.id ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hovered = session.id } else if hovered == session.id { hovered = nil }
                }
                .hoverCard(hovered == session.id, side: .trailing, width: TrajectoryCard.width) {
                    TrajectoryCard(session: session, color: color, now: now, window: window, range: range, metric: metric)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(session.name): \(Format.tokens(burns[index].total)) \(unit) in the \(range.caption)")
            }
            TimeLabels(window: window, range: range)
        }

        Text("Thicker means more \(unit) per minute, full thickness at \(Format.tokens(fullScale))/min or more. A thin line means busy without tokens.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A session's ribbon: a thin line where it was busy, swelling with the tokens it burnt.
struct BurnLane: View {
    /// When the session was busy; none for past windows, which keep only the tokens.
    let turns: [FleetSession.Span]
    let burn: TokenBurn
    let fullScale: Double
    let color: Color
    let window: ClosedRange<Date>

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let length = window.upperBound.timeIntervalSince(window.lowerBound)
            func x(_ time: Date) -> CGFloat {
                size.width * min(1, max(0, time.timeIntervalSince(window.lowerBound) / length))
            }

            context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
                         with: .color(.primary.opacity(0.12)))
            for turn in turns where turn.end >= window.lowerBound && turn.start <= window.upperBound {
                let start = x(turn.start)
                context.fill(Path(CGRect(x: start, y: middle - 1, width: max(1.5, x(turn.end) - start), height: 2)),
                             with: .color(color))
            }

            guard fullScale > 0 else { return }
            let step = size.width / CGFloat(burn.perMinute.count)
            var top = [CGPoint(x: 0, y: middle)]
            var bottom: [CGPoint] = []
            for (slice, rate) in burn.perMinute.enumerated() {
                // Any burn stays visible.
                let thickness = rate > 0 ? max(1.5, size.height * TokenBurn.thickness(rate, fullScale: fullScale)) : 0
                let center = (CGFloat(slice) + 0.5) * step
                top.append(CGPoint(x: center, y: middle - thickness / 2))
                bottom.append(CGPoint(x: center, y: middle + thickness / 2))
            }
            top.append(CGPoint(x: size.width, y: middle))
            var ribbon = Path()
            ribbon.addLines(top + bottom.reversed())
            ribbon.closeSubpath()
            context.fill(ribbon, with: .color(color))
        }
        .frame(height: 18)
    }
}

/// Clock times under the lanes.
struct TimeLabels: View {
    let window: ClosedRange<Date>
    let range: TrajectoryRange

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let length = window.upperBound.timeIntervalSince(window.lowerBound)
            ZStack(alignment: .topLeading) {
                ForEach(clockTicks(in: window, every: TimeInterval(range.tickMinutes * 60)), id: \.self) { tick in
                    let x = width * tick.timeIntervalSince(window.lowerBound) / length
                    // Labels too close to an edge would be cut off.
                    if x > 14, x < width - 14 {
                        Text(tick.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .position(x: x, y: 6)
                    }
                }
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Running now: what burns, and what's left

/// The sessions working right now, by how fast they burn tokens, with the work they still
/// have open: tasks left, subagents and workflows running.
struct RunningNow: View {
    let fleet: FleetStore
    private let metric = TokenMetric.all
    @AppStorage(SettingsKey.trajectoryRange) private var range = TrajectoryRange.threeHours
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: String?
    /// The burn rate is averaged over this much recent time.
    static let rateSpan: TimeInterval = 10 * 60
    private static let maxRows = 4

    var body: some View {
        let now = fleet.lastUpdated ?? Date()
        let running = fleet.sessions
            .filter { $0.isBusy || !$0.runningAgents.isEmpty }
            .map { (session: $0, rate: $0.tokensPerMinute(now: now, over: Self.rateSpan, metric: metric)) }
            .sorted { $0.rate > $1.rate }
        let peak = running.map(\.rate).max() ?? 0

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ColumnTitle("Running now")
                Spacer()
                if !running.isEmpty {
                    Text("\(Format.tokens(running.reduce(0) { $0 + $1.rate }))/min")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // As tall as the headings beside it, which carry a switch.
            .frame(minHeight: 22)
            .help("\(metric == .all ? "Tokens" : "Output tokens") per minute over the last 10 minutes")

            if fleet.lastUpdated == nil {
                Text("Looking for sessions…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if running.isEmpty {
                Text("Nothing is running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(running.prefix(Self.maxRows), id: \.session.id) { item in
                    row(item.session, rate: item.rate, peak: peak, now: now)
                }
                if running.count > Self.maxRows {
                    Text("+\(running.count - Self.maxRows) more running")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { fleet.startPolling() }
        .onDisappear { fleet.stopPolling() }
    }

    private func row(_ session: FleetSession, rate: Double, peak: Double, now: Date) -> some View {
        let color = SeriesPalette.color(fleet.slots[session.id], scheme)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Capsule().fill(color).frame(width: 10, height: 3)
                Text(session.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(Format.tokens(rate))/min")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule()
                        .fill(color)
                        .frame(width: peak > 0 && rate > 0 ? max(4, geometry.size.width * rate / peak) : 0)
                }
            }
            .frame(height: 4)
            Text(outlook(session, now: now))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .background(hovered == session.id ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = session.id } else if hovered == session.id { hovered = nil }
        }
        .hoverCard(hovered == session.id, side: .leading, width: TrajectoryCard.width) {
            TrajectoryCard(session: session, color: color, now: now,
                           window: now.addingTimeInterval(-range.seconds)...now, range: range, metric: metric)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.name): \(Format.tokens(rate)) tokens per minute. \(outlook(session, now: now))")
    }

    /// What the session still has open, to gauge how much more it will burn.
    private func outlook(_ session: FleetSession, now: Date) -> String {
        var parts: [String] = []
        if let left = session.tasksLeft {
            parts.append(left > 0 ? "\(left) of \(session.tasks.total) tasks left" : "all \(session.tasks.total) tasks done")
        }
        if !session.runningAgents.isEmpty { parts.append(counted(session.runningAgents.count, "subagent")) }
        if session.workflowsRunning > 0 { parts.append(counted(session.workflowsRunning, "workflow")) }
        if parts.isEmpty {
            parts.append("\(session.isBusy ? "busy" : "idle") \(Format.duration(now.timeIntervalSince(session.statusSince)))")
        }
        return parts.joined(separator: " · ")
    }
}
