import SwiftUI

extension SettingsKey {
    /// Tokens per 1% of the 5-hour limit, as last measured; one value per token metric.
    static func tokensPerPercent(_ metric: TokenMetric) -> String { "tokensPerPercent.\(metric.rawValue)" }
}

/// The 5-hour limit in tokens: how fast all sessions together burnt tokens over the window, and
/// the cruise budget, the rate that would use exactly what's left by reset, as it moved.
///
/// `/usage` reports percentages only. Tokens per percent come from comparing the tokens every
/// Claude Code session on this Mac used since the window opened with the percentage used, so
/// usage elsewhere (claude.ai, other machines) is spread over this Mac's tokens.
struct TokenBudget {
    let start: Date
    let reset: Date
    let now: Date
    let percentUsed: Double
    /// Tokens per 1% of the limit.
    let perPercent: Double
    /// Measured in this window; nil when the window is too young and an earlier value is used.
    let measured: Double?
    /// Tokens used on this Mac in each equal slice of the window.
    let sliceTokens: [Double]

    /// Below this share of the window used, 1% steps make the measurement too coarse.
    static let minimumPercent = 5.0
    /// Five-minute slices over the 5-hour window.
    static let slices = 60

    var capacity: Double { perPercent * 100 }
    var usedTokens: Double { percentUsed * perPercent }
    var available: Double { max(0, capacity - usedTokens) }
    var length: TimeInterval { reset.timeIntervalSince(start) }
    var sliceLength: TimeInterval { length / Double(sliceTokens.count) }
    var nowFraction: Double { min(1, max(0, now.timeIntervalSince(start) / length)) }

    /// The cruise budget at the window's opening: an even fifth of the limit per hour, per minute.
    var startRate: Double { capacity / (length / 60) }
    /// The cruise budget now, per minute: what's left over the time that's left.
    var setRate: Double {
        let left = reset.timeIntervalSince(now)
        return left > 60 ? available / (left / 60) : 0
    }

    func sliceStart(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * sliceLength) }

    /// Tokens per minute burnt in a slice; nil for slices that haven't started.
    func burn(_ index: Int) -> Double? {
        let from = sliceStart(index)
        guard from < now else { return nil }
        let minutes = min(sliceLength, now.timeIntervalSince(from)) / 60
        return minutes > 0 ? sliceTokens[index] / minutes : 0
    }

    /// The cruise budget per minute as it stood when a slice began: what was left of the limit
    /// over the time that was left. Slices still ahead keep today's budget, the projection.
    func budget(_ index: Int) -> Double {
        let from = sliceStart(index)
        guard from < now else { return setRate }
        let usedBefore = sliceTokens[..<index].reduce(0, +)
        let left = reset.timeIntervalSince(from) / 60
        return max(0, capacity - usedBefore) / max(1, left)
    }

    static func make(meter: Meter, requests: [FleetSession.Request], metric: TokenMetric,
                     stored: Double, now: Date) -> TokenBudget? {
        guard let resetsAt = meter.resetsAt, let length = meter.window else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        var sliceTokens = [Double](repeating: 0, count: slices)
        var local = 0.0
        for request in requests where request.t >= start && request.t <= now {
            let index = min(slices - 1, Int(request.t.timeIntervalSince(start) / length * Double(slices)))
            let count = Double(metric.count(request))
            sliceTokens[index] += count
            local += count
        }
        let measured = meter.percent >= minimumPercent && local > 0 ? local / meter.percent : nil
        guard let perPercent = measured ?? (stored > 0 ? stored : nil) else { return nil }
        return TokenBudget(start: start, reset: resetsAt, now: now, percentUsed: meter.percent,
                           perPercent: perPercent, measured: measured, sliceTokens: sliceTokens)
    }
}

/// The whole 5-hour window as one ribbon, like a session's in the history: thickness is the
/// tokens all sessions burnt per minute. Behind it, a translucent band is the cruise budget per
/// minute; where the ribbon sticks out of the band, usage ran faster than cruise.
struct TokenBudgetView: View {
    let store: UsageStore
    let fleet: FleetStore
    private let metric = TokenMetric.all

    var body: some View {
        if let meter = store.meters.first(where: { $0.unit == .perHour && $0.window != nil }) {
            let budget = TokenBudget.make(meter: meter, requests: fleet.recentRequests, metric: metric,
                                          stored: store.tokensPerPercent(for: metric),
                                          now: fleet.lastUpdated ?? Date())
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                    .padding(.bottom, 10)
                if let budget {
                    BudgetRibbonSection(budget: budget, title: "All sessions · 5-hour window", tint: meter.levelTint,
                                        note: note(budget))
                } else {
                    Text("All sessions · 5-hour window: shown once this Mac's Claude Code sessions have used \(Format.percent(TokenBudget.minimumPercent)) of it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { fleet.startPolling() }
            .onDisappear { fleet.stopPolling() }
            // Keep a well-measured value for the start of the next window.
            .onChange(of: budget?.measured) { _, measured in
                if let measured, meter.percent >= 10 {
                    store.recordTokensPerPercent(measured, for: metric)
                }
            }
        }
    }

    /// The rate drawn at full thickness: the busiest slices (95th percentile, so one spike
    /// doesn't flatten the rest) or the cruise budget, whichever is larger. Both ribbons share it.
    static func fullScale(_ budget: TokenBudget) -> Double {
        let burns = (0..<budget.sliceTokens.count).compactMap(budget.burn).filter { $0 > 0 }.sorted()
        let busy = burns.isEmpty ? 0 : burns[min(burns.count - 1, Int(Double(burns.count) * 0.95))]
        return max(busy, budget.startRate * 1.5, budget.setRate * 1.2, 1)
    }

    private func note(_ budget: TokenBudget) -> String {
        let unit = metric == .all ? "tokens" : "output tokens"
        let basis = budget.measured != nil
            ? "\(Format.tokens(budget.usedTokens)) \(unit) used on this Mac so far = \(Format.percent(budget.percentUsed)) of the limit"
            : "measured in an earlier window (this one is under \(Format.percent(TokenBudget.minimumPercent)))"
        return "About \(Format.tokens(budget.capacity)) \(unit) per 5 hours: \(basis). Usage elsewhere (claude.ai, other machines) is spread over this Mac's tokens. The budget started at \(Format.tokens(budget.startRate))/min."
    }
}

/// A window's ribbon with its title, a readout that follows the pointer, clock times and the
/// scale: the current window on the tempomat, or a past one on the History page.
struct BudgetRibbonSection: View {
    let budget: TokenBudget
    let title: String
    let tint: Color
    var note: String?
    @State private var hoverFraction: Double?

    var body: some View {
        let fullScale = TokenBudgetView.fullScale(budget)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Capsule().fill(tint).frame(width: 10, height: 3)
                Text(title)
                    .font(.caption)
                Spacer(minLength: 4)
                Text(readout)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .help(note ?? "")
            BudgetRibbon(budget: budget, fullScale: fullScale, tint: tint, hoverFraction: $hoverFraction)
                .frame(height: 44)
            WindowTimeLabels(window: budget.start...budget.reset)
            Text("Thickness is tokens per minute, full at \(Format.tokens(fullScale))/min. The light band is the cruise budget, "
                 + (budget.now < budget.reset ? "now \(Format.tokens(budget.setRate))/min." : "which started at \(Format.tokens(budget.startRate))/min."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Used and left, or while hovering, the burn and the budget at that moment.
    private var readout: String {
        guard let fraction = hoverFraction else {
            return "\(Format.tokens(budget.usedTokens)) used · \(Format.tokens(budget.available)) left"
        }
        let index = min(budget.sliceTokens.count - 1, Int(fraction * Double(budget.sliceTokens.count)))
        let time = Format.clock(budget.start.addingTimeInterval(fraction * budget.length))
        let cruise = "budget \(Format.tokens(budget.budget(index)))/min"
        guard let burn = budget.burn(index) else { return "\(time) · \(cruise)" }
        return "\(time) · \(Format.tokens(burn))/min · \(cruise)"
    }
}

/// The window's ribbon: the cruise budget as a translucent band, the burn as a solid ribbon
/// over it up to now, and a mark at now.
struct BudgetRibbon: View {
    let budget: TokenBudget
    let fullScale: Double
    let tint: Color
    @Binding var hoverFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            canvas
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverFraction = min(1, max(0, location.x / max(1, geometry.size.width)))
                    case .ended:
                        hoverFraction = nil
                    }
                }
        }
    }

    private var canvas: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let count = budget.sliceTokens.count
            let step = size.width / CGFloat(count)
            func thickness(_ rate: Double) -> CGFloat { size.height * CGFloat(min(1, rate / fullScale)) }

            context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
                         with: .color(.primary.opacity(0.12)))

            // The cruise budget, across the whole window.
            let band = (0..<count).map { thickness(budget.budget($0)) }
            context.fill(Self.ribbon(band, step: step, middle: middle, endX: size.width, taperEnds: false),
                         with: .color(.green.opacity(0.22)))

            // The burn, up to now. Any burn stays visible.
            let nowX = size.width * CGFloat(budget.nowFraction)
            let burnt = (0..<count).compactMap(budget.burn).map { $0 > 0 ? max(1.5, thickness($0)) : 0 }
            if !burnt.isEmpty {
                context.fill(Self.ribbon(burnt, step: step, middle: middle, endX: nowX, taperEnds: true),
                             with: .color(tint))
            }

            context.fill(Path(CGRect(x: nowX - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(.primary.opacity(0.45)))
            if let hoverFraction {
                let x = size.width * CGFloat(hoverFraction)
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                             with: .color(.secondary.opacity(0.6)))
            }
        }
    }

    /// A ribbon mirrored around the middle, through one thickness per slice (at the slice's
    /// center), from the left edge to `endX`.
    static func ribbon(_ thicknesses: [CGFloat], step: CGFloat, middle: CGFloat, endX: CGFloat, taperEnds: Bool) -> Path {
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        let first = thicknesses.first ?? 0
        top.append(CGPoint(x: 0, y: middle - (taperEnds ? 0 : first / 2)))
        bottom.append(CGPoint(x: 0, y: middle + (taperEnds ? 0 : first / 2)))
        for (index, thickness) in thicknesses.enumerated() {
            let x = min(endX, (CGFloat(index) + 0.5) * step)
            top.append(CGPoint(x: x, y: middle - thickness / 2))
            bottom.append(CGPoint(x: x, y: middle + thickness / 2))
        }
        let last = thicknesses.last ?? 0
        top.append(CGPoint(x: endX, y: middle - (taperEnds ? 0 : last / 2)))
        bottom.append(CGPoint(x: endX, y: middle + (taperEnds ? 0 : last / 2)))
        var path = Path()
        path.addLines(top + bottom.reversed())
        path.closeSubpath()
        return path
    }
}

/// Hourly clock times under the window's ribbon.
private struct WindowTimeLabels: View {
    let window: ClosedRange<Date>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let length = window.upperBound.timeIntervalSince(window.lowerBound)
            ZStack(alignment: .topLeading) {
                ForEach(clockTicks(in: window, every: 3600), id: \.self) { tick in
                    let x = width * tick.timeIntervalSince(window.lowerBound) / length
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
