import Foundation
import Darwin

protocol UsageSource: Sendable {
    func fetch() async throws -> [LimitRow]
}

/// Reads plan usage by running `claude -p "/usage"`, which never calls the model and costs no quota.
actor ClaudeCLISource: UsageSource {
    private var resolved: ClaudeBinary?
    private var resolvedAt = Date.distantPast

    func fetch() async throws -> [LimitRow] {
        let binary = try await resolve()
        let arguments = [
            "-p", "/usage",
            "--output-format", "stream-json", "--verbose",
            "--no-session-persistence",
            // Skip hooks, plugins and MCP servers: we only want the local /usage command.
            "--setting-sources", "",
            "--strict-mcp-config",
        ]
        let result = try await ProcessRunner.run(binary.url, arguments, timeout: 45)
        do {
            return try UsageReportParser.parse(result.output, cliVersion: binary.versionString)
        } catch UsageError.notSignedIn {
            throw UsageError.notSignedIn(claude: binary.url)
        } catch UsageError.unsupportedCLI(let version) {
            // No report at all: either the CLI has no plan login, or it predates usage_report.
            if try await !isSignedInToPlan(binary) { throw UsageError.notSignedIn(claude: binary.url) }
            resolved = nil  // look for a newer binary next time
            if result.status != 0 {
                // Not the CLI's own output: its sign-in diagnostics can hold account details.
                throw UsageError.cliFailed("Claude Code exited with status \(result.status). Check its login with `claude auth status`.")
            }
            throw UsageError.unsupportedCLI(version: version)
        }
    }

    private func isSignedInToPlan(_ binary: ClaudeBinary) async throws -> Bool {
        struct Status: Decodable { let loggedIn: Bool; let authMethod: String? }
        let result = try await ProcessRunner.run(binary.url, ["auth", "status"], timeout: 15)
        guard let status = try? JSONDecoder().decode(Status.self, from: result.output) else { return true }
        return status.loggedIn && status.authMethod == "claude.ai"
    }

    /// Finds the newest `claude` binary, re-checking hourly so updates are picked up.
    private func resolve() async throws -> ClaudeBinary {
        if let resolved, Date().timeIntervalSince(resolvedAt) < 3600 { return resolved }
        guard let best = await ClaudeBinary.newest() else { throw UsageError.cliNotFound }
        resolved = best
        resolvedAt = Date()
        return best
    }
}

/// A `claude` binary and the version it reports. The usage check and Sign in both run the one
/// `newest()` finds.
struct ClaudeBinary: Sendable {
    let url: URL
    let version: [Int]
    let versionString: String?

    /// The newest of the candidates that runs, or nil when none does.
    static func newest(among candidates: [URL] = candidates()) async -> ClaudeBinary? {
        var best: ClaudeBinary?
        for url in candidates {
            guard let result = try? await ProcessRunner.run(url, ["--version"], timeout: 15),
                  result.status == 0 else { continue }
            let text = String(decoding: result.output, as: UTF8.self)
            let versionString = text.split(separator: " ").first.map(String.init)
            let version = versionString?.split(separator: ".").compactMap { Int($0) } ?? []
            if best.map({ $0.version.lexicographicallyPrecedes(version) }) ?? true {
                best = ClaudeBinary(url: url, version: version, versionString: versionString)
            }
        }
        return best
    }

    /// The binary set in the claudePath setting, else those in the usual places and the desktop
    /// app's own copies. A setting whose binary is gone is passed over, so a fresh install (Install
    /// Claude Code) is still found.
    static func candidates() -> [URL] {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "claudePath"), !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if fm.isExecutableFile(atPath: url.path) { return [url] }
        }

        let home = fm.homeDirectoryForCurrentUser
        var urls = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].map { URL(fileURLWithPath: $0) }
        urls += [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude"].map { home.appending(path: $0) }

        // The Claude desktop app ships its own copy at claude-code/<version>/<build>/claude.app.
        let bundled = home.appending(path: "Library/Application Support/Claude/claude-code")
        for version in (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [] {
            let versionDir = bundled.appending(path: version)
            for build in (try? fm.contentsOfDirectory(atPath: versionDir.path)) ?? [] {
                urls.append(versionDir.appending(path: "\(build)/claude.app/Contents/MacOS/claude"))
            }
        }
        return urls.filter { fm.isExecutableFile(atPath: $0.path) }
    }
}

enum ProcessRunner {
    struct Result: Sendable { let status: Int32; let output: Data }

    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        var hasExpired: Bool { lock.withLock { expired } }

        func terminate(_ process: Process) {
            lock.withLock {
                guard process.isRunning else { return }
                expired = true
                process.terminate()
            }
        }
    }

    /// The environment for the CLI: without what a parent Claude Code session exports, so the
    /// CLI uses its own login, and with a PATH for apps launched from Finder, which get a minimal one.
    static func environment(inheriting inherited: [String: String]) -> [String: String] {
        var environment = inherited.filter { key, _ in
            key == "CLAUDE_CONFIG_DIR" || !(key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC_"))
        }
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                               environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        return environment
    }

    /// Runs a process with stdout and stderr merged, killing it after `timeout` seconds.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.environment = environment(inheriting: ProcessInfo.processInfo.environment)

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let deadline = Deadline()
                let killer = DispatchWorkItem { deadline.terminate(process) }
                let forceKiller = DispatchWorkItem {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // A subprocess may ignore SIGTERM; it still must not block later polls.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1, execute: forceKiller)
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                forceKiller.cancel()

                if deadline.hasExpired || process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: UsageError.timedOut)
                } else {
                    continuation.resume(returning: Result(status: process.terminationStatus, output: output))
                }
            }
        }
    }
}

/// Fixed sample data for `--demo` and `--render-preview`.
struct DemoSource: UsageSource {
    static func rows(now: Date = Date()) -> [LimitRow] {
        let iso = ISO8601DateFormatter()
        func row(_ kind: String, _ group: String, _ percent: Double, resetsIn: TimeInterval,
                 model: String? = nil, severity: String = "normal", active: Bool = false) -> LimitRow {
            LimitRow(kind: kind, group: group, percent: percent,
                     resetsAt: iso.string(from: now.addingTimeInterval(resetsIn)),
                     scope: model.map { LimitRow.Scope(model: .init(displayName: $0), surface: nil) },
                     severity: severity, isActive: active)
        }
        return [
            row("session", "session", 62, resetsIn: 108 * 60, severity: "warning", active: true),
            row("weekly_all", "weekly", 31, resetsIn: 53 * 3600),
            row("weekly_scoped", "weekly", 4, resetsIn: 53 * 3600, model: "Fable"),
        ]
    }

    /// History that gives the demo a recent pace: 26 %/h for the session, 8 %/day for the week.
    static func history(now: Date = Date()) -> History {
        var history = History()
        let meters = rows(now: now).map(Meter.init)
        for minutesAgo in stride(from: 13 * 60, through: 0, by: -2) {
            let t = now.addingTimeInterval(-Double(minutesAgo) * 60)
            for meter in meters {
                let percent: Double
                switch meter.id {
                case "session":
                    // The window opened 192 minutes ago: a first burst, a break, a steady stretch,
                    // then the last 40 minutes at 26 %/h.
                    guard minutesAgo <= 190 else { continue }
                    let m = Double(minutesAgo)
                    percent = switch minutesAgo {
                    case ...40: (62 - m * 26 / 60).rounded()
                    case ..<110: (20 + (110 - m) / 70 * 24).rounded()
                    case ..<140: 20
                    default: ((190 - m) / 50 * 20).rounded()
                    }
                case "weekly_all":
                    percent = (31 - Double(minutesAgo) / 60 * 8 / 24).rounded()
                default:
                    percent = meter.percent
                }
                history.record(meter, at: t, percent: percent)
            }
        }
        return history
    }

    /// Two weeks of past 5-hour windows: recorded ones with readings and sessions, some running
    /// into the limit, and the oldest estimated from transcripts.
    static func archive(now: Date = Date()) -> WindowArchive {
        var generator = SeededGenerator(seed: 11)
        // About what the demo sessions burn per 1% of the current window.
        let perPercent = 2.6e6
        let names = [("Dev documentation for the API", "api-server"), ("Named entity recognition fixes", "nlp-lab"),
                     ("Claude usage API widget", "ai-tempomat"), ("Local LLM endpoint usage", "llm-proxy"),
                     ("Grant proposal figures", "grant-proposal"), ("Replication package", "eeg-study")]
        // Percent of the limit each window's sessions asked for, newest first; past 100 runs into the limit.
        let targets: [Double] = [88, 46, 118, 72, 31, 95, 64, 125, 54, 12, 81, 38, 69, 22, 90, 57]
        // What a turn was asked, the task it worked on, and the subagents it may hand work to.
        let prompts = ["why is the export so slow? profile it", "write tests for the parser", "review the open PR and fix what you find",
                       "summarize the results into the report", "refactor the session store", "go with your recommendations"]
        let subjects = ["Profile the export", "Write the parser tests", "Fix the review findings", "Draft the results section",
                        "Refactor the store", "Apply the recommendations"]
        let loners = ["Explore: Find the slow query", "general-purpose: Audit the test suite", "Plan: Design the cache"]
        let workflows = [("review-changes", ["Review: review:correctness", "Review: review:tests", "Review: review:docs", "Verify: verify:findings"]),
                         ("build-report", ["Build: build:figures", "Build: build:tables", "Build: build:text", "Critic: critic"])]
        var archive = WindowArchive()
        // The current demo window opened 192 minutes ago.
        var reset = now.addingTimeInterval(-(192 + 25) * 60)
        for (index, target) in targets.enumerated() {
            let start = reset.addingTimeInterval(-5 * 3600)
            /// Each request with its session, and its subagent if it isn't the main agent's.
            var tagged: [(session: Int, agent: Int?, request: FleetSession.Request)] = []
            let count = Int.random(in: 1...3, using: &generator)
            var asked = [[FleetSession.Prompt]](repeating: [], count: count)
            var tasks = [[FleetSession.TaskSpan]](repeating: [], count: count)
            var agents = [[(label: String, workflow: String?)]](repeating: [], count: count)
            func burn(_ session: Int, agent: Int?, from: Double, to end: Double, size: ClosedRange<Int>) {
                var t = from
                while t < end {
                    let total = Int.random(in: size, using: &generator)
                    tagged.append((session, agent, .init(t: start.addingTimeInterval(t), total: total, output: total / 80)))
                    t += Double.random(in: 10...40, using: &generator)
                }
            }
            for session in 0..<count {
                for _ in 0..<Int.random(in: 1...3, using: &generator) {
                    let from = Double.random(in: 0...4, using: &generator) * 3600
                    let end = min(from + Double.random(in: 0.3...1.5, using: &generator) * 3600, 5 * 3600)
                    let topic = Int.random(in: 0..<prompts.count, using: &generator)
                    asked[session].append(.init(t: start.addingTimeInterval(from), text: prompts[topic]))
                    tasks[session].append(.init(subject: subjects[topic], start: start.addingTimeInterval(from + 60),
                                                end: start.addingTimeInterval(end)))
                    burn(session, agent: nil, from: from, to: end, size: 10_000...40_000)
                    // Some turns hand work to subagents: a workflow's, several at once, or one alone.
                    switch Int.random(in: 0...2, using: &generator) {
                    case 0:
                        let (name, labels) = workflows[Int.random(in: 0..<workflows.count, using: &generator)]
                        let at = from + (end - from) * 0.3
                        for label in labels {
                            agents[session].append((label, name))
                            burn(session, agent: agents[session].count - 1, from: at, to: min(end, at + 20 * 60), size: 15_000...45_000)
                        }
                    case 1:
                        agents[session].append((loners[Int.random(in: 0..<loners.count, using: &generator)], nil))
                        burn(session, agent: agents[session].count - 1, from: from + 120, to: min(end, from + 15 * 60), size: 10_000...30_000)
                    default:
                        break
                    }
                }
            }
            // Scaled to the target; nothing gets through once the limit is reached.
            tagged.sort { $0.request.t < $1.request.t }
            let factor = target * perPercent / Double(max(1, tagged.reduce(0) { $0 + $1.request.total }))
            var used = 0.0
            var samples: [History.Sample] = []
            var kept: [(session: Int, agent: Int?, request: FleetSession.Request)] = []
            var next = 0
            for minute in stride(from: 0.0, through: 300, by: 2) {
                let t = start.addingTimeInterval(minute * 60)
                while next < tagged.count, tagged[next].request.t <= t {
                    let request = tagged[next].request
                    let total = Int(Double(request.total) * factor)
                    if used < 100 * perPercent {
                        used += Double(total)
                        kept.append((tagged[next].session, tagged[next].agent, .init(t: request.t, total: total, output: total / 80)))
                    }
                    next += 1
                }
                samples.append(.init(t: t, p: min(100, (used / perPercent).rounded(.down))))
            }
            let sessions = (0..<count).map { session in
                let own = kept.filter { $0.session == session }
                return SessionRequests(id: "demo-\(index)-\(session)", name: names[(index + session) % names.count].0,
                                       project: names[(index + session) % names.count].1,
                                       requests: own.map(\.request), prompts: asked[session], tasks: tasks[session],
                                       agents: agents[session].enumerated().map { agent, info in
                                           AgentRequests(label: info.label, workflow: info.workflow,
                                                         requests: own.filter { $0.agent == agent }.map(\.request))
                                       })
            }
            let source: PastWindow.Source = index >= 12 ? .estimated : .recorded
            archive.add(PastWindow(meter: PastWindow.sessionMeter, start: start, reset: reset, source: source,
                                   samples: source == .recorded ? PastWindow.thin(samples, over: 5 * 3600) : [],
                                   sessions: sessions))
            reset = start.addingTimeInterval(-Double.random(in: 0.5...9, using: &generator) * 3600)
        }
        return archive
    }

    func fetch() async throws -> [LimitRow] { Self.rows() }
}
