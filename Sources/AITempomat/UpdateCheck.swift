import AppKit
import Darwin
import Foundation
import Observation

/// What this copy of the app is and where it was built, as build-app.sh wrote it into the
/// Info.plist: the version, the clone and its branch, and where to ask for a newer version.
struct BuildInfo: Equatable, Sendable {
    var version: String
    /// Goes up with every release; a release is newer when its build is higher.
    var build: Int
    /// Where the app asks whether a newer version is out. Without one it never asks.
    var checkURL: URL?
    /// The clone the app was built from, where the Update button pulls and builds.
    var sourceFolder: URL?
    var branch: String?
    /// The check URL comes from the settings (a test server, or a fork's), not the app.
    var usesCheckURLOverride = false

    init(version: String, build: Int, checkURL: URL? = nil, sourceFolder: URL? = nil, branch: String? = nil) {
        self.version = version
        self.build = build
        self.checkURL = checkURL
        self.sourceFolder = sourceFolder
        self.branch = branch
    }

    /// Reads the Info.plist's keys. A check URL in the settings replaces the app's own.
    init(info: [String: Any], checkURLOverride: String? = nil) {
        func string(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        version = string("CFBundleShortVersionString") ?? "unknown"
        build = string("CFBundleVersion").flatMap { Int($0) } ?? 0
        let override = UpdateCheck.checkURL(checkURLOverride)
        checkURL = override ?? UpdateCheck.checkURL(string("AITCheckURL"))
        usesCheckURLOverride = override != nil
        sourceFolder = string("AITSourceFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        branch = string("AITSourceBranch")
    }

    /// The branch, when it's one releases are made from. Another branch's name stays on the Mac.
    var releaseBranch: String? { branch.flatMap { UpdateCheck.releaseBranches.contains($0) ? $0 : nil } }

    /// Whether a release tells this build anything: not on a branch of your own, which neither
    /// the release nor a pull of that branch is about. A build from outside git counts as main's.
    var followsReleases: Bool { branch == nil || releaseBranch != nil }

    /// This app's.
    static var current: BuildInfo {
        BuildInfo(info: Bundle.main.infoDictionary ?? [:],
                  checkURLOverride: UserDefaults.standard.string(forKey: SettingsKey.updateCheckURL))
    }
}

/// The latest release of the branch, as the server read it from version.json. An answer
/// without a usable version and build is no release: the server sends `{}` when it can't read
/// the file. Notes and a link of the wrong type are left out.
struct Release: Decodable, Equatable, Sendable {
    let version: String
    let build: Int
    /// A sentence or two on what's new.
    var notes: String?
    /// A page with more on what's new.
    var url: URL?

    init(version: String, build: Int, notes: String? = nil, url: URL? = nil) {
        self.version = version
        self.build = build
        self.notes = notes
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case version, build, notes, url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        build = try container.decode(Int.self, forKey: .build)
        guard !version.isEmpty, version.count <= 24, build >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No usable version and build"))
        }
        let notes = ((try? container.decodeIfPresent(String.self, forKey: .notes)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        url = ((try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil).flatMap(UpdateCheck.checkURL)
    }

    /// The release in a check's answer, if it holds one.
    static func parse(_ data: Data) -> Release? { try? JSONDecoder().decode(Release.self, from: data) }

    func isNewer(than build: Int) -> Bool { self.build > build }
}

/// Which counts a check adds to on the server: the first check from this install, and the first
/// of the day, the week and the month. They stand in for an ID: an install that runs on a day
/// sends a day flag that day until one is answered, so the day flags the server gets in a day are
/// about that day's users (a retry after a lost answer counts twice).
struct CheckFlags: Equatable, Sendable {
    var day: Bool
    var week: Bool
    var month: Bool
    var first: Bool

    /// Counts as no one, for the diagnostic check.
    static let none = CheckFlags(day: false, week: false, month: false, first: false)
}

extension CheckFlags {
    /// The flags for a check at `now`, given when the server last answered one (nil: never).
    /// Days and months in UTC and weeks from Monday (ISO 8601), as the server counts them,
    /// whatever this Mac's time zone.
    init(lastCounted: Date?, now: Date) {
        guard let last = lastCounted else {
            self.init(day: true, week: true, month: true, first: true)
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var weeks = Calendar(identifier: .iso8601)
        weeks.timeZone = .gmt
        func differ(_ calendar: Calendar, _ components: Set<Calendar.Component>) -> Bool {
            calendar.dateComponents(components, from: last) != calendar.dateComponents(components, from: now)
        }
        self.init(day: differ(calendar, [.year, .month, .day]),
                  week: differ(weeks, [.yearForWeekOfYear, .weekOfYear]),
                  month: differ(calendar, [.year, .month]),
                  first: false)
    }
}

/// The update check: one GET with the app and macOS version, the branch the app was built from
/// (main or multi-profile; any other stays empty) and the flags above. Nothing else leaves the Mac: no ID, nothing about your usage, your
/// account, or this Mac's or your name.
enum UpdateCheck {
    /// Ephemeral, without cookies or a cache, so one check can't be told from another install's.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// The branches releases are made from, each with its own version.json.
    static let releaseBranches = ["main", "multi-profile"]

    /// The macOS version, major and minor: "15.1".
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// An http(s) URL with a host, else nil (an empty or malformed setting).
    static func checkURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// `base` with the check's query, and only that.
    static func requestURL(_ base: URL, build: BuildInfo, os: String = osVersion, flags: CheckFlags) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        func flag(_ name: String, _ value: Bool) -> URLQueryItem { URLQueryItem(name: name, value: value ? "1" : "0") }
        components.queryItems = [
            URLQueryItem(name: "v", value: build.version),
            URLQueryItem(name: "b", value: String(build.build)),
            URLQueryItem(name: "os", value: os),
            URLQueryItem(name: "branch", value: build.releaseBranch ?? ""),
            flag("day", flags.day), flag("week", flags.week), flag("month", flags.month), flag("first", flags.first),
        ]
        // URLComponents leaves "+" as it is, which a server reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Sends a check and returns the answer's HTTP status and body.
    static func send(_ url: URL, version: String, session: URLSession = session) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("AITempomat/\(version)", forHTTPHeaderField: "User-Agent")
        // In place of this Mac's languages, which URLSession sends otherwise.
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    /// Sends one check to `argument`, or the app's check URL, prints what came back, and exits:
    /// 0 when the server answered 2xx. Every flag is 0, so it counts as no one, and it leaves
    /// the date of the last check alone. For diagnostics.
    static func printCheck(_ argument: String?) -> Never {
        Task { @MainActor in
            let build = BuildInfo.current
            let given = argument.flatMap { $0.hasPrefix("-") ? nil : $0 }
            if let given, checkURL(given) == nil {
                print("Not an http(s) URL: \(given)")
                exit(1)
            }
            guard let base = given.flatMap(checkURL) ?? build.checkURL,
                  let url = requestURL(base, build: build, flags: .none) else {
                print("No check URL. Set checkURL in version.json and rebuild, or pass one: --check-for-updates <url>")
                exit(1)
            }
            print("GET \(url.absoluteString)")
            do {
                let (status, body) = try await send(url, version: build.version)
                print("HTTP \(status)")
                guard (200..<300).contains(status) else {
                    if !body.isEmpty { print(String(decoding: body.prefix(300), as: UTF8.self)) }
                    exit(1)
                }
                if let release = Release.parse(body) {
                    let newer = release.isNewer(than: build.build) ? "newer than" : "not newer than"
                    print("latest: \(release.version) (build \(release.build)), \(newer) this app (\(build.version), build \(build.build))")
                    if let notes = release.notes { print("notes: \(notes)") }
                    if let url = release.url { print("url: \(url.absoluteString)") }
                } else {
                    print("no release in the answer: \(String(decoding: body.prefix(300), as: UTF8.self))")
                }
                exit(0)
            } catch {
                print("failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}

/// Updates the app the way it was installed: `git pull` and `build-app.sh --install` in the
/// clone it was built from. build-app.sh quits this app and opens the new one, so the shell
/// runs on its own: its output goes to a log file, never through a pipe back to the app, which
/// would break the build (SIGPIPE) when the app quits.
enum UpdateInstaller {
    /// What to run by hand in the clone.
    static let command = "git pull && ./scripts/build-app.sh --install"

    static var logFile: URL { URL.libraryDirectory.appending(path: "Logs/AI Tempomat/update.log") }

    /// The update, run by /bin/sh with the clone as $1, the branch the app was built from as $2
    /// and the release's build as $3: arguments, so no character in them can change the script.
    /// It stops with a line saying why when the clone is on another branch now, or when the pull
    /// didn't bring the release (a fork, or a remote behind), rather than build the same version again.
    static let script = """
        set -e
        echo "== update $(date)"
        cd "$1"
        branch="$(git rev-parse --abbrev-ref HEAD)"
        [ "$branch" = "$2" ] || { echo "error: this folder is on $branch now, not $2, the branch the app was built from"; exit 1; }
        # Never wait for a passphrase or a host key, unless you pick your own ssh command.
        [ -n "${GIT_SSH_COMMAND:-}" ] || [ -n "${GIT_SSH:-}" ] || [ -n "$(git config core.sshCommand || true)" ] \\
            || export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
        git pull --ff-only
        build="$(plutil -extract build raw -o - version.json 2>/dev/null || true)"
        [ "$build" -ge "$3" ] 2>/dev/null || { echo "error: after git pull this folder is at build ${build:-?}, not $3: its remote doesn't have the new version"; exit 1; }
        ./scripts/build-app.sh --install
        """

    /// Whether `folder` still is a clone with the build script.
    static func canUpdate(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: folder.appending(path: ".git").path)
            && fileManager.fileExists(atPath: folder.appending(path: "scripts/build-app.sh").path)
    }

    /// The command with a `cd` into `folder` first, quoted for the shell.
    static func command(in folder: URL) -> String {
        "cd '\(folder.path.replacingOccurrences(of: "'", with: "'\\''"))' && \(command)"
    }

    /// The app's environment, with git never asking for a password (the script keeps ssh from
    /// asking too), and a PATH that finds git and swift in an app launched from Finder.
    static func environment(inheriting inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["GIT_TERMINAL_PROMPT"] = "0"
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(folder) {
            path.append(folder)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    /// Starts the update to `build` in `folder`, on `branch`, appending its output to `log`.
    /// `finished` gets the exit status on a background thread, if this app still runs then:
    /// build-app.sh only quits it once the new build is ready, so a failed pull or build leaves it running.
    @discardableResult
    static func launch(in folder: URL, branch: String, build: Int, log: URL,
                       finished: @escaping @Sendable (Int32) -> Void) throws -> Process {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Past a megabyte, the log starts afresh.
        if let size = (try? fileManager.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 1_000_000 {
            try? fileManager.removeItem(at: log)
        }
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", folder.path, branch, String(build)]
        process.environment = environment(inheriting: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished($0.terminationStatus) }
        try process.run()
        return process
    }

    /// What went wrong in the last update: its last error line (git's `fatal:` or `error:`, the
    /// script's own `error:`, a compiler's `file:line: error:`), else the last line it wrote.
    /// git prints "Updating a..b" after the error that stopped it, so the last line alone often
    /// doesn't say why.
    static func failureLine(of log: URL) -> String? {
        guard let data = try? Data(contentsOf: log) else { return nil }
        let text = String(decoding: data.suffix(16384), as: UTF8.self)
        let run = text.range(of: "== update", options: .backwards).map { text[$0.lowerBound...] } ?? text[...]
        let lines = run.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("== update") }
        return lines.last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") || $0.contains(": error:") } ?? lines.last
    }
}

/// Asks the server once a day whether a newer version is out, and runs the update when you
/// click Update. Off, it sends nothing and shows no update.
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum InstallState: Equatable {
        case idle
        /// Pulling and building; the app restarts when it's done.
        case installing
        /// The pull or the build failed; the log's last line says why.
        case failed(String)
    }

    /// The newer release a check found.
    private(set) var available: Release?
    private(set) var installState = InstallState.idle
    private(set) var checksForUpdates: Bool

    let build: BuildInfo
    let logFile: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private var loop: Task<Void, Never>?
    private var isChecking = false

    init(build: BuildInfo = .current, defaults: UserDefaults = .standard, session: URLSession = UpdateCheck.session,
         logFile: URL = UpdateInstaller.logFile) {
        self.build = build
        self.defaults = defaults
        self.session = session
        self.logFile = logFile
        checksForUpdates = true
        readSetting()
    }

    /// The setting as saved, on unless turned off; `defaults write` with a string such as `NO`
    /// counts too. Read before every check and every hour, so turning it off from Terminal stops a
    /// running app and, within the hour, its checkbox and banner.
    private func readSetting() {
        checksForUpdates = defaults.object(forKey: SettingsKey.checkForUpdates) == nil
            || defaults.bool(forKey: SettingsKey.checkForUpdates)
        if !checksForUpdates { available = nil }
    }

    /// Whether this build has a server to ask. Without one it never checks.
    var canCheck: Bool { build.checkURL != nil }

    /// The clone the Update button updates, as recorded at build time; nil when the app wasn't
    /// built from a release branch's clone. Whether it's still there is checked only on Update:
    /// for a clone in Documents or Desktop, a look from the panel would make macOS ask for access.
    var installFolder: URL? { build.releaseBranch == nil ? nil : build.sourceFolder }

    /// Turning checks on checks right away; turning them off hides the update.
    func setChecksForUpdates(_ enabled: Bool) {
        checksForUpdates = enabled
        defaults.set(enabled, forKey: SettingsKey.checkForUpdates)
        if !enabled {
            available = nil
        } else if loop != nil {
            Task { await check() }
        }
    }

    /// Checks about 10 seconds after launch, then every hour unless today's check went through:
    /// one counted check a day while the app runs, retried hourly while offline.
    func start() {
        guard loop == nil, canCheck else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.check()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                readSetting()
                if CheckFlags(lastCounted: lastCounted, now: Date()).day { await check() }
            }
        }
    }

    /// When the server last answered a check. A test server's or a fork's answers (the
    /// updateCheckURL setting) are kept apart, so they don't use up the flags meant for the app's own.
    private var countedKey: String {
        build.usesCheckURLOverride ? SettingsKey.updateCheckCountedOverride : SettingsKey.updateCheckCounted
    }
    private var lastCounted: Date? { defaults.object(forKey: countedKey) as? Date }

    /// Asks for the latest release. Only an answer from the server counts the day (and week and
    /// month) as checked, so a check that fails is sent again an hour later and the day isn't
    /// lost. (One whose answer is lost after the server got it counts twice; without an ID,
    /// exactly once can't be had.)
    func check(now: Date = Date()) async {
        readSetting()
        guard checksForUpdates, !isChecking, let base = build.checkURL,
              let url = UpdateCheck.requestURL(base, build: build, flags: CheckFlags(lastCounted: lastCounted, now: now))
        else { return }
        isChecking = true
        defer { isChecking = false }
        guard let answer = try? await UpdateCheck.send(url, version: build.version, session: session),
              (200..<300).contains(answer.status) else { return }
        defaults.set(now, forKey: countedKey)
        // An answer without a release ({}) says nothing new; keep what the last one said.
        guard checksForUpdates, build.followsReleases, let release = Release.parse(answer.body) else { return }
        let newer = release.isNewer(than: build.build) ? release : nil
        // A failed update is about the release it tried; another one starts afresh.
        if newer?.build != available?.build, installState != .installing { installState = .idle }
        available = newer
    }

    /// Pulls and builds the available release in the clone the app was built from. When it
    /// works, build-app.sh quits this app and opens the new one.
    func install() {
        guard installState != .installing, let folder = installFolder, let branch = build.releaseBranch,
              let release = available else { return }
        installState = .installing
        Task {
            // Off the main thread: for a clone in Documents or Desktop, macOS may ask for access
            // first, and the question holds up whoever looks.
            guard await Task.detached(operation: { UpdateInstaller.canUpdate(folder) }).value else {
                installState = .failed("Can't open \(folder.path): it was moved, or macOS didn't allow access to it.")
                return
            }
            do {
                try UpdateInstaller.launch(in: folder, branch: branch, build: release.build, log: logFile) { status in
                    Task { @MainActor in self.installFinished(status: status) }
                }
            } catch {
                installState = .failed("Couldn't start the update: \(error.localizedDescription)")
            }
        }
    }

    func showLog() { NSWorkspace.shared.open(logFile) }

    private func installFinished(status: Int32) {
        if status == 0 {
            // The new build is installed; this copy runs on until it's quit.
            installState = .idle
            available = nil
        } else {
            installState = .failed(UpdateInstaller.failureLine(of: logFile) ?? "The update stopped (status \(status)).")
        }
    }
}
