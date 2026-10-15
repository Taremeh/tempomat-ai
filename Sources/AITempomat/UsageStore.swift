import Foundation
import CryptoKit
import Observation
import ServiceManagement

/// A problem worth showing in the panel, with an optional command to fix it.
struct UsageProblem: Equatable {
    let title: String
    let detail: String
    var command: String?

    init(_ error: Error) {
        switch error as? UsageError {
        case .cliNotFound:
            title = "Claude Code CLI not found"
            detail = "Install Claude Code, or point the app at your claude binary:"
            command = "defaults write \(Bundle.main.bundleIdentifier ?? "AITempomat") claudePath /path/to/claude"
        case .unsupportedCLI(let version):
            title = "Update Claude Code"
            detail = "Claude Code \(version ?? "(unknown version)") doesn't return a usage report. Update it:"
            command = "claude update"
        case .notSignedIn:
            title = "Sign the CLI in to your plan"
            detail = "The desktop app's login isn't shared with the terminal CLI. Run this once in Terminal:"
            command = "claude auth login"
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
    let savedDataFolder: URL?
    var savedArchiveURL: URL? { archiveURL }
    private let defaults: UserDefaults
    private let storageName: String?
    /// The profile's Claude Code sessions, for the tokens used in past windows; nil leaves them out.
    private let transcripts: SessionScope?
    private let refreshInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var archiveTasks: [UUID: Task<Void, Never>] = [:]
    /// Invalidates results from work started before a profile was stopped or reconfigured.
    private var generation = 0
    private var refreshID: UUID?
    private var estimateID: UUID?
    private var lastEstimate = Date.distantPast
    private let savesGaugeChoice: Bool

    /// A nil storage ID retains the original app's history and settings. Every named profile
    /// gets independent files and calibration. The optional dependencies keep tests isolated.
    init(source: any UsageSource, history: History? = nil, archive: WindowArchive? = nil, persist: Bool,
         transcripts: SessionScope? = nil, storageID: String? = nil,
         dataFolder: URL? = nil, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        storageName = storageID.map(Self.safeStorageName)
        let root = dataFolder ?? Self.dataFolder
        let folder = storageName.map { root.appending(path: "profiles").appending(path: $0) } ?? root
        savedDataFolder = persist ? folder : nil
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = interval >= 30 ? interval : 120
        historyURL = persist ? folder.appending(path: "history.json") : nil
        archiveURL = persist ? folder.appending(path: "windows.json") : nil
        self.transcripts = transcripts
        self.history = history ?? historyURL.flatMap { Self.load(History.self, from: $0) } ?? History()
        self.archive = archive ?? archiveURL.flatMap { Self.load(WindowArchive.self, from: $0) } ?? WindowArchive()
        savesGaugeChoice = persist
        if persist, let saved = defaults.stringArray(forKey: settingsKey(SettingsKey.gaugeChoice)), saved.count == 2 {
            gaugeChoice = (saved[0], saved[1])
        }
        // Windows kept before the app told the desktop app's logins apart hold every login's
        // sessions in ~/.claude. Saved as it is: merging the file back in would undo it.
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
        let stored = tokensPerPercent(for: .all)
        return stored > 0 ? stored : nil
    }

    /// Applies the same profile namespace to all calibration and gauge preferences.
    func settingsKey(_ base: String) -> String {
        storageName.map { "profiles.\($0).\(base)" } ?? base
    }

    func tokensPerPercent(for metric: TokenMetric) -> Double {
        defaults.double(forKey: settingsKey(SettingsKey.tokensPerPercent(metric)))
    }

    func recordTokensPerPercent(_ value: Double, for metric: TokenMetric) {
        guard savesGaugeChoice, value.isFinite, value > 0 else { return }
        defaults.set(value, forKey: settingsKey(SettingsKey.tokensPerPercent(metric)))
    }

    func start() {
        guard pollTask == nil else { return }
        let generation = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.generation == generation else { return }
                await self?.refresh()
                guard !Task.isCancelled, self?.generation == generation,
                      let interval = self?.refreshInterval else { return }
                // Every few hours, catch up on windows the app missed (asleep, or not running).
                self?.scheduleEstimationIfNeeded()
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    /// Stops polling and ignores late fetch/transcript results. Calling start again begins
    /// immediately, even when a source has not yet returned from its cancelled request.
    func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        estimateTask?.cancel()
        estimateTask = nil
        for task in archiveTasks.values { task.cancel() }
        archiveTasks.removeAll()
        refreshID = nil
        estimateID = nil
        isRefreshing = false
        isReadingTranscripts = false
        lastEstimate = .distantPast
    }

    private func scheduleEstimationIfNeeded() {
        guard transcripts != nil, estimateTask == nil,
              Date().timeIntervalSince(lastEstimate) > 3 * 3600 else { return }
        let generation = generation
        estimateTask = Task { [weak self] in
            await self?.estimateMissedWindows()
            if self?.generation == generation { self?.estimateTask = nil }
        }
    }

    func refreshIfStale() {
        guard !isRefreshing, refreshTask == nil,
              Date().timeIntervalSince(lastUpdated ?? .distantPast) > 30 else { return }
        let generation = generation
        refreshTask = Task { [weak self] in
            await self?.refresh()
            if self?.generation == generation { self?.refreshTask = nil }
        }
    }

    func refresh() async {
        guard !isRefreshing, !Task.isCancelled else { return }
        let generation = generation
        let id = UUID()
        refreshID = id
        isRefreshing = true
        defer {
            if refreshID == id {
                refreshID = nil
                isRefreshing = false
            }
        }

        do {
            let rows = try await source.fetch()
            guard !Task.isCancelled, self.generation == generation else { return }
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
            guard !Task.isCancelled, self.generation == generation,
                  !(error is CancellationError) else { return }
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

    func refreshLoginStatus() { opensAtLogin = SMAppService.mainApp.status == .enabled }

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
        let generation = generation
        let id = UUID()
        archiveTasks[id] = Task { [weak self] in
            let sessions = await Task.detached(priority: .utility) {
                FleetScanner.sessionRequests(in: transcripts, since: start)
            }.value
            guard let self else { return }
            defer { self.archiveTasks[id] = nil }
            guard !Task.isCancelled, self.generation == generation else { return }
            self.archive.add(PastWindow(meter: meter.id, start: start, reset: reset, source: .recorded, samples: samples,
                                        sessions: sessions))
            self.saveArchive()
        }
    }

    /// Estimates the 5-hour windows the app didn't record from Claude Code's transcripts: every
    /// one they hold the first time, then those since the last pass. The first pass also fills in
    /// the prompts and subagents of windows kept before the app logged them.
    func estimateMissedWindows() async {
        let now = Date()
        guard let transcripts, !isReadingTranscripts, !Task.isCancelled else { return }
        let generation = generation
        lastEstimate = now
        let length: TimeInterval = 5 * 3600
        let from = archive.estimatedThrough ?? .distantPast
        // A window that opened since then may still be open.
        let cutoff = now.addingTimeInterval(-length)
        let unlogged = archive.loggedBack == true ? nil : archive.windows.filter(\.lacksLog).map(\.start).min()
        guard cutoff > from || unlogged != nil else { return }
        let id = UUID()
        estimateID = id
        isReadingTranscripts = true
        defer {
            if estimateID == id {
                estimateID = nil
                isReadingTranscripts = false
            }
        }

        let readFrom = min(from, unlogged ?? from)
        let sessions = await Task.detached(priority: .utility) {
            FleetScanner.sessionRequests(in: transcripts, since: readFrom)
        }.value
        guard !Task.isCancelled, self.generation == generation else { return }
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

    /// Lowercase IDs remain readable; all others use a stable digest to prevent path
    /// traversal, filename length failures and collisions on case-insensitive volumes.
    private static func safeStorageName(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        if !id.isEmpty, id.utf8.count <= 120, id.unicodeScalars.allSatisfy(allowed.contains) { return id }
        return "profile-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

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
            defaults.set([gaugeChoice.meter, gaugeChoice.over], forKey: settingsKey(SettingsKey.gaugeChoice))
        } else {
            defaults.removeObject(forKey: settingsKey(SettingsKey.gaugeChoice))
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
