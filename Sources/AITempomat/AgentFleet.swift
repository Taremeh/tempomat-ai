import Darwin
import Foundation
import Observation

/// One Claude Code session running on this Mac, as its registry entry and transcripts describe it.
struct FleetSession: Identifiable, Sendable {
    struct Span: Sendable, Hashable {
        let start: Date
        let end: Date
    }

    struct Agent: Identifiable, Sendable {
        let id: String          // transcript path
        let label: String       // "Explore: Mine temporal-window analysis"
        let span: Span
        let isRunning: Bool
        let workflow: String?   // the workflow run it belongs to, if any
        /// Its own requests, sorted by time.
        var requests: [Request] = []
    }

    /// Something you asked a session: a prompt you typed, or a command you ran.
    struct Prompt: Codable, Sendable {
        let t: Date
        let text: String
    }

    /// A task it worked on, from when it was marked in progress until it left that state.
    struct TaskSpan: Codable, Sendable {
        let subject: String
        let start: Date
        /// Nil while it is still in progress.
        var end: Date?
    }

    struct Tasks: Sendable {
        var done = 0
        var active = 0
        var pending = 0
        var current: String?

        var total: Int { done + active + pending }
    }

    /// Tokens one model request used, main agent or subagent.
    struct Request: Sendable {
        let t: Date
        let total: Int      // input + cache writes + cache reads + output
        let output: Int
    }

    let id: String
    let pid: Int32
    let name: String
    let project: String
    let isBusy: Bool
    let startedAt: Date
    /// When it last turned busy or idle.
    let statusSince: Date
    var lastActivity: Date
    /// Busy stretches: from a prompt to the end of the turn it started.
    var turns: [Span] = []
    var agents: [Agent] = []
    /// Sorted by time.
    var requests: [Request] = []
    /// When tasks were marked done.
    var completions: [Date] = []
    var tasks = Tasks()
    var totalTokens = 0
    var outputTokens = 0
    /// The main agent's context at its last request.
    var context = 0
    var workflowsDone = 0
    var lastPrompt: String?
    /// When you prompted it.
    var prompts: [Prompt] = []
    /// When its tasks were in progress.
    var taskSpans: [TaskSpan] = []

    var runningAgents: [Agent] { agents.filter(\.isRunning) }
    var workflowsRunning: Int { Set(runningAgents.compactMap(\.workflow)).count }

    /// What it's working on: the task in progress, else the prompt of a running turn.
    var doing: String? { tasks.current ?? (isBusy ? lastPrompt : nil) }
}

// MARK: - Reading transcripts

/// What one transcript file adds up to, read incrementally. Streamed messages are written as
/// several lines sharing one id, so each request is counted once, at its latest usage.
struct TranscriptState: Sendable {
    struct Item: Sendable {
        var subject: String
        var status: String
        var activeForm: String?
    }

    var offset: UInt64 = 0
    var requests: [FleetSession.Request] = []
    private var requestIndex: [String: Int] = [:]
    var first: Date?
    var last: Date?
    var context = 0
    var lastPrompt: String?
    /// The session's name, as you or Claude Code set it.
    var title: String?
    /// The folder the session ran in.
    var cwd: String?
    var completions: [Date] = []
    /// What you typed, in order.
    private(set) var prompts: [FleetSession.Prompt] = []
    /// When each task was in progress, in the order they started.
    private(set) var taskSpans: [FleetSession.TaskSpan] = []
    /// The names of the workflows it launched, by run id.
    private(set) var workflows: [String: String] = [:]
    private(set) var turns: [FleetSession.Span] = []
    private var openTurn: (start: Date, last: Date)?
    private var taskOrder: [String] = []
    private var taskItems: [String: Item] = [:]
    private var todos: [Item] = []
    /// Spans of the tasks in progress, by task id or to-do text, as indices into `taskSpans`.
    private var openTasks: [String: Int] = [:]

    /// Closed turns, plus the open one ending at `openEnd` (now, while the session is busy).
    func turns(openEnd: Date?) -> [FleetSession.Span] {
        guard let openTurn else { return turns }
        return turns + [FleetSession.Span(start: openTurn.start, end: max(openTurn.last, openEnd ?? openTurn.last))]
    }

    var tasks: FleetSession.Tasks {
        let list = taskOrder.isEmpty ? todos : taskOrder.compactMap { taskItems[$0] }
        let current = list.first { $0.status == "in_progress" }
        return FleetSession.Tasks(done: list.filter { $0.status == "completed" }.count,
                                  active: list.filter { $0.status == "in_progress" }.count,
                                  pending: list.filter { $0.status == "pending" }.count,
                                  current: current.map { $0.activeForm ?? $0.subject })
    }

    private static let chunkSize = 8 << 20

    /// Reads the lines appended to `url` since the last call, in chunks so a long transcript
    /// is never in memory at once. A line still being written waits for the next call.
    /// `keep` skips the lines it turns down without parsing them.
    mutating func catchUp(_ url: URL, size: UInt64, keep: ((Data) -> Bool)? = nil) {
        if size < offset { self = TranscriptState() }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return }
        var pending = Data()
        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            guard let newline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...newline]
            // JSONSerialization's objects are autoreleased; drain them per line.
            for line in complete.split(separator: 0x0A) where keep?(line) ?? true {
                autoreleasepool { ingest(Data(line)) }
            }
            offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: newline)...])
        }
    }

    /// The lines past windows need, a small share of a transcript: each request's usage (and the
    /// tool calls that come with it), the session's name, your prompts, and the tasks and
    /// workflows it started. Other tool results, the bulk of a transcript, are left out. Keys
    /// inside a prompt's text are escaped, so they never match.
    static func carriesHistory(_ line: Data) -> Bool {
        line.contains(bytes: usageKey) || line.contains(bytes: titleKey) || line.contains(bytes: agentNameKey)
            || line.contains(bytes: createdTaskKey) || line.contains(bytes: workflowNameKey)
            || (line.contains(bytes: userKey) && !line.contains(bytes: toolResultKey))
    }

    private static let usageKey = Array("\"usage\"".utf8)
    private static let titleKey = Array("\"customTitle\"".utf8)
    private static let agentNameKey = Array("\"agentName\"".utf8)
    private static let createdTaskKey = Array("\"task\":{\"id\"".utf8)
    private static let workflowNameKey = Array("\"workflowName\"".utf8)
    private static let userKey = Array("\"type\":\"user\"".utf8)
    private static let toolResultKey = Array("\"type\":\"tool_result\"".utf8)

    mutating func ingest(_ line: Data) {
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = row["type"] as? String else { return }

        if type == "last-prompt", let prompt = row["lastPrompt"] as? String { lastPrompt = prompt }
        if let name = (row["customTitle"] ?? row["agentName"]) as? String, !name.isEmpty { title = name }
        if cwd == nil, let dir = row["cwd"] as? String { cwd = dir }
        guard let t = (row["timestamp"] as? String).flatMap(Self.parseDate) else { return }
        let message = row["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []

        switch type {
        case "assistant":
            touch(t)
            if let usage = message?["usage"] as? [String: Any] {
                record(usage, id: message?["id"] as? String ?? row["requestId"] as? String, at: t)
            }
            for block in blocks where block["type"] as? String == "tool_use" {
                track(tool: block["name"] as? String, input: block["input"] as? [String: Any] ?? [:], at: t)
            }
        case "user":
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                touch(t)
                let result = row["toolUseResult"] as? [String: Any]
                // TaskCreate's id only exists in its result.
                if let task = result?["task"] as? [String: Any],
                   let id = Self.string(task["id"]), taskItems[id] == nil {
                    taskOrder.append(id)
                    taskItems[id] = Item(subject: task["subject"] as? String ?? "#\(id)", status: "pending")
                }
                // A workflow's run id and its name meet only in the result of the call that launched it.
                if let run = result?["runId"] as? String, let name = result?["workflowName"] as? String {
                    workflows[run] = name
                }
            } else if row["isMeta"] as? Bool != true, row["isCompactSummary"] as? Bool != true {
                startTurn(t)
                if let text = Self.promptText(row, content: message?["content"]) {
                    prompts.append(.init(t: t, text: text))
                }
            }
        case "system" where row["subtype"] as? String == "stop_hook_summary":
            if let open = openTurn { turns.append(.init(start: open.start, end: max(open.last, t))) }
            openTurn = nil
        default:
            break
        }
    }

    private mutating func touch(_ t: Date) {
        first = min(first ?? t, t)
        last = max(last ?? t, t)
        if let open = openTurn {
            openTurn = (open.start, max(open.last, t))
        } else {
            openTurn = (t, t)   // activity with no prompt on record (a resumed session)
        }
    }

    private mutating func startTurn(_ t: Date) {
        if let open = openTurn { turns.append(.init(start: open.start, end: open.last)) }
        openTurn = (t, t)
        first = min(first ?? t, t)
        last = max(last ?? t, t)
    }

    private mutating func record(_ usage: [String: Any], id: String?, at t: Date) {
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let input = count("input_tokens") + count("cache_creation_input_tokens") + count("cache_read_input_tokens")
        let output = count("output_tokens")
        if input > 0 { context = input }
        if let id, let index = requestIndex[id] {
            let earlier = requests[index]
            requests[index] = .init(t: earlier.t, total: input + output, output: output)
        } else {
            if let id { requestIndex[id] = requests.count }
            requests.append(.init(t: t, total: input + output, output: output))
        }
    }

    private mutating func track(tool: String?, input: [String: Any], at t: Date) {
        switch tool {
        case "TaskUpdate":
            guard let id = Self.string(input["taskId"]) else { return }
            if input["status"] as? String == "deleted" {
                taskItems[id] = nil
                taskOrder.removeAll { $0 == id }
                setTask("task \(id)", subject: "", inProgress: false, at: t)
                return
            }
            if taskItems[id] == nil { taskOrder.append(id) }
            var item = taskItems[id] ?? Item(subject: "#\(id)", status: "pending")
            if let status = input["status"] as? String {
                if status == "completed", item.status != "completed" { completions.append(t) }
                item.status = status
            }
            item.subject = input["subject"] as? String ?? item.subject
            item.activeForm = input["activeForm"] as? String ?? item.activeForm
            taskItems[id] = item
            setTask("task \(id)", subject: item.subject, inProgress: item.status == "in_progress", at: t)
        case "TodoWrite":
            guard let list = input["todos"] as? [[String: Any]] else { return }
            let before = todos.filter { $0.status == "completed" }.count
            todos = list.map {
                Item(subject: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending",
                     activeForm: $0["activeForm"] as? String)
            }
            let after = todos.filter { $0.status == "completed" }.count
            if after > before { completions += Array(repeating: t, count: after - before) }
            let working = Set(todos.filter { $0.status == "in_progress" }.map(\.subject))
            for key in openTasks.keys where key.hasPrefix("todo ") && !working.contains(String(key.dropFirst(5))) {
                setTask(key, subject: "", inProgress: false, at: t)
            }
            for subject in working { setTask("todo \(subject)", subject: subject, inProgress: true, at: t) }
        default:
            break
        }
    }

    /// Opens a task's span when it goes in progress, and closes it when it leaves that state.
    private mutating func setTask(_ key: String, subject: String, inProgress: Bool, at t: Date) {
        if inProgress {
            guard openTasks[key] == nil else { return }
            openTasks[key] = taskSpans.count
            taskSpans.append(.init(subject: subject, start: t))
        } else if let index = openTasks.removeValue(forKey: key) {
            taskSpans[index].end = t
        }
    }

    /// What you typed, from a user line that isn't a tool result: a command as you ran it, and
    /// nil for what Claude Code writes there itself (task notifications, command output).
    static func promptText(_ row: [String: Any], content: Any?) -> String? {
        // Newer transcripts say who it came from.
        if let kind = (row["origin"] as? [String: Any])?["kind"] as? String, kind != "human" { return nil }
        var text: String
        switch content {
        case let string as String:
            text = string
        case let blocks as [[String: Any]]:
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            if text.isEmpty, blocks.contains(where: { $0["type"] as? String == "image" }) { text = "[Image]" }
        default:
            return nil
        }
        if let command = tag("command-name", in: text) {
            text = [command, tag("command-args", in: text) ?? ""].joined(separator: " ")
        } else if let shell = tag("bash-input", in: text) {
            text = "! \(shell)"
        } else if notPrompts.contains(where: text.hasPrefix) {
            return nil
        }
        // One line, and short: a prompt can be a whole pasted document.
        let words = text.prefix(4 * promptLength).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > promptLength ? String(words.prefix(promptLength - 1)) + "…" : words
    }

    private static let promptLength = 200
    /// User lines Claude Code writes on its own.
    private static let notPrompts = ["<task-notification", "<local-command-", "<bash-stdout", "<bash-stderr", "<system-reminder"]

    /// The text between `<name>` and `</name>`.
    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func parseDate(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }
}

extension Data {
    /// Whether these bytes contain `needle`, without decoding them.
    func contains(bytes needle: [UInt8]) -> Bool {
        guard !isEmpty, !needle.isEmpty else { return false }
        return withUnsafeBytes { haystack in
            needle.withUnsafeBytes { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
        }
    }
}

// MARK: - Scanning the fleet

/// Finds a profile's running sessions in `<config folder>/sessions` (see `SessionScope`) and
/// reads what their transcripts added since the last scan.
actor FleetScanner {
    private struct Registry: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let startedAt: Double
        let name: String?
        let status: String?
        let statusUpdatedAt: Double?
        let updatedAt: Double?
        /// The desktop app's id for a session it runs.
        let hostSessionId: String?
    }

    /// A subagent whose transcript was written this recently counts as running.
    static let activeWindow: TimeInterval = 45

    private let scope: SessionScope
    private var files: [String: TranscriptState] = [:]
    private var transcriptDirs: [String: URL] = [:]
    private var labels: [String: String] = [:]
    private var workflowNames: [String: String] = [:]
    /// Transcripts written to recently, ended sessions included (see `recentSessions`).
    private var recentPaths: Set<String> = []

    static let defaultClaudeDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")

    init(scope: SessionScope) {
        self.scope = scope
    }

    func scan(now: Date = Date()) -> [FleetSession] {
        let filter = scope.filter()
        let registries = scope.folders.flatMap { claudeDir in
            let entries = (try? FileManager.default.contentsOfDirectory(at: claudeDir.appending(path: "sessions"),
                                                                       includingPropertiesForKeys: nil)) ?? []
            return entries
                .filter { $0.pathExtension == "json" && Int32($0.deletingPathExtension().lastPathComponent) != nil }
                .compactMap { try? JSONDecoder().decode(Registry.self, from: Data(contentsOf: $0)) }
                .filter { filter.includes($0.sessionId, host: $0.hostSessionId, in: claudeDir) && Self.isClaude(pid: $0.pid) }
                .map { (entry: $0, claudeDir: claudeDir) }
        }

        let sessions = registries.map { session(for: $0.entry, in: $0.claudeDir, now: now) }
        // Forget the transcripts of sessions that ended, unless they still count for recent usage.
        files = files.filter { path, _ in recentPaths.contains(path) || sessions.contains { path.contains($0.id) } }
        return sessions
    }

    /// What the profile's Claude Code sessions on this Mac did since `start`, sessions that have
    /// ended included: their requests, your prompts, their tasks and subagents. The usage that
    /// fills the plan's current limit window, as far as this Mac sees it.
    func recentSessions(since start: Date) -> [SessionRequests] {
        let found = Self.transcripts(in: scope, modifiedSince: start)
        recentPaths = Set(found.map(\.url.path))
        var sessions: [String: SessionRequests] = [:]
        for file in found {
            let state = read(file.url)
            sessions[file.session, default: SessionRequests(id: file.session)]
                .add(state, of: file, since: start, label: file.isSubagent ? label(for: file.url) : nil,
                     workflow: file.workflow.map { workflowName($0, in: file.sessionFolder) })
        }
        return sessions.values.map { $0.finished() }
    }

    /// A transcript on disk: a session's own, or one of its subagents'.
    struct TranscriptFile: Sendable {
        let url: URL
        /// The session it belongs to.
        let session: String
        let isSubagent: Bool
        /// The workflow run a subagent belongs to, if any.
        var workflow: String?
        /// The session's folder, beside its transcript: subagents, finished workflows.
        let sessionFolder: URL
    }

    /// Every transcript of the profile's sessions written to since `start`, sessions that have
    /// ended included.
    static func transcripts(in scope: SessionScope, modifiedSince start: Date) -> [TranscriptFile] {
        let filter = scope.filter()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        func entries(_ dir: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        }
        func recent(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) >= start
        }

        var found: [TranscriptFile] = []
        for claudeDir in scope.folders {
            for project in entries(claudeDir.appending(path: "projects")) {
                let entries = entries(project)
                var activeSessions: Set<String> = []
                for transcript in entries where transcript.pathExtension == "jsonl" {
                    let session = transcript.deletingPathExtension().lastPathComponent
                    guard filter.includes(session, in: claudeDir), recent(transcript) else { continue }
                    found.append(TranscriptFile(url: transcript, session: session, isSubagent: false,
                                                sessionFolder: project.appending(path: session)))
                    activeSessions.insert(session)
                }
                // Session folders hold the subagent transcripts. A folder's own date doesn't change
                // when a file in it grows, so its session's transcript and its subagents folder count too.
                for folder in entries where (try? folder.resourceValues(forKeys: keys))?.isDirectory == true {
                    let subagents = folder.appending(path: "subagents")
                    guard filter.includes(folder.lastPathComponent, in: claudeDir),
                          activeSessions.contains(folder.lastPathComponent) || recent(folder) || recent(subagents) else { continue }
                    for agent in agentFiles(in: subagents) where agent.modified >= start {
                        found.append(TranscriptFile(url: agent.url, session: folder.lastPathComponent, isSubagent: true,
                                                    workflow: agent.workflow, sessionFolder: folder))
                    }
                }
            }
        }
        return found
    }

    private func session(for entry: Registry, in claudeDir: URL, now: Date) -> FleetSession {
        let project = URL(fileURLWithPath: entry.cwd).lastPathComponent
        let startedAt = Date(timeIntervalSince1970: entry.startedAt / 1000)
        let isBusy = entry.status == "busy"
        var session = FleetSession(
            id: entry.sessionId, pid: entry.pid, name: entry.name ?? project, project: project, isBusy: isBusy,
            startedAt: startedAt,
            statusSince: Date(timeIntervalSince1970: (entry.statusUpdatedAt ?? entry.updatedAt ?? entry.startedAt) / 1000),
            lastActivity: startedAt)

        guard let dir = transcriptDir(for: entry, in: claudeDir) else { return session }
        let mainURL = dir.appending(path: "\(entry.sessionId).jsonl")
        let main = read(mainURL)
        session.turns = main.turns(openEnd: isBusy ? now : nil)
        // A session stays busy past its turns while it waits on background work (a workflow,
        // a background agent): it has been busy since its status last changed.
        if isBusy {
            session.turns = Self.merge(session.turns + [.init(start: session.statusSince, end: now)])
        }
        session.tasks = main.tasks
        session.completions = main.completions
        session.context = main.context
        session.lastPrompt = main.lastPrompt
        session.prompts = main.prompts
        session.taskSpans = main.taskSpans
        session.lastActivity = max(startedAt, main.last ?? startedAt)
        var requests = main.requests

        let sessionDir = dir.appending(path: entry.sessionId)
        for file in Self.agentFiles(in: sessionDir.appending(path: "subagents")) {
            let state = read(file.url)
            requests += state.requests
            let start = state.first ?? file.modified
            session.agents.append(.init(
                id: file.url.path, label: label(for: file.url),
                span: .init(start: start, end: max(start, state.last ?? file.modified)),
                isRunning: now.timeIntervalSince(file.modified) < Self.activeWindow,
                workflow: file.workflow, requests: state.requests))
            session.lastActivity = max(session.lastActivity, file.modified)
        }
        session.agents.sort { $0.span.start < $1.span.start }
        session.requests = requests.sorted { $0.t < $1.t }
        session.totalTokens = requests.reduce(0) { $0 + $1.total }
        session.outputTokens = requests.reduce(0) { $0 + $1.output }
        session.workflowsDone = ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir.appending(path: "workflows").path)) ?? [])
            .filter { $0.hasPrefix("wf_") && $0.hasSuffix(".json") }.count
        return session
    }

    /// Joins overlapping spans.
    static func merge(_ spans: [FleetSession.Span]) -> [FleetSession.Span] {
        var merged: [FleetSession.Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func read(_ url: URL) -> TranscriptState {
        // Taken out while it's updated, so its arrays aren't copied on every scan.
        var state = files.removeValue(forKey: url.path) ?? TranscriptState()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(UInt64.init) } ?? 0
        state.catchUp(url, size: size)
        files[url.path] = state
        return state
    }

    /// `~/.claude/projects/<cwd with every non-alphanumeric as ->/`; a session that moved
    /// (a worktree, /cd) keeps its transcript where it began, so fall back to a search.
    private func transcriptDir(for entry: Registry, in claudeDir: URL) -> URL? {
        if let known = transcriptDirs[entry.sessionId] { return known }
        let projects = claudeDir.appending(path: "projects")
        let slug = String(entry.cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        let candidates = [projects.appending(path: slug)]
            + ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
        let found = candidates.first {
            FileManager.default.fileExists(atPath: $0.appending(path: "\(entry.sessionId).jsonl").path)
        }
        if let found { transcriptDirs[entry.sessionId] = found }
        return found
    }

    private struct AgentFile {
        let url: URL
        let modified: Date
        let workflow: String?
    }

    /// `subagents/agent-*.jsonl`, and workflow agents in `subagents/workflows/<run>/agent-*.jsonl`.
    private static func agentFiles(in dir: URL) -> [AgentFile] {
        var found: [AgentFile] = []
        func walk(_ dir: URL, workflow: String?, depth: Int) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true, depth < 2 {
                    walk(url, workflow: depth == 1 ? url.lastPathComponent : workflow, depth: depth + 1)
                } else if url.lastPathComponent.hasPrefix("agent-"), url.pathExtension == "jsonl" {
                    found.append(AgentFile(url: url, modified: values?.contentModificationDate ?? .distantPast, workflow: workflow))
                }
            }
        }
        walk(dir, workflow: nil, depth: 0)
        return found
    }

    /// What a subagent was asked to do, read once.
    private func label(for url: URL) -> String {
        if let known = labels[url.path] { return known }
        guard let label = Self.agentLabel(for: url) else { return "Subagent" }
        labels[url.path] = label
        return label
    }

    /// What a subagent was asked to do, from the `.meta.json` beside its transcript; nil until
    /// that file is written.
    static func agentLabel(for url: URL) -> String? {
        let metaURL = url.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let kind = meta["workflowPhase"] as? String ?? meta["agentType"] as? String
        let joined = [kind, meta["description"] as? String].compactMap { $0 }.joined(separator: ": ")
        return joined.isEmpty ? "Subagent" : joined
    }

    /// A workflow's name, read once it is known; its run id until then.
    private func workflowName(_ run: String, in sessionFolder: URL) -> String {
        if let known = workflowNames[run] { return known }
        guard let name = Self.workflowName(run, in: sessionFolder) else { return run }
        workflowNames[run] = name
        return name
    }

    /// A workflow's name, from the file its run leaves in the session's folder once it has
    /// finished; nil while it runs.
    static func workflowName(_ run: String, in sessionFolder: URL) -> String? {
        let file = sessionFolder.appending(path: "workflows").appending(path: "\(run).json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["workflowName"] as? String
    }

    /// A registry file outlives a crashed session; only count PIDs that still run Claude Code.
    private static func isClaude(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.lowercased().contains("claude")
    }
}

// MARK: - Store

@MainActor @Observable
final class FleetStore {
    private(set) var sessions: [FleetSession] = []
    /// Every session on this Mac in the last five hours and a bit, ended ones included, with
    /// their requests, prompts, tasks and subagents: what fills the current 5-hour limit window.
    private(set) var recentSessions: [SessionRequests] = []
    /// Their requests, all together, sorted by time.
    private(set) var recentRequests: [FleetSession.Request] = []
    static let recentSpan: TimeInterval = 5 * 3600 + 10 * 60
    private(set) var lastUpdated: Date?
    private(set) var isScanning = false
    /// Categorical color slot per session, kept for as long as it runs.
    private(set) var slots: [String: Int] = [:]

    private let scanner: FleetScanner?
    private var pollTask: Task<Void, Never>?
    static let pollInterval: Duration = .seconds(5)

    /// `scanner` nil keeps the sessions it was given, for demos and previews.
    init(scanner: FleetScanner?, sessions: [FleetSession] = []) {
        self.scanner = scanner
        if !sessions.isEmpty {
            apply(sessions, at: Date())
            recentSessions = sessions.map(SessionRequests.init)
            recentRequests = sessions.flatMap(\.requests).sorted { $0.t < $1.t }
        }
    }

    var busyCount: Int { sessions.filter(\.isBusy).count }

    /// How many views showing the fleet are on screen. Switching pages can show the new view
    /// before the old one goes, so polling is counted rather than toggled.
    private var watchers = 0

    /// Polls while a view of the fleet is on screen. The history comes from the transcripts,
    /// so nothing is lost while none is.
    func startPolling() {
        watchers += 1
        guard pollTask == nil, scanner != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stopPolling() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let scanner, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let now = Date()
        let scanned = await scanner.scan(now: now)
        recentSessions = await scanner.recentSessions(since: now.addingTimeInterval(-Self.recentSpan))
        recentRequests = recentSessions.flatMap(\.requests).sorted { $0.t < $1.t }
        apply(scanned, at: now)
    }

    private func apply(_ scanned: [FleetSession], at now: Date) {
        // Busy first, then oldest first: an order that holds still between scans.
        sessions = scanned.sorted {
            $0.isBusy != $1.isBusy ? $0.isBusy : $0.startedAt < $1.startedAt
        }
        // Color follows the session: survivors keep theirs, new ones take the lowest free slot.
        let ids = Set(scanned.map(\.id))
        slots = slots.filter { ids.contains($0.key) }
        for session in scanned.sorted(by: { $0.startedAt < $1.startedAt }) where slots[session.id] == nil {
            if let free = (0..<SeriesPalette.count).first(where: { !slots.values.contains($0) }) {
                slots[session.id] = free
            }
        }
        lastUpdated = now
    }
}

extension Format {
    /// "812", "46k", "1.2M", "110M", "4.0B": one decimal below 10 of a unit.
    static func tokens(_ count: Double) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            String(format: value < 9.95 ? "%.1f%@" : "%.0f%@", value, unit)
        }
        // A count that would round up to 1000 of a unit is shown in the next one.
        switch count {
        case 999.5e6...: return scaled(count / 1e9, "B")
        case 999.5e3...: return scaled(count / 1e6, "M")
        case 999.5...: return String(format: "%.0fk", count / 1e3)
        default: return String(format: "%.0f", count)
        }
    }

    static func tokens(_ count: Int) -> String { tokens(Double(count)) }
}

// MARK: - Demo data

enum DemoFleet {
    static func sessions(now: Date = Date()) -> [FleetSession] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func span(_ from: Double, _ to: Double) -> FleetSession.Span { .init(start: ago(from), end: ago(to)) }

        /// Requests every ~20 s inside each turn, with context growing through the session.
        func requests(in turns: [FleetSession.Span], context: Int, seed: Int) -> [FleetSession.Request] {
            var generator = SeededGenerator(seed: UInt64(seed))
            var result: [FleetSession.Request] = []
            var size = context / 3
            for turn in turns {
                var t = turn.start
                while t < turn.end {
                    size = min(context, size + Int.random(in: 500...4000, using: &generator))
                    let output = Int.random(in: 200...3000, using: &generator)
                    result.append(.init(t: t, total: size + output, output: output))
                    t.addTimeInterval(Double.random(in: 10...40, using: &generator))
                }
            }
            return result
        }

        /// `prompts` start the turns, one each; `steps` are the tasks finished at `done`, then the current one.
        func make(_ id: String, _ name: String, _ project: String, busy: Bool, started: Double, turns: [FleetSession.Span],
                  prompts: [String], agents: [(String, Double, Double, String?)], tasks: FleetSession.Tasks,
                  done: [Double], steps: [String], context: Int, seed: Int) -> FleetSession {
            var session = FleetSession(id: id, pid: 0, name: name, project: project, isBusy: busy, startedAt: ago(started),
                                       statusSince: busy ? turns.last?.start ?? now : turns.last?.end ?? now,
                                       lastActivity: turns.last?.end ?? now)
            session.turns = turns
            session.prompts = zip(turns, prompts).map { .init(t: $0.start, text: $1) }
            var all = requests(in: turns, context: context, seed: seed)
            session.agents = agents.map {
                let agentSpan = span($0.1, $0.2)
                let own = requests(in: [agentSpan], context: context / 2, seed: seed + $0.0.count)
                all += own
                return .init(id: "\(id)-\($0.0)", label: $0.0, span: agentSpan, isRunning: $0.2 < 0.5, workflow: $0.3,
                             requests: own)
            }
            session.requests = all.sorted { $0.t < $1.t }
            session.totalTokens = all.reduce(0) { $0 + $1.total }
            session.outputTokens = all.reduce(0) { $0 + $1.output }
            session.tasks = tasks
            session.completions = done.map(ago)
            // Each task runs from the one before it finishing (or the first turn) to its own finish.
            let ends = session.completions.map(Optional.some) + (tasks.current != nil ? [nil] : [])
            var from = turns.first?.start ?? now
            for (subject, end) in zip(steps + [tasks.current].compactMap { $0 }, ends) {
                session.taskSpans.append(.init(subject: subject, start: from, end: end))
                from = end ?? now
            }
            session.context = context
            session.workflowsDone = agents.contains { $0.3 != nil } ? 1 : 0
            return session
        }

        return [
            make("demo-docs", "Dev documentation for the API", "api-server", busy: true, started: 160,
                 turns: [span(155, 120), span(96, 0)],
                 prompts: ["generate a /dev/doc part of the API, mapped from the code", "go with your recommendations, start with chapters 0–4"],
                 agents: [("Map: map:areas", 150, 128, "map-dev-docs"), ("Map: map:trace", 148, 125, "map-dev-docs"),
                          ("Critic: critic", 124, 121, "map-dev-docs"), ("Explore: Find route guards", 60, 41, nil),
                          ("Build: build:pages", 22, 0, "build-dev-docs"), ("Build: build:styles", 18, 0, "build-dev-docs")],
                 tasks: .init(done: 4, active: 1, pending: 2, current: "Write the pipeline page"),
                 done: [110, 80, 52, 30], steps: ["Map the app's areas", "Outline the chapters", "Write the routing page", "Write the data page"],
                 context: 286_000, seed: 1),
            make("demo-ner", "Named entity recognition fixes", "nlp-lab", busy: true, started: 100,
                 turns: [span(98, 70), span(45, 0)],
                 prompts: ["names with \"and with\" aren't recognized, fix the extraction", "move the corpora into a test folder and re-run"],
                 agents: [("general-purpose: Audit label sets", 40, 12, nil)],
                 tasks: .init(done: 2, active: 1, pending: 3, current: "Re-run the evaluation"),
                 done: [75, 20], steps: ["Reproduce the missed names", "Fix the prompt"], context: 166_000, seed: 2),
            make("demo-widget", "Claude usage API widget", "ai-tempomat", busy: false, started: 60,
                 turns: [span(58, 49), span(47, 20), span(16, 9)],
                 prompts: ["is there a way to read my plan usage from the CLI?", "build it as a menu bar widget", "/compact"],
                 agents: [("claude-code-guide: Usage data sources", 55, 50, nil)],
                 tasks: .init(), done: [], steps: [], context: 231_000, seed: 3),
            make("demo-llm", "Local LLM endpoint usage", "llm-proxy", busy: false, started: 170,
                 turns: [span(168, 150)],
                 prompts: ["log the tokens the local endpoint serves"],
                 agents: [], tasks: .init(done: 3, active: 0, pending: 0), done: [160, 155, 151],
                 steps: ["Add a request logger", "Count tokens per model", "Write the summary"], context: 93_000, seed: 4),
        ]
    }
}

/// Deterministic randomness, so previews render the same each time.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
