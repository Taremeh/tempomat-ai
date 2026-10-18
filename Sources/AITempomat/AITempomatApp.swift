import AppKit
import SwiftUI

@main
struct AITempomatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-preview"), index + 1 < arguments.count {
            PreviewRenderer.render(to: URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        if arguments.contains("--print-usage") {
            Self.printUsage()
        }
        if arguments.contains("--print-fleet") {
            Self.printFleet()
        }
        if arguments.contains("--print-history") {
            Self.printHistory()
        }
        if let index = arguments.firstIndex(of: "--export-history"), index + 1 < arguments.count {
            Self.exportHistory(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--render-expanded"), index + 1 < arguments.count {
            PreviewRenderer.renderLive(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--render-history"), index + 1 < arguments.count {
            PreviewRenderer.renderLive(to: URL(fileURLWithPath: arguments[index + 1]), page: .history)
        }

        let isDemo = arguments.contains("--demo")
        let store = isDemo
            ? UsageStore(source: DemoSource(), history: DemoSource.history(), archive: DemoSource.archive(), persist: false)
            : UsageStore(source: ClaudeCLISource(), persist: true, transcripts: .standard)
        store.start()
        let fleet = isDemo
            ? FleetStore(scanner: nil, sessions: DemoFleet.sessions())
            : FleetStore(scanner: FleetScanner())
        // The first scan reads every transcript in full; do it now so the Agents page opens ready.
        Task { await fleet.refresh() }
        AppDelegate.model = (store, fleet)
    }

    /// Scans the running Claude Code sessions once, prints what the Agents view would show, and exits.
    private static func printFleet() -> Never {
        Task { @MainActor in
            let started = Date()
            let fleet = FleetStore(scanner: FleetScanner())
            await fleet.refresh()
            let now = fleet.lastUpdated ?? Date()
            for session in fleet.sessions {
                let state = session.isBusy ? "busy" : "idle"
                print("\(session.isBusy ? "●" : "○") \(session.name) [\(session.project), \(state) \(Format.duration(now.timeIntervalSince(session.statusSince))),"
                      + " open \(Format.duration(now.timeIntervalSince(session.startedAt)))]")
                print("  tasks \(session.tasks.done)/\(session.tasks.total) · subagents \(session.runningAgents.count)/\(session.agents.count)"
                      + " · workflows \(session.workflowsRunning) running, \(session.workflowsDone) done")
                print("  \(Format.tokens(session.totalTokens)) tokens (\(Format.tokens(session.outputTokens)) out) in \(session.requests.count) requests"
                      + " · context \(Format.tokens(session.context)) · \(session.turns.count) turns · \(session.completions.count) tasks finished")
                if let last = session.turns.last {
                    print("  last turn \(Format.clock(last.start))–\(Format.clock(last.end))")
                }
                for agent in session.runningAgents { print("    ↳ \(agent.label)") }
            }
            print("scanned \(fleet.sessions.count) sessions in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// A store with the saved readings and past windows that saves nothing, and so leaves the
    /// running app's files alone, with the windows missed estimated from the transcripts.
    static func savedStore(estimating: Bool = true) async -> UsageStore {
        let store = UsageStore(source: ClaudeCLISource(),
                               history: UsageStore.load(History.self, from: UsageStore.historyFile, keepUnreadable: false),
                               archive: UsageStore.load(WindowArchive.self, from: UsageStore.archiveFile, keepUnreadable: false),
                               persist: false, transcripts: .standard)
        if estimating { await store.estimateMissedWindows() }
        return store
    }

    /// Prints the past 5-hour windows the History page would show, and exits.
    private static func printHistory() -> Never {
        Task { @MainActor in
            let started = Date()
            let store = await savedStore()
            let typical = store.typicalTokensPerPercent
            for window in store.archive.windows where window.meter == PastWindow.sessionMeter {
                let used = window.percentUsed(typical: typical).map(Format.percent) ?? "–"
                let hit = window.limitHitAt.map { " · limit hit \(Format.clock($0))" } ?? ""
                let prompts = window.sessions.reduce(0) { $0 + ($1.prompts?.count ?? 0) }
                let agents = window.sessions.reduce(0) { $0 + ($1.agents?.count ?? 0) }
                let logged = window.sessions.contains(where: \.isLogged)
                    ? " · \(counted(prompts, "prompt")), \(counted(agents, "subagent"))"
                    : window.slices.isEmpty ? "" : " · not logged"
                print("\(window.start.formatted(.dateTime.weekday().day().month().hour().minute()))–\(Format.clock(window.reset, now: window.start))"
                      + " \(window.source == .recorded ? "recorded " : "estimated") \(used) used\(hit)"
                      + " · \(Format.tokens(window.tokens)) tokens · \(counted(window.sessions.count, "session"))"
                      + (window.sessions.first.map { " · top: \($0.name) (\(Format.tokens($0.tokens)))" } ?? "") + logged)
            }
            print("\(store.archive.windows.count) windows · \(typical.map { Format.tokens($0) } ?? "?") tokens per 1%"
                  + " · read in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Writes the History page's export, JSON and CSV, into `folder`, and exits.
    private static func exportHistory(to folder: URL) -> Never {
        Task { @MainActor in
            let store = await savedStore()
            do {
                for format in [HistoryExport.Format.json, .csv] {
                    print("wrote \(try HistoryExport.write(format, store: store, to: folder).path)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("export failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Fetches once from the CLI, prints what the panel would show, and exits. For diagnostics.
    private static func printUsage() -> Never {
        Task { @MainActor in
            let store = UsageStore(source: ClaudeCLISource(), persist: false)
            await store.refresh()
            if let problem = store.problem {
                print("\(problem.title): \(problem.detail) \(problem.command ?? "")")
            }
            for meter in store.meters {
                let reset = meter.resetsAt.map { Format.clock($0) } ?? "–"
                print("\(meter.title): \(Format.percent(meter.percent)) used [\(meter.severity)\(meter.isActive ? ", headline" : "")]"
                      + " resets \(reset)")
                for method in PaceMethod.allCases {
                    let pace = store.pace(for: meter, method: method)
                    print("  \(method.rawValue): \(pace.rate.map { Format.rate(meter.unit.display($0)) } ?? "–") \(meter.unit.label),"
                          + " relative \(pace.relative.map(Format.percent) ?? "–")")
                }
            }
            exit(store.problem == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// The menu bar item and its panel are the app's own (StatusPanelController), so it can
    /// place the panel before showing it; SwiftUI needs a scene, and this one is never opened.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Puts the menu bar item up once the app has launched.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: (store: UsageStore, fleet: FleetStore)?
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.model else { return }
        statusPanel = StatusPanelController(store: model.store, fleet: model.fleet)
        // For development: open the panel right away.
        if CommandLine.arguments.contains("--open-panel") { statusPanel?.show() }
    }
}

/// Renders the panel with demo data in all four display modes to PNGs, one light and one dark,
/// for checking the layout.
@MainActor
enum PreviewRenderer {
    /// Renders the expanded panel (or another page) from live data, light and dark, and exits:
    /// the plan usage and its recorded history, and the sessions running now. Saves nothing.
    static func renderLive(to url: URL, page: PanelPage = .tempomat) -> Never {
        Task { @MainActor in
            let fleet = FleetStore(scanner: FleetScanner())
            await fleet.refresh()
            let store = await AITempomatApp.savedStore(estimating: page == .history)
            await store.refresh()
            let defaults = UserDefaults(suiteName: "AITempomat.preview.live")!
            defaults.set(PanelLayout.expanded.rawValue, forKey: SettingsKey.panelLayout)
            defaults.set(false, forKey: SettingsKey.historyExpanded)
            for scheme in [ColorScheme.light, .dark] {
                write(PanelView(store: store, fleet: fleet, page: page).defaultAppStorage(defaults), scheme: scheme, to: url,
                      hosted: page == .history)
            }
            if page == .history {
                let window = url.deletingPathExtension().appendingPathExtension("window").appendingPathExtension(url.pathExtension)
                for scheme in [ColorScheme.light, .dark] {
                    write(ExpandedWindowPreview(store: store, fleet: fleet).defaultAppStorage(defaults), scheme: scheme, to: window,
                          hosted: true)
                }
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Writes `content` on the panel's background as a PNG; the dark one beside it as `.dark.png`.
    /// `hosted` draws it with AppKit, for pages with scroll views (see `hostedPNG`).
    private static func write(_ content: some View, scheme: ColorScheme, to url: URL, hosted: Bool = false) {
        let content = content
            .background(scheme == .light ? Color(white: 0.97) : Color(white: 0.15))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let target = scheme == .light ? url
            : url.deletingPathExtension().appendingPathExtension("dark").appendingPathExtension(url.pathExtension)
        let drawn = hosted ? hostedPNG(content, scheme: scheme)
            : renderer.nsImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png = drawn else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return
        }
        try? png.write(to: target)
        print("wrote \(target.path)")
    }

    static func render(to url: URL) {
        let store = UsageStore(source: DemoSource(), history: DemoSource.history(), archive: DemoSource.archive(), persist: false)
        store.load(rows: DemoSource.rows())

        let variants: [(DisplayMode, AmountShown, PaceMethod)] = [
            (.relative, .left, .sensitive), (.relative, .left, .overall), (.total, .left, .sensitive), (.total, .used, .sensitive),
        ]
        let settings = variants.enumerated().map { index, variant in
            let defaults = UserDefaults(suiteName: "AITempomat.preview.\(index)")!
            defaults.set(PanelLayout.reduced.rawValue, forKey: SettingsKey.panelLayout)
            defaults.set(variant.0.rawValue, forKey: SettingsKey.mode)
            defaults.set(variant.1.rawValue, forKey: SettingsKey.amount)
            defaults.set(variant.2.rawValue, forKey: SettingsKey.paceMethod)
            return defaults
        }
        let fleet = FleetStore(scanner: nil, sessions: DemoFleet.sessions())

        for scheme in [ColorScheme.light, .dark] {
            let content = HStack(alignment: .top, spacing: 0) {
                ForEach(settings.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        // Mock of the menu bar item.
                        HStack(spacing: 4) { MenuBarLabel(store: store) }
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .background(.primary.opacity(0.08))
                        PanelView(store: store, fleet: fleet)
                    }
                    .defaultAppStorage(settings[index])
                    .background(scheme == .light ? Color(white: 0.97) : Color(white: 0.15))
                    .environment(\.colorScheme, scheme)
                }
            }
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let target = scheme == .light ? url
                : url.deletingPathExtension().appendingPathExtension("dark").appendingPathExtension(url.pathExtension)
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("render failed\n".utf8))
                return
            }
            try? png.write(to: target)
            print("wrote \(target.path)")
        }

        // The expanded panel, in a file of its own: it is three columns wide.
        let expanded = UserDefaults(suiteName: "AITempomat.preview.expanded")!
        expanded.set(PanelLayout.expanded.rawValue, forKey: SettingsKey.panelLayout)
        expanded.set(DisplayMode.relative.rawValue, forKey: SettingsKey.mode)
        expanded.set(AmountShown.used.rawValue, forKey: SettingsKey.amount)
        expanded.set(PaceMethod.sensitive.rawValue, forKey: SettingsKey.paceMethod)
        expanded.set(HistoryWindow.session.rawValue, forKey: SettingsKey.historyWindow)
        expanded.set(TrajectoryRange.threeHours.rawValue, forKey: SettingsKey.trajectoryRange)
        let base = url.deletingPathExtension().appendingPathExtension("expanded").appendingPathExtension(url.pathExtension)
        for scheme in [ColorScheme.light, .dark] {
            write(PanelView(store: store, fleet: fleet).defaultAppStorage(expanded), scheme: scheme, to: base)
        }

        // The History page, also in a file of its own, and its newest window expanded in another.
        expanded.set(false, forKey: SettingsKey.historyExpanded)
        let history = url.deletingPathExtension().appendingPathExtension("history").appendingPathExtension(url.pathExtension)
        let window = history.deletingPathExtension().appendingPathExtension("window").appendingPathExtension(url.pathExtension)
        for scheme in [ColorScheme.light, .dark] {
            write(PanelView(store: store, fleet: fleet, page: .history).defaultAppStorage(expanded), scheme: scheme, to: history,
                  hosted: true)
            write(ExpandedWindowPreview(store: store, fleet: fleet).defaultAppStorage(expanded), scheme: scheme, to: window,
                  hosted: true)
        }
    }

    /// Draws `content` in an offscreen window: unlike ImageRenderer, AppKit draws scroll views
    /// and menus too, which the History page has.
    private static func hostedPNG(_ content: some View, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI lay out the scroll views' content and draw the charts.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
