import Foundation
import Observation

enum UsageProvider: String, Codable, CaseIterable, Identifiable {
    case claudeDesktop, claudeCLI, codex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeDesktop: "Claude desktop"
        case .claudeCLI: "Claude Code CLI"
        case .codex: "ChatGPT / Codex"
        }
    }
    var defaultPath: String {
        switch self {
        case .claudeDesktop: "~/Library/Application Support/Claude"
        case .claudeCLI: "~/.claude"
        case .codex: "~/.codex"
        }
    }
}

struct UsageProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var provider: UsageProvider
    var path: String
    /// Shown in the panel's switcher. (Named for when each profile had its own menu bar item.)
    var showInMenuBar: Bool = true
    /// Only the original CLI profile uses the pre-profile history files.
    var usesLegacyHistory: Bool = false
    var directory: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

    /// The Claude account this profile is signed in to, from the app's own settings (no credentials):
    /// the desktop app's config.json, or the CLI's .claude.json (~/.claude.json for the default login).
    var claudeAccountID: String? {
        func read(_ file: URL, _ value: ([String: Any]) -> Any?) -> String? {
            guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value(object) as? String, UUID(uuidString: id) != nil else { return nil }
            return id.lowercased()
        }
        switch provider {
        case .claudeDesktop:
            return read(directory.appending(path: "config.json")) { $0["lastKnownAccountUuid"] }
        case .claudeCLI:
            return ClaudeLogin.read(settings: cliSettingsFile)?.account
        case .codex:
            return nil
        }
    }

    /// A CLI profile's settings, which name its login: `.claude.json` in its configuration folder,
    /// `~/.claude.json` for the default login.
    var cliSettingsFile: URL {
        usesLegacyHistory ? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
            : directory.appending(path: ".claude.json")
    }

    /// The Claude Code sessions a CLI profile counts: those run on its login, in its folder or in
    /// the desktop app's. Other profiles have none.
    var sessionScope: SessionScope? {
        provider == .claudeCLI ? SessionScope(folder: directory, settingsFile: cliSettingsFile) : nil
    }

    static let originalCLIName = "Claude Code (original)"

    /// The terminal's default login, which keeps the history files from before profiles.
    static var originalCLI: UsageProfile {
        UsageProfile(id: "claude-cli-original", name: originalCLIName, provider: .claudeCLI, path: "~/.claude",
                     usesLegacyHistory: true)
    }

    /// A desktop profile signed in to the same account as a CLI profile shows the same usage twice,
    /// so the two become one: the CLI's, which reads usage without Keychain access and knows the
    /// sessions. It takes the desktop profile's place (and its name, unless renamed). Returns the
    /// profiles and, for each one dropped, the profile that replaces it.
    static func mergingDuplicateLogins(_ profiles: [UsageProfile], account: (UsageProfile) -> String?)
        -> (profiles: [UsageProfile], replaced: [String: String]) {
        let accounts = Dictionary(profiles.map { ($0.id, account($0)) }, uniquingKeysWith: { first, _ in first })
        var result = profiles
        var replaced: [String: String] = [:]
        for cli in profiles where cli.provider == .claudeCLI {
            guard let id = accounts[cli.id] ?? nil else { continue }
            let duplicates = result.filter { $0.provider == .claudeDesktop && accounts[$0.id] == id }
            guard let first = duplicates.first else { continue }
            var merged = cli
            if merged.name == originalCLIName { merged.name = first.name }
            merged.showInMenuBar = cli.showInMenuBar || duplicates.contains(where: \.showInMenuBar)
            result.removeAll { $0.id == cli.id }
            result = result.compactMap { profile in
                guard duplicates.contains(where: { $0.id == profile.id }) else { return profile }
                replaced[profile.id] = cli.id
                return profile.id == first.id ? merged : nil
            }
        }
        return (result, replaced)
    }
}

@MainActor @Observable
final class ProfileRuntime: Identifiable {
    nonisolated let id: String
    let isDemo: Bool
    var profile: UsageProfile
    let store: UsageStore
    let fleet: FleetStore
    var supportsSessions: Bool { profile.provider == .claudeCLI }

    init(profile: UsageProfile, demo: Bool = false, persist: Bool = true) {
        id = profile.id
        isDemo = demo
        self.profile = profile
        if demo {
            let source = ProfileDemoSource(provider: profile.provider)
            store = UsageStore(source: source, history: profile.provider == .codex ? History() : DemoSource.history(),
                               archive: profile.provider == .codex ? WindowArchive() : DemoSource.archive(), persist: false)
            store.load(rows: source.rows())
            fleet = FleetStore(scanner: nil, sessions: DemoFleet.sessions())
            return
        }
        let source: any UsageSource
        switch profile.provider {
        case .claudeDesktop: source = ClaudeDesktopSource(directory: profile.directory)
        case .claudeCLI: source = ClaudeCLISource(configDirectory: profile.usesLegacyHistory ? nil : profile.directory)
        case .codex: source = CodexUsageSource(home: profile.directory)
        }
        let transcripts = profile.sessionScope
        store = UsageStore(source: source, persist: persist, transcripts: transcripts,
                           storageID: profile.usesLegacyHistory ? nil : profile.id)
        fleet = FleetStore(scanner: transcripts.map { FleetScanner(scope: $0) })
    }
}

private struct ProfileDemoSource: UsageSource {
    let provider: UsageProvider
    func rows() -> [LimitRow] {
        guard provider == .codex else { return DemoSource.rows() }
        return [LimitRow(kind: "codex_codex_primary", group: "codex", percent: 18,
                         resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400)),
                         scope: nil, severity: "normal", isActive: true,
                         displayTitle: "Weekly limit", windowDuration: 7 * 86400)]
    }
    func fetch() async throws -> [LimitRow] { rows() }
}

@MainActor @Observable
final class ProfilesStore {
    static let profilesKey = "usageProfiles.v1"
    static let selectionKey = "selectedUsageProfile.v1"
    private(set) var profiles: [ProfileRuntime]
    private(set) var selectedID: String
    var isShowingSettings = false
    private let defaults: UserDefaults
    private let demo: Bool
    private let persist: Bool

    var selected: ProfileRuntime { profiles.first { $0.id == selectedID } ?? profiles[0] }
    /// The profiles in the panel's switcher; the selected one is always among them.
    var visibleProfiles: [ProfileRuntime] { profiles.filter { $0.profile.showInMenuBar || $0.id == selectedID } }

    init(defaults: UserDefaults = .standard, demo: Bool = false, persist: Bool = true) {
        self.defaults = defaults
        self.demo = demo
        self.persist = persist && !demo
        let saved = defaults.data(forKey: Self.profilesKey).flatMap { try? JSONDecoder().decode([UsageProfile].self, from: $0) }
        var definitions = demo ? Self.demoProfiles : (saved?.isEmpty == false ? saved! : Self.discoveredProfiles())
        // A malformed preferences file must not create duplicate SwiftUI identities or paths.
        var seen = Set<String>()
        definitions = definitions.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        if definitions.isEmpty { definitions = Self.discoveredProfiles() }
        var previous = defaults.string(forKey: Self.selectionKey)
        if !demo {
            let merged = UsageProfile.mergingDuplicateLogins(definitions, account: \.claudeAccountID)
            definitions = merged.profiles
            previous = previous.map { merged.replaced[$0] ?? $0 }
        }
        profiles = definitions.map { ProfileRuntime(profile: $0, demo: demo, persist: persist) }
        selectedID = definitions.first { $0.id == previous }?.id ?? definitions[0].id
        save()
        if self.persist { defaults.set(selectedID, forKey: Self.selectionKey) }
    }

    func start() {
        for runtime in profiles { runtime.store.start() }
    }

    func select(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        isShowingSettings = false
        if persist { defaults.set(id, forKey: Self.selectionKey) }
        selected.store.refreshIfStale()
    }

    func rename(_ runtime: ProfileRuntime, to name: String) {
        runtime.profile.name = name
        save()
    }

    func setVisible(_ runtime: ProfileRuntime, _ visible: Bool) {
        runtime.profile.showInMenuBar = visible
        save()
    }

    func add(name: String, provider: UsageProvider, path: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanPath.isEmpty else { return }
        let profile = UsageProfile(name: cleanName, provider: provider, path: cleanPath)
        let runtime = ProfileRuntime(profile: profile, demo: demo, persist: persist)
        profiles.append(runtime)
        runtime.store.start()
        save()
    }

    func remove(_ runtime: ProfileRuntime) {
        guard profiles.count > 1 else { return }
        runtime.store.stop()
        profiles.removeAll { $0.id == runtime.id }
        if selectedID == runtime.id {
            selectedID = profiles[0].id
            if persist { defaults.set(selectedID, forKey: Self.selectionKey) }
        }
        save()
    }

    private func save() {
        guard persist, let data = try? JSONEncoder().encode(profiles.map(\.profile)) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    private static func discoveredProfiles() -> [UsageProfile] {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        var profiles: [UsageProfile] = []
        for (folder, name, id) in [("Claude", "Claude", "claude-personal"), ("Claude-Work", "Claude Work", "claude-work")] {
            let path = support.appending(path: folder).path
            if fm.fileExists(atPath: path) {
                profiles.append(UsageProfile(id: id, name: name, provider: .claudeDesktop, path: path))
            }
        }
        if fm.fileExists(atPath: ("~/.codex" as NSString).expandingTildeInPath)
            || fm.fileExists(atPath: "/Applications/ChatGPT.app") || fm.fileExists(atPath: "/Applications/Codex.app") {
            profiles.append(UsageProfile(id: "codex-default", name: "ChatGPT / Codex", provider: .codex, path: "~/.codex"))
        }
        // The terminal's default login. When the desktop app is signed in to the same account, the
        // two are merged (see mergingDuplicateLogins); a CLI that isn't signed in stays out of the switcher.
        var cli = UsageProfile.originalCLI
        cli.showInMenuBar = profiles.allSatisfy { $0.provider != .claudeDesktop } || cli.claudeAccountID != nil
        profiles.append(cli)
        return profiles
    }

    static var demoProfiles: [UsageProfile] {
        [UsageProfile(id: "demo-personal", name: "Claude", provider: .claudeDesktop, path: "~/Library/Application Support/Claude"),
         UsageProfile(id: "demo-work", name: "Claude Work", provider: .claudeDesktop, path: "~/Library/Application Support/Claude-Work"),
         UsageProfile(id: "demo-codex", name: "ChatGPT / Codex", provider: .codex, path: "~/.codex")]
    }
}
