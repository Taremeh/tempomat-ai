import Foundation
import Testing
@testable import AITempomat

struct ClaudeProfileTests {
    @Test func explicitConfigurationReplacesInheritedProfile() {
        let inherited = [
            "CLAUDE_CONFIG_DIR": "/tmp/personal",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-token",
            "ANTHROPIC_API_KEY": "synthetic-parent-key",
            "CLAUDE_CODE_SESSION_ID": "synthetic-session",
            "PATH": "/custom/bin",
            "LANG": "en_US.UTF-8",
        ]
        let environment = ProcessRunner.environment(inheriting: inherited,
                                                     overrides: ["CLAUDE_CONFIG_DIR": "/tmp/work"])
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/work")
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"]?.contains("/custom/bin") == true)
    }

    @Test func defaultConfigurationPreservesExistingCLIBehavior() {
        let environment = ProcessRunner.environment(inheriting: ["CLAUDE_CONFIG_DIR": "/tmp/existing"])
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/existing")
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
    }

    @Test func explicitProviderEnvironmentWinsAfterSanitizing() {
        let environment = ProcessRunner.environment(
            inheriting: ["CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-token"],
            overrides: ["CLAUDE_CODE_OAUTH_TOKEN": "synthetic-selected-token"])
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == "synthetic-selected-token")
    }

    @Test func concurrentProcessesKeepProfileEnvironmentsSeparate() async throws {
        async let personal = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/printenv"), ["CLAUDE_CONFIG_DIR"],
                                               timeout: 5, environmentOverrides: ["CLAUDE_CONFIG_DIR": "/tmp/personal"])
        async let work = ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/printenv"), ["CLAUDE_CONFIG_DIR"],
                                           timeout: 5, environmentOverrides: ["CLAUDE_CONFIG_DIR": "/tmp/work"])
        let (first, second) = try await (personal, work)
        #expect(first.status == 0)
        #expect(second.status == 0)
        #expect(String(decoding: first.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp/personal")
        #expect(String(decoding: second.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp/work")
    }

    @Test func subprocessIgnoringTerminationStillTimesOut() async {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                            ["-c", "trap '' TERM; exec /bin/sleep 15"], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch UsageError.timedOut {
            #expect(start.duration(to: .now) < .seconds(5))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
