import Foundation
import Testing
@testable import AITempomat

/// The daily update check: the flags that count active users without an ID, the request it
/// sends, how it reads the answer, and the update it runs.
@Suite struct UpdateCheckTests {
    // MARK: Flags

    @Test func firstCheckCountsEverything() {
        #expect(CheckFlags(lastCounted: nil, now: utc(2026, 10, 26, 9)) == CheckFlags(day: true, week: true, month: true, first: true))
    }

    @Test func secondCheckOfTheDayCountsNothing() {
        #expect(CheckFlags(lastCounted: utc(2026, 10, 26, 0, 0), now: utc(2026, 10, 26, 23, 59)) == .none)
    }

    @Test func nextDayInTheSameWeekAndMonth() {
        // Tuesday, then Wednesday.
        #expect(CheckFlags(lastCounted: utc(2026, 10, 27, 23), now: utc(2026, 10, 28, 1))
                == CheckFlags(day: true, week: false, month: false, first: false))
    }

    @Test func mondayStartsAWeek() {
        // Sunday night, then Monday morning.
        #expect(CheckFlags(lastCounted: utc(2026, 10, 25, 23), now: utc(2026, 10, 26, 1))
                == CheckFlags(day: true, week: true, month: false, first: false))
    }

    @Test func monthBoundaryInsideAWeek() {
        // Wednesday 30 September, then Thursday 1 October.
        #expect(CheckFlags(lastCounted: utc(2026, 9, 30, 12), now: utc(2026, 10, 1, 12))
                == CheckFlags(day: true, week: false, month: true, first: false))
    }

    @Test func weeksFollowTheISOYear() {
        // 31 December 2026 and 2 January 2027 are both in ISO week 53 of 2026.
        #expect(CheckFlags(lastCounted: utc(2026, 12, 31, 12), now: utc(2027, 1, 2, 12))
                == CheckFlags(day: true, week: false, month: true, first: false))
        // Monday 4 January starts week 1 of 2027.
        #expect(CheckFlags(lastCounted: utc(2027, 1, 3, 12), now: utc(2027, 1, 4, 12))
                == CheckFlags(day: true, week: true, month: false, first: false))
        // Monday 30 December 2024 is already in week 1 of 2025.
        #expect(CheckFlags(lastCounted: utc(2024, 12, 30, 12), now: utc(2025, 1, 1, 12))
                == CheckFlags(day: true, week: false, month: true, first: false))
    }

    @Test func daysAreUTCWhateverTheTimeZone() throws {
        // The same day in Kiritimati (UTC+14) is two days in UTC.
        let kiritimati = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        #expect(CheckFlags(lastCounted: date(2026, 10, 26, 1, in: kiritimati), now: date(2026, 10, 26, 23, in: kiritimati)).day)
        // Sunday night and Monday morning in Los Angeles (UTC-7) are both Monday in UTC.
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(CheckFlags(lastCounted: date(2026, 10, 25, 22, in: losAngeles), now: date(2026, 10, 26, 1, in: losAngeles)) == .none)
    }

    // MARK: Request

    @Test func requestCarriesTheVersionsAndFlagsOnly() throws {
        let build = BuildInfo(version: "0.2", build: 2, sourceFolder: URL(fileURLWithPath: "/Users/someone/ai-tempomat"), branch: "main")
        let base = try #require(URL(string: "https://tempomat-ai.example.workers.dev/v1/check?ref=old"))
        let url = try #require(UpdateCheck.requestURL(base, build: build, os: "15.1",
                                                      flags: CheckFlags(day: true, week: false, month: true, first: false)))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "tempomat-ai.example.workers.dev")
        #expect(components.path == "/v1/check")
        #expect(components.queryItems == [
            URLQueryItem(name: "v", value: "0.2"), URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "os", value: "15.1"),
            URLQueryItem(name: "branch", value: "main"), URLQueryItem(name: "day", value: "1"), URLQueryItem(name: "week", value: "0"),
            URLQueryItem(name: "month", value: "1"), URLQueryItem(name: "first", value: "0"),
        ])
        #expect(!url.absoluteString.contains("someone"))
    }

    @Test func onlyAReleaseBranchNameIsSent() throws {
        let base = try #require(URL(string: "https://example.test/v1/check"))
        func branch(_ name: String?) -> String? {
            let url = UpdateCheck.requestURL(base, build: BuildInfo(version: "0.2", build: 2, branch: name), os: "26.0", flags: .none)
            return url.flatMap { Self.query($0)["branch"] }
        }
        #expect(branch("main") == "main")
        #expect(branch("multi-profile") == "multi-profile")
        #expect(branch("tarek/secret-client-work") == "")
        #expect(branch("HEAD") == "")
        #expect(branch(nil) == "")
    }

    @Test func requestEscapesWhatAServerWouldMisread() throws {
        let base = try #require(URL(string: "https://example.test/v1/check"))
        let url = try #require(UpdateCheck.requestURL(base, build: BuildInfo(version: "1.0+dev", build: 7), os: "26.0", flags: .none))
        #expect(url.query?.contains("v=1.0%2Bdev") == true)
        #expect(url.query?.contains("branch=&") == true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "v" }?.value == "1.0+dev")
    }

    @Test func buildInfoReadsWhatBuildAppWrites() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.3", "CFBundleVersion": "3", "AITCheckURL": "https://example.test/v1/check",
            "AITSourceFolder": "/Users/someone/ai tempomat", "AITSourceBranch": "multi-profile",
        ]
        let build = BuildInfo(info: info)
        #expect(build == BuildInfo(version: "0.3", build: 3, checkURL: URL(string: "https://example.test/v1/check"),
                                   sourceFolder: URL(fileURLWithPath: "/Users/someone/ai tempomat", isDirectory: true),
                                   branch: "multi-profile"))
        #expect(build.sourceFolder?.path == "/Users/someone/ai tempomat")
        #expect(!build.usesCheckURLOverride)
        let overridden = BuildInfo(info: info, checkURLOverride: "http://localhost:8787/v1/check")
        #expect(overridden.checkURL == URL(string: "http://localhost:8787/v1/check"))
        #expect(overridden.usesCheckURLOverride)
        // An empty or broken override leaves the app's own.
        #expect(BuildInfo(info: info, checkURLOverride: "").checkURL == build.checkURL)
        #expect(!BuildInfo(info: info, checkURLOverride: "ftp://example.test").usesCheckURLOverride)
        // An app built without a check URL never checks.
        let bare = BuildInfo(info: ["CFBundleVersion": "2"])
        #expect(bare.checkURL == nil && bare.sourceFolder == nil && bare.branch == nil && bare.build == 2)
    }

    // MARK: Answer

    @Test func releaseReadsAFullAnswer() {
        let body = #"{"version":"0.3","build":3,"notes":" Faster history. ","url":"https://example.test/notes"}"#
        #expect(Release.parse(Data(body.utf8))
                == Release(version: "0.3", build: 3, notes: "Faster history.", url: URL(string: "https://example.test/notes")))
    }

    @Test func emptyAnswerIsNoRelease() {
        #expect(Release.parse(Data("{}".utf8)) == nil)
        #expect(Release.parse(Data()) == nil)
        #expect(Release.parse(Data("<html>".utf8)) == nil)
    }

    @Test func badTypesAreNoReleaseOrLeftOut() {
        #expect(Release.parse(Data(#"{"version":"0.3","build":"3"}"#.utf8)) == nil)
        #expect(Release.parse(Data(#"{"version":3,"build":3}"#.utf8)) == nil)
        #expect(Release.parse(Data(#"{"version":"0.3","build":-1}"#.utf8)) == nil)
        #expect(Release.parse(Data(#"{"version":"","build":3}"#.utf8)) == nil)
        #expect(Release.parse(Data(#"{"version":"0.3","build":3,"notes":5,"url":"javascript:alert(1)"}"#.utf8))
                == Release(version: "0.3", build: 3))
    }

    @Test func newerMeansAHigherBuild() {
        let release = Release(version: "0.3", build: 3)
        #expect(release.isNewer(than: 2))
        #expect(!release.isNewer(than: 3))
        #expect(!release.isNewer(than: 4))
    }

    // MARK: Checker

    @MainActor @Test func onlyAnAnsweredCheckCountsTheDay() async throws {
        let host = "check-\(UUID().uuidString.prefix(8).lowercased()).test"
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(build: BuildInfo(version: "0.2", build: 2, checkURL: URL(string: "https://\(host)/v1/check")),
                                    defaults: defaults, session: StubProtocol.session)
        #expect(checker.checksForUpdates)
        let now = utc(2026, 10, 26, 9)

        // The server is down: nothing counted, so the next check is the first again.
        StubProtocol.answer(host, status: 503, body: "")
        await checker.check(now: now)
        #expect(defaults.object(forKey: SettingsKey.updateCheckCounted) == nil)
        StubProtocol.answer(host, status: 200, body: #"{"version":"0.3","build":3,"notes":"New."}"#)
        await checker.check(now: now.addingTimeInterval(3600))
        let counted = try #require(defaults.object(forKey: SettingsKey.updateCheckCounted) as? Date)
        #expect(abs(counted.timeIntervalSince(now.addingTimeInterval(3600))) < 0.001)
        #expect(checker.available == Release(version: "0.3", build: 3, notes: "New."))

        // Later that day an answer without a release keeps the one known; the day isn't counted again.
        StubProtocol.answer(host, status: 200, body: "{}")
        await checker.check(now: now.addingTimeInterval(7200))
        #expect(checker.available?.build == 3)
        let sent = StubProtocol.requests(to: host).map(Self.query)
        #expect(sent.map { $0["first"] } == ["1", "1", "0"])
        #expect(sent.map { $0["day"] } == ["1", "1", "0"])

        // Off: no update shown, nothing sent.
        checker.setChecksForUpdates(false)
        #expect(checker.available == nil)
        #expect(defaults.object(forKey: SettingsKey.checkForUpdates) as? Bool == false)
        await checker.check(now: now.addingTimeInterval(86400))
        #expect(StubProtocol.requests(to: host).count == 3)
    }

    @MainActor @Test func releaseNoNewerThanThisAppIsNoUpdate() async {
        let host = "same-\(UUID().uuidString.prefix(8).lowercased()).test"
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(build: BuildInfo(version: "0.3", build: 3, checkURL: URL(string: "https://\(host)/v1/check")),
                                    defaults: defaults, session: StubProtocol.session)
        StubProtocol.answer(host, status: 200, body: #"{"version":"0.3","build":3}"#)
        await checker.check()
        #expect(checker.available == nil)
        #expect(StubProtocol.requests(to: host).count == 1)
    }

    @MainActor @Test func turningChecksOffOutsideTheAppStopsTheNextCheck() async {
        let host = "off-\(UUID().uuidString.prefix(8).lowercased()).test"
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(build: BuildInfo(version: "0.2", build: 2, checkURL: URL(string: "https://\(host)/v1/check")),
                                    defaults: defaults, session: StubProtocol.session)
        StubProtocol.answer(host, status: 200, body: #"{"version":"0.3","build":3}"#)
        await checker.check(now: utc(2026, 10, 26, 9))
        #expect(checker.available?.build == 3)
        // `defaults write local.ai-tempomat checkForUpdates -bool false` while the app runs.
        defaults.set(false, forKey: SettingsKey.checkForUpdates)
        await checker.check(now: utc(2026, 10, 27, 9))
        #expect(!checker.checksForUpdates)
        #expect(checker.available == nil)
        #expect(StubProtocol.requests(to: host).count == 1)
        // Written without -bool, as a string.
        defaults.set("NO", forKey: SettingsKey.checkForUpdates)
        await checker.check(now: utc(2026, 10, 28, 9))
        #expect(StubProtocol.requests(to: host).count == 1)
        defaults.removeObject(forKey: SettingsKey.checkForUpdates)
        await checker.check(now: utc(2026, 10, 28, 10))
        #expect(checker.checksForUpdates)
        #expect(StubProtocol.requests(to: host).count == 2)
    }

    @MainActor @Test func aBranchOfYourOwnIsCountedButOffersNoRelease() async {
        let host = "own-\(UUID().uuidString.prefix(8).lowercased()).test"
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let build = BuildInfo(version: "0.2", build: 2, checkURL: URL(string: "https://\(host)/v1/check"),
                              sourceFolder: URL(fileURLWithPath: "/Users/someone/ai-tempomat"), branch: "experiment")
        let checker = UpdateChecker(build: build, defaults: defaults, session: StubProtocol.session)
        #expect(checker.installFolder == nil)
        StubProtocol.answer(host, status: 200, body: #"{"version":"0.3","build":3}"#)
        await checker.check()
        #expect(checker.available == nil)
        #expect(StubProtocol.requests(to: host).map(Self.query).first?["day"] == "1")
    }

    @MainActor @Test func aTestServerDoesNotUseUpTheAppsFlags() async {
        let host = "test-\(UUID().uuidString.prefix(8).lowercased()).test"
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let build = BuildInfo(info: ["CFBundleShortVersionString": "0.2", "CFBundleVersion": "2",
                                     "AITCheckURL": "https://app.example.test/v1/check"],
                              checkURLOverride: "https://\(host)/v1/check")
        let checker = UpdateChecker(build: build, defaults: defaults, session: StubProtocol.session)
        StubProtocol.answer(host, status: 200, body: "{}")
        await checker.check()
        #expect(StubProtocol.requests(to: host).count == 1)
        #expect(defaults.object(forKey: SettingsKey.updateCheckCountedOverride) is Date)
        #expect(defaults.object(forKey: SettingsKey.updateCheckCounted) == nil)
    }

    @MainActor @Test func buildWithoutACheckURLNeverChecks() async {
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(build: BuildInfo(version: "0.2", build: 2), defaults: defaults, session: StubProtocol.session)
        #expect(!checker.canCheck)
        checker.setChecksForUpdates(true)
        await checker.check()
        #expect(defaults.object(forKey: SettingsKey.updateCheckCounted) == nil)
    }

    // MARK: Update

    @Test func updateNeverWaitsForAPrompt() {
        let environment = UpdateInstaller.environment(inheriting: ["PATH": "/custom/bin", "HOME": "/Users/someone"])
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        // Set by the script, and only when the clone doesn't pick its own (core.sshCommand).
        #expect(environment["GIT_SSH_COMMAND"] == nil)
        #expect(environment["HOME"] == "/Users/someone")
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/custom/bin")
        #expect(["/usr/bin", "/bin", "/usr/sbin", "/sbin"].allSatisfy(path.contains))
        #expect(UpdateInstaller.environment(inheriting: [:])["PATH"]?.hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin") == true)
    }

    @Test func manualCommandQuotesTheFolder() {
        #expect(UpdateInstaller.command(in: URL(fileURLWithPath: "/Users/someone/it's here"))
                == #"cd '/Users/someone/it'\''s here' && git pull && ./scripts/build-app.sh --install"#)
    }

    @Test func onlyACloneWithTheBuildScriptCanUpdate() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AITempomatUpdateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "scripts"), withIntermediateDirectories: true)
        #expect(!UpdateInstaller.canUpdate(folder))
        try Data().write(to: folder.appending(path: "scripts/build-app.sh"))
        #expect(!UpdateInstaller.canUpdate(folder))
        // A worktree's .git is a file.
        try Data("gitdir: elsewhere".utf8).write(to: folder.appending(path: ".git"))
        #expect(UpdateInstaller.canUpdate(folder))
    }

    @Test func updateWritesToTheLogNotToThisApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AITempomatUpdateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "Logs/update.log")
        let (statuses, exited) = AsyncStream<Int32>.makeStream()
        // Not a clone: git fails, and set -e stops there.
        let process = try UpdateInstaller.launch(in: folder, branch: "main", build: 3, log: log) { exited.yield($0); exited.finish() }
        #expect(process.standardOutput is FileHandle && !(process.standardOutput is Pipe))
        #expect(process.standardError is FileHandle && !(process.standardError is Pipe))
        #expect(!(process.standardInput is Pipe))
        var iterator = statuses.makeAsyncIterator()
        let status = await iterator.next()
        #expect(status != nil && status != 0)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.hasPrefix("== update "))
        #expect(UpdateInstaller.failureLine(of: log).map { $0.hasPrefix("fatal:") } == true)
    }

    @Test func failureLineIsTheErrorNotGitsLastWord() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AITempomatUpdateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "update.log")
        try Data("""
            == update Mon Oct 26 09:00:00 UTC 2026
            error: an earlier run's
            == update Mon Oct 26 10:00:00 UTC 2026
            error: Your local changes to the following files would be overwritten by merge:
            \tSources/AITempomat/PanelView.swift
            Please commit your changes or stash them before you merge.
            Aborting
            Updating 9a13d4a..a2dc432

            """.utf8).write(to: log)
        #expect(UpdateInstaller.failureLine(of: log)
                == "error: Your local changes to the following files would be overwritten by merge:")
        try Data("== update Mon Oct 26 10:00:00 UTC 2026\nsomething else went wrong\n".utf8).write(to: log)
        #expect(UpdateInstaller.failureLine(of: log) == "something else went wrong")
        // Stopped before it wrote anything but its first line.
        try Data("== update Mon Oct 26 10:00:00 UTC 2026\n".utf8).write(to: log)
        #expect(UpdateInstaller.failureLine(of: log) == nil)
    }

    /// The clone has moved on to another branch since the app was built: no pull, no build.
    @Test func updateStopsOnAnotherBranch() async throws {
        let (root, clone) = try Self.clone(build: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "update.log")
        let status = await Self.run(in: clone, branch: "multi-profile", build: 3, log: log)
        #expect(status != 0)
        #expect(UpdateInstaller.failureLine(of: log) == "error: this folder is on main now, not multi-profile, the branch the app was built from")
        #expect(try !String(contentsOf: log, encoding: .utf8).contains("building in"))
    }

    /// A fork, or a remote behind the release: the pull doesn't bring it, so nothing is rebuilt.
    @Test func updateStopsWhenThePullDoesNotBringTheRelease() async throws {
        let (root, clone) = try Self.clone(build: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "update.log")
        let status = await Self.run(in: clone, branch: "main", build: 3, log: log)
        #expect(status != 0)
        #expect(UpdateInstaller.failureLine(of: log)
                == "error: after git pull this folder is at build 2, not 3: its remote doesn't have the new version")
        #expect(try !String(contentsOf: log, encoding: .utf8).contains("building in"))
    }

    /// A clone whose build fails, at a path the shell would misread if it were put into the script.
    @MainActor @Test func failedBuildShowsItsLastLine() async throws {
        let (root, clone) = try Self.clone(build: 3)
        defer { try? FileManager.default.removeItem(at: root) }

        let host = "install-\(UUID().uuidString.prefix(8).lowercased()).test"
        let (defaults, suite) = Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = root.appending(path: "Logs/update.log")
        let build = BuildInfo(version: "0.2", build: 2, checkURL: URL(string: "https://\(host)/v1/check"), sourceFolder: clone,
                              branch: "main")
        let checker = UpdateChecker(build: build, defaults: defaults, session: StubProtocol.session, logFile: log)
        #expect(checker.installFolder == clone)
        StubProtocol.answer(host, status: 200, body: #"{"version":"0.3","build":3}"#)
        await checker.check()
        #expect(checker.available?.build == 3)
        checker.install()
        #expect(checker.installState == .installing)
        let deadline = Date().addingTimeInterval(30)
        while checker.installState == .installing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(checker.installState == .failed("error: the build failed"))
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.hasPrefix("== update "))
        #expect(text.contains(#"building in "# + clone.path))
    }

    // MARK: Helpers

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        date(year, month, day, hour, minute, in: .gmt)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    /// An origin on main whose version.json is at `build`, and a clone of it, at a path the shell
    /// would misread if it were put into the script, with a build-app.sh that says where it runs
    /// and fails. Returns the folder holding both, and the clone.
    private static func clone(build: Int) throws -> (root: URL, clone: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "AITempomatUpdateTests-\(UUID().uuidString)")
        let origin = root.appending(path: "origin")
        let clone = root.appending(path: #"it's a "clone" $HOME"#)
        let script = origin.appending(path: "scripts/build-app.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho \"building in $(pwd)\"\necho 'error: the build failed' >&2\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data(#"{"version":"0.\#(build)","build":\#(build)}"#.utf8).write(to: origin.appending(path: "version.json"))
        try git("init", "-q", "-b", "main", origin.path)
        try git("-C", origin.path, "add", ".")
        try git("-C", origin.path, "commit", "-q", "-m", "Start")
        try git("clone", "-q", origin.path, clone.path)
        return (root, clone)
    }

    /// Runs the update script and waits for its exit status.
    private static func run(in folder: URL, branch: String, build: Int, log: URL) async -> Int32? {
        let (statuses, exited) = AsyncStream<Int32>.makeStream()
        guard (try? UpdateInstaller.launch(in: folder, branch: branch, build: build, log: log, finished: {
            exited.yield($0); exited.finish()
        })) != nil else { return nil }
        var iterator = statuses.makeAsyncIterator()
        return await iterator.next()
    }

    private static func defaults() -> (UserDefaults, String) {
        let suite = "AITempomatTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Runs git without the user's or the system's configuration.
    private static func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}

/// Answers each host's requests from a table, and keeps the URLs it was asked for.
private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var asked: [String: [URL]] = [:]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static func answer(_ host: String, status: Int, body: String) { lock.withLock { answers[host] = (status, body) } }
    static func requests(to host: String) -> [URL] { lock.withLock { asked[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host ?? ""
        let answer = Self.lock.withLock {
            Self.asked[host, default: []].append(url)
            return Self.answers[host]
        }
        guard let answer, let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                         headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
