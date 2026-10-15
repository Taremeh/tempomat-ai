import Foundation
import Testing
@testable import AITempomat

/// Two desktop app instances, each signed in to its own account, run Claude Code in the same
/// default folder; a terminal login in a folder of its own runs on the second account too.
@Suite struct SessionScopeTests {
    @Test func desktopSessionsCountForTheLoginTheyRanOn() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let personal = fixture.scope(folder: fixture.defaultFolder, settings: fixture.personalSettings)
        let work = fixture.scope(folder: fixture.workFolder, settings: fixture.workFolder.appending(path: ".claude.json"))
        #expect(personal.folders.map(\.path) == [fixture.defaultFolder.path])
        #expect(work.folders.map(\.path) == [fixture.workFolder.path, fixture.defaultFolder.path])

        #expect(fixture.sessions(in: personal) == [fixture.personalDesktop, fixture.terminal].sorted())
        #expect(fixture.sessions(in: work) == [fixture.workDesktop, fixture.workTerminal].sorted())
        let workFiles = FleetScanner.transcripts(in: work, modifiedSince: .distantPast)
        #expect(workFiles.contains { $0.session == fixture.workDesktop && $0.isSubagent })
        let requests = FleetScanner.sessionRequests(in: work, since: .distantPast)
        #expect(Set(requests.map(\.id)) == [fixture.workDesktop, fixture.workTerminal])
        #expect(requests.first { $0.id == fixture.workDesktop }?.requests.count == 2)

        // A running session the desktop app hasn't named in its record yet goes by the app's own id.
        let filter = work.filter()
        #expect(filter.includes(UUID().uuidString.lowercased(), host: "local_work", in: fixture.defaultFolder))
        #expect(!personal.filter().includes(UUID().uuidString.lowercased(), host: "local_work", in: fixture.defaultFolder))
        #expect(filter.isForeign(fixture.personalDesktop))
        #expect(!filter.isForeign(fixture.workDesktop))
        #expect(!filter.isForeign(fixture.terminal))
    }

    @Test func unknownLoginKeepsEverySessionInItsFolder() throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let everything = [fixture.personalDesktop, fixture.workDesktop, fixture.terminal].sorted()
        let signedOut = fixture.scope(folder: fixture.defaultFolder, settings: fixture.root.appending(path: "missing.json"))
        #expect(fixture.sessions(in: signedOut) == everything)
        #expect(!signedOut.filter().isForeign(fixture.workDesktop))
        let unscoped = SessionScope(folder: fixture.defaultFolder)
        #expect(fixture.sessions(in: unscoped) == everything)
        // Signed out elsewhere, a profile has only the sessions in its own folder.
        let workSignedOut = fixture.scope(folder: fixture.workFolder, settings: fixture.root.appending(path: "missing.json"))
        #expect(fixture.sessions(in: workSignedOut) == [fixture.workTerminal])
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

    @Test func cliProfilesReadTheirOwnLogin() {
        let original = UsageProfile.originalCLI
        #expect(original.cliSettingsFile == FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json"))
        #expect(original.sessionScope?.folders.map(\.path) == [FleetScanner.defaultClaudeDir.path])
        let work = UsageProfile(name: "Work", provider: .claudeCLI, path: "/tmp/claude-work")
        #expect(work.cliSettingsFile.path == "/tmp/claude-work/.claude.json")
        #expect(work.sessionScope?.folders.map(\.path) == ["/tmp/claude-work", FleetScanner.defaultClaudeDir.path])
        #expect(UsageProfile(name: "Desktop", provider: .claudeDesktop, path: "/tmp/Claude").sessionScope == nil)
        #expect(UsageProfile(name: "Codex", provider: .codex, path: "~/.codex").sessionScope == nil)
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
        let file = data.appending(path: "profiles/personal/windows.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: file)

        let suite = "SessionScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = fixture.scope(folder: fixture.defaultFolder, settings: fixture.personalSettings)
        let store = UsageStore(source: DemoSource(), persist: true, transcripts: scope, storageID: "personal",
                               dataFolder: data, defaults: defaults)
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
    let workFolder: URL
    let personalSettings: URL
    let personalDesktopFolder: URL
    let workDesktopFolder: URL
    let personalLogin = ClaudeLogin(account: UUID().uuidString, organization: UUID().uuidString)!
    let workLogin = ClaudeLogin(account: UUID().uuidString, organization: UUID().uuidString)!
    let personalDesktop = UUID().uuidString.lowercased()
    let workDesktop = UUID().uuidString.lowercased()
    let terminal = UUID().uuidString.lowercased()
    let workTerminal = UUID().uuidString.lowercased()
    let logins: ClaudeLogins

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AITempomatSessionTests-\(UUID().uuidString)")
        defaultFolder = root.appending(path: "claude")
        workFolder = root.appending(path: "claude-work")
        personalSettings = root.appending(path: "claude.json")
        personalDesktopFolder = root.appending(path: "Claude")
        workDesktopFolder = root.appending(path: "Claude-Work")
        let desktops = [personalDesktopFolder, workDesktopFolder]
        logins = ClaudeLogins(desktopFolders: { desktops })

        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        try settings(for: personalLogin).write(to: personalSettings)
        try settings(for: workLogin).write(to: workFolder.appending(path: ".claude.json"))
        try writeRecord("local_personal", session: personalDesktop, under: personalLogin, in: personalDesktopFolder)
        try writeRecord("local_work", session: workDesktop, under: workLogin, in: workDesktopFolder)
        for session in [personalDesktop, workDesktop, terminal] {
            try transcript(session, in: defaultFolder)
        }
        try transcript(workTerminal, in: workFolder)
        try transcript("agent-a", in: defaultFolder, under: "\(workDesktop)/subagents")
    }

    func scope(folder: URL, settings: URL) -> SessionScope {
        SessionScope(folder: folder, settingsFile: settings, desktopFolder: defaultFolder, logins: logins)
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
