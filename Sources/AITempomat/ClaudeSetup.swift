import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI
import os

/// What a new user otherwise does in Terminal before the app can read any limits: signing Claude
/// Code in to a Claude plan, and installing it. The problem banner offers both as buttons.
@MainActor @Observable
final class ClaudeSetup {
    static let shared = ClaudeSetup()

    enum SignInState: Equatable {
        case idle
        /// `claude auth login` waits for you to approve in the browser. The link opens the
        /// sign-in page again, once the CLI has said where it is.
        case signingIn(link: URL?)
        /// Why it stopped, in a sentence of the app's own: the CLI's output can hold account details.
        case failed(String)
    }

    enum InstallState: Equatable {
        case idle
        /// Anthropic's installer runs in Terminal, and the app looks for Claude Code every few seconds.
        case installing
        case failed(String)
    }

    /// Reads usage again and returns the problem that's left, if any.
    typealias Refresh = @MainActor () async -> UsageProblem?

    static let signInFailed = "Sign-in didn't finish. Try again, or run the command below in Terminal."
    static let signInTimedOut = "Sign-in timed out."

    private(set) var signInState = SignInState.idle {
        didSet { if case .failed = signInState { signInFailedAt = .now } }
    }
    private(set) var installState = InstallState.idle {
        didSet { if case .failed = installState { installFailedAt = .now } }
    }
    @ObservationIgnored private var signInFailedAt = Date.distantPast
    @ObservationIgnored private var installFailedAt = Date.distantPast

    private let findClaude: @Sendable () async -> URL?
    private let signInTimeout: Duration
    private let installFolder: URL
    private let openInTerminal: @MainActor (URL) async throws -> Void
    private let lookInterval: Duration
    private let installTimeout: Duration

    private var signInTask: Task<Void, Never>?
    /// Counts sign-ins, so one that was cancelled can't change the state of the next.
    private var signInRun = 0
    private var installTask: Task<Void, Never>?

    /// `findClaude` finds the binary the usage check runs; `installFolder` is where the installer
    /// script is written. The rest is for tests.
    init(findClaude: @escaping @Sendable () async -> URL? = { await ClaudeBinary.newest()?.url },
         signInTimeout: Duration = .seconds(600),
         installFolder: URL = ClaudeInstaller.folder,
         openInTerminal: @escaping @MainActor (URL) async throws -> Void = ClaudeInstaller.openInTerminal,
         lookInterval: Duration = .seconds(5),
         installTimeout: Duration = .seconds(600)) {
        self.findClaude = findClaude
        self.signInTimeout = signInTimeout
        self.installFolder = installFolder
        self.openInTerminal = openInTerminal
        self.lookInterval = lookInterval
        self.installTimeout = installTimeout
        // Quitting mid sign-in would leave `claude auth login` waiting on its port for good.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelSignIn() }
        }
    }

    /// A failure is about the attempt the banner showed; once the banner is gone (the problem
    /// went away, or the panel closed), the next one starts afresh. One that came while the
    /// banner wasn't there (the panel closed for the browser) is shown when it comes back, unless
    /// it's older than `age`: by then it's about an attempt you've likely forgotten.
    func forgetFailures(olderThan age: TimeInterval = 0) {
        if case .failed = signInState, Date.now.timeIntervalSince(signInFailedAt) >= age { signInState = .idle }
        if case .failed = installState, Date.now.timeIntervalSince(installFailedAt) >= age { installState = .idle }
    }

    // MARK: Sign in

    /// Runs `claude auth login --claudeai`, which opens claude.com in the browser and finishes by
    /// itself once you approve there. Then `refresh` reads usage again, and the banner goes with
    /// the problem. One sign-in at a time; it gives up after 10 minutes.
    func signIn(refresh: @escaping Refresh) {
        if case .signingIn = signInState { return }
        signInRun += 1
        let run = signInRun
        signInState = .signingIn(link: nil)
        signInTask = Task {
            var outcome = ClaudeSignIn.Outcome.notStarted
            if let claude = await findClaude() {
                outcome = await ClaudeSignIn.run(claude, timeout: signInTimeout) { link in
                    Task { @MainActor in self.found(link, run: run) }
                }
            }
            guard run == signInRun else { return }
            switch outcome {
            case .exited(0):
                let problem = await refresh()
                guard run == signInRun else { return }
                // Still not signed in to a plan: a login of another kind, or none after all.
                signInState = problem?.action == .signIn ? .failed(Self.signInFailed) : .idle
            case .timedOut:
                signInState = .failed(Self.signInTimedOut)
            default:
                signInState = .failed(Self.signInFailed)
            }
        }
    }

    /// Stops the sign-in and the CLI with it.
    func cancelSignIn() {
        guard case .signingIn = signInState else { return }
        signInRun += 1
        signInTask?.cancel()
        signInTask = nil
        signInState = .idle
    }

    private func found(_ link: URL, run: Int) {
        guard run == signInRun, case .signingIn = signInState else { return }
        signInState = .signingIn(link: link)
    }

    // MARK: Install

    /// Opens Terminal on a script that runs Anthropic's installer, then reads usage every few
    /// seconds until Claude Code turns up, for up to 10 minutes. A fresh install isn't signed in
    /// yet, so the banner then offers Sign in.
    func installClaudeCode(refresh: @escaping Refresh) {
        guard installState != .installing else { return }
        installState = .installing
        installTask?.cancel()
        installTask = Task {
            let script: URL
            do {
                script = try ClaudeInstaller.writeScript(in: installFolder)
            } catch {
                installState = .failed("Couldn't write the installer script.")
                return
            }
            do {
                try await openInTerminal(script)
            } catch {
                installState = .failed("Couldn't open Terminal.")
                return
            }
            let deadline = ContinuousClock.now + installTimeout
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: lookInterval)
                guard !Task.isCancelled else { return }
                if await refresh()?.action != .installCLI {
                    installState = .idle
                    return
                }
            }
            installState = .failed("Didn't find Claude Code after 10 minutes.")
        }
    }

    /// Stops looking for Claude Code, say because the installer failed in Terminal.
    func cancelInstall() {
        guard installState == .installing else { return }
        installTask?.cancel()
        installTask = nil
        installState = .idle
    }
}

/// `claude auth login --claudeai`, run without a terminal: it opens the sign-in page in the
/// browser and waits on a localhost port for the browser to come back once you approve.
enum ClaudeSignIn {
    enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case cancelled
        /// No CLI, or it didn't start.
        case notStarted
    }

    static let arguments = ["auth", "login", "--claudeai"]

    /// Runs the login until it exits, `timeout` passes or the task is cancelled; in the last two
    /// cases the CLI is terminated. `link` gets the sign-in page once the CLI has printed it. The
    /// output is read for that link only, never kept or logged: it can hold account details.
    static func run(_ claude: URL, timeout: Duration, link: @escaping @Sendable (URL) -> Void) async -> Outcome {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = ProcessRunner.environment(inheriting: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let reader = OSAllocatedUnfairLock(initialState: SignInLink.Reader())
        let output = pipe.fileHandleForReading
        output.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let printed = reader.withLock({ $0.read(chunk) }) else { return }
            let pid = process.processIdentifier
            Task.detached {
                if let page = await SignInLink.page(for: printed, pid: pid) { link(page) }
            }
        }
        let (exits, exited) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.yield(process.terminationStatus)
            exited.finish()
        }
        do {
            try process.run()
        } catch {
            output.readabilityHandler = nil
            return .notStarted
        }
        defer {
            stop(process)
            output.readabilityHandler = nil
        }

        return await withTaskCancellationHandler {
            await withTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    for await status in exits { return .exited(status) }
                    return .cancelled
                }
                group.addTask {
                    do { try await Task.sleep(for: timeout) } catch { return .cancelled }
                    return .timedOut
                }
                let first = await group.next() ?? .cancelled
                group.cancelAll()
                return first
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Ends the login, by force if it ignores the request.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// The sign-in page `claude auth login` prints, after "If the browser didn't open, visit:". That
/// link ends on a page with a code to paste into the CLI, which can't be done here: the CLI reads
/// no input. The page it opened in the browser is the same one, but it sends you back to the
/// CLI's port on localhost, which finishes the sign-in, so that is the one the banner offers.
enum SignInLink {
    /// Reads the output as it comes, for the printed link. Keeps only the line not finished yet.
    struct Reader: Sendable {
        private var line = Data()
        private var found = false

        /// The printed link, once the chunk that ends its line has been read.
        mutating func read(_ chunk: Data) -> URL? {
            guard !found else { return nil }
            line.append(chunk)
            while let newline = line.firstIndex(of: UInt8(ascii: "\n")) {
                let text = String(decoding: line[line.startIndex..<newline], as: UTF8.self)
                line = Data(line[line.index(after: newline)...])
                if let url = SignInLink.printed(in: text) {
                    found = true
                    line = Data()
                    return url
                }
            }
            // A line this long is no sign-in prompt.
            if line.count > 65_536 { line = Data() }
            return nil
        }
    }

    /// The first https URL on a line that says "visit:".
    static func printed(in line: String) -> URL? {
        guard line.contains("visit:"), let start = line.range(of: "https://") else { return nil }
        let text = line[start.lowerBound...].prefix { !$0.isWhitespace && $0 != "\u{1B}" }
        guard let url = URL(string: String(text)), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// `printed` with its redirect_uri on the CLI's callback at `port`, as on the page the CLI
    /// opened; nil without a redirect_uri.
    static func returning(_ printed: URL, toPort port: Int) -> URL? {
        guard var components = URLComponents(url: printed, resolvingAgainstBaseURL: false),
              var items = components.percentEncodedQueryItems,
              let index = items.firstIndex(where: { $0.name == "redirect_uri" }) else { return nil }
        items[index].value = "http%3A%2F%2Flocalhost%3A\(port)%2Fcallback"
        components.percentEncodedQueryItems = items
        return components.url
    }

    /// The page the CLI opened: `printed`, sent back to the one port `pid` listens on. The CLI
    /// listens before it prints the link; a little time is allowed anyway.
    static func page(for printed: URL, pid: pid_t) async -> URL? {
        for _ in 0..<20 {
            let ports = listeningPorts(of: pid)
            if ports.count == 1 { return returning(printed, toPort: ports[0]) }
            if ports.count > 1 { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The TCP ports `pid` listens on, from the kernel's list of its open files.
    static func listeningPorts(of pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var files = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = files.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return files.prefix(Int(filled) / stride).compactMap { file -> Int? in
            guard file.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, file.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP),
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            // In network byte order.
            return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
        }
    }
}

/// Anthropic's installer for Claude Code, run in Terminal from a `.command` file: Terminal shows
/// what it does, and opening a file with it needs no permission, unlike scripting Terminal.
enum ClaudeInstaller {
    /// What to run by hand.
    static let command = "curl -fsSL https://claude.ai/install.sh | bash"

    static var folder: URL { URL.cachesDirectory.appending(path: "AI Tempomat") }

    /// Downloads the installer before running it, rather than piping curl into bash: a failed
    /// download would hand bash an empty script, which "succeeds", and the window would say Done.
    static let script = """
        #!/bin/sh
        echo "Installing Claude Code with Anthropic's installer (https://claude.ai/install.sh)…"
        installer=$(mktemp -t claude-install) || exit 1
        if curl -fsSL https://claude.ai/install.sh -o "$installer" && bash "$installer"; then
            echo
            echo "Done. AI Tempomat finds Claude Code in a few seconds. You can close this window."
        else
            echo
            echo "The installer didn't finish (see above). Check your connection, then try again from AI Tempomat's panel."
        fi
        rm -f "$installer"

        """

    /// Writes the script into `folder` as install-claude-code.command, executable, and returns it.
    static func writeScript(in folder: URL) throws -> URL {
        let file = folder.appending(path: "install-claude-code.command")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Opens `file` with Terminal, which runs it in a new window.
    @MainActor static func openInTerminal(_ file: URL) async throws {
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// The problem banner's part for a problem the app can fix itself: the Sign in or Install
/// Claude Code button, what's under way, or why it stopped, and how to do it in Terminal instead.
struct ClaudeSetupActions: View {
    let action: UsageProblem.Action
    /// The problem's own command.
    let command: String?
    var setup: ClaudeSetup = .shared
    let refresh: ClaudeSetup.Refresh

    var body: some View {
        Group {
            switch action {
            case .signIn: signIn
            case .installCLI: install
            }
        }
        .onAppear { setup.forgetFailures(olderThan: 15 * 60) }
        .onDisappear { setup.forgetFailures() }
    }

    @ViewBuilder
    private var signIn: some View {
        switch setup.signInState {
        case .idle:
            AccentButton(title: "Sign in") { setup.signIn(refresh: refresh) }
                .help("Opens claude.com in your browser to sign Claude Code in to your Claude plan.")
            byHand("Or in Terminal:", command)
        case .signingIn(let link):
            underWay("Approve in your browser, then come back here.") {
                Button("Cancel") { setup.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if let link {
                Link("Browser didn't open? Open the sign-in page", destination: link)
                    .font(.caption)
            }
        case .failed(let message):
            failed(message) { setup.signIn(refresh: refresh) }
            byHand("Or in Terminal:", command)
        }
    }

    @ViewBuilder
    private var install: some View {
        switch setup.installState {
        case .idle:
            AccentButton(title: "Install Claude Code") { setup.installClaudeCode(refresh: refresh) }
                .help("Opens Terminal and runs Anthropic's installer from claude.ai/install.sh.")
            byHand("Installed somewhere else? Point the app at it:", command)
        case .installing:
            underWay("Installing in Terminal… AI Tempomat looks for Claude Code every few seconds.") {
                Button("Cancel") { setup.cancelInstall() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            byHand("Or in Terminal:", ClaudeInstaller.command)
        case .failed(let message):
            failed(message) { setup.installClaudeCode(refresh: refresh) }
            byHand("Or in Terminal:", ClaudeInstaller.command)
        }
    }

    private func underWay(_ text: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func failed(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try again", action: retry)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private func byHand(_ intro: String, _ command: String?) -> some View {
        if let command {
            Text(intro)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProblemCommand(command: command)
        }
    }
}

/// The banner's button, drawn here: a prominent system button turns gray in the panel, which
/// never activates the app.
private struct AccentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
