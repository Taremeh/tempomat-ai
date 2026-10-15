import SwiftUI

// MARK: - Peaks

/// A stretch of a window where the burn peaked.
struct BurnPeak: Identifiable {
    /// 1, 2, …, in time order.
    let number: Int
    let slices: Range<Int>
    let tokens: Int

    var id: Int { number }
}

/// One session's part in a stretch of a window: its tokens there, where in it they went, and
/// what it was working on.
struct PeakShare: Identifiable {
    /// Where a session's tokens went: its main agent, a workflow's subagents, or a subagent alone.
    struct Source: Identifiable {
        enum Kind { case main, workflow, subagent }
        let kind: Kind
        let label: String
        let tokens: Int
        /// A workflow's agents and their tokens, most first.
        var parts: [(label: String, tokens: Int)] = []

        var id: String { "\(kind) \(label)" }
    }

    let session: PastWindow.Session
    /// Its place among the window's sessions, for its color.
    let index: Int
    let tokens: Int
    /// Most tokens first; empty when the session wasn't logged.
    let sources: [Source]
    /// Your last prompt to it by the end of the stretch, from before the window if need be.
    let prompt: FleetSession.Prompt?
    /// The tasks in progress during the stretch.
    let tasks: [String]

    var id: String { session.id }
}

extension PastWindow {
    /// A peak is an hour at most.
    private static let peakSlices = 12

    /// Where the burn peaked: up to `limit` stretches in time order, each around one of the
    /// busiest slices and reaching on while its neighbors burnt at least half as much. A slice
    /// well under the busiest isn't a peak, nor is one close to the window's average, so an even
    /// burn has none. `elapsed` is how many slices have begun.
    func peaks(elapsed: Int, limit: Int = 4) -> [BurnPeak] {
        guard let top = slices.max(), top > 0 else { return [] }
        let elapsed = min(max(elapsed, 1), slices.count)
        let average = Double(slices.prefix(elapsed).reduce(0, +)) / Double(elapsed)
        let floor = max(Double(top) * 0.35, average * 1.5)
        var claimed = [Bool](repeating: false, count: slices.count)
        var found: [Range<Int>] = []
        for index in slices.indices.sorted(by: { slices[$0] > slices[$1] }) {
            guard found.count < limit, Double(slices[index]) >= floor else { break }
            guard !claimed[index] else { continue }
            var lower = index, upper = index
            while upper - lower + 1 < Self.peakSlices {
                let left = lower > 0 && !claimed[lower - 1] ? slices[lower - 1] : -1
                let right = upper < slices.count - 1 && !claimed[upper + 1] ? slices[upper + 1] : -1
                guard max(left, right) * 2 >= slices[index] else { break }
                if left >= right { lower -= 1 } else { upper += 1 }
            }
            for slice in lower...upper { claimed[slice] = true }
            found.append(lower..<upper + 1)
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }.enumerated().map { number, range in
            BurnPeak(number: number + 1, slices: range, tokens: slices[range].reduce(0, +))
        }
    }

    /// Who burnt the tokens in some slices: each session's share, most first, split into its
    /// main agent's, each workflow's and each lone subagent's.
    func shares(in range: Range<Int>) -> [PeakShare] {
        let from = sliceStart(range.lowerBound)
        let to = sliceStart(range.upperBound)
        return sessions.enumerated().compactMap { index, session -> PeakShare? in
            let tokens = session.slices[range.clamped(to: session.slices.indices)].reduce(0, +)
            guard tokens > 0 else { return nil }
            var sources: [PeakShare.Source] = []
            if let agents = session.agents {
                var workflows: [String: [(label: String, tokens: Int)]] = [:]
                for agent in agents {
                    let spent = agent.tokens(in: range)
                    guard spent > 0 else { continue }
                    if let workflow = agent.workflow {
                        // Inside a workflow, its phase goes without saying.
                        let name = agent.label.range(of: ": ").map { String(agent.label[$0.upperBound...]) } ?? agent.label
                        workflows[workflow, default: []].append((name, spent))
                    } else {
                        sources.append(.init(kind: .subagent, label: agent.label, tokens: spent))
                    }
                }
                for (name, parts) in workflows {
                    sources.append(.init(kind: .workflow, label: name, tokens: parts.reduce(0) { $0 + $1.tokens },
                                         parts: parts.sorted { $0.tokens > $1.tokens }))
                }
                let main = tokens - sources.reduce(0) { $0 + $1.tokens }
                if main > 0 { sources.append(.init(kind: .main, label: "Main agent", tokens: main)) }
                sources.sort { $0.tokens > $1.tokens }
            }
            var seen = Set<String>()
            let tasks = (session.tasks ?? [])
                .filter { $0.start < to && ($0.end ?? to) >= from }
                .map(\.subject)
                .filter { seen.insert($0).inserted }
            return PeakShare(session: session, index: index, tokens: tokens, sources: sources,
                             prompt: session.prompts?.last { $0.t < to } ?? session.promptBefore, tasks: tasks)
        }
        .sorted { $0.tokens > $1.tokens }
    }
}

// MARK: - Timeline

/// Where the pointer is on the timeline: a time, on one lane, and how near counts as on a prompt.
private struct TimelineHover: Equatable {
    let time: Date
    let lane: String
    /// The time a few points of width stand for.
    let reach: TimeInterval
}

/// A window on one wide timeline: all sessions together against the cruise budget, then each
/// session, with a mark wherever you prompted and the peaks numbered; below, what burnt each peak.
struct WindowTimeline: View {
    let window: PastWindow
    let budget: TokenBudget?
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    @State private var hover: TimelineHover?
    /// The peak under the pointer, on its badge or its card.
    @State private var focused: Int?
    private static let listedSessions = 8
    private static let allLane = "all"
    private static let markHeight = TimelineDrawing.markHeight

    var body: some View {
        if window.slices.isEmpty {
            Text("No token data: this Mac's Claude Code sessions weren't read for this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let peaks = window.peaks(elapsed: elapsed)
            VStack(alignment: .leading, spacing: 22) {
                aggregate(peaks: peaks)
                sessions(peaks: peaks)
                peakCards(peaks)
            }
        }
    }

    private var span: ClosedRange<Date> { window.start...window.reset }
    private var sliceMinutes: Double { window.length / 60 / Double(max(1, window.slices.count)) }

    /// Slices that have begun: all of them once the window has reset.
    private var elapsed: Int {
        let now = budget?.now ?? Date()
        guard now < window.reset else { return window.slices.count }
        return (PastWindow.slice(of: now, start: window.start, reset: window.reset) ?? 0) + 1
    }

    private func color(_ index: Int) -> Color { SeriesPalette.color(index, scheme) }

    private func slice(at time: Date) -> Int {
        PastWindow.slice(of: min(time, window.reset.addingTimeInterval(-1)), start: window.start, reset: window.reset) ?? 0
    }

    private func clock(_ time: Date) -> String { Format.clock(time, now: window.start) }

    /// The prompt nearest the pointer on `lane`, if the pointer is on one.
    private func prompt<Item>(near lane: String, in items: [Item], time: (Item) -> Date) -> Item? {
        guard let hover, hover.lane == lane else { return nil }
        return items
            .filter { abs(time($0).timeIntervalSince(hover.time)) <= hover.reach }
            .min { abs(time($0).timeIntervalSince(hover.time)) < abs(time($1).timeIntervalSince(hover.time)) }
    }

    // MARK: All sessions

    private func aggregate(peaks: [BurnPeak]) -> some View {
        let prompts = window.sessions.enumerated()
            .flatMap { index, session in (session.prompts ?? []).map { (prompt: $0, session: index) } }
            .sorted { $0.prompt.t < $1.prompt.t }
        let near = prompt(near: Self.allLane, in: prompts) { $0.prompt.t }
        let marks = prompts.map { TimelineMark(t: $0.prompt.t, color: color($0.session)) }
        let hoverFraction = hover.map { $0.time.timeIntervalSince(window.start) / window.length }

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Capsule().fill(tint).frame(width: 10, height: 3)
                Text("All sessions on this Mac")
                    .font(.caption)
                Spacer(minLength: 4)
                Text(aggregateReadout(peaks: peaks))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            PeakMarks(peaks: peaks, count: window.slices.count, focused: $focused)
            Group {
                if let budget {
                    ZStack(alignment: .top) {
                        Canvas { context, size in
                            TimelineDrawing.peaks(peaks, count: window.slices.count, focused: focused,
                                                  in: context, size: size, top: Self.markHeight)
                        }
                        BudgetRibbon(budget: budget, fullScale: TokenBudgetView.fullScale(budget), tint: tint,
                                     hoverFraction: .constant(hoverFraction))
                            .padding(.top, Self.markHeight)
                        Canvas { context, size in
                            TimelineDrawing.prompts(marks, highlighted: near?.prompt.t, window: span, in: context, size: size)
                        }
                    }
                } else {
                    let burn = window.slices.map { Double($0) / sliceMinutes }
                    SessionLane(total: burn, main: nil, fullScale: TokenBurn.fullScale([TokenBurn(perMinute: burn, total: window.tokens)]),
                                color: tint, marks: marks, highlighted: near?.prompt.t, peaks: peaks, focused: focused,
                                window: span, hover: hover?.time)
                }
            }
            .frame(height: 56 + Self.markHeight)
            .modifier(TimelineHoverArea(lane: Self.allLane, window: span, hover: $hover))
            .accessibilityLabel("All sessions: \(Format.tokens(window.tokens)) tokens, \(counted(prompts.count, "prompt")), \(counted(peaks.count, "peak"))")
            TimelineAxis(window: span)
            Group {
                if let near {
                    Text("▸ \(clock(near.prompt.t)) · \(window.sessions[near.session].name): ")
                        + Text("“\(near.prompt.text)”").italic()
                } else {
                    Text(prompts.isEmpty ? "Numbered: the peaks, explained below."
                                         : "▾ marks where you prompted, in the session's color. Numbered: the peaks, explained below.")
                }
            }
            .font(.caption2)
            .foregroundStyle(near == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    /// The window's total, or at the pointer the burn there, the budget and the peak it is in.
    private func aggregateReadout(peaks: [BurnPeak]) -> String {
        guard let hover else {
            return "\(Format.tokens(window.tokens)) tokens" + (budget.map { " of ≈ \(Format.tokens($0.capacity))" } ?? "")
        }
        let index = slice(at: hover.time)
        let burn = budget?.burn(index) ?? Double(window.slices[index]) / sliceMinutes
        var parts = ["\(clock(hover.time))", "\(Format.tokens(burn))/min"]
        if let budget { parts.append("budget \(Format.tokens(budget.budget(index)))/min") }
        if let peak = peaks.first(where: { $0.slices.contains(index) }) { parts.append("peak \(peak.number)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Each session

    private func sessions(peaks: [BurnPeak]) -> some View {
        let listed = Array(window.sessions.prefix(Self.listedSessions))
        let burns = listed.map { TokenBurn(perMinute: $0.slices.map { Double($0) / sliceMinutes }, total: $0.tokens) }
        let fullScale = TokenBurn.fullScale(burns)
        let others = window.sessions.dropFirst(Self.listedSessions)
        let unlogged = window.sessions.contains { !$0.isLogged }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ColumnTitle("Sessions")
                Spacer()
                Text("Share of the window's tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(listed.enumerated()), id: \.element.id) { index, session in
                sessionRow(session, index: index, burn: burns[index], fullScale: fullScale, peaks: peaks)
            }
            if !others.isEmpty {
                Text("+ \(counted(others.count, "more session")), \(Format.tokens(others.reduce(0) { $0 + $1.tokens })) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TimelineAxis(window: span)
            Text("Thickness is tokens per minute; twice as thick is four times the tokens. Solid: the session's main agent. Light: its subagents."
                 + (unlogged ? " Sessions drawn solid only weren't logged: the window was kept before the app logged prompts and subagents, and their transcripts are gone." : ""))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sessionRow(_ session: PastWindow.Session, index: Int, burn: TokenBurn, fullScale: Double,
                            peaks: [BurnPeak]) -> some View {
        let color = color(index)
        let prompts = session.prompts ?? []
        let near = prompt(near: session.id, in: prompts) { $0.t }
        // The main agent's own tokens: the session's, less its subagents'.
        let main = session.agents.map { agents in
            var main = session.slices.map(Double.init)
            for agent in agents {
                for (offset, tokens) in agent.slices.enumerated() where main.indices.contains(agent.firstSlice + offset) {
                    main[agent.firstSlice + offset] -= Double(tokens)
                }
            }
            return main.map { max(0, $0) / sliceMinutes }
        }

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Capsule().fill(color).frame(width: 10, height: 3)
                Text(session.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if let near {
                        Text("▸ \(clock(near.t)) ") + Text("“\(near.text)”").italic()
                    } else {
                        Text(rowDetail(session))
                    }
                }
                .font(.caption2)
                .foregroundStyle(near == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                Spacer(minLength: 4)
                Text(Format.tokens(session.tokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Format.percent(Double(session.tokens) / Double(max(1, window.tokens)) * 100))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            SessionLane(total: burn.perMinute, main: main, fullScale: fullScale, color: color,
                        marks: prompts.map { TimelineMark(t: $0.t, color: color) }, highlighted: near?.t,
                        peaks: peaks, focused: focused, window: span, hover: hover?.time)
                .frame(height: 26 + Self.markHeight)
                .modifier(TimelineHoverArea(lane: session.id, window: span, hover: $hover))
                .accessibilityLabel("\(session.name): \(Format.tokens(session.tokens)) tokens, \(counted(prompts.count, "prompt"))")
        }
    }

    /// Beside the name: its folder, prompts and subagents; at the pointer, its burn there and
    /// how much of it its subagents' was.
    private func rowDetail(_ session: PastWindow.Session) -> String {
        if let hover, hover.lane == session.id {
            let index = slice(at: hover.time)
            let tokens = session.slices[index]
            let agents = session.agents?.reduce(0) { $0 + $1.tokens(in: index..<index + 1) } ?? 0
            return "\(clock(hover.time)) · \(Format.tokens(Double(tokens) / sliceMinutes))/min"
                + (agents > 0 && tokens > 0 ? ", \(Format.percent(Double(agents) / Double(tokens) * 100)) subagents" : "")
        }
        var parts: [String] = []
        if !session.project.isEmpty, session.project != session.name { parts.append(session.project) }
        if let prompts = session.prompts, !prompts.isEmpty { parts.append(counted(prompts.count, "prompt")) }
        if let agents = session.agents, !agents.isEmpty { parts.append(counted(agents.count, "subagent")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Peaks

    private func peakCards(_ peaks: [BurnPeak]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ColumnTitle("Peaks · what burnt the tokens")
                Spacer()
                if !peaks.isEmpty {
                    Text("Point at a peak to find it on the timeline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if peaks.isEmpty {
                Text("No peaks: the burn was about even across the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(peaks) { peak in
                        PeakCard(peak: peak, window: window, budget: budget, isFocused: focused == peak.number, color: color)
                            .onHover { inside in
                                if inside { focused = peak.number } else if focused == peak.number { focused = nil }
                            }
                    }
                }
            }
        }
    }
}

/// Follows the pointer over a lane as a time on the window.
private struct TimelineHoverArea: ViewModifier {
    let lane: String
    let window: ClosedRange<Date>
    @Binding var hover: TimelineHover?

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        let length = window.upperBound.timeIntervalSince(window.lowerBound)
                        let width = max(1, geometry.size.width)
                        switch phase {
                        case .active(let location):
                            let fraction = min(1, max(0, location.x / width))
                            hover = TimelineHover(time: window.lowerBound.addingTimeInterval(fraction * length), lane: lane,
                                                  reach: 5 / width * length)
                        case .ended:
                            if hover?.lane == lane { hover = nil }
                        }
                    }
            }
        }
    }
}

// MARK: - Drawing

/// A prompt's mark on a lane.
private struct TimelineMark {
    let t: Date
    let color: Color
}

/// What every lane draws the same way: peaks behind, prompt marks over.
private enum TimelineDrawing {
    /// Above each ribbon, the strip for prompt marks.
    static let markHeight: CGFloat = 9

    static func x(_ time: Date, in window: ClosedRange<Date>, width: CGFloat) -> CGFloat {
        let length = window.upperBound.timeIntervalSince(window.lowerBound)
        return width * min(1, max(0, time.timeIntervalSince(window.lowerBound) / length))
    }

    /// The peaks as shaded columns below `top`, the one in focus stronger.
    static func peaks(_ peaks: [BurnPeak], count: Int, focused: Int?, in context: GraphicsContext, size: CGSize, top: CGFloat) {
        for peak in peaks {
            let from = size.width * CGFloat(peak.slices.lowerBound) / CGFloat(count)
            let to = size.width * CGFloat(peak.slices.upperBound) / CGFloat(count)
            context.fill(Path(CGRect(x: from, y: top, width: to - from, height: size.height - top)),
                         with: .color(peak.number == focused ? Color.accentColor.opacity(0.16) : .primary.opacity(0.045)))
        }
    }

    /// A small triangle above the ribbon pointing down at each prompt, with a hairline through
    /// the ribbon; the one under the pointer stands out.
    static func prompts(_ marks: [TimelineMark], highlighted: Date?, window: ClosedRange<Date>, in context: GraphicsContext,
                        size: CGSize) {
        let top = markHeight
        for mark in marks {
            let x = x(mark.t, in: window, width: size.width)
            let isHighlighted = mark.t == highlighted
            context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: size.height - top)),
                         with: .color(mark.color.opacity(isHighlighted ? 0.95 : 0.4)))
            let half: CGFloat = isHighlighted ? 5 : 3.5
            var triangle = Path()
            triangle.move(to: CGPoint(x: x - half, y: isHighlighted ? 0 : 1.5))
            triangle.addLine(to: CGPoint(x: x + half, y: isHighlighted ? 0 : 1.5))
            triangle.addLine(to: CGPoint(x: x, y: top - 1))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(mark.color))
        }
    }
}

/// A session's ribbon on the wide timeline: its whole burn light, its main agent's part solid in
/// the middle, with the peaks behind and a mark wherever you prompted it.
private struct SessionLane: View {
    /// Tokens per minute in each slice, subagents included.
    let total: [Double]
    /// The main agent's part of it; nil when the session wasn't logged.
    let main: [Double]?
    let fullScale: Double
    let color: Color
    let marks: [TimelineMark]
    let highlighted: Date?
    let peaks: [BurnPeak]
    let focused: Int?
    let window: ClosedRange<Date>
    let hover: Date?

    var body: some View {
        Canvas { context, size in
            let top = TimelineDrawing.markHeight
            let height = size.height - top
            let middle = top + height / 2
            let step = size.width / CGFloat(max(1, total.count))
            TimelineDrawing.peaks(peaks, count: total.count, focused: focused, in: context, size: size, top: top)
            context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)), with: .color(.primary.opacity(0.12)))

            // Any burn stays visible.
            let outer = total.map { $0 > 0 ? max(1.5, height * CGFloat(TokenBurn.thickness($0, fullScale: fullScale))) : 0 }
            if let main {
                context.fill(BudgetRibbon.ribbon(outer, step: step, middle: middle, endX: size.width, taperEnds: true),
                             with: .color(color.opacity(0.35)))
                // The main agent's share of the thickness, as its share of the tokens.
                let inner = outer.indices.map { total[$0] > 0 ? outer[$0] * CGFloat(min(1, main[$0] / total[$0])) : 0 }
                context.fill(BudgetRibbon.ribbon(inner, step: step, middle: middle, endX: size.width, taperEnds: true),
                             with: .color(color))
            } else {
                context.fill(BudgetRibbon.ribbon(outer, step: step, middle: middle, endX: size.width, taperEnds: true),
                             with: .color(color))
            }

            TimelineDrawing.prompts(marks, highlighted: highlighted, window: window, in: context, size: size)
            if let hover {
                let x = TimelineDrawing.x(hover, in: window, width: size.width)
                context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: height)), with: .color(.secondary.opacity(0.6)))
            }
        }
    }
}

/// Numbered badges over the peaks, each above a bracket spanning its stretch.
private struct PeakMarks: View {
    let peaks: [BurnPeak]
    let count: Int
    @Binding var focused: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(peaks) { peak in
                    let from = width * CGFloat(peak.slices.lowerBound) / CGFloat(count) + 1
                    let to = width * CGFloat(peak.slices.upperBound) / CGFloat(count) - 1
                    Path { path in
                        path.move(to: CGPoint(x: from, y: 21))
                        path.addLine(to: CGPoint(x: from, y: 17))
                        path.addLine(to: CGPoint(x: to, y: 17))
                        path.addLine(to: CGPoint(x: to, y: 21))
                    }
                    .stroke(focused == peak.number ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1)
                    PeakBadge(number: peak.number, isFocused: focused == peak.number)
                        .onHover { inside in
                            if inside { focused = peak.number } else if focused == peak.number { focused = nil }
                        }
                        .position(x: (from + to) / 2, y: 8)
                }
            }
        }
        .frame(height: 21)
    }
}

/// A peak's number in a dot.
private struct PeakBadge: View {
    let number: Int
    let isFocused: Bool

    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.background))
            .frame(width: 16, height: 16)
            .background(isFocused ? Color.accentColor : .primary.opacity(0.75), in: Circle())
            .accessibilityLabel("Peak \(number)")
    }
}

/// Clock times every half hour under the wide timeline.
private struct TimelineAxis: View {
    let window: ClosedRange<Date>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(clockTicks(in: window, every: 1800), id: \.self) { tick in
                    let x = TimelineDrawing.x(tick, in: window, width: width)
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

// MARK: - A peak explained

/// What burnt one peak: its stretch and tokens, how fast that was against the cruise budget,
/// and for each session that burnt in it, where its tokens went (main agent, workflows,
/// subagents), the prompt it was answering and the tasks it was on.
private struct PeakCard: View {
    let peak: BurnPeak
    let window: PastWindow
    let budget: TokenBudget?
    let isFocused: Bool
    let color: (Int) -> Color
    private static let listedShares = 3
    private static let listedSources = 4

    var body: some View {
        let shares = window.shares(in: peak.slices)
        let from = window.sliceStart(peak.slices.lowerBound)
        let to = window.sliceStart(peak.slices.upperBound)
        let others = shares.dropFirst(Self.listedShares)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PeakBadge(number: peak.number, isFocused: isFocused)
                Text("\(clock(from))–\(clock(to))")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 4)
                Text(Format.tokens(peak.tokens))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text("tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(summary(from: from, to: to))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            shareBar(shares)

            ForEach(shares.prefix(Self.listedShares)) { share in
                shareRows(share)
            }
            if !others.isEmpty {
                Text("+ \(counted(others.count, "more session")), \(Format.tokens(others.reduce(0) { $0 + $1.tokens })) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(isFocused ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : .clear))
    }

    private func clock(_ time: Date) -> String { Format.clock(time, now: window.start) }

    /// How fast, against the cruise budget, and its share of the window.
    private func summary(from: Date, to: Date) -> String {
        let end = min(to, budget?.now ?? to)
        let rate = Double(peak.tokens) / max(1, end.timeIntervalSince(from) / 60)
        var parts = ["\(Format.tokens(rate))/min"]
        if let budget {
            let cruise = peak.slices.map(budget.budget).reduce(0, +) / Double(peak.slices.count)
            if cruise > 0 { parts.append(String(format: "%.1f× the cruise budget", rate / cruise)) }
        }
        parts.append("\(Format.percent(Double(peak.tokens) / Double(max(1, window.tokens)) * 100)) of the window's tokens")
        return parts.joined(separator: " · ")
    }

    /// Each session's part of the peak, in its color.
    private func shareBar(_ shares: [PeakShare]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(shares) { share in
                    Rectangle()
                        .fill(color(share.index))
                        .frame(width: max(1, (geometry.size.width - CGFloat(shares.count - 1))
                                * CGFloat(share.tokens) / CGFloat(max(1, peak.tokens))))
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }

    private func shareRows(_ share: PeakShare) -> some View {
        let sources = share.sources.prefix(Self.listedSources)
        let rest = share.sources.dropFirst(Self.listedSources)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Capsule().fill(color(share.index)).frame(width: 10, height: 3)
                Text(share.session.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Format.tokens(share.tokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Format.percent(Double(share.tokens) / Double(max(1, peak.tokens)) * 100))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sources) { source in
                    sourceRow(source)
                }
                if !rest.isEmpty {
                    Text("+ \(rest.count) more, \(Format.tokens(rest.reduce(0) { $0 + $1.tokens }))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 17)
                }
                if let prompt = share.prompt {
                    line(symbol: "text.quote", Text("\(clock(prompt.t)) · ") + Text("“\(prompt.text)”").italic())
                        .help(prompt.text)
                }
                if !share.tasks.isEmpty {
                    line(symbol: "checklist", Text(share.tasks.joined(separator: " · ")))
                }
                if !share.session.isLogged {
                    Text("Its prompts and subagents weren't logged for this window.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 15)
        }
    }

    private func sourceRow(_ source: PeakShare.Source) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: symbol(source.kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(source.kind == .workflow ? "Workflow \(source.label) · \(counted(source.parts.count, "agent"))" : source.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Format.tokens(source.tokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !source.parts.isEmpty {
                let shown = source.parts.prefix(4).map { "\($0.label) \(Format.tokens($0.tokens))" }
                Text((shown + (source.parts.count > 4 ? ["+\(source.parts.count - 4)"] : [])).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.leading, 17)
            }
        }
    }

    private func line(symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            text
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func symbol(_ kind: PeakShare.Source.Kind) -> String {
        switch kind {
        case .main: "bubble.left"
        case .workflow: "flowchart"
        case .subagent: "arrow.turn.down.right"
        }
    }
}
