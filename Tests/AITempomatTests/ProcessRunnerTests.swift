import Foundation
import Testing
@testable import AITempomat

struct ProcessRunnerTests {
    @Test func parentSessionCredentialsAreDropped() {
        let inherited = [
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-parent-token",
            "ANTHROPIC_API_KEY": "synthetic-parent-key",
            "CLAUDE_CODE_SESSION_ID": "synthetic-session",
            "PATH": "/custom/bin",
            "LANG": "en_US.UTF-8",
        ]
        let environment = ProcessRunner.environment(inheriting: inherited)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"]?.contains("/custom/bin") == true)
    }

    @Test func configurationFolderIsKept() {
        let environment = ProcessRunner.environment(inheriting: ["CLAUDE_CONFIG_DIR": "/tmp/existing"])
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/existing")
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
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
