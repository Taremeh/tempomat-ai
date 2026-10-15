import Foundation
import Testing
@testable import AITempomat

struct ClaudeDesktopTests {
    private let account = "00000000-0000-0000-0000-000000000001"
    private let otherAccount = "00000000-0000-0000-0000-000000000002"
    private let organization = "00000000-0000-0000-0000-000000000003"
    private let otherOrganization = "00000000-0000-0000-0000-000000000004"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(account: String, organization: String,
                     scopes: String = "user:inference user:file_upload user:profile user:sessions:claude_code") -> String {
        "acct:\(account)|\(ClaudeDesktopCredentialParser.clientID):\(organization):https://api.anthropic.com:\(scopes)"
    }

    private func entry(token: String, expired: Bool = false, lasting: TimeInterval = 3600) -> [String: Any] {
        ["token": token, "expiresAt": now.addingTimeInterval(expired ? -60 : lasting).timeIntervalSince1970 * 1000]
    }

    @Test func desktopTokensWithExtraScopesAreAccepted() throws {
        let scopes = "user:inference user:file_upload user:profile user:sessions:claude_code user:plugins"
        let cache = [key(account: account, organization: organization, scopes: scopes): entry(token: "synthetic-plugins")]
        let token = try ClaudeDesktopCredentialParser.accessToken(from: JSONSerialization.data(withJSONObject: cache),
                                                                  accountID: account, now: now)
        #expect(token == "synthetic-plugins")
    }

    @Test func tokensMissingCodeScopesAreIgnored() throws {
        let cache = [key(account: account, organization: organization, scopes: "user:inference user:profile"): entry(token: "synthetic-chat")]
        let data = try JSONSerialization.data(withJSONObject: cache)
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeDesktopCredentialParser.accessToken(from: data, accountID: account, now: now)
        }
    }

    @Test func severalTokensForOneOrganizationUseTheLongestLasting() throws {
        let plugins = "user:inference user:file_upload user:profile user:sessions:claude_code user:plugins"
        let cache = [
            key(account: account, organization: organization): entry(token: "synthetic-older", lasting: 600),
            key(account: account, organization: organization, scopes: plugins): entry(token: "synthetic-newer", lasting: 7200),
        ]
        let token = try ClaudeDesktopCredentialParser.accessToken(from: JSONSerialization.data(withJSONObject: cache),
                                                                  accountID: account, now: now)
        #expect(token == "synthetic-newer")
    }

    @Test func desktopActiveOrganizationSettlesSeveralOrganizations() throws {
        let cache: [String: Any] = [
            key(account: account, organization: organization): entry(token: "synthetic-first"),
            key(account: account, organization: otherOrganization): entry(token: "synthetic-second"),
        ]
        let data = try JSONSerialization.data(withJSONObject: cache)
        let token = try ClaudeDesktopCredentialParser.accessToken(from: data, accountID: account,
                                                                  organizationID: otherOrganization, now: now)
        #expect(token == "synthetic-second")
        // A signed-out active organization never falls back to another one.
        let signedOut: [String: Any] = [
            key(account: account, organization: organization): entry(token: "synthetic-first"),
            key(account: account, organization: otherOrganization): NSNull(),
        ]
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeDesktopCredentialParser.accessToken(from: JSONSerialization.data(withJSONObject: signedOut),
                                                          accountID: account, organizationID: otherOrganization, now: now)
        }
    }

    @Test func activeOrganizationComesFromTheNewestUsageSample() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempomat-org-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = #"{"version":2,"samples":[{"t":2,"org":"\#(otherOrganization)","u":{}},{"t":1,"org":"\#(organization)","u":{}}]}"#
        try Data(history.utf8).write(to: folder.appending(path: "plan-usage-history.json"))
        #expect(ClaudeDesktopCredentialParser.activeOrganization(in: folder) == otherOrganization)
        #expect(ClaudeDesktopCredentialParser.activeOrganization(in: folder.appending(path: "missing")) == nil)
    }

    @Test func connectionRequiresConsentBeforeAnyCredentialRead() async {
        let directory = URL(fileURLWithPath: "/tmp/tempomat-unconnected-\(UUID().uuidString)")
        #expect(!ClaudeDesktopSource.isAccessAllowed(to: directory))
        do {
            _ = try await ClaudeDesktopSource(directory: directory).fetch()
            Issue.record("An unconnected profile must not fetch usage")
        } catch ClaudeDesktopError.consentRequired {
            // This nonexistent directory deliberately cannot contain credentials.
        } catch {
            Issue.record("Consent must be checked before reading the directory")
        }
    }

    @Test func knownSyntheticElectronCiphertextDecrypts() throws {
        let encrypted = try #require(Data(base64Encoded: "djEwF0oRUQZSpkigG57s02iZkCDAQgvnAVWSV5pG+eq8NJo="))
        let result = try ClaudeSafeStorage.decrypt(encrypted, password: Data("synthetic-test-password".utf8))
        #expect(String(decoding: result, as: UTF8.self) == "{\"synthetic\":true}")
    }

    @Test func unsupportedCiphertextNeverFallsBackToPlaintext() {
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeSafeStorage.decrypt(Data("{\"token\":\"synthetic\"}".utf8), password: Data("test".utf8))
        }
    }

    @Test func matchingUsesTheSelectedAccountOnly() throws {
        let cache = [
            key(account: otherAccount, organization: organization): entry(token: "synthetic-other"),
            key(account: account, organization: organization): entry(token: "synthetic-selected"),
        ]
        let token = try ClaudeDesktopCredentialParser.accessToken(from: JSONSerialization.data(withJSONObject: cache),
                                                                  accountID: account, now: now)
        #expect(token == "synthetic-selected")
    }

    @Test func ambiguousOrganizationsAreRejected() throws {
        let cache = [
            key(account: account, organization: organization): entry(token: "synthetic-first"),
            key(account: account, organization: otherOrganization): entry(token: "synthetic-second"),
        ]
        let data = try JSONSerialization.data(withJSONObject: cache)
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeDesktopCredentialParser.accessToken(from: data, accountID: account, now: now)
        }
    }

    @Test func expiredCredentialsAreRejected() throws {
        let cache = [key(account: account, organization: organization): entry(token: "synthetic-expired", expired: true)]
        let data = try JSONSerialization.data(withJSONObject: cache)
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeDesktopCredentialParser.accessToken(from: data, accountID: account, now: now)
        }
    }

    @Test func signedOutOrganizationDoesNotSelectAnotherOrganization() throws {
        let cache: [String: Any] = [
            key(account: account, organization: organization): entry(token: "synthetic-first"),
            key(account: account, organization: otherOrganization): NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: cache)
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeDesktopCredentialParser.accessToken(from: data, accountID: account, now: now)
        }
    }

    @Test func anotherAccountIsNeverUsedAsFallback() throws {
        let cache = [key(account: otherAccount, organization: organization): entry(token: "synthetic-other")]
        let data = try JSONSerialization.data(withJSONObject: cache)
        #expect(throws: ClaudeDesktopError.self) {
            try ClaudeDesktopCredentialParser.accessToken(from: data, accountID: account, now: now)
        }
    }

    @Test func legacyUsageProvidesSessionAndWeeklyMeters() throws {
        let data = Data(#"{"five_hour":{"utilization":34,"resets_at":"2027-01-15T10:00:00Z"},"seven_day":{"utilization":92,"resets_at":1800000000},"seven_day_opus":null}"#.utf8)
        let rows = try ClaudeDesktopUsageParser.parse(data)
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.kind == "session" })?.percent == 34)
        #expect(rows.first(where: { $0.kind == "weekly_all" })?.isActive == true)
        #expect(rows.first(where: { $0.kind == "weekly_all" })?.resetsAt != nil)
    }

    @Test func modernUsageKeepsScopedLimitsAndAvoidsDuplicateLegacyMeters() throws {
        let data = Data(#"{"limits":[{"kind":"session","percent":24,"is_active":true},{"kind":"weekly_scoped","percent":8,"scope":{"model":{"display_name":"Fable"}}}],"five_hour":{"utilization":24},"seven_day":{"utilization":45}}"#.utf8)
        let rows = try ClaudeDesktopUsageParser.parse(data)
        #expect(rows.count == 3)
        #expect(rows.filter { $0.kind == "session" }.count == 1)
        #expect(rows.first(where: { $0.kind == "weekly_scoped" })?.scope?.model?.displayName == "Fable")
        #expect(rows.first(where: { $0.kind == "session" })?.isActive == true)
    }

    @Test func emptyUsageIsNotShownAsZero() {
        #expect(throws: UsageError.self) {
            try ClaudeDesktopUsageParser.parse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
        }
    }

    @Test func invalidPercentagesAreRejected() {
        for percentage in ["-1", "101", "true", "\"45\""] {
            #expect(throws: ClaudeDesktopError.self) {
                try ClaudeDesktopUsageParser.parse(Data("{\"five_hour\":{\"utilization\":\(percentage)}}".utf8))
            }
        }
    }
}
