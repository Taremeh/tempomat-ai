import AppKit
import Charts
import SwiftUI

/// How far back the History page looks.
enum HistoryRange: String, CaseIterable {
    case week = "7d", month = "30d", all = "All"

    var seconds: TimeInterval? {
        switch self {
        case .week: 7 * 86400
        case .month: 30 * 86400
        case .all: nil
        }
    }

    var caption: String {
        switch self {
        case .week: "last 7 days"
        case .month: "last 30 days"
        case .all: "everything kept"
        }
    }

    func includes(_ window: PastWindow, now: Date) -> Bool {
        seconds.map { window.reset > now.addingTimeInterval(-$0) } ?? true
    }
}

extension SettingsKey {
    static let historyRange = "historyRange"
    /// The picked window across the whole page, in place of the tiles.
    static let historyExpanded = "historyDetailExpanded"
}

// MARK: - A window as the page shows it

/// A 5-hour window as the History page shows it: one that has ended, from the archive, or the
/// current one, from the live readings and this Mac's sessions.
struct WindowSnapshot: Identifiable {
    let window: PastWindow
    /// The window still open.
    let isCurrent: Bool
    /// Its readings as a meter, for the charts the tempomat uses.
    let meter: Meter
    /// The pace now, for the current window; none for those that have ended.
    let pace: Pace
    /// Percent used, by reset or so far; nil with nothing to go on.
    let percentUsed: Double?
    let budget: TokenBudget?

    var id: String { window.id }
    var isEstimated: Bool { window.source == .estimated }
    var hitLimit: Bool { window.limitHitAt != nil || (percentUsed ?? 0) >= 100 }
}

extension WindowSnapshot {
    /// A window that has ended. Estimated windows are read at `typical` tokens per percent.
    init(past window: PastWindow, typical: Double?) {
        let percent = window.percentUsed(typical: typical)
        let hit = window.limitHitAt != nil || (percent ?? 0) >= 100
        self.window = window
        isCurrent = false
        percentUsed = percent
        meter = Meter(id: window.meter, title: "5-hour limit", percent: percent ?? 0, resetsAt: window.reset,
                      window: window.length, unit: .perHour, severity: hit ? "critical" : "normal")
        pace = Pace(rate: nil, basis: .unknown, setpoint: nil, limitAt: nil, projectedAtReset: nil, reached: hit)
        if let perPercent = window.tokensPerPercent ?? typical, perPercent > 0, !window.slices.isEmpty {
            budget = TokenBudget(start: window.start, reset: window.reset, now: window.reset,
                                 percentUsed: percent ?? Double(window.tokens) / perPercent, perPercent: perPercent,
                                 measured: window.tokensPerPercent, sliceTokens: window.slices.map(Double.init))
        } else {
            budget = nil
        }
    }

    /// The window open now: its readings so far, and every session this Mac ran in it, ended
    /// ones included, with your prompts and their subagents.
    @MainActor
    static func current(store: UsageStore, fleet: FleetStore, paceMethod: PaceMethod, now: Date) -> WindowSnapshot? {
        guard let meter = store.meters.first(where: { $0.id == PastWindow.sessionMeter }),
              let resetsAt = meter.resetsAt, let length = meter.window else { return nil }
        // As the archive keeps it, so it starts exactly where the window before it reset.
        let reset = PastWindow.minute(resetsAt)
        let start = reset.addingTimeInterval(-length)
        // Running sessions go by the name they run under now.
        let names = Dictionary(fleet.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let sessions = fleet.recentSessions.map { session in
            var session = session
            if let name = names[session.id] { session.name = name }
            return session
        }
        let window = PastWindow(meter: meter.id, start: start, reset: reset, source: .recorded,
                                samples: store.samples(for: meter), sessions: sessions)
        let budget = TokenBudget.make(meter: meter, requests: fleet.recentRequests, metric: .all,
                                      stored: store.tokensPerPercent(for: .all),
                                      now: fleet.lastUpdated ?? now)
        return WindowSnapshot(window: window, isCurrent: reset > now, meter: meter,
                              pace: store.pace(for: meter, method: paceMethod), percentUsed: meter.percent, budget: budget)
    }

    /// Every 5-hour window, newest first, the current one included.
    @MainActor
    static func all(store: UsageStore, fleet: FleetStore, paceMethod: PaceMethod, now: Date) -> [WindowSnapshot] {
        let current = WindowSnapshot.current(store: store, fleet: fleet, paceMethod: paceMethod, now: now)
        // Before any window has been measured, the current one's measurement will do.
        let typical = store.typicalTokensPerPercent ?? current?.window.tokensPerPercent
        let past = store.archive.windows
            // The current window, kept already (by another copy of the app), shows once.
            .filter { past in past.meter == PastWindow.sessionMeter && !(current?.window.sharesTime(with: past) ?? false) }
            .map { WindowSnapshot(past: $0, typical: typical) }
        return (past + [current].compactMap { $0 }).sorted { $0.window.start > $1.window.start }
    }

    /// "14:30–19:30".
    var hours: String {
        "\(window.start.formatted(date: .omitted, time: .shortened))–\(window.reset.formatted(date: .omitted, time: .shortened))"
    }

    /// The percentage the switches ask for, "≈" for estimates.
    func reading(_ amount: AmountShown) -> String {
        percentUsed.map { (isEstimated ? "≈" : "") + Format.percent(amount.value($0)) } ?? "–"
    }
}

// MARK: - Page

/// Past 5-hour windows and how much of each was used: totals over a time range, then every
/// window as a tile, and the one picked in full.
struct HistoryPage: View {
    let store: UsageStore
    let fleet: FleetStore
    @AppStorage(SettingsKey.historyRange) private var range = HistoryRange.week
    @AppStorage(SettingsKey.amount) private var amount = AmountShown.left
    @AppStorage(SettingsKey.paceMethod) private var paceMethod = PaceMethod.sensitive
    @AppStorage(SettingsKey.historyExpanded) private var isExpanded = false
    @State private var selection: String?

    static let width = PanelLayout.expanded.width
    private static let gridWidth: CGFloat = 520
    private static let detailWidth: CGFloat = 405

    /// The tiles and the breakdown scroll within this height, so the panel fits on the screen.
    private static var scrollHeight: CGFloat {
        min(540, max(280, (NSScreen.main?.visibleFrame.height ?? 900) - 420))
    }

    var body: some View {
        let now = Date()
        let shown = WindowSnapshot.all(store: store, fleet: fleet, paceMethod: paceMethod, now: now)
            .filter { range.includes($0.window, now: now) }
        let selected = shown.first { $0.id == selection } ?? shown.first
        let select = Binding<String?>(get: { selected?.id }, set: { selection = $0 })

        VStack(alignment: .leading, spacing: 14) {
            HistorySummary(snapshots: shown, range: $range, amount: amount, now: now, selection: select)
            Divider()
            if let selected {
                if isExpanded {
                    // Newest first: the next index is the window before.
                    let index = shown.firstIndex { $0.id == selected.id } ?? 0
                    ScrollView {
                        WindowDetail(snapshot: selected, amount: amount, paceMethod: paceMethod, isExpanded: $isExpanded,
                                     earlier: shown.indices.contains(index + 1) ? shown[index + 1].id : nil,
                                     later: index > 0 ? shown[index - 1].id : nil,
                                     select: { selection = $0 })
                            .padding(.trailing, 10)
                    }
                    .frame(height: Self.scrollHeight)
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        WindowGrid(snapshots: shown, amount: amount, selection: select)
                            .frame(width: Self.gridWidth, height: Self.scrollHeight)
                        Divider()
                        ScrollView {
                            WindowDetail(snapshot: selected, amount: amount, paceMethod: paceMethod, isExpanded: $isExpanded)
                                .padding(.trailing, 10)
                        }
                        .frame(width: Self.detailWidth, height: Self.scrollHeight)
                    }
                }
            } else {
                Text(store.isReadingTranscripts
                     ? "Reading Claude Code's transcripts for the windows before the app ran…"
                     : "No windows in the \(range.caption) yet. Each 5-hour window shows up here once it has opened.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
            DataNote(store: store)
        }
        .onAppear { fleet.startPolling() }
        .onDisappear { fleet.stopPolling() }
    }
}

/// The newest window expanded, in full rather than scrolled, for `--render-preview` and
/// `--render-history`.
struct ExpandedWindowPreview: View {
    let store: UsageStore
    let fleet: FleetStore
    @AppStorage(SettingsKey.amount) private var amount = AmountShown.left
    @AppStorage(SettingsKey.paceMethod) private var paceMethod = PaceMethod.sensitive

    var body: some View {
        if let snapshot = WindowSnapshot.all(store: store, fleet: fleet, paceMethod: paceMethod, now: Date()).first {
            WindowDetail(snapshot: snapshot, amount: amount, paceMethod: paceMethod, isExpanded: .constant(true))
                .padding(16)
                .frame(width: HistoryPage.width)
        }
    }
}

/// The panel's header on the History page: back to the tempomat, and the export.
struct HistoryHeader: View {
    let store: UsageStore
    let back: () -> Void
    @State private var exportProblem: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back to the tempomat")
            Text("History")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            if let exportProblem {
                Text(exportProblem)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Menu {
                Button("Everything, as JSON") { export(.json) }
                Button("One row per window, as CSV") { export(.csv) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save the history to your Downloads folder: every window with its readings, tokens and sessions")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func export(_ format: HistoryExport.Format) {
        do {
            let url = try HistoryExport.write(format, store: store)
            exportProblem = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportProblem = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Where the history is kept, and a way to it.
private struct DataNote: View {
    let store: UsageStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isReadingTranscripts {
                ProgressView()
                    .controlSize(.mini)
                Text("Reading Claude Code's transcripts for the windows the app didn't record…")
            } else {
                Image(systemName: "externaldrive")
                Text("Saved in this profile’s windows.json. Windows marked ≈ are estimated from its Claude Code transcripts.")
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                if let file = store.savedArchiveURL, FileManager.default.fileExists(atPath: file.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else if let folder = store.savedDataFolder {
                    NSWorkspace.shared.open(folder)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Summary

/// Totals over the time range, and every window in it as a bar of how much it used.
private struct HistorySummary: View {
    let snapshots: [WindowSnapshot]
    @Binding var range: HistoryRange
    let amount: AmountShown
    let now: Date
    @Binding var selection: String?

    var body: some View {
        let ended = snapshots.filter { !$0.isCurrent }
        let percents = ended.compactMap(\.percentUsed)
        let average = percents.isEmpty ? nil : percents.reduce(0, +) / Double(percents.count)
        let hits = ended.filter(\.hitLimit)
        let lockout = hits.compactMap { snapshot in snapshot.window.limitHitAt.map { snapshot.window.reset.timeIntervalSince($0) } }
            .reduce(0, +)
        let unused = ended.compactMap { snapshot -> Double? in
            guard let percent = snapshot.percentUsed, let budget = snapshot.budget else { return nil }
            return (100 - percent) * budget.perPercent
        }.reduce(0, +)
        let estimated = ended.filter(\.isEstimated).count
        let tokens = snapshots.reduce(0) { $0 + $1.window.tokens }
        let busiest = Dictionary(grouping: snapshots) { Calendar.current.startOfDay(for: $0.window.start) }
            .mapValues { $0.reduce(0) { $0 + $1.window.tokens } }
            .max { $0.value < $1.value }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColumnTitle("Summary · \(range.caption)")
                Spacer()
                Segmented(selection: $range, options: HistoryRange.allCases.map { ($0, $0.rawValue) })
                    .help("How far back to look")
            }

            HStack(alignment: .top, spacing: 12) {
                stat("Windows", "\(ended.count)",
                     estimated > 0 ? "ended, \(estimated) estimated" : "ended",
                     help: "5-hour windows that have ended in the range. Estimated ones are read from Claude Code's transcripts, for times the app wasn't recording.")
                stat(amount == .used ? "Used at reset" : "Left at reset", average.map { Format.percent(amount.value($0)) } ?? "–",
                     "average per window",
                     help: "How much of each window's limit was used by the time it reset, on average.")
                stat("Limit hit", hits.isEmpty ? "never" : "\(hits.count)×",
                     lockout > 0 ? "\(Format.duration(lockout)) locked out" : hits.isEmpty ? "in the range" : "estimated",
                     tint: hits.isEmpty ? nil : .red,
                     help: "Windows that reached 100% before they reset, and how long you then waited for the reset.")
                stat("Left unused", unused > 0 ? "≈ \(Format.tokens(unused))" : "–", "tokens, all windows",
                     help: "What the windows had left when they reset, in tokens.")
                stat("Tokens", Format.tokens(tokens),
                     busiest.map { "most on \($0.key.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" } ?? "on this Mac",
                     help: "Tokens this Mac's Claude Code sessions used in these windows: input, cache and output together.")
            }

            UsageTimeline(snapshots: snapshots, domain: domain, range: range, selection: $selection)
        }
    }

    /// The range, to the current window's reset.
    private var domain: ClosedRange<Date> {
        let start = range.seconds.map { now.addingTimeInterval(-$0) }
            ?? snapshots.map(\.window.start).min().map { min($0, now.addingTimeInterval(-86400)) }
            ?? now.addingTimeInterval(-7 * 86400)
        return start...max(now, snapshots.map(\.window.reset).max() ?? now)
    }

    private func stat(_ label: String, _ value: String, _ detail: String, tint: Color? = nil, help: String) -> some View {
        StatView(label: label, value: value, detail: detail, tint: tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help)
    }
}

/// Each window as a bar across its five hours, as tall as the share of the limit it used.
/// Click one to see it in full.
private struct UsageTimeline: View {
    let snapshots: [WindowSnapshot]
    let domain: ClosedRange<Date>
    let range: HistoryRange
    @Binding var selection: String?
    @State private var hover: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(readout)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Chart {
                if let selected = snapshots.first(where: { $0.id == selection }) {
                    RectangleMark(xStart: .value("Opened", selected.window.start), xEnd: .value("Reset", selected.window.reset),
                                  yStart: .value("Bottom", 0), yEnd: .value("Top", 100))
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                }
                RuleMark(y: .value("Limit", 100))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                ForEach(snapshots) { snapshot in
                    RectangleMark(xStart: .value("Opened", snapshot.window.start), xEnd: .value("Reset", snapshot.window.reset),
                                  yStart: .value("Bottom", 0), yEnd: .value("Used", max(1, snapshot.percentUsed ?? 0)))
                        .foregroundStyle(snapshot.meter.levelTint.opacity(snapshot.isEstimated ? 0.4 : 0.9))
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
                AxisMarks(values: ticks) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: tickFormat)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { if let percent = value.as(Double.self) { Text(Format.percent(percent)) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let frame = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hover = proxy.value(atX: location.x - frame.minX, as: Date.self)
                            case .ended: hover = nil
                            }
                        }
                        .onTapGesture { location in
                            if let time = proxy.value(atX: location.x - frame.minX, as: Date.self), let hit = window(near: time) {
                                selection = hit.id
                            }
                        }
                }
            }
            .frame(height: 74)
            .accessibilityLabel("Percent of the limit each 5-hour window used")
        }
    }

    /// The window under the pointer, or the nearest one within a little of it: thin bars are hard to hit.
    private func window(near time: Date) -> WindowSnapshot? {
        let slack = domain.upperBound.timeIntervalSince(domain.lowerBound) / 80
        func distance(_ snapshot: WindowSnapshot) -> TimeInterval {
            snapshot.window.interval.contains(time) ? 0
                : min(abs(snapshot.window.start.timeIntervalSince(time)), abs(snapshot.window.reset.timeIntervalSince(time)))
        }
        return snapshots.filter { distance($0) <= slack }.min { distance($0) < distance($1) }
    }

    private var readout: String {
        guard let hover else { return "Used by reset, per window · click a bar to see that window" }
        guard let snapshot = window(near: hover) else { return hover.formatted(.dateTime.weekday().day().month().hour().minute()) + " · no window" }
        let day = snapshot.window.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day), \(snapshot.hours) · \(snapshot.reading(.used)) used · \(Format.tokens(snapshot.window.tokens)) tokens"
    }

    private var ticks: AxisMarkValues {
        switch range {
        case .week: .stride(by: .day)
        case .month: .stride(by: .weekOfYear)
        case .all: domain.upperBound.timeIntervalSince(domain.lowerBound) > 60 * 86400 ? .stride(by: .month) : .stride(by: .weekOfYear)
        }
    }

    private var tickFormat: Date.FormatStyle {
        switch range {
        case .week: .dateTime.weekday(.abbreviated).day()
        case .month, .all: .dateTime.day().month(.abbreviated)
        }
    }
}

// MARK: - Tiles

/// The windows as tiles, a row of them per day, newest day first.
private struct WindowGrid: View {
    let snapshots: [WindowSnapshot]
    let amount: AmountShown
    @Binding var selection: String?

    var body: some View {
        let fullScale = sharedScale
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                          alignment: .leading, spacing: 10) {
                    ForEach(days, id: \.day) { day in
                        Section {
                            ForEach(day.windows) { snapshot in
                                Button {
                                    selection = snapshot.id
                                } label: {
                                    WindowTile(snapshot: snapshot, fullScale: fullScale, amount: amount,
                                               isSelected: snapshot.id == selection)
                                }
                                .buttonStyle(.plain)
                                .id(snapshot.id)
                            }
                        } header: {
                            dayHeader(day.day, windows: day.windows)
                        }
                    }
                }
                .padding(.trailing, 10)
            }
            .onChange(of: selection) { _, id in
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id) }
            }
        }
    }

    /// Newest day first; a day's windows in the order they came.
    private var days: [(day: Date, windows: [WindowSnapshot])] {
        Dictionary(grouping: snapshots) { Calendar.current.startOfDay(for: $0.window.start) }
            .map { (day: $0.key, windows: $0.value.sorted { $0.window.start < $1.window.start }) }
            .sorted { $0.day > $1.day }
    }

    private func dayHeader(_ day: Date, windows: [WindowSnapshot]) -> some View {
        let calendar = Calendar.current
        let title = calendar.isDateInToday(day) ? "Today"
            : calendar.isDateInYesterday(day) ? "Yesterday"
            : day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(Format.tokens(windows.reduce(0) { $0 + $1.window.tokens })) tokens")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.top, 6)
    }

    /// One scale for every thumbnail, so their thickness compares: the middle of the windows' own.
    private var sharedScale: Double {
        let scales = snapshots.compactMap(\.budget).map(TokenBudgetView.fullScale).sorted()
        return scales.isEmpty ? 1 : scales[scales.count / 2]
    }
}

/// A window at a glance: its hours, its ribbon, how much it used, and how it ended.
private struct WindowTile: View {
    let snapshot: WindowSnapshot
    let fullScale: Double
    let amount: AmountShown
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snapshot.hours)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 2)
                badge
            }

            Group {
                if let budget = snapshot.budget {
                    BudgetRibbon(budget: budget, fullScale: fullScale, tint: snapshot.meter.levelTint, hoverFraction: .constant(nil))
                } else {
                    Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
                }
            }
            .frame(height: 28)
            .allowsHitTesting(false)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(snapshot.reading(amount))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(amount.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(Format.tokens(snapshot.window.tokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            UsageBar(percentUsed: snapshot.percentUsed ?? 0, projectedUsed: snapshot.isCurrent ? snapshot.pace.projectedAtReset : nil,
                     shown: amount, tint: snapshot.meter.levelTint.opacity(snapshot.isEstimated ? 0.45 : 1),
                     projectionTint: snapshot.pace.status.tint, height: 4)
            Text(outcome)
                .font(.caption2)
                .foregroundStyle(snapshot.hitLimit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(8)
        .background(.primary.opacity(isSelected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.hours): \(snapshot.reading(amount)) \(amount.rawValue). \(outcome)")
    }

    @ViewBuilder
    private var badge: some View {
        if snapshot.isCurrent {
            Text("now")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .background(.green, in: Capsule())
        } else if snapshot.window.limitHitAt != nil {
            Image(systemName: "xmark.octagon.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        } else if snapshot.isEstimated {
            Text("≈")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .help("Estimated from Claude Code's transcripts: the app wasn't recording")
        }
    }

    private var outcome: String {
        let window = snapshot.window
        if snapshot.isCurrent { return "resets \(Format.clock(window.reset))" }
        if let hit = window.limitHitAt {
            return "limit hit \(hit.formatted(date: .omitted, time: .shortened)), \(Format.duration(window.reset.timeIntervalSince(hit))) out"
        }
        if snapshot.isEstimated { return snapshot.hitLimit ? "likely hit the limit" : "estimated from tokens" }
        guard let percent = snapshot.percentUsed else { return "no readings" }
        return "\(Format.percent(100 - percent)) left unused"
    }
}

// MARK: - One window in full

/// How one window was used: the verdict, its numbers, its ribbon against the cruise budget,
/// its readings and pace as the tempomat charts them, and each session's share. Expanded, it
/// takes the whole page: the same, on a timeline wide enough to mark your prompts and explain
/// each peak.
private struct WindowDetail: View {
    let snapshot: WindowSnapshot
    let amount: AmountShown
    let paceMethod: PaceMethod
    @Binding var isExpanded: Bool
    /// The windows before and after, for the arrows of the expanded view.
    var earlier: String?
    var later: String?
    var select: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    private static let listedSessions = 8

    var body: some View {
        if isExpanded { expanded } else { compact }
    }

    private var compact: some View {
        let window = snapshot.window
        return VStack(alignment: .leading, spacing: 14) {
            header
            verdict
            stats

            if let budget = snapshot.budget {
                BudgetRibbonSection(budget: budget, title: "All sessions on this Mac", tint: snapshot.meter.levelTint)
            } else {
                Text("No token data: this Mac's Claude Code sessions weren't read for this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !window.samples.isEmpty {
                let points = History(window.samples, of: snapshot.meter).trajectory(for: snapshot.meter, method: paceMethod)
                let domain = window.start...window.reset
                AmountHistoryChart(meter: snapshot.meter, points: points, pace: snapshot.pace, amount: amount, domain: domain)
                RelativeHistoryChart(points: points, method: paceMethod, domain: domain)
            }

            if !window.sessions.isEmpty { sessions }
        }
    }

    /// The verdict and numbers side by side, then every session on one wide timeline with your
    /// prompts and the peaks explained, then the charts side by side.
    private var expanded: some View {
        let window = snapshot.window
        return VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 28) {
                verdict
                    .frame(width: 380)
                stats
            }
            WindowTimeline(window: window, budget: snapshot.budget, tint: snapshot.meter.levelTint)
                .id(window.id)
            if !window.samples.isEmpty {
                let points = History(window.samples, of: snapshot.meter).trajectory(for: snapshot.meter, method: paceMethod)
                let domain = window.start...window.reset
                HStack(alignment: .top, spacing: 28) {
                    AmountHistoryChart(meter: snapshot.meter, points: points, pace: snapshot.pace, amount: amount, domain: domain)
                    RelativeHistoryChart(points: points, method: paceMethod, domain: domain)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                ColumnTitle(snapshot.window.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Text(snapshot.hours)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            Spacer()
            Text(snapshot.isCurrent ? "Open now" : snapshot.isEstimated ? "Estimated" : "Recorded")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.07), in: Capsule())
                .help(snapshot.isEstimated
                      ? "The app wasn't recording: estimated from the tokens in Claude Code's transcripts."
                      : "Read from /usage every few minutes while the app ran.")
            Group {
                if isExpanded {
                    step("chevron.left", to: earlier, help: "The window before")
                    step("chevron.right", to: later, help: "The window after")
                }
                Button {
                    withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isExpanded ? "Back to the tiles"
                                 : "Expand: this window across the page, with your prompts and what burnt the tokens at each peak")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
        }
    }

    private func step(_ symbol: String, to id: String?, help: String) -> some View {
        Button {
            if let id { select(id) }
        } label: {
            Image(systemName: symbol)
        }
        .disabled(id == nil)
        .help(help)
    }

    @ViewBuilder
    private var verdict: some View {
        let window = snapshot.window
        if snapshot.isCurrent {
            StatusLine(meter: snapshot.meter, pace: snapshot.pace, amount: amount)
        } else if let hit = window.limitHitAt {
            StatusBox(symbol: "xmark.octagon.fill", tint: .red,
                      message: "Hit the limit at \(hit.formatted(date: .omitted, time: .shortened)), \(Format.duration(window.reset.timeIntervalSince(hit))) before reset.",
                      detail: "It ran faster than the cruise budget; nothing was left until it reset.")
        } else if let percent = snapshot.percentUsed {
            if snapshot.isEstimated {
                StatusBox(symbol: "questionmark.circle", tint: .secondary,
                          message: "About \(Format.percent(percent)) used, estimated from this Mac's tokens.",
                          detail: "The app wasn't recording. Read at \(snapshot.budget.map { Format.tokens($0.perPercent) } ?? "?") tokens per 1%; use on claude.ai or other machines isn't counted.")
            } else {
                StatusBox(symbol: percent >= 75 ? "checkmark.circle.fill" : "gauge.with.dots.needle.33percent",
                          tint: percent >= 75 ? .green : .accentColor,
                          message: "Used \(Format.percent(percent)) of the limit by reset.",
                          detail: recordedUntil.map { "\(Format.percent(100 - percent)) left unused. Recorded until \($0)." }
                              ?? "\(Format.percent(100 - percent)) left unused.")
            }
        }
    }

    /// When readings stopped well before the reset (the app quit, or the Mac slept).
    private var recordedUntil: String? {
        guard let last = snapshot.window.samples.last, snapshot.window.reset.timeIntervalSince(last.t) > 15 * 60 else { return nil }
        return last.t.formatted(date: .omitted, time: .shortened)
    }

    private var stats: some View {
        let window = snapshot.window
        let budget = snapshot.budget
        let peak = budget.flatMap { budget in
            (0..<budget.sliceTokens.count).compactMap { index in budget.burn(index).map { (index, $0) } }.max { $0.1 < $1.1 }
        }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                StatView(label: amount == .used ? "Used" : "Left", value: snapshot.reading(amount),
                         detail: snapshot.isCurrent ? "so far" : "at reset")
                StatView(label: "Tokens", value: Format.tokens(window.tokens),
                         detail: budget.map { "of ≈ \(Format.tokens($0.capacity))" } ?? "on this Mac")
                StatView(label: "Sessions", value: "\(window.sessions.count)", detail: "on this Mac")
            }
            GridRow {
                StatView(label: "Busiest 5 min", value: peak.map { "\(Format.tokens($0.1))/min" } ?? "–",
                         detail: peak.flatMap { peak in budget.map { "at \($0.sliceStart(peak.0).formatted(date: .omitted, time: .shortened))" } } ?? "")
                StatView(label: "Over cruise", value: overCruise.map(Format.duration) ?? "–", detail: "faster than budget")
                StatView(label: "Limit", value: window.limitHitAt.map { $0.formatted(date: .omitted, time: .shortened) }
                            ?? (snapshot.hitLimit ? "≈ reached" : "–"),
                         detail: window.limitHitAt.map { "\(Format.duration(window.reset.timeIntervalSince($0))) locked out" }
                            ?? (snapshot.isEstimated ? "no readings" : "not reached"),
                         tint: snapshot.hitLimit ? .red : nil)
            }
        }
    }

    /// How long the burn ran above the cruise budget.
    private var overCruise: TimeInterval? {
        guard let budget = snapshot.budget else { return nil }
        let slices = (0..<budget.sliceTokens.count).filter { index in
            budget.burn(index).map { $0 > budget.budget(index) } ?? false
        }
        return Double(slices.count) * budget.sliceLength
    }

    private var sessions: some View {
        let window = snapshot.window
        let listed = Array(window.sessions.prefix(Self.listedSessions))
        let sliceMinutes = window.length / 60 / Double(max(1, window.slices.count))
        let burns = listed.map { TokenBurn(perMinute: $0.slices.map { Double($0) / sliceMinutes }, total: $0.tokens) }
        let fullScale = TokenBurn.fullScale(burns)
        let others = window.sessions.dropFirst(Self.listedSessions)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ColumnTitle("Sessions")
                Spacer()
                Text("Share of the window's tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(listed.enumerated()), id: \.element.id) { index, session in
                let color = SeriesPalette.color(index, scheme)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Capsule().fill(color).frame(width: 10, height: 3)
                        Text(session.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !session.project.isEmpty, session.project != session.name {
                            Text(session.project)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
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
                    BurnLane(turns: [], burn: burns[index], fullScale: fullScale, color: color,
                             window: window.start...window.reset)
                }
            }
            if !others.isEmpty {
                Text("+ \(counted(others.count, "more session")), \(Format.tokens(others.reduce(0) { $0 + $1.tokens })) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TimeLabels(window: window.start...window.reset, range: .threeHours)
        }
    }
}
