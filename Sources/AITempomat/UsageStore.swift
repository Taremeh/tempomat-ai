import Foundation
import Observation
import ServiceManagement

/// A problem worth showing in the panel, with an optional command to fix it.
struct UsageProblem: Equatable {
    /// What the panel can do about a problem itself, with a button: sign Claude Code in, or install it.
    enum Action: Equatable {
        case signIn, installCLI
    }

    let title: String
    let detail: String
    var command: String?
    /// The button the panel offers; the command stays as the way to do it in Terminal.
    var action: Action?

    init(_ error: Error) {
        switch error as? UsageError {
        case .cliNotFound:
            title = "Claude Code CLI not found"
            detail = "AI Tempomat reads your limits through the Claude Code CLI. Install it with Anthropic's installer, "
                + "which runs in Terminal."
            command = "defaults write \(Bundle.main.bundleIdentifier ?? "AITempomat") claudePath /path/to/claude"
            action = .installCLI
        case .unsupportedCLI(let version):
            title = "Update Claude Code"
            detail = "Claude Code \(version ?? "(unknown version)") doesn't return a usage report. Update it:"
            command = "claude update"
        case .notSignedIn(let claude):
            title = "Sign Claude Code in to your plan"
            detail = "Claude Code on this Mac isn't signed in to your Claude plan; the desktop app's login isn't shared "
                + "with it. Sign in opens claude.com in your browser, and replaces a Console (API) login if Claude Code has one."
            command = Self.command(claude, "auth login")
            action = .signIn
        case .noMeters:
            title = "No plan limits reported"
            detail = "Your account didn't report any usage limits. API-key and gateway logins have none."
        case .timedOut:
            title = "Claude Code didn't answer"
            detail = "The /usage check timed out. It will retry automatically."
        case .cliFailed(let message):
            title = "Couldn't read usage"
            detail = message
        case nil:
            title = "Couldn't read usage"
            detail = error.localizedDescription
        }
    }

    /// `arguments` for the claude binary at `url`, as you'd type it in Terminal: `claude` where
    /// Terminal finds it by name, else its full path, quoted (the desktop app's own copy, or one
    /// just installed into ~/.local/bin before that's on your PATH).
    static func command(_ url: URL?, _ arguments: String) -> String {
        guard let path = url?.path, !["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].contains(path) else {
            return "claude \(arguments)"
        }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' \(arguments)"
    }
}

@MainActor @Observable
final class UsageStore {
    private(set) var meters: [Meter] = []
    private(set) var problem: UsageProblem?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private var history: History
    /// Windows that have ended, for the History page.
    private(set) var archive: WindowArchive
    /// Reading Claude Code's transcripts for the tokens of past windows.
    private(set) var isReadingTranscripts = false

    private let source: any UsageSource
    private let historyURL: URL?
    private let archiveURL: URL?
    /// The Claude Code sessions that count, for the tokens used in past windows; nil leaves them out.
    private let transcripts: SessionScope?
    private let refreshInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var lastEstimate = Date.distantPast
    private let savesGaugeChoice: Bool

    /// `persist` reads and saves the files in `dataFolder`; `transcripts` are the sessions to
    /// read the tokens from.
    init(source: any UsageSource, history: History? = nil, archive: WindowArchive? = nil, persist: Bool,
         transcripts: SessionScope? = nil, dataFolder: URL = UsageStore.dataFolder) {
        self.source = source
        let interval = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = interval >= 30 ? interval : 120
        historyURL = persist ? dataFolder.appending(path: "history.json") : nil
        archiveURL = persist ? dataFolder.appending(path: "windows.json") : nil
        self.transcripts = transcripts
        self.history = history ?? historyURL.flatMap { Self.load(History.self, from: $0) } ?? History()
        self.archive = archive ?? archiveURL.flatMap { Self.load(WindowArchive.self, from: $0) } ?? WindowArchive()
        savesGaugeChoice = persist
        if persist, let saved = UserDefaults.standard.stringArray(forKey: SettingsKey.gaugeChoice), saved.count == 2 {
            gaugeChoice = (saved[0], saved[1])
        }
        // Windows kept before the app told the desktop app's logins apart hold the sessions every
        // login ran in ~/.claude. Saved as it is: merging the file back in would undo it.
        if let transcripts, self.archive.removeSessions(where: transcripts.filter().isForeign), let archiveURL {
            Self.save(self.archive, to: archiveURL)
        }
    }

    /// The meter the big gauge shows: the one the user swapped in, else the server's pick.
    var headline: Meter? {
        if let gaugeChoice, gaugeChoice.over == serverPick?.id,
           let chosen = meters.first(where: { $0.id == gaugeChoice.meter }) { return chosen }
        return serverPick
    }

    /// The server's pick for the big gauge (it moves to a limit that turns critical), else the first.
    private var serverPick: Meter? { meters.first(where: \.isActive) ?? meters.first }

    /// The meter the user swapped onto the gauge and the server's pick it replaced. It holds until
    /// the server picks another meter, so a limit turning critical still takes the gauge.
    private var gaugeChoice: (meter: String, over: String)?

    /// Puts `meter` on the big gauge. Swapping the server's pick back in follows the server again.
    func showOnGauge(_ meter: Meter) {
        guard let pick = serverPick else { return }
        gaugeChoice = meter.id == pick.id ? nil : (meter.id, pick.id)
        saveGaugeChoice()
    }

    func pace(for meter: Meter, method: PaceMethod) -> Pace { history.pace(for: meter, at: Date(), method: method) }

    /// The meter's recorded readings and the pace each had, for the history charts.
    func trajectory(for meter: Meter, method: PaceMethod) -> [History.PacePoint] {
        history.trajectory(for: meter, method: method)
    }

    /// The readings of a meter's current window.
    func samples(for meter: Meter) -> [History.Sample] { history.tracks[meter.id]?.samples ?? [] }

    /// Every meter's current window, as recorded so far.
    var currentTracks: [String: History.Track] { history.tracks }

    /// Tokens per 1% of the 5-hour limit: the middle of what the latest recorded windows
    /// measured, else what the tempomat measured last. Estimated windows are read with it.
    var typicalTokensPerPercent: Double? {
        let measured = archive.windows.filter { $0.meter == PastWindow.sessionMeter }.suffix(20).compactMap(\.tokensPerPercent).sorted()
        if !measured.isEmpty { return measured[measured.count / 2] }
        let stored = UserDefaults.standard.double(forKey: SettingsKey.tokensPerPercent(.all))
        return stored > 0 ? stored : nil
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Every few hours, catch up on windows the app missed (asleep, or not running).
                if let self, Date().timeIntervalSince(self.lastEstimate) > 3 * 3600 {
                    Task { await self.estimateMissedWindows() }
                }
                try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 120))
            }
        }
    }

    func refreshIfStale() {
        guard !isRefreshing, Date().timeIntervalSince(lastUpdated ?? .distantPast) > 30 else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let rows = try await source.fetch()
            let now = Date()
            meters = rows.map(Meter.init)
            if let gaugeChoice, gaugeChoice.over != serverPick?.id {
                self.gaugeChoice = nil
                saveGaugeChoice()
            }
            for meter in meters {
                if let ended = history.record(meter, at: now) { keep(ended, of: meter) }
            }
            lastUpdated = now
            problem = nil
            saveHistory()
        } catch {
            problem = UsageProblem(error)
        }
    }

    /// Seeds the store without fetching, for rendering previews.
    func load(rows: [LimitRow]) {
        meters = rows.map(Meter.init)
        lastUpdated = Date()
    }

    // MARK: Launch at login

    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = UsageProblem(UsageError.cliFailed("Couldn't change the login item: \(error.localizedDescription)"))
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Past windows

    /// Keeps a window that just ended: its readings now, the tokens used in it once the
    /// transcripts are read.
    private func keep(_ track: History.Track, of meter: Meter) {
        guard let resetsAt = track.resetsAt, let length = meter.window,
              track.samples.contains(where: { $0.p >= 0.5 }) else { return }
        let reset = PastWindow.minute(resetsAt)
        let start = reset.addingTimeInterval(-length)
        let samples = PastWindow.thin(track.samples, over: length)
        archive.add(PastWindow(meter: meter.id, start: start, reset: reset, source: .recorded, samples: samples, sessions: nil))
        saveArchive()

        guard meter.id == PastWindow.sessionMeter, let transcripts else { return }
        Task {
            let sessions = await Task.detached(priority: .utility) {
                FleetScanner.sessionRequests(in: transcripts, since: start)
            }.value
            archive.add(PastWindow(meter: meter.id, start: start, reset: reset, source: .recorded, samples: samples,
                                   sessions: sessions))
            saveArchive()
        }
    }

    /// Estimates the 5-hour windows the app didn't record from Claude Code's transcripts: every
    /// one they hold the first time, then those since the last pass. The first pass also fills in
    /// the prompts and subagents of windows kept before the app logged them.
    func estimateMissedWindows() async {
        let now = Date()
        lastEstimate = now
        guard let transcripts, !isReadingTranscripts else { return }
        let length: TimeInterval = 5 * 3600
        let from = archive.estimatedThrough ?? .distantPast
        // A window that opened since then may still be open.
        let cutoff = now.addingTimeInterval(-length)
        let unlogged = archive.loggedBack == true ? nil : archive.windows.filter(\.lacksLog).map(\.start).min()
        guard cutoff > from || unlogged != nil else { return }
        isReadingTranscripts = true
        defer { isReadingTranscripts = false }

        let readFrom = min(from, unlogged ?? from)
        let sessions = await Task.detached(priority: .utility) {
            FleetScanner.sessionRequests(in: transcripts, since: readFrom)
        }.value
        if unlogged != nil {
            archive.logBack(from: sessions)
            archive.loggedBack = true
        }
        if cutoff > from {
            // Known now, after the read: the archive may have grown meanwhile.
            var known = archive.windows.filter { $0.meter == PastWindow.sessionMeter }.map(\.interval)
            if let track = history.tracks[PastWindow.sessionMeter], let resetsAt = track.resetsAt, !track.samples.isEmpty {
                let reset = PastWindow.minute(resetsAt)
                known.append(reset.addingTimeInterval(-length)..<reset)
            }
            for window in WindowArchive.estimate(sessions, known: known, from: from, until: cutoff, length: length) {
                archive.add(window)
            }
            archive.estimatedThrough = cutoff
        }
        saveArchive()
    }

    // MARK: Persistence

    /// Where the app keeps its data: `history.json` for the windows still open, `windows.json`
    /// for those that have ended.
    static var dataFolder: URL { URL.applicationSupportDirectory.appending(path: "AI Tempomat") }
    static var historyFile: URL { dataFolder.appending(path: "history.json") }
    static var archiveFile: URL { dataFolder.appending(path: "windows.json") }

    /// Reads a saved file. One that can't be read is moved aside, so it isn't overwritten.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, keepUnreadable: Bool = true) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            guard keepUnreadable else { return nil }
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    private func saveHistory() {
        guard let historyURL else { return }
        Self.save(history, to: historyURL)
    }

    private func saveGaugeChoice() {
        guard savesGaugeChoice else { return }
        if let gaugeChoice {
            UserDefaults.standard.set([gaugeChoice.meter, gaugeChoice.over], forKey: SettingsKey.gaugeChoice)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.gaugeChoice)
        }
    }

    private func saveArchive() {
        guard let archiveURL else { return }
        // Another instance of the app may have saved windows this one hasn't seen.
        if let saved = Self.load(WindowArchive.self, from: archiveURL) { archive.merge(saved) }
        Self.save(archive, to: archiveURL)
    }

    private static func save(_ value: some Encodable, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
