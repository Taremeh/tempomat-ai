import AppKit
import SwiftUI

/// The panel's pages: the tempomat (reduced or expanded), or the history of past windows.
enum PanelPage {
    case tempomat, history
}

struct PanelView: View {
    let store: UsageStore
    let fleet: FleetStore
    @State private var page: PanelPage
    @AppStorage(SettingsKey.panelLayout) private var layout = PanelLayout.reduced
    @AppStorage(SettingsKey.mode) private var mode = DisplayMode.relative
    @AppStorage(SettingsKey.amount) private var amount = AmountShown.left
    @AppStorage(SettingsKey.paceMethod) private var paceMethod = PaceMethod.sensitive
    private var updates: UpdateChecker { .shared }

    init(store: UsageStore, fleet: FleetStore, page: PanelPage = .tempomat) {
        self.store = store
        self.fleet = fleet
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch page {
            case .tempomat:
                header
                switch layout {
                case .reduced: tempomat
                case .expanded: expanded
                }
            case .history:
                HistoryHeader(store: store) { show(.tempomat) }
                HistoryPage(store: store, fleet: fleet)
            }

            if updates.checksForUpdates, let release = updates.available {
                UpdateBanner(release: release, state: updates.installState, folder: updates.installFolder,
                             install: { updates.install() }, showLog: { updates.showLog() })
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: page == .history ? HistoryPage.width : layout.width)
        // Hover cards draw here, above every column.
        .hoverCardLayer()
        .onAppear { store.refreshIfStale() }
        // The panel opens on the tempomat.
        .onDisappear { page = .tempomat }
    }

    private func show(_ page: PanelPage) {
        withAnimation(.snappy(duration: 0.25)) { self.page = page }
    }

    /// The past on the left (what each session burnt), the tempomat in the middle, and what lies
    /// ahead on the right (what runs now, what's left, where the limit is heading).
    private var expanded: some View {
        HStack(alignment: .top, spacing: 18) {
            AgentHistory(fleet: fleet)
                .frame(width: 290)
            Divider()
            VStack(alignment: .leading, spacing: 14) { tempomat }
                .frame(width: 308)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                RunningNow(fleet: fleet)
                Divider()
                UsageOutlook(store: store, amount: amount, paceMethod: paceMethod)
            }
            .frame(width: 290)
        }
    }

    @ViewBuilder
    private var tempomat: some View {
        controls

        if let problem = store.problem {
            ProblemBanner(problem: problem)
        }

        if let headline = store.headline {
            HeadlineSection(meter: headline, pace: store.pace(for: headline, method: paceMethod),
                            mode: mode, amount: amount)
        } else if store.problem == nil {
            Text("Reading usage…")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }

        TokenBudgetView(store: store, fleet: fleet)

        let others = store.meters.filter { $0.id != store.headline?.id }
        if !others.isEmpty {
            Divider()
            VStack(spacing: 12) {
                ForEach(others) { meter in
                    MeterRow(meter: meter, pace: store.pace(for: meter, method: paceMethod), mode: mode, amount: amount) {
                        withAnimation(.snappy(duration: 0.25)) { store.showOnGauge(meter) }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tempomat")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            if store.isRefreshing, store.lastUpdated == nil {
                Text("Updating…")
            } else if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
            }
            Button {
                Task {
                    async let usage: Void = store.refresh()
                    async let sessions: Void = fleet.refresh()
                    _ = await (usage, sessions)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh now")
            Button {
                show(.history)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("History: past 5-hour windows and how much of each you used")
            Button {
                withAnimation(.snappy(duration: 0.25)) { layout = layout == .reduced ? .expanded : .reduced }
            } label: {
                Image(systemName: layout == .reduced ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help(layout == .reduced ? "Expand: history, running sessions and the outlook beside the tempomat"
                                     : "Reduce to the tempomat")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack {
            Segmented(selection: $mode, options: [(.total, "Total"), (.relative, "Relative")])
                .help("Total: how much of the limit is left, like a fuel gauge. Relative: your pace, where 100% runs out exactly at reset.")
            Spacer()
            switch mode {
            case .total:
                Segmented(selection: $amount, options: [(.left, "Left"), (.used, "Used")])
                    .help("Show what's left in the tank, or what you've burned")
            case .relative:
                Segmented(selection: $paceMethod, options: [(.overall, "Overall"), (.sensitive, "Sensitive")])
                    .help("Overall: average since the last reset. Sensitive: the last 30 minutes (12 hours for weekly limits).")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                store.setOpensAtLogin(!store.opensAtLogin)
            } label: {
                Label("Open at login", systemImage: store.opensAtLogin ? "checkmark.square.fill" : "square")
            }
            // A build without a check URL never checks, so there's nothing to turn off.
            if updates.canCheck {
                Button {
                    updates.setChecksForUpdates(!updates.checksForUpdates)
                } label: {
                    Label("Check for updates", systemImage: updates.checksForUpdates ? "checkmark.square.fill" : "square")
                }
                .padding(.leading, 6)
                .help("At launch and once a day, asks whether a newer version is out. It sends the app's version and build, the "
                      + "macOS version, the branch if it's main or multi-profile, and whether it's the first check today, this "
                      + "week, this month or ever, which is how active users are counted. No ID, nothing about your usage.")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A compact capsule switch, drawn in SwiftUI so it matches the panel.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let selected = option.0 == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.08), in: Capsule())
    }
}

private struct HeadlineSection: View {
    let meter: Meter
    let pace: Pace
    let mode: DisplayMode
    let amount: AmountShown

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Dial(reading: mode == .total
                 ? .total(meter: meter, pace: pace, shown: amount)
                 : .relative(meter: meter, pace: pace))
                .frame(maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(meter.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(amount.value(meter.percent)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(amount.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let projected = pace.projectedAtReset, projected > meter.percent + 0.5 {
                    Text("→ \(Format.percent(amount.value(projected)))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }

            UsageBar(percentUsed: meter.percent, projectedUsed: pace.projectedAtReset, shown: amount,
                     tint: meter.severityTint, projectionTint: pace.status.tint)

            if let resetsAt = meter.resetsAt {
                Text("Resets \(Format.clock(resetsAt)) · in \(Format.duration(resetsAt.timeIntervalSinceNow))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            StatusLine(meter: meter, pace: pace, amount: amount)
        }
    }
}

struct StatusLine: View {
    let meter: Meter
    let pace: Pace
    let amount: AmountShown

    var body: some View {
        StatusBox(symbol: symbol, tint: pace.status.tint, message: message, detail: basis)
    }

    private var symbol: String {
        switch pace.status {
        case .cruising: "gauge.with.dots.needle.33percent"
        case .overPace: "exclamationmark.triangle.fill"
        case .limitReached: "xmark.octagon.fill"
        case .unknown: "hourglass"
        }
    }

    private var message: String {
        let reset = meter.resetsAt.map { Format.clock($0) }
        switch pace.status {
        case .limitReached:
            return "Limit reached." + (reset.map { " Resets at \($0)." } ?? "")
        case .overPace:
            guard let limitAt = pace.limitAt else { return "Over cruise speed." }
            let early = meter.resetsAt.map { " \(Format.duration($0.timeIntervalSince(limitAt))) before reset" } ?? ""
            return "At this pace you run out at \(Format.clock(limitAt)),\(early)."
        case .cruising:
            if (pace.rate ?? 0) < 0.05 {
                return "Idle. Holding at \(Format.percent(amount.value(meter.percent))) \(amount.rawValue) until reset."
            }
            let projected = amount.value(pace.projectedAtReset ?? meter.percent)
            return "Cruising. About \(Format.percent(projected)) \(amount.rawValue) at reset."
        case .unknown:
            return "Measuring pace…"
        }
    }

    private var basis: String? {
        switch pace.basis {
        case .recent(let span): "Sensitive: pace over the last \(Format.duration(span))"
        case .windowAverage: "Overall: pace averaged since the last reset"
        case .unknown: nil
        }
    }
}

private struct MeterRow: View {
    let meter: Meter
    let pace: Pace
    let mode: DisplayMode
    let amount: AmountShown
    /// Swaps this meter with the one on the gauge.
    let swap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(meter.title)
                    .font(.callout)
                Spacer()
                Text(Format.percent(amount.value(meter.percent)))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(amount.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: swap) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .help("Show on the gauge")
            }
            UsageBar(percentUsed: meter.percent, projectedUsed: pace.projectedAtReset, shown: amount,
                     tint: meter.severityTint, projectionTint: pace.status.tint, height: 5)
            Text(subline)
                .font(.caption)
                .foregroundStyle(pace.status == .overPace ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private var subline: String {
        var parts: [String] = []
        if pace.status == .limitReached {
            parts.append("Limit reached")
        } else if let limitAt = pace.limitAt {
            parts.append("Runs out \(Format.clock(limitAt))")
        } else if let projected = pace.projectedAtReset, projected > meter.percent + 0.5 {
            parts.append("→ \(Format.percent(amount.value(projected))) \(amount.rawValue) at reset")
        }
        switch mode {
        case .relative:
            if let relative = pace.relative { parts.append("\(Format.percent(relative)) pace") }
        case .total:
            if let rate = pace.rate, rate > 0.05 { parts.append("\(Format.rate(meter.unit.display(rate))) \(meter.unit.label)") }
        }
        if let resetsAt = meter.resetsAt { parts.append("resets \(Format.clock(resetsAt))") }
        return parts.joined(separator: " · ")
    }
}

/// A verdict in a tinted box: an icon, a sentence and a smaller line under it.
struct StatusBox: View {
    let symbol: String
    let tint: Color
    let message: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(message)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A bar that drains (left) or fills (used). The faded part is what the current pace burns before reset.
struct UsageBar: View {
    let percentUsed: Double
    let projectedUsed: Double?
    let shown: AmountShown
    let tint: Color
    let projectionTint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let used = min(percentUsed, 100) / 100
            let projected = min(max(projectedUsed ?? percentUsed, percentUsed), 100) / 100
            // Solid part and faded part, as fractions of the bar.
            let (solid, faded) = shown == .used ? (used, projected) : (1 - projected, 1 - used)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09))
                Capsule()
                    .fill(projectionTint.opacity(0.3))
                    .frame(width: width * faded)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: solid > 0 ? max(height, width * solid) : 0)
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.6), value: percentUsed)
        .animation(.easeInOut(duration: 0.6), value: projectedUsed)
        .animation(.easeInOut(duration: 0.6), value: shown)
    }
}

private struct ProblemBanner: View {
    let problem: UsageProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(problem.title, systemImage: "exclamationmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(problem.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command = problem.command {
                HStack {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
                .padding(8)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
