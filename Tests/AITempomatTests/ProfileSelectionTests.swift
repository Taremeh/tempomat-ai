import Foundation
import Testing
@testable import AITempomat

@MainActor
struct ProfileSelectionTests {
    @Test func demoChangesNeverOverwriteSavedProfiles() throws {
        let suite = "Tempomat.ProfileSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("saved profiles must survive a demo".utf8)
        defaults.set(original, forKey: ProfilesStore.profilesKey)
        defaults.set("real-account", forKey: ProfilesStore.selectionKey)
        let profiles = ProfilesStore(defaults: defaults, demo: true)
        defer { profiles.profiles.forEach { $0.store.stop() } }
        let codex = try #require(profiles.profiles.first { $0.profile.provider == .codex })
        profiles.select(codex.id)
        profiles.rename(codex, to: "Preview account")
        profiles.setVisible(codex, false)
        profiles.add(name: "Preview CLI", provider: .claudeCLI, path: "~/demo-unused")
        profiles.remove(codex)
        #expect(defaults.data(forKey: ProfilesStore.profilesKey) == original)
        #expect(defaults.string(forKey: ProfilesStore.selectionKey) == "real-account")
    }

    @Test func hiddenProfilesRemainSelectableAndLastProfileCannotBeRemoved() throws {
        let suite = "Tempomat.ProfileSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesStore(defaults: defaults, demo: true)
        defer { profiles.profiles.forEach { $0.store.stop() } }
        for runtime in profiles.profiles { profiles.setVisible(runtime, false) }
        // The selected profile stays in the switcher, so the panel never loses its place.
        #expect(profiles.visibleProfiles.map(\.id) == [profiles.selectedID])
        let target = try #require(profiles.profiles.last)
        profiles.select(target.id)
        #expect(profiles.selected.id == target.id)
        #expect(profiles.selected.store.headline?.title == "Weekly limit")
        profiles.select("missing-profile")
        #expect(profiles.selected.id == target.id)
        profiles.remove(target)
        #expect(profiles.profiles.contains { $0.id == profiles.selectedID })
        for runtime in profiles.profiles { profiles.remove(runtime) }
        #expect(profiles.profiles.count == 1)
        #expect(profiles.selected.id == profiles.profiles[0].id)
    }

    @Test func desktopLoginSharedWithTheCLIBecomesOneProfile() {
        let personal = UsageProfile(id: "claude-personal", name: "Claude", provider: .claudeDesktop, path: "/tmp/Claude")
        let work = UsageProfile(id: "claude-work", name: "Claude Work", provider: .claudeDesktop, path: "/tmp/Claude-Work")
        let codex = UsageProfile(id: "codex-default", name: "ChatGPT / Codex", provider: .codex, path: "~/.codex")
        let cli = UsageProfile(id: "claude-cli-original", name: UsageProfile.originalCLIName, provider: .claudeCLI,
                               path: "~/.claude", showInMenuBar: false, usesLegacyHistory: true)
        let accounts = ["claude-personal": "a", "claude-work": "b", "claude-cli-original": "a"]
        let merged = UsageProfile.mergingDuplicateLogins([personal, work, codex, cli]) { accounts[$0.id] }
        #expect(merged.profiles.map(\.id) == ["claude-cli-original", "claude-work", "codex-default"])
        #expect(merged.profiles[0].name == "Claude")
        #expect(merged.profiles[0].showInMenuBar)
        #expect(merged.profiles[0].usesLegacyHistory)
        #expect(merged.replaced == ["claude-personal": "claude-cli-original"])
        // Merging again changes nothing.
        let again = UsageProfile.mergingDuplicateLogins(merged.profiles) { accounts[$0.id] }
        #expect(again.profiles == merged.profiles)
        #expect(again.replaced.isEmpty)
    }

    @Test func separateOrUnknownLoginsAreKept() {
        let desktop = UsageProfile(id: "claude-work", name: "Claude Work", provider: .claudeDesktop, path: "/tmp/Claude-Work")
        var cli = UsageProfile(id: "cli", name: "My CLI", provider: .claudeCLI, path: "~/.claude")
        cli.showInMenuBar = false
        let separate = UsageProfile.mergingDuplicateLogins([desktop, cli]) { $0.id == "cli" ? "a" : "b" }
        #expect(separate.profiles == [desktop, cli])
        let signedOut = UsageProfile.mergingDuplicateLogins([desktop, cli]) { $0.id == "cli" ? nil : "b" }
        #expect(signedOut.profiles == [desktop, cli])
        // A renamed CLI profile keeps its name when it takes the desktop profile's place.
        let renamed = UsageProfile.mergingDuplicateLogins([desktop, cli]) { _ in "a" }
        #expect(renamed.profiles.map(\.name) == ["My CLI"])
    }
}
