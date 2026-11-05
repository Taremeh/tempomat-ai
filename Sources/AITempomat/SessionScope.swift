import Darwin
import Foundation

/// A Claude login: the account, and the organization whose plan it uses when known.
struct ClaudeLogin: Hashable, Sendable {
    let account: String
    let organization: String?
    /// The account's email, to show in the panel; not part of what makes two logins the same.
    let email: String?

    init?(account: String?, organization: String?, email: String? = nil) {
        guard let account, UUID(uuidString: account) != nil else { return nil }
        self.account = account.lowercased()
        self.organization = organization.flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
        self.email = email.flatMap { $0.contains("@") && $0.count <= 320 ? $0 : nil }
    }

    static func == (lhs: ClaudeLogin, rhs: ClaudeLogin) -> Bool {
        lhs.account == rhs.account && lhs.organization == rhs.organization
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(account)
        hasher.combine(organization)
    }

    /// The same account, in the same organization unless one of them doesn't say.
    func matches(_ other: ClaudeLogin) -> Bool {
        account == other.account && (organization == nil || other.organization == nil || organization == other.organization)
    }

    /// The login a Claude Code configuration's settings (`.claude.json`) name. They hold no credentials.
    static func read(settings file: URL) -> ClaudeLogin? {
        guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        return ClaudeLogin(account: account["accountUuid"] as? String, organization: account["organizationUuid"] as? String,
                           email: account["emailAddress"] as? String)
    }

    /// The login a running Claude Code process was started on, from its environment: the desktop
    /// app starts each of its sessions with the account it is signed in to. Only these three
    /// variables are read; the rest of the environment (it holds tokens) is left alone.
    static func running(pid: pid_t) -> ClaudeLogin? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return started(from: buffer[..<size])
    }

    static let environmentKeys = (account: "CLAUDE_CODE_ACCOUNT_UUID", organization: "CLAUDE_CODE_ORGANIZATION_UUID",
                                  email: "CLAUDE_CODE_USER_EMAIL")

    /// The login in a process's arguments as `KERN_PROCARGS2` gives them: the argument count, the
    /// executable's path, the arguments, then the environment, each ending in a zero byte.
    static func started(from bytes: ArraySlice<UInt8>) -> ClaudeLogin? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = bytes.startIndex + 4
        func skipString() {
            while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        }
        skipString()
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
        for _ in 0..<argc {
            skipString()
            index += 1
        }
        var values: [String: String] = [:]
        let keys = [environmentKeys.account, environmentKeys.organization, environmentKeys.email]
        while index < bytes.endIndex {
            let start = index
            skipString()
            guard index > start else { break }
            let entry = bytes[start..<index]
            for key in keys where entry.starts(with: Array((key + "=").utf8)) {
                values[key] = String(decoding: entry.dropFirst(key.utf8.count + 1), as: UTF8.self)
            }
            index += 1
        }
        return ClaudeLogin(account: values[environmentKeys.account], organization: values[environmentKeys.organization],
                           email: values[environmentKeys.email])
    }
}

/// The logins behind `claude` and the desktop app's sessions, from files that rarely change; each
/// is read again only when it does.
///
/// The desktop app runs Claude Code in its default folder, `~/.claude`, whichever account it is
/// signed in to, so a second instance (one started with `--user-data-dir`, such as Claude-Work)
/// keeps its sessions beside the first one's. Each instance files a record of a session under a
/// login, `claude-code-sessions/<account>/<organization>/local_<id>.json`, and the record names the
/// Claude Code session (`cliSessionId`). Newer versions of the app copy every record under each
/// login it has been signed in to, so a record found under more than one login tells nothing.
/// What does tell is the session's own process while it runs: the app starts it with the account
/// in its environment (see `ClaudeLogin.running`), and that is kept once seen.
final class ClaudeLogins: @unchecked Sendable {
    static let shared = ClaudeLogins()

    private let desktopFolders: @Sendable () -> [URL]
    private let lock = NSLock()
    /// The logins whose folders hold a record of each session, by Claude Code's session id and
    /// by the desktop app's own (`local_…`).
    private var recorded: [String: Set<ClaudeLogin>] = [:]
    /// The login each session's process was started on, by both ids; it outranks the records.
    private var started: [String: ClaudeLogin] = [:]
    /// When each desktop record was last read.
    private var recordsRead: [String: Date] = [:]
    private var settings: [String: (modified: Date, login: ClaudeLogin?)] = [:]

    /// `desktopFolders` lists the desktop app's data folders.
    init(desktopFolders: @escaping @Sendable () -> [URL] = ClaudeLogins.desktopDataFolders) {
        self.desktopFolders = desktopFolders
    }

    /// The desktop app's data folders: `Claude`, and those of other instances beside it, such as `Claude-Work`.
    static func desktopDataFolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: URL.applicationSupportDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Claude") }
    }

    /// The login a Claude Code configuration's settings name.
    func login(settings file: URL) -> ClaudeLogin? {
        // Not the URL's resource values: a URL kept around can keep returning the date it first read.
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date ?? .distantPast
        if let known = lock.withLock({ settings[file.path] }), known.modified == modified { return known.login }
        let login = ClaudeLogin.read(settings: file)
        lock.withLock { settings[file.path] = (modified, login) }
        return login
    }

    /// Notes the login session `id` (the desktop app's `host`, if it runs it) was started on.
    func learn(_ id: String, host: String?, startedOn login: ClaudeLogin) {
        lock.withLock {
            started[id] = login
            if let host { started[host] = login }
        }
    }

    /// Every session the desktop app ran whose login is known, and that login: the one its
    /// process was started on, else the one login its records are filed under. A session keeps
    /// its login after the app removes its record.
    func desktopSessions() -> [String: ClaudeLogin] {
        lock.withLock {
            readDesktopRecords()
            var hosts: [String: ClaudeLogin] = [:]
            for (id, logins) in recorded where logins.count == 1 { hosts[id] = logins.first }
            hosts.merge(started) { _, process in process }
            return hosts
        }
    }

    private func readDesktopRecords() {
        func children(_ dir: URL, _ keys: [URLResourceKey]? = nil) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        }
        for folder in desktopFolders() {
            for account in children(folder.appending(path: "claude-code-sessions")) {
                for organization in children(account) where UUID(uuidString: organization.lastPathComponent) != nil {
                    guard let login = ClaudeLogin(account: account.lastPathComponent,
                                                  organization: organization.lastPathComponent) else { continue }
                    for record in children(organization, [.contentModificationDateKey]) where record.pathExtension == "json" {
                        let host = record.deletingPathExtension().lastPathComponent
                        guard host.hasPrefix("local_") else { continue }
                        recorded[host, default: []].insert(login)
                        let modified = (try? record.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            ?? .distantPast
                        guard recordsRead[record.path] != modified else { continue }
                        recordsRead[record.path] = modified
                        if let session = Self.cliSession(in: record) { recorded[session, default: []].insert(login) }
                    }
                }
            }
        }
    }

    /// The Claude Code session a desktop record names.
    private static func cliSession(in record: URL) -> String? {
        guard let data = try? Data(contentsOf: record), data.count <= 8 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["cliSessionId"] as? String, UUID(uuidString: session) != nil else { return nil }
        return session
    }
}

/// The Claude Code sessions that count: those run on the login `claude` uses.
///
/// Claude Code keeps its sessions in `~/.claude`, and the desktop app runs it there too, whichever
/// account the app is signed in to. Sessions a second instance (such as Claude-Work) ran on another
/// account are told apart by the desktop app's records of them (see `ClaudeLogins`).
struct SessionScope: Sendable {
    /// Claude Code's folder.
    let folder: URL
    /// Its settings, which name its login; nil counts every session in `folder`.
    let settingsFile: URL?
    private let logins: ClaudeLogins

    /// `~/.claude`, on the login `~/.claude.json` names.
    static let standard = SessionScope(
        folder: FleetScanner.defaultClaudeDir,
        settingsFile: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json"))

    init(folder: URL, settingsFile: URL? = nil, logins: ClaudeLogins = .shared) {
        self.folder = folder.standardizedFileURL
        self.settingsFile = settingsFile
        self.logins = logins
    }

    /// Notes the login a running session was started on (see `ClaudeLogins.learn`).
    func learn(_ id: String, host: String?, startedOn login: ClaudeLogin) {
        logins.learn(id, host: host, startedOn: login)
    }

    /// Which sessions count, as the files say now: taken once for each scan.
    func filter() -> SessionFilter {
        guard let settingsFile, let login = logins.login(settings: settingsFile) else {
            return SessionFilter(login: nil, hosts: [:])
        }
        return SessionFilter(login: login, hosts: logins.desktopSessions())
    }
}

/// Which sessions count, as `SessionScope.filter()` found them.
struct SessionFilter {
    /// The login `claude` uses; nil while it isn't known, which counts every session.
    let login: ClaudeLogin?
    /// The login the desktop app ran each of its sessions on.
    let hosts: [String: ClaudeLogin]

    /// Whether session `id` counts: every session but those the desktop app ran on another
    /// login (`host` is the app's id for it).
    func includes(_ id: String, host: String? = nil) -> Bool {
        guard let login, let ranOn = ranOn(id, host: host) else { return true }
        return login.matches(ranOn)
    }

    /// The login the desktop app ran session `id` on, if known.
    func ranOn(_ id: String, host: String? = nil) -> ClaudeLogin? {
        hosts[id] ?? host.flatMap { hosts[$0] }
    }

    /// Whether the desktop app ran session `id` on another login.
    func isForeign(_ id: String) -> Bool { !includes(id) }
}
