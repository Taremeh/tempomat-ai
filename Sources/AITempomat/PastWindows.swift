import Foundation

/// A limit window that has ended, kept for the History page: the `/usage` readings the app
/// took during it, and the tokens this Mac's Claude Code sessions used in it.
struct PastWindow: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        /// The app read `/usage` during the window.
        case recorded
        /// The app wasn't recording: inferred from Claude Code's transcripts.
        case estimated
    }

    /// One session's share of the window, and what it did in it. `prompts`, `tasks` and `agents`
    /// are nil in windows kept before the app logged them.
    struct Session: Codable, Sendable {
        let id: String
        let name: String
        let project: String
        let tokens: Int
        let output: Int
        /// Tokens in each slice of the window, its subagents' included.
        let slices: [Int]
        /// When you prompted it.
        var prompts: [FleetSession.Prompt]?
        /// Your last prompt before the window opened: what it may still have been working on.
        var promptBefore: FleetSession.Prompt?
        /// When its tasks were in progress, within the window.
        var tasks: [FleetSession.TaskSpan]?
        /// Its subagents that made requests in the window.
        var agents: [Agent]?

        var isLogged: Bool { prompts != nil }
    }

    /// A subagent's share of the window.
    struct Agent: Codable, Sendable {
        /// What it was asked to do: "Explore: Find route guards", "Review: review:planner".
        let label: String
        /// The workflow it ran in: its name, or its run id when the run hadn't finished yet.
        let workflow: String?
        /// Its first and last request in the window.
        let start: Date
        let end: Date
        let tokens: Int
        /// The slice of its first request, and its tokens in each slice from there on.
        let firstSlice: Int
        let slices: [Int]

        /// Its tokens in some slices of the window.
        func tokens(in range: Range<Int>) -> Int {
            let lower = max(range.lowerBound - firstSlice, 0)
            let upper = min(range.upperBound - firstSlice, slices.count)
            return lower < upper ? slices[lower..<upper].reduce(0, +) : 0
        }
    }

    /// The meter's id: "session" for the 5-hour limit, "weekly_all", …
    let meter: String
    let start: Date
    let reset: Date
    let source: Source
    /// `/usage` readings, percent used; none for estimated windows.
    var samples: [History.Sample]
    /// Tokens per 1% of the limit, when the window measured it: recorded, and 5% or more used.
    var tokensPerPercent: Double?
    /// Tokens this Mac's sessions used in each 5-minute slice; empty for weekly windows.
    var slices: [Int]
    /// Most tokens first.
    var sessions: [Session]

    static let sessionMeter = "session"

    var id: String { "\(meter)@\(Int(start.timeIntervalSince1970))" }
    var length: TimeInterval { reset.timeIntervalSince(start) }
    var interval: Range<Date> { start..<reset }
    var tokens: Int { slices.reduce(0, +) }
    var outputTokens: Int { sessions.reduce(0) { $0 + $1.output } }

    /// The plan's reset time to the whole minute: it jitters by a second or so between readings,
    /// and rounded, each window gets one id and ends where the next one starts.
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// Whether two windows cover the same stretch of time. Reset times jitter and estimates are
    /// off by minutes, so windows that only touch at an edge don't count.
    func sharesTime(with other: PastWindow) -> Bool {
        meter == other.meter && interval.overlap(with: other.interval) > 10 * 60
    }

    /// Percent used by reset as last read. Usage only grows within a window.
    var recordedPercent: Double? { samples.map(\.p).max() }
    /// When it first read 100%.
    var limitHitAt: Date? { samples.first { $0.p >= 100 }?.t }

    /// Percent used by reset: as read, or estimated from the tokens at `typical` tokens per percent.
    func percentUsed(typical: Double?) -> Double? {
        if let recordedPercent { return min(100, recordedPercent) }
        guard let perPercent = tokensPerPercent ?? typical, perPercent > 0, !slices.isEmpty else { return nil }
        return min(100, Double(tokens) / perPercent)
    }

    /// Slices the sessions' requests over the window, adds up each session's share, and logs
    /// what each did in it. Without sessions, the window has no token data.
    init(meter: String, start: Date, reset: Date, source: Source, samples: [History.Sample],
         sessions: [SessionRequests]?) {
        self.meter = meter
        self.start = start
        self.reset = reset
        self.source = source
        self.samples = samples.filter { $0.t >= start && $0.t <= reset }

        let count = TokenBudget.slices
        var totals = [Int](repeating: 0, count: count)
        var shares: [Session] = []
        for session in sessions ?? [] {
            var slices = [Int](repeating: 0, count: count)
            var output = 0
            for request in session.requests {
                guard let index = Self.slice(of: request.t, start: start, reset: reset) else { continue }
                slices[index] += request.total
                output += request.output
            }
            let tokens = slices.reduce(0, +)
            guard tokens > 0 else { continue }
            for index in 0..<count { totals[index] += slices[index] }
            var share = Session(id: session.id, name: session.name, project: session.project,
                                tokens: tokens, output: output, slices: slices)
            share.log(session, start: start, reset: reset)
            shares.append(share)
        }
        slices = sessions == nil ? [] : totals
        self.sessions = shares.sorted { $0.tokens > $1.tokens }
        tokensPerPercent = Self.tokensPerPercent(tokens: totals.reduce(0, +), samples: self.samples)
    }

    /// Tokens per 1% of the limit, when the window can tell: 5% or more read as used.
    private static func tokensPerPercent(tokens: Int, samples: [History.Sample]) -> Double? {
        let percent = samples.map(\.p).max() ?? 0
        return percent >= TokenBudget.minimumPercent && tokens > 0 ? Double(tokens) / percent : nil
    }

    /// Takes sessions out of the window, with their tokens.
    mutating func removeSessions(where remove: (Session) -> Bool) {
        for session in sessions where remove(session) && session.slices.count == slices.count {
            for index in slices.indices { slices[index] = max(0, slices[index] - session.slices[index]) }
        }
        sessions.removeAll(where: remove)
        tokensPerPercent = Self.tokensPerPercent(tokens: tokens, samples: samples)
    }

    /// The 5-minute slice a time falls in, if it's inside the window.
    static func slice(of t: Date, start: Date, reset: Date, count: Int = TokenBudget.slices) -> Int? {
        let length = reset.timeIntervalSince(start)
        guard t >= start, t < reset, length > 0 else { return nil }
        return min(count - 1, Int(t.timeIntervalSince(start) / length * Double(count)))
    }

    /// When a slice of the window begins; the window's reset for the slice after the last.
    func sliceStart(_ index: Int) -> Date {
        start.addingTimeInterval(length * Double(index) / Double(max(1, slices.count)))
    }

    /// Whether some session's prompts and subagents weren't logged.
    var lacksLog: Bool { !slices.isEmpty && sessions.contains { !$0.isLogged } }

    /// Readings thinned for keeping: where the percentage changed, and otherwise one per
    /// 1/150 of the window (two minutes of a 5-hour window), so replayed paces stay right.
    static func thin(_ samples: [History.Sample], over length: TimeInterval) -> [History.Sample] {
        var kept: [History.Sample] = []
        for sample in samples {
            if let last = kept.last, sample.p == last.p, sample.t.timeIntervalSince(last.t) < length / 150 { continue }
            kept.append(sample)
        }
        if let last = samples.last, kept.last?.t != last.t { kept.append(last) }
        return kept
    }
}

extension PastWindow.Session {
    /// Logs what the session did in the window: your prompts, its tasks, and each subagent's tokens.
    mutating func log(_ session: SessionRequests, start: Date, reset: Date) {
        let window = start..<reset
        prompts = session.prompts.filter { window.contains($0.t) }
        promptBefore = session.prompts.last { $0.t < start } ?? session.promptBefore.flatMap { $0.t < start ? $0 : nil }
        // A task still in progress ends, as far as the window goes, at the session's last request in it.
        let last = session.requests.last { window.contains($0.t) }?.t ?? reset
        tasks = session.tasks.compactMap { task in
            let end = min(task.end ?? max(last, task.start), reset)
            guard task.start < reset, end >= start else { return nil }
            return .init(subject: task.subject, start: max(task.start, start), end: end)
        }
        agents = session.agents.compactMap { PastWindow.Agent($0, start: start, reset: reset) }
    }
}

extension PastWindow.Agent {
    /// A subagent's requests in the window, sliced; nil when it made none there.
    init?(_ agent: AgentRequests, start: Date, reset: Date) {
        let inside = agent.requests.compactMap { request in
            PastWindow.slice(of: request.t, start: start, reset: reset).map { (slice: $0, request: request) }
        }
        guard let first = inside.map(\.slice).min(), let last = inside.map(\.slice).max() else { return nil }
        var slices = [Int](repeating: 0, count: last - first + 1)
        for (slice, request) in inside { slices[slice - first] += request.total }
        let tokens = slices.reduce(0, +)
        guard tokens > 0 else { return nil }
        self.init(label: agent.label, workflow: agent.workflow, start: inside.map(\.request.t).min() ?? start,
                  end: inside.map(\.request.t).max() ?? start, tokens: tokens, firstSlice: first, slices: slices)
    }
}

/// One Claude Code session on this Mac, with the name and folder it ran under: its requests,
/// your prompts, its tasks and its subagents.
struct SessionRequests: Sendable {
    let id: String
    var name = ""
    var project = ""
    /// Every request, its subagents' included.
    var requests: [FleetSession.Request] = []
    var prompts: [FleetSession.Prompt] = []
    /// The last prompt before the requests start, which they may still be answering.
    var promptBefore: FleetSession.Prompt?
    var tasks: [FleetSession.TaskSpan] = []
    var agents: [AgentRequests] = []
    /// The names of the workflows it launched, by run id: they name its agents' workflows
    /// while those still run.
    var workflowNames: [String: String] = [:]
}

/// A subagent's own requests, with what it was asked to do and the workflow it ran in.
struct AgentRequests: Sendable {
    let label: String
    let workflow: String?
    let requests: [FleetSession.Request]
}

extension SessionRequests {
    /// A running session as the fleet read it.
    init(_ session: FleetSession) {
        self.init(id: session.id, name: session.name, project: session.project, requests: session.requests,
                  prompts: session.prompts, tasks: session.taskSpans,
                  agents: session.agents.map { AgentRequests(label: $0.label, workflow: $0.workflow, requests: $0.requests) })
    }

    /// Adds what one of the session's transcripts holds since `start`: its own, or a subagent's.
    mutating func add(_ state: TranscriptState, of file: FleetScanner.TranscriptFile, since start: Date,
                      label: String?, workflow: String?) {
        let recent = state.requests.filter { $0.t >= start }
        requests += recent
        if file.isSubagent {
            if !recent.isEmpty {
                agents.append(AgentRequests(label: label ?? "Subagent", workflow: workflow, requests: recent))
            }
        } else {
            // The session's own transcript has its name; its subagents' have their own.
            if let title = state.title { name = title }
            prompts += state.prompts.filter { $0.t >= start }
            promptBefore = state.prompts.last { $0.t < start } ?? promptBefore
            tasks += state.taskSpans.filter { ($0.end ?? .distantFuture) >= start }
            workflowNames.merge(state.workflows) { _, new in new }
        }
        if project.isEmpty, let cwd = state.cwd { project = URL(fileURLWithPath: cwd).lastPathComponent }
    }

    /// With a name and a folder, its requests in order, and its workflows named.
    func finished() -> SessionRequests {
        var session = self
        if session.project.isEmpty { session.project = "Unknown folder" }
        if session.name.isEmpty { session.name = session.project }
        session.requests.sort { $0.t < $1.t }
        session.agents = agents.map { agent in
            guard let run = agent.workflow, let name = workflowNames[run] else { return agent }
            return AgentRequests(label: agent.label, workflow: name, requests: agent.requests)
        }
        return session
    }
}

extension FleetScanner {
    /// What the profile's sessions did since `start`, from the transcripts written since then,
    /// ended sessions included. Parses only the lines past windows need (see `carriesHistory`),
    /// so going over months of transcripts takes seconds rather than minutes.
    static func sessionRequests(in scope: SessionScope, since start: Date) -> [SessionRequests] {
        var sessions: [String: SessionRequests] = [:]
        var workflows: [String: String] = [:]
        for file in transcripts(in: scope, modifiedSince: start) {
            var state = TranscriptState()
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(UInt64.init) } ?? 0
            state.catchUp(file.url, size: size, keep: TranscriptState.carriesHistory)
            let workflow = file.workflow.map { run in
                if let known = workflows[run] { return known }
                let name = workflowName(run, in: file.sessionFolder) ?? run
                workflows[run] = name
                return name
            }
            sessions[file.session, default: SessionRequests(id: file.session)]
                .add(state, of: file, since: start, label: file.isSubagent ? agentLabel(for: file.url) : nil, workflow: workflow)
        }
        return sessions.values.map { $0.finished() }
    }
}

/// The past windows as kept on disk, and how far the transcripts have been read for windows
/// the app didn't record.
struct WindowArchive: Codable, Sendable {
    var windows: [PastWindow] = []
    /// Windows that opened before this have been estimated from the transcripts.
    var estimatedThrough: Date?
    /// Windows kept before the app logged prompts and subagents have had them filled in, as far
    /// as the transcripts still on disk allowed.
    var loggedBack: Bool?

    /// Fills in what the sessions did (prompts, tasks, subagents) for windows kept before the app
    /// logged it. Their tokens stay as kept: the transcripts may have been cleaned up since.
    mutating func logBack(from sessions: [SessionRequests]) {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in windows.indices where windows[index].lacksLog {
            let (start, reset) = (windows[index].start, windows[index].reset)
            for slot in windows[index].sessions.indices where !windows[index].sessions[slot].isLogged {
                guard let session = byID[windows[index].sessions[slot].id] else { continue }
                windows[index].sessions[slot].log(session, start: start, reset: reset)
            }
        }
    }

    /// Takes the sessions `foreign` picks, and their tokens, out of every window. Returns whether
    /// a window held one.
    mutating func removeSessions(where foreign: (String) -> Bool) -> Bool {
        var removed = false
        for index in windows.indices where windows[index].sessions.contains(where: { foreign($0.id) }) {
            windows[index].removeSessions { foreign($0.id) }
            removed = true
        }
        return removed
    }

    /// Adds a window. A recorded one replaces any estimate it overlaps, and the same window
    /// twice keeps the one with more in it.
    mutating func add(_ window: PastWindow) {
        if let existing = windows.first(where: { $0.id == window.id }), existing.richness > window.richness { return }
        if window.source == .estimated,
           windows.contains(where: { $0.source == .recorded && $0.sharesTime(with: window) }) {
            return
        }
        windows.removeAll {
            $0.id == window.id
                || (window.source == .recorded && $0.source == .estimated && $0.sharesTime(with: window))
        }
        windows.append(window)
        windows.sort { $0.start < $1.start }
    }

    /// Takes in what another copy of the archive knows: another instance of the app may have
    /// saved windows this one hasn't seen.
    mutating func merge(_ other: WindowArchive) {
        for window in other.windows { add(window) }
        estimatedThrough = [estimatedThrough, other.estimatedThrough].compactMap { $0 }.max()
        if other.loggedBack == true { loggedBack = true }
    }

    /// 5-hour windows inferred from the transcripts where no window is known: as the plan's
    /// windows do, each opens with the first request after the previous one reset.
    static func estimate(_ sessions: [SessionRequests], known: [Range<Date>], from: Date, until cutoff: Date,
                         length: TimeInterval) -> [PastWindow] {
        let times = sessions.flatMap { $0.requests.filter { $0.total > 0 }.map(\.t) }.filter { $0 >= from && $0 < cutoff }.sorted()
        let known = known.sorted { $0.lowerBound < $1.lowerBound }
        var spans: [Range<Date>] = []
        for t in times {
            if spans.last?.contains(t) == true || known.contains(where: { $0.contains(t) }) { continue }
            // Whole minutes, as the plan reports them.
            let start = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 60).rounded(.down) * 60)
            var end = start.addingTimeInterval(length)
            if let next = known.first(where: { $0.lowerBound > start }) { end = min(end, next.lowerBound) }
            if let last = spans.last { spans[spans.count - 1] = last.lowerBound..<min(last.upperBound, start) }
            spans.append(start..<end)
        }
        // A few minutes squeezed in before a known window are its own requests, a little early.
        return spans.filter { $0.upperBound.timeIntervalSince($0.lowerBound) >= 10 * 60 }.map {
            PastWindow(meter: PastWindow.sessionMeter, start: $0.lowerBound, reset: $0.upperBound, source: .estimated,
                       samples: [], sessions: sessions)
        }
    }
}

extension Range where Bound == Date {
    /// How long two stretches of time have in common.
    func overlap(with other: Range<Date>) -> TimeInterval {
        Swift.max(0, Swift.min(upperBound, other.upperBound).timeIntervalSince(Swift.max(lowerBound, other.lowerBound)))
    }
}

private extension PastWindow {
    /// How much a copy of a window holds, to keep the fuller one.
    var richness: Int {
        (source == .recorded ? 1_000_000 : 0) + samples.count * 1000 + (slices.isEmpty ? 0 : 1)
            + (sessions.contains(where: \.isLogged) ? 2 : 0)
    }
}

// MARK: - Export

/// The History page's data in files of their own: everything as JSON, or one row per window as CSV.
enum HistoryExport {
    enum Format: String {
        case json, csv
    }

    private struct Document: Encodable {
        let app = "AI Tempomat"
        let exportedAt: Date
        let notes: [String]
        let tokensPerPercent: Double?
        let windows: [PastWindow]
        let current: [String: History.Track]
    }

    @MainActor
    static func data(_ format: Format, store: UsageStore, now: Date = Date()) throws -> Data {
        switch format {
        case .json:
            let document = Document(
                exportedAt: now,
                notes: [
                    "windows: limit windows that have ended. source is recorded (read from /usage while the app ran) or estimated (from Claude Code transcripts, no readings).",
                    "samples: percent of the limit used (p) at a time (t).",
                    "slices: tokens this Mac's Claude Code sessions used in each 5-minute slice of the window, input, cache and output together.",
                    "tokensPerPercent: tokens per 1% of the 5-hour limit, measured in that window; the top-level value is the typical one, used for estimates.",
                    "sessions: each session's tokens per slice, and what it did in the window: prompts (what you typed, cut to 200 characters), tasks (when each was in progress) and agents (each subagent's tokens per slice from firstSlice on, with the workflow it ran in). These are missing for windows kept before the app logged them.",
                    "current: readings of the windows still open, per meter.",
                ],
                tokensPerPercent: store.typicalTokensPerPercent,
                windows: store.archive.windows,
                current: store.currentTracks)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(document)
        case .csv:
            let typical = store.typicalTokensPerPercent
            let dates = ISO8601DateFormatter()
            dates.timeZone = .current
            var rows = [["meter", "start", "reset", "source", "percent_used", "limit_hit_at", "locked_out_minutes",
                         "tokens", "output_tokens", "tokens_per_percent", "sessions", "top_session", "top_session_tokens"]]
            for window in store.archive.windows {
                let lockout = window.limitHitAt.map { String(Int(window.reset.timeIntervalSince($0) / 60)) } ?? ""
                rows.append([
                    window.meter, dates.string(from: window.start), dates.string(from: window.reset), window.source.rawValue,
                    window.percentUsed(typical: window.meter == PastWindow.sessionMeter ? typical : nil).map { String(format: "%.1f", $0) } ?? "",
                    window.limitHitAt.map(dates.string) ?? "", lockout,
                    window.slices.isEmpty ? "" : String(window.tokens), window.slices.isEmpty ? "" : String(window.outputTokens),
                    window.tokensPerPercent.map { String(Int($0)) } ?? "",
                    String(window.sessions.count), window.sessions.first?.name ?? "", window.sessions.first.map { String($0.tokens) } ?? "",
                ])
            }
            return Data(rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n").appending("\n").utf8)
        }
    }

    /// Writes the export to `folder` (the Downloads folder unless given) and returns where.
    @MainActor
    static func write(_ format: Format, store: UsageStore, to folder: URL? = nil, now: Date = Date()) throws -> URL {
        let folder = folder
            ?? (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let url = folder.appending(path: "AI Tempomat history \(stamp.string(from: now)).\(format.rawValue)")
        try data(format, store: store, now: now).write(to: url, options: .atomic)
        return url
    }

    private static func csvField(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            : value
    }
}
