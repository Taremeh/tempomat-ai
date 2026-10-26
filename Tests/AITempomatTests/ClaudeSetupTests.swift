import Darwin
import Foundation
import Testing
@testable import AITempomat

/// Sign in and Install Claude Code in the problem banner: which problems offer them, the sign-in
/// link read from the CLI's output, sign-in against a fake `claude`, and the installer script.
@Suite struct ClaudeSetupTests {
    // MARK: Actions

    @Test func onlySignInAndAMissingCLIOfferAButton() {
        let signIn = UsageProblem(UsageError.notSignedIn(claude: nil))
        #expect(signIn.action == .signIn)
        #expect(signIn.command == "claude auth login")
        let install = UsageProblem(UsageError.cliNotFound)
        #expect(install.action == .installCLI)
        #expect(install.command?.contains("claudePath") == true)
        let others: [Error] = [UsageError.unsupportedCLI(version: "2.1.0"), UsageError.noMeters, UsageError.timedOut,
                               UsageError.cliFailed("Couldn't change the login item"), CocoaError(.fileNoSuchFile)]
        for error in others {
            #expect(UsageProblem(error).action == nil)
        }
    }

    // MARK: Sign-in link

    /// The link as `claude auth login --claudeai` prints it: the one for pasting a code back.
    static let printed = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        + "&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
        + "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference&code_challenge=Zk3v9Q_x-2&code_challenge_method=S256"
        + "&state=s7Hq-Lm2"
    static let output = "Opening browser to sign in…\nIf the browser didn't open, visit: \(printed)\nPaste code here if prompted > "

    @Test func linkIsReadFromTheVisitLine() {
        var reader = SignInLink.Reader()
        #expect(reader.read(Data(Self.output.utf8))?.absoluteString == Self.printed)
        // Once.
        #expect(reader.read(Data(Self.output.utf8)) == nil)
    }

    @Test func linkSplitAcrossChunks() {
        let bytes = Data(Self.output.utf8)
        // Cut anywhere: in the "…", in the URL, right before the line ends.
        for cut in 1..<bytes.count {
            var reader = SignInLink.Reader()
            let first = reader.read(bytes.prefix(cut))
            let second = reader.read(bytes.dropFirst(cut))
            #expect((first ?? second)?.absoluteString == Self.printed, "cut at \(cut)")
            #expect(first == nil || second == nil)
        }
        // A byte at a time.
        var reader = SignInLink.Reader()
        let links = bytes.compactMap { reader.read(Data([$0])) }
        #expect(links.map(\.absoluteString) == [Self.printed])
    }

    @Test func onlyAnHTTPSLinkOnAVisitLine() {
        #expect(SignInLink.printed(in: "See https://claude.com/docs for help") == nil)
        #expect(SignInLink.printed(in: "If the browser didn't open, visit: http://claude.com/cai/oauth/authorize") == nil)
        #expect(SignInLink.printed(in: "If the browser didn't open, visit: \u{1B}[1mhttps://claude.com/a?b=c\u{1B}[0m\r")?
            .absoluteString == "https://claude.com/a?b=c")
    }

    @Test func pageSendsTheBrowserBackToTheCLI() throws {
        let printed = try #require(URL(string: Self.printed))
        let page = try #require(SignInLink.returning(printed, toPort: 54321))
        // The page the CLI opened: everything the same, in order, but where the browser goes after.
        #expect(page.absoluteString == Self.printed.replacingOccurrences(
            of: "https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback", with: "http%3A%2F%2Flocalhost%3A54321%2Fcallback"))
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "redirect_uri" }?.value == "http://localhost:54321/callback")
        let noRedirect = try #require(URL(string: "https://claude.com/cai?state=x"))
        #expect(SignInLink.returning(noRedirect, toPort: 1) == nil)
    }

    @Test func listeningPortsFindsAListener() throws {
        let (socket, port) = try Self.listener()
        defer { close(socket) }
        #expect(SignInLink.listeningPorts(of: getpid()).contains(port))
        #expect(SignInLink.listeningPorts(of: -1).isEmpty)
    }

    // MARK: Sign in

    /// What the CLI prints, as shell commands.
    static let prints = """
        printf '%s\\n' 'Opening browser to sign in…' "If the browser didn't open, visit: \(printed)"
        printf 'Paste code here if prompted > '
        """

    @MainActor @Test func signInRefreshesOnceWhenItWorks() async throws {
        let (folder, claude) = try Self.fakeClaude(Self.prints + "\nsleep 0.3\nexit 0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { claude })
        let refreshes = Counter()
        setup.signIn { refreshes.count += 1; return nil }
        #expect(setup.signInState == .signingIn(link: nil))
        // One sign-in at a time: a second click starts nothing.
        setup.signIn { refreshes.count += 1; return nil }
        try await Self.wait { setup.signInState == .idle }
        #expect(refreshes.count == 1)
        #expect(try String(contentsOf: folder.appending(path: "arguments"), encoding: .utf8) == "auth login --claudeai\n")
        #expect(try String(contentsOf: folder.appending(path: "stdin"), encoding: .utf8) == "empty\n")
    }

    @MainActor @Test func signInThatLeavesTheCLISignedOutFails() async throws {
        let (folder, claude) = try Self.fakeClaude(Self.prints + "\nexit 0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { claude })
        setup.signIn { UsageProblem(UsageError.notSignedIn(claude: nil)) }
        try await Self.wait { setup.signInState == .failed(ClaudeSetup.signInFailed) }
    }

    @MainActor @Test func failedSignInSaysSoWithoutTheCLIsOutput() async throws {
        let (folder, claude) = try Self.fakeClaude(Self.prints + "\necho 'Login failed: someone@example.com is not allowed' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { claude })
        let refreshes = Counter()
        setup.signIn { refreshes.count += 1; return nil }
        try await Self.wait { setup.signInState == .failed(ClaudeSetup.signInFailed) }
        #expect(refreshes.count == 0)
    }

    @MainActor @Test func withoutClaudeSignInFails() async throws {
        let setup = ClaudeSetup(findClaude: { nil })
        setup.signIn { nil }
        try await Self.wait { setup.signInState == .failed(ClaudeSetup.signInFailed) }
    }

    /// The fake waits like the CLI does, listening on a localhost port, until it's stopped.
    @MainActor @Test func cancelEndsTheCLI() async throws {
        let port = try Self.freePort()
        let (folder, claude) = try Self.fakeClaude(Self.waits(on: port))
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { claude })
        let refreshes = Counter()
        setup.signIn { refreshes.count += 1; return nil }
        let printed = try #require(URL(string: Self.printed))
        let page = try #require(SignInLink.returning(printed, toPort: port))
        try await Self.wait { setup.signInState == .signingIn(link: page) }
        let pid = try Self.pid(in: folder)
        #expect(kill(pid, 0) == 0)

        setup.cancelSignIn()
        #expect(setup.signInState == .idle)
        try await Self.wait { kill(pid, 0) != 0 }
        // The cancelled sign-in doesn't come back to change the state.
        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.signInState == .idle)
        #expect(refreshes.count == 0)
    }

    @MainActor @Test func signInTimesOut() async throws {
        let port = try Self.freePort()
        let (folder, claude) = try Self.fakeClaude(Self.waits(on: port))
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { claude }, signInTimeout: .seconds(4))
        setup.signIn { nil }
        // Started and waiting: a fresh script can take most of a second to start.
        try await Self.wait { if case .signingIn(.some) = setup.signInState { true } else { false } }
        let pid = try Self.pid(in: folder)
        try await Self.wait { setup.signInState == .failed(ClaudeSetup.signInTimedOut) }
        try await Self.wait { kill(pid, 0) != 0 }
    }

    // MARK: Finding claude

    @Test func newestClaudeIsTheOneThatRuns() async throws {
        let folder = Self.temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fake(_ name: String, _ body: String) throws -> URL {
            let url = folder.appending(path: name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let old = try fake("old", "echo '2.1.9 (Claude Code)'")
        let new = try fake("new", "echo '2.1.10 (Claude Code)'")
        let broken = try fake("broken", "echo '9.0.0 (Claude Code)'; exit 1")
        let binary = await ClaudeBinary.newest(among: [old, new, broken])
        #expect(binary?.url == new)
        #expect(binary?.versionString == "2.1.10")
        #expect(await ClaudeBinary.newest(among: [broken]) == nil)
    }

    // MARK: Install

    @Test func installerScriptRunsAnthropicsInstaller() throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try ClaudeInstaller.writeScript(in: folder.appending(path: "AI Tempomat"))
        #expect(file == folder.appending(path: "AI Tempomat/install-claude-code.command"))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("curl -fsSL https://claude.ai/install.sh -o"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        // Again, over the one written before.
        #expect(try ClaudeInstaller.writeScript(in: folder.appending(path: "AI Tempomat")) == file)
    }

    /// The window says Done only when the download and the installer both worked.
    @Test func installerScriptSaysWhetherItWorked() throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = try ClaudeInstaller.writeScript(in: folder)
        // A curl that writes an installer to its -o file, or fails like a dropped connection.
        func run(curl: String) throws -> String {
            let bin = folder.appending(path: "bin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n\(curl)\n".utf8).write(to: bin.appending(path: "curl"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "curl").path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "TMPDIR": folder.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: output, as: UTF8.self)
        }
        let worked = try run(curl: #"while [ "$1" != -o ]; do shift; done; echo 'echo installer ran' > "$2""#)
        #expect(worked.contains("installer ran") && worked.contains("Done."))
        let offline = try run(curl: #"echo "curl: (6) Could not resolve host: claude.ai" >&2; exit 6"#)
        #expect(offline.contains("didn't finish") && !offline.contains("Done."))
        let failed = try run(curl: #"while [ "$1" != -o ]; do shift; done; echo 'exit 1' > "$2""#)
        #expect(failed.contains("didn't finish") && !failed.contains("Done."))
    }

    @MainActor @Test func installCanBeCancelledAndFailuresAreForgotten() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { nil }, installFolder: folder, openInTerminal: { _ in },
                                lookInterval: .milliseconds(20))
        setup.installClaudeCode { UsageProblem(UsageError.cliNotFound) }
        #expect(setup.installState == .installing)
        setup.cancelInstall()
        #expect(setup.installState == .idle)

        let failing = ClaudeSetup(findClaude: { nil }, installFolder: folder,
                                  openInTerminal: { _ in throw CocoaError(.fileNoSuchFile) })
        failing.installClaudeCode { nil }
        try await Self.wait { failing.installState == .failed("Couldn't open Terminal.") }
        // Shown when the banner comes back soon after, forgotten once it's gone.
        failing.forgetFailures(olderThan: 15 * 60)
        #expect(failing.installState == .failed("Couldn't open Terminal."))
        failing.forgetFailures()
        #expect(failing.installState == .idle)
    }

    @Test func terminalCommandNamesTheCopyTheAppRuns() {
        #expect(UsageProblem(UsageError.notSignedIn(claude: URL(fileURLWithPath: "/opt/homebrew/bin/claude"))).command
                == "claude auth login")
        let bundled = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Claude/claude-code/2.1.308/b/claude.app/Contents/MacOS/claude")
        #expect(UsageProblem(UsageError.notSignedIn(claude: bundled)).command == "'\(bundled.path)' auth login")
        #expect(UsageProblem.command(URL(fileURLWithPath: "/Users/it's me/.local/bin/claude"), "auth login")
                == #"'/Users/it'\''s me/.local/bin/claude' auth login"#)
    }

    @MainActor @Test func installLooksForClaudeCodeUntilItTurnsUp() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let opened = Recorder()
        let setup = ClaudeSetup(findClaude: { nil }, installFolder: folder, openInTerminal: { opened.urls.append($0) },
                                lookInterval: .milliseconds(20))
        // Not there yet, then installed: signed out, so the banner offers Sign in next.
        let problems = Recorder()
        problems.problems = [UsageProblem(UsageError.cliNotFound), UsageProblem(UsageError.cliNotFound),
                             UsageProblem(UsageError.notSignedIn(claude: nil))]
        setup.installClaudeCode { problems.problems.removeFirst() }
        #expect(setup.installState == .installing)
        try await Self.wait { setup.installState == .idle }
        #expect(problems.problems.isEmpty)
        #expect(opened.urls == [folder.appending(path: "install-claude-code.command")])
    }

    @MainActor @Test func installThatCantOpenTerminalFails() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { nil }, installFolder: folder,
                                openInTerminal: { _ in throw CocoaError(.fileNoSuchFile) }, lookInterval: .milliseconds(20))
        let refreshes = Counter()
        setup.installClaudeCode { refreshes.count += 1; return nil }
        try await Self.wait { setup.installState == .failed("Couldn't open Terminal.") }
        #expect(refreshes.count == 0)
    }

    @MainActor @Test func installGivesUpWhenClaudeCodeNeverTurnsUp() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = ClaudeSetup(findClaude: { nil }, installFolder: folder, openInTerminal: { _ in },
                                lookInterval: .milliseconds(20), installTimeout: .milliseconds(200))
        setup.installClaudeCode { UsageProblem(UsageError.cliNotFound) }
        try await Self.wait { setup.installState == .failed("Didn't find Claude Code after 10 minutes.") }
    }

    // MARK: Helpers

    @MainActor private final class Counter { var count = 0 }

    @MainActor private final class Recorder {
        var urls: [URL] = []
        var problems: [UsageProblem] = []
    }

    private static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "AITempomatSetupTests-\(UUID().uuidString)")
    }

    /// A fake `claude` in a folder of its own. It writes down its arguments and whether it got
    /// anything on stdin, then runs `body`.
    private static func fakeClaude(_ body: String) throws -> (folder: URL, claude: URL) {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claude = folder.appending(path: "claude")
        try Data("""
            #!/bin/sh
            here="$(dirname "$0")"
            echo "$*" >> "$here/arguments"
            if read -r line; then echo data > "$here/stdin"; else echo empty > "$here/stdin"; fi
            \(body)

            """.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return (folder, claude)
    }

    /// Prints like the CLI once it listens on `port`, and listens until it's stopped. Its pid
    /// stays the shell's, which it writes down.
    private static func waits(on port: Int) -> String {
        """
        echo $$ > "$here/pid"
        ( sleep 0.3; \(prints) ) &
        exec /usr/bin/nc -l 127.0.0.1 \(port)
        """
    }

    private static func pid(in folder: URL) throws -> pid_t {
        let text = try String(contentsOf: folder.appending(path: "pid"), encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// A socket listening on 127.0.0.1, and its port.
    private static func listener() throws -> (socket: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, 1) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    /// A port nothing listens on now.
    private static func freePort() throws -> Int {
        let (socket, port) = try listener()
        close(socket)
        return port
    }

    @MainActor private static func wait(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
                                        until condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
