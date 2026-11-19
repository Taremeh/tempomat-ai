import Foundation
import Testing
@testable import AITempomat

/// Two desktop app instances, each signed in to its own account, run Claude Code in the same
/// default folder, beside a terminal session.
@Suite struct SessionScopeTests {
    @Test func sessionsCountForTheLoginClaudeUses() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let personal = fixture.scope(settings: fixture.personalSettings)
        #expect(fixture.sessions(in: personal) == [fixture.personalDesktop, fixture.terminal].sorted())
        let requests = FleetScanner.sessionRequests(in: personal, since: .distantPast)
        #expect(Set(requests.map(\.id)) == [fixture.personalDesktop, fixture.terminal])

        // A running session the desktop app hasn't named in its record yet goes by the app's own id.
        let filter = personal.filter()
        #expect(!filter.includes(UUID().uuidString.lowercased(), host: "local_work"))
        #expect(filter.includes(UUID().uuidString.lowercased(), host: "local_personal"))
        #expect(filter.isForeign(fixture.workDesktop))
        #expect(!filter.isForeign(fixture.personalDesktop))
        #expect(!filter.isForeign(fixture.terminal))
    }

    @Test func signingClaudeInToAnotherAccountFollowsIt() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let work = fixture.scope(settings: fixture.workSettings)
        #expect(fixture.sessions(in: work) == [fixture.workDesktop, fixture.terminal].sorted())
        let files = FleetScanner.transcripts(in: work, modifiedSince: .distantPast)
        #expect(files.contains { $0.session == fixture.workDesktop && $0.isSubagent })
        let requests = FleetScanner.sessionRequests(in: work, since: .distantPast)
        #expect(requests.first { $0.id == fixture.workDesktop }?.requests.count == 2)
    }

    @Test func unknownLoginKeepsEverySession() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let everything = [fixture.personalDesktop, fixture.workDesktop, fixture.terminal].sorted()
        let signedOut = fixture.scope(settings: fixture.root.appending(path: "missing.json"))
        #expect(fixture.sessions(in: signedOut) == everything)
        #expect(!signedOut.filter().isForeign(fixture.workDesktop))
        let unscoped = SessionScope(folder: fixture.defaultFolder)
        #expect(fixture.sessions(in: unscoped) == everything)
    }

    @Test func standardScopeReadsClaudesDefaultLogin() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(SessionScope.standard.folder.path == home.appending(path: ".claude").path)
        #expect(SessionScope.standard.settingsFile == home.appending(path: ".claude.json"))
    }

    @Test func desktopSessionsKeepTheirLoginWhenTheRecordMovesOn() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let logins = fixture.logins
        #expect(logins.desktopSessions()[fixture.workDesktop] == fixture.workLogin)
        // The app points its record at a new Claude Code session (after /clear, say).
        let next = UUID().uuidString.lowercased()
        try fixture.writeRecord("local_work", session: next, under: fixture.workLogin, in: fixture.workDesktopFolder,
                                modified: Date().addingTimeInterval(60))
        let sessions = logins.desktopSessions()
        #expect(sessions[next] == fixture.workLogin)
        #expect(sessions[fixture.workDesktop] == fixture.workLogin)
        #expect(sessions["local_work"] == fixture.workLogin)
    }

    /// Newer desktop apps file a copy of every record under each login they've been signed in to.
    @Test func recordsUnderEveryLoginTellNothingButTheProcessDoes() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.writeRecord("local_work", session: fixture.workDesktop, under: fixture.personalLogin,
                                in: fixture.personalDesktopFolder)
        let personal = fixture.scope(settings: fixture.personalSettings)
        #expect(fixture.logins.desktopSessions()[fixture.workDesktop] == nil)
        #expect(personal.filter().includes(fixture.workDesktop))

        // While it runs, its process says it was started on the work account.
        personal.learn(fixture.workDesktop, host: "local_work", startedOn: fixture.workLogin)
        #expect(personal.filter().isForeign(fixture.workDesktop))
        #expect(!personal.filter().includes(UUID().uuidString.lowercased(), host: "local_work"))
        #expect(personal.filter().ranOn(fixture.workDesktop) == fixture.workLogin)
    }

    @Test func runningLoginsTellTheOtherAccountsApart() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let workOtherOrg = try #require(ClaudeLogin(account: fixture.workLogin.account, organization: UUID().uuidString))
        var logins = RunningLogins(claude: fixture.personalLogin,
                                   started: [fixture.personalLogin: 2, fixture.workLogin: 3, workOtherOrg: 1])
        #expect(logins.elsewhere.map(\.login) == [fixture.workLogin, workOtherOrg])
        #expect(logins.elsewhere.map(\.sessions) == [3, 1])
        #expect(logins.busiest == fixture.workLogin)
        logins.claude = nil
        #expect(logins.elsewhere.isEmpty)
    }

    @Test func emailIsNotPartOfTheLogin() throws {
        let account = UUID().uuidString
        let named = try #require(ClaudeLogin(account: account, organization: nil, email: "a@example.com"))
        #expect(named == ClaudeLogin(account: account, organization: nil))
        #expect(named.email == "a@example.com")
        #expect(ClaudeLogin(account: account, organization: nil, email: "not an email")?.email == nil)
    }

    /// The layout `KERN_PROCARGS2` gives: argc, the executable, padding, the arguments, the environment.
    @Test func startedLoginComesFromTheEnvironmentOnly() throws {
        let account = UUID().uuidString.lowercased(), organization = UUID().uuidString.lowercased()
        func bytes(_ argc: Int32, _ strings: [String], padding: Int = 3) -> ArraySlice<UInt8> {
            var data = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
            data += Array(strings[0].utf8) + [UInt8](repeating: 0, count: padding)
            for string in strings.dropFirst() { data += Array(string.utf8) + [0] }
            return data[...]
        }
        let started = ClaudeLogin.started(from: bytes(2, [
            "/path/claude", "claude", "CLAUDE_CODE_ACCOUNT_UUID=\(UUID().uuidString)",
            "HOME=/Users/me", "CLAUDE_CODE_ACCOUNT_UUID=\(account)", "CLAUDE_CODE_ORGANIZATION_UUID=\(organization)",
            "CLAUDE_CODE_USER_EMAIL=me@example.com", "", "garbage",
        ]))
        #expect(started == ClaudeLogin(account: account, organization: organization))
        #expect(started?.email == "me@example.com")
        #expect(ClaudeLogin.started(from: bytes(1, ["/path/claude", "claude", "HOME=/Users/me"])) == nil)
        #expect(ClaudeLogin.started(from: [1, 0][...]) == nil)
    }

    /// macOS hides the environment of its own binaries, so the process is a re-signed copy of sleep.
    /// GitHub's hosted runners don't let a process read another one's environment, so this runs locally only.
    @Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "hosted CI runners hide other processes' environments"))
    func startedLoginReadsARunningProcess() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AITempomatProcessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleep = folder.appending(path: "sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
        for arguments in [["--remove-signature", sleep.path], ["-s", "-", sleep.path]] {
            let codesign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: arguments)
            codesign.waitUntilExit()
            try #require(codesign.terminationStatus == 0)
        }

        let account = UUID().uuidString.lowercased()
        let process = Process()
        process.executableURL = sleep
        process.arguments = ["5"]
        process.environment = ["CLAUDE_CODE_ACCOUNT_UUID": account, "CLAUDE_CODE_USER_EMAIL": "me@example.com"]
        try process.run()
        defer { process.terminate() }
        let started = ClaudeLogin.running(pid: process.processIdentifier)
        #expect(started == ClaudeLogin(account: account, organization: nil))
        #expect(started?.email == "me@example.com")
        #expect(ClaudeLogin.running(pid: -1) == nil)
    }

    @Test func loginsMatchByAccountAndKnownOrganization() throws {

        let account = UUID().uuidString, organization = UUID().uuidString, other = UUID().uuidString
        let login = try #require(ClaudeLogin(account: account, organization: organization))
        #expect(login.account == account.lowercased())
        #expect(login.matches(try #require(ClaudeLogin(account: account.lowercased(), organization: nil))))
        #expect(login.matches(try #require(ClaudeLogin(account: account, organization: organization.lowercased()))))
        #expect(!login.matches(try #require(ClaudeLogin(account: account, organization: other))))
        #expect(!login.matches(try #require(ClaudeLogin(account: other, organization: organization))))
        #expect(ClaudeLogin(account: "not-an-account", organization: organization) == nil)
        #expect(ClaudeLogin(account: account, organization: "not-an-organization")?.organization == nil)
    }

    @Test func removingSessionsTakesOutTheirTokens() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = start.addingTimeInterval(5 * 3600)
        func session(_ id: String, tokens: Int) -> SessionRequests {
            SessionRequests(id: id, name: id, project: "p", requests: [.init(t: start.addingTimeInterval(600), total: tokens, output: 1)])
        }
        let samples = [History.Sample(t: start.addingTimeInterval(900), p: 10)]
        var archive = WindowArchive()
        archive.add(PastWindow(meter: PastWindow.sessionMeter, start: start, reset: reset, source: .recorded, samples: samples,
                               sessions: [session("own", tokens: 1000), session("foreign", tokens: 3000)]))
        #expect(archive.windows[0].tokensPerPercent == 400)
        #expect(archive.removeSessions { $0 == "foreign" })
        #expect(archive.windows[0].sessions.map(\.id) == ["own"])
        #expect(archive.windows[0].tokens == 1000)
        #expect(archive.windows[0].tokensPerPercent == 100)
        #expect(!archive.removeSessions { $0 == "foreign" })
    }

    @Test @MainActor func savedWindowsLoseAnotherLoginsSessions() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let start = Date().addingTimeInterval(-6 * 3600)
        let requests = [FleetSession.Request(t: start.addingTimeInterval(60), total: 500, output: 5)]
        var archive = WindowArchive()
        archive.add(PastWindow(meter: PastWindow.sessionMeter, start: start, reset: start.addingTimeInterval(5 * 3600),
                               source: .recorded, samples: [.init(t: start.addingTimeInterval(120), p: 20)],
                               sessions: [SessionRequests(id: fixture.workDesktop, requests: requests),
                                          SessionRequests(id: fixture.personalDesktop, requests: requests)]))
        let data = fixture.root.appending(path: "data")
        let file = data.appending(path: "windows.json")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: file)

        let scope = fixture.scope(settings: fixture.personalSettings)
        let store = UsageStore(source: DemoSource(), persist: true, transcripts: scope, dataFolder: data)
        #expect(store.archive.windows[0].sessions.map(\.id) == [fixture.personalDesktop])
        let saved = try JSONDecoder().decode(WindowArchive.self, from: Data(contentsOf: file))
        #expect(saved.windows[0].sessions.map(\.id) == [fixture.personalDesktop])
        #expect(saved.windows[0].tokens == 500)
    }
}

private struct SessionFixture {
    let root: URL
    /// Claude Code's default folder, where both desktop instances keep their sessions.
    let defaultFolder: URL
    let personalSettings: URL
    let workSettings: URL
    let personalDesktopFolder: URL
    let workDesktopFolder: URL
    let personalLogin = ClaudeLogin(account: UUID().uuidString, organization: UUID().uuidString)!
    let workLogin = ClaudeLogin(account: UUID().uuidString, organization: UUID().uuidString)!
    let personalDesktop = UUID().uuidString.lowercased()
    let workDesktop = UUID().uuidString.lowercased()
    let terminal = UUID().uuidString.lowercased()
    let logins: ClaudeLogins

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AITempomatSessionTests-\(UUID().uuidString)")
        defaultFolder = root.appending(path: "claude")
        personalSettings = root.appending(path: "claude.json")
        workSettings = root.appending(path: "claude-work.json")
        personalDesktopFolder = root.appending(path: "Claude")
        workDesktopFolder = root.appending(path: "Claude-Work")
        let desktops = [personalDesktopFolder, workDesktopFolder]
        logins = ClaudeLogins(desktopFolders: { desktops })

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try settings(for: personalLogin).write(to: personalSettings)
        try settings(for: workLogin).write(to: workSettings)
        try writeRecord("local_personal", session: personalDesktop, under: personalLogin, in: personalDesktopFolder)
        try writeRecord("local_work", session: workDesktop, under: workLogin, in: workDesktopFolder)
        for session in [personalDesktop, workDesktop, terminal] {
            try transcript(session, in: defaultFolder)
        }
        try transcript("agent-a", in: defaultFolder, under: "\(workDesktop)/subagents")
    }

    func scope(settings: URL) -> SessionScope {
        SessionScope(folder: defaultFolder, settingsFile: settings, logins: logins)
    }

    /// The sessions whose transcripts count for `scope`.
    func sessions(in scope: SessionScope) -> [String] {
        Set(FleetScanner.transcripts(in: scope, modifiedSince: .distantPast).map(\.session)).sorted()
    }

    func writeRecord(_ host: String, session: String, under login: ClaudeLogin, in desktop: URL,
                     modified: Date? = nil) throws {
        let folder = desktop.appending(path: "claude-code-sessions/\(login.account)/\(login.organization!)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = folder.appending(path: "\(host).json")
        try JSONSerialization.data(withJSONObject: ["sessionId": host, "cliSessionId": session, "title": "t"]).write(to: record)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: record.path) }
    }

    private func settings(for login: ClaudeLogin) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "oauthAccount": ["accountUuid": login.account, "organizationUuid": login.organization!, "emailAddress": "x@example.com"],
        ])
    }

    private func transcript(_ name: String, in claudeDir: URL, under subfolder: String? = nil) throws {
        var folder = claudeDir.appending(path: "projects/-Users-me-project")
        if let subfolder { folder = folder.appending(path: subfolder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t = ISO8601DateFormatter().string(from: Date())
        let line = #"{"type":"assistant","timestamp":"\#(t)","message":{"id":"msg_\#(name)","usage":{"input_tokens":10,"output_tokens":5}}}"#
        try Data((line + "\n").utf8).write(to: folder.appending(path: "\(name).jsonl"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
