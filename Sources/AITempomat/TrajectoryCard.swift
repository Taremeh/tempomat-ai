import SwiftUI

// MARK: - Hover card layer

/// Which side of the hovered row a card opens on.
enum CardSide {
    case leading, trailing
}

/// A card a hovered row asks to show: the row's bounds, the side to open on, and the card.
struct HoverCardRequest {
    let row: Anchor<CGRect>
    let side: CardSide
    let width: CGFloat
    let card: AnyView
}

struct HoverCardKey: PreferenceKey {
    static var defaultValue: HoverCardRequest? { nil }
    static func reduce(value: inout HoverCardRequest?, nextValue: () -> HoverCardRequest?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// While `isShown`, shows `card` beside this view, in the panel's top layer (see
    /// `HoverCardLayer`), so nothing laid out after this view draws over it.
    func hoverCard<Card: View>(_ isShown: Bool, side: CardSide, width: CGFloat,
                               @ViewBuilder card: @escaping () -> Card) -> some View {
        anchorPreference(key: HoverCardKey.self, value: .bounds) { row in
            isShown ? HoverCardRequest(row: row, side: side, width: width, card: AnyView(card())) : nil
        }
    }

    /// Draws the hover card a row below asks for, above everything in this view.
    func hoverCardLayer() -> some View {
        overlayPreferenceValue(HoverCardKey.self) { request in
            HoverCardLayer(request: request)
        }
    }
}

/// Places a hover card beside its row: level with its top in the upper half of the panel, level
/// with its bottom in the lower half, and always inside the panel.
private struct HoverCardLayer: View {
    let request: HoverCardRequest?
    private static let gap: CGFloat = 12
    private static let inset: CGFloat = 8

    var body: some View {
        GeometryReader { panel in
            if let request {
                let row = panel[request.row]
                let x = request.side == .trailing
                    ? min(row.maxX + Self.gap, panel.size.width - request.width - Self.inset)
                    : max(row.minX - Self.gap - request.width, Self.inset)
                let card = request.card
                    .frame(width: request.width)
                    .fixedSize(horizontal: false, vertical: true)
                if row.midY < panel.size.height / 2 {
                    card.offset(x: x, y: max(Self.inset, row.minY - 4))
                } else {
                    // Bottom-aligned in a frame that ends just below the row.
                    card.frame(height: max(0, row.maxY + 4), alignment: .bottom)
                        .offset(x: x)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Trajectory card

/// Everything about one session's trajectory, shown while the pointer is over it: its state, its
/// numbers, its tokens over the time range, when it was busy and finished tasks, and each of its
/// subagents on the same time axis.
struct TrajectoryCard: View {
    let session: FleetSession
    let color: Color
    let now: Date
    let window: ClosedRange<Date>
    let range: TrajectoryRange
    let metric: TokenMetric

    static let width: CGFloat = 460
    private static let labelWidth: CGFloat = 150
    private static let listedAgents = 8

    var body: some View {
        let inView = session.agents.filter { $0.span.end >= window.lowerBound && $0.span.start <= window.upperBound }
        let listed = Array(inView.suffix(Self.listedAgents))
        let turns = session.turns.filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }
        let done = session.completions.filter(window.contains).count
        let unit = metric == .all ? "tokens" : "output"

        VStack(alignment: .leading, spacing: 10) {
            header(turns: turns.count)
            stats

            VStack(alignment: .leading, spacing: 5) {
                timelineRow(unit.capitalized, detail: "\(Format.tokens(session.tokens(in: window, metric: metric))) in \(range.rawValue)") {
                    TokenCurve(session: session, color: color, window: window, metric: metric)
                        .frame(height: 38)
                }
                timelineRow("Busy", detail: done > 0 ? "\(counted(done, "task")) done" : "\(counted(turns.count, "turn"))") {
                    BusyStrip(session: session, color: color, window: window)
                        .frame(height: 8)
                }

                if !inView.isEmpty {
                    let running = inView.filter(\.isRunning).count
                    Text("Subagents: \(running) running, \(inView.count) in the \(range.caption)"
                         + (inView.count > listed.count ? ", latest \(listed.count) shown" : ""))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(listed) { agent in
                        timelineRow(agent.label, isRunning: agent.isRunning) {
                            AgentBar(agent: agent, color: color, window: window)
                                .frame(height: 6)
                        }
                    }
                }

                timelineRow("") {
                    TimeLabels(window: window, range: range)
                }
            }

            if let doing = session.doing {
                Text("▸ \(doing.replacingOccurrences(of: "\n", with: " "))")
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .cardSurface()
    }

    private func header(turns: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Capsule().fill(color).frame(width: 12, height: 3)
                Text(session.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: session.isBusy ? "circle.fill" : "circle")
                    .font(.system(size: 6))
                    .foregroundStyle(session.isBusy ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                Text("\(session.isBusy ? "busy" : "idle") \(Format.duration(now.timeIntervalSince(session.statusSince)))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text("\(session.project) · open \(Format.duration(now.timeIntervalSince(session.startedAt))) · \(counted(turns, "turn")) in the \(range.caption)")
                .foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        let tasks = session.tasks
        let agents = session.agents.count
        let workflows = session.workflowsRunning + session.workflowsDone
        let rate = session.tokensPerMinute(now: now, over: RunningNow.rateSpan, metric: metric)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                stat("Tasks", tasks.total > 0 ? "\(tasks.done)/\(tasks.total)" : "–",
                     tasks.total > 0 ? "done, \(tasks.active + tasks.pending) left" : "none listed")
                stat("Subagents", agents > 0 ? "\(session.runningAgents.count)/\(agents)" : "–", agents > 0 ? "running" : "none")
                stat("Workflows", workflows > 0 ? "\(session.workflowsRunning)/\(workflows)" : "–", workflows > 0 ? "running" : "none")
            }
            GridRow {
                stat("Tokens", Format.tokens(session.totalTokens), "\(Format.tokens(session.outputTokens)) out")
                stat("Context", session.context > 0 ? Format.tokens(session.context) : "–", "now")
                stat("Burn", rate > 0 ? "\(Format.tokens(rate))/min" : "–", "last 10 minutes")
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ detail: String) -> some View {
        StatView(label: label, value: value, detail: detail)
    }

    /// A label (and detail) in a fixed column, then a track on the shared time axis.
    private func timelineRow<Track: View>(_ label: String, detail: String? = nil, isRunning: Bool = false,
                                          @ViewBuilder track: () -> Track) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .foregroundStyle(isRunning || detail != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            track()
                .frame(maxWidth: .infinity)
        }
    }
}

/// A number with its name above and what it counts below.
struct StatView: View {
    let label: String
    let value: String
    let detail: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// Where on a track `time` falls, from 0 to `width`.
private func trackX(_ time: Date, in window: ClosedRange<Date>, width: CGFloat) -> CGFloat {
    let length = window.upperBound.timeIntervalSince(window.lowerBound)
    return width * min(1, max(0, time.timeIntervalSince(window.lowerBound) / length))
}

/// The session's tokens added up over the time range, on its own scale: a line with a wash
/// under it, ending in a dot at the total.
private struct TokenCurve: View {
    let session: FleetSession
    let color: Color
    let window: ClosedRange<Date>
    let metric: TokenMetric

    var body: some View {
        Canvas { context, size in
            var total = 0
            var points: [CGPoint] = []
            for request in session.requests where window.contains(request.t) {
                total += metric.count(request)
                points.append(CGPoint(x: trackX(request.t, in: window, width: size.width), y: Double(total)))
            }
            context.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)),
                         with: .color(.primary.opacity(0.15)))
            guard total > 0 else { return }

            let top: CGFloat = 4
            func y(_ value: Double) -> CGFloat { size.height - (size.height - top) * CGFloat(value / Double(total)) }
            // Steps: the count holds until the next request adds to it.
            var line = Path()
            line.move(to: CGPoint(x: points[0].x, y: size.height))
            var previous = size.height
            for point in points {
                line.addLine(to: CGPoint(x: point.x, y: previous))
                previous = y(point.y)
                line.addLine(to: CGPoint(x: point.x, y: previous))
            }
            line.addLine(to: CGPoint(x: size.width, y: previous))

            var wash = line
            wash.addLine(to: CGPoint(x: size.width, y: size.height))
            wash.addLine(to: CGPoint(x: points[0].x, y: size.height))
            wash.closeSubpath()
            context.fill(wash, with: .color(color.opacity(0.12)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: size.width - 4, y: previous - 3, width: 6, height: 6)), with: .color(color))
        }
    }
}

/// When the session was busy (bars) and when it finished tasks (dots).
private struct BusyStrip: View {
    let session: FleetSession
    let color: Color
    let window: ClosedRange<Date>

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2),
                         with: .color(.primary.opacity(0.07)))
            for turn in session.turns where turn.end >= window.lowerBound && turn.start <= window.upperBound {
                let start = trackX(turn.start, in: window, width: size.width)
                let end = trackX(turn.end, in: window, width: size.width)
                context.fill(Path(roundedRect: CGRect(x: start, y: 0, width: max(2, end - start), height: size.height), cornerRadius: 2),
                             with: .color(color))
            }
            for time in session.completions where window.contains(time) {
                let x = trackX(time, in: window, width: size.width)
                context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: size.height / 2 - 3.5, width: 7, height: 7)), with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height / 2 - 2, width: 4, height: 4)), with: .color(.black))
            }
        }
    }
}

/// One subagent's run on the time axis: solid while it runs, faded once done.
private struct AgentBar: View {
    let agent: FleetSession.Agent
    let color: Color
    let window: ClosedRange<Date>

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)),
                         with: .color(.primary.opacity(0.1)))
            let start = trackX(agent.span.start, in: window, width: size.width)
            let end = trackX(agent.span.end, in: window, width: size.width)
            let width = max(3, end - start)
            context.fill(Path(roundedRect: CGRect(x: min(start, size.width - width), y: 0, width: width, height: size.height),
                              cornerRadius: size.height / 2),
                         with: .color(color.opacity(agent.isRunning ? 1 : 0.45)))
        }
    }
}
