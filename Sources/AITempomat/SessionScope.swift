import Foundation

/// A Claude login: the account, and the organization whose plan it uses when known.
struct ClaudeLogin: Hashable, Sendable {
    let account: String
    let organization: String?

    init?(account: String?, organization: String?) {
        guard let account, UUID(uuidString: account) != nil else { return nil }
        self.account = account.lowercased()
        self.organization = organization.flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
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
        return ClaudeLogin(account: account["accountUuid"] as? String, organization: account["organizationUuid"] as? String)
    }
}

/// The logins behind profiles and sessions, from files that rarely change; each is read again
/// only when it does.
///
/// The desktop app runs Claude Code in its default folder, `~/.claude`, whichever account it is
/// signed in to, so a second instance (one started with `--user-data-dir`, such as Claude-Work)
/// keeps its sessions beside the first one's. Each instance files its own record of a session
/// under the login it runs on, `claude-code-sessions/<account>/<organization>/local_<id>.json`,
/// and the record names the Claude Code session (`cliSessionId`).
final class ClaudeLogins: @unchecked Sendable {
    static let shared = ClaudeLogins()

    private let desktopFolders: @Sendable () -> [URL]
    private let lock = NSLock()
    /// By Claude Code's session id, and by the desktop app's own (`local_…`).
    private var hosts: [String: ClaudeLogin] = [:]
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

    /// Every session the desktop app ran, and the login it ran on. A session keeps its login
    /// after the app removes its record.
    func desktopSessions() -> [String: ClaudeLogin] {
        lock.withLock {
            readDesktopRecords()
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
                        hosts[host] = login
                        let modified = (try? record.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            ?? .distantPast
                        guard recordsRead[record.path] != modified else { continue }
                        recordsRead[record.path] = modified
                        if let session = Self.cliSession(in: record) { hosts[session] = login }
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

/// The Claude Code sessions that count for one profile: those run on its login.
///
/// Claude Code keeps a session in its configuration folder: `~/.claude`, or the folder
/// CLAUDE_CONFIG_DIR names. A profile's terminal sessions are in its own folder; the desktop
/// app's are all in `~/.claude`, told apart by the login the app ran them on (see `ClaudeLogins`).
struct SessionScope: Sendable {
    /// The profile's configuration folder.
    let folder: URL
    /// Its settings, which name its login; nil counts every session in `folder`.
    let settingsFile: URL?
    /// Where its sessions may be: its own folder, and the one the desktop app keeps its sessions in.
    let folders: [URL]
    private let logins: ClaudeLogins

    init(folder: URL, settingsFile: URL? = nil, desktopFolder: URL = FleetScanner.defaultClaudeDir,
         logins: ClaudeLogins = .shared) {
        self.folder = folder.standardizedFileURL
        self.settingsFile = settingsFile
        let desktopFolder = desktopFolder.standardizedFileURL
        folders = settingsFile == nil || desktopFolder.path == self.folder.path ? [self.folder] : [self.folder, desktopFolder]
        self.logins = logins
    }

    /// Which sessions count, as the files say now: taken once for each scan.
    func filter() -> SessionFilter {
        guard let settingsFile, let login = logins.login(settings: settingsFile) else {
            return SessionFilter(folder: folder.path, login: nil, hosts: [:])
        }
        return SessionFilter(folder: folder.path, login: login, hosts: logins.desktopSessions())
    }
}

/// Which sessions count for a profile, as `SessionScope.filter()` found them.
struct SessionFilter {
    /// The profile's configuration folder.
    let folder: String
    /// The profile's login; nil while it isn't known, which counts every session in its folder.
    let login: ClaudeLogin?
    /// The login the desktop app ran each of its sessions on.
    let hosts: [String: ClaudeLogin]

    /// Whether session `id`, found in the configuration folder `found`, counts: one the desktop
    /// app ran (`host` is the app's id for it) when the app ran it on the profile's login, any
    /// other when it is in the profile's own folder.
    func includes(_ id: String, host: String? = nil, in found: URL) -> Bool {
        if let login, let ranOn = hosts[id] ?? host.flatMap({ hosts[$0] }) { return login.matches(ranOn) }
        return found.standardizedFileURL.path == folder
    }

    /// Whether the desktop app ran session `id` on another login than the profile's.
    func isForeign(_ id: String) -> Bool {
        guard let login, let ranOn = hosts[id] else { return false }
        return !login.matches(ranOn)
    }
}
