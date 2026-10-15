import Foundation
import Testing
@testable import AITempomat

struct CodexUsageTests {
    @Test func testWeeklyOnlyPrimaryKeepsActualWindow() throws {
        let rows = try CodexUsageParser.parse(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1792699471},"secondary":null}}}"#.utf8))
        #expect(rows.count == 1)
        let meter = Meter(rows[0])
        #expect(meter.title == "Weekly limit")
        #expect(meter.window == 604800.0)
        #expect(meter.unit == .perDay)
        #expect(meter.percent == 21)
        #expect(meter.resetsAt?.timeIntervalSince1970 == 1792699471)
    }

    @Test func testMapOverridesLegacyAndPreservesSeparateBuckets() throws {
        let json = #"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300}},"review":{"limitName":"Code review","primary":{"usedPercent":80,"windowDurationMins":15},"secondary":{"usedPercent":30,"windowDurationMins":1440}}}}"#
        let rows = try CodexUsageParser.parse(Data(json.utf8))
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.kind)).count == 3)
        #expect(rows.filter(\.isActive).map(\.percent) == [80])
        #expect(!(rows.contains { $0.percent == 99 }))
        #expect(rows.map(Meter.init).map(\.window) == [18000, 900, 86400])
        #expect(rows.contains { $0.displayTitle == "Code review · 15-minute limit" })
    }

    @Test func testLegacyFallbackAndUnknownDuration() throws {
        let rows = try CodexUsageParser.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":0},"secondary":null}}"#.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].percent == 0)
        #expect(Meter(rows[0]).window == nil)
        #expect(Meter(rows[0]).resetsAt == nil)
    }

    @Test func testMissingPercentIsNotReportedAsZero() throws {
        for json in [
            #"{"rateLimits":null,"rateLimitsByLimitId":null}"#,
            #"{"rateLimits":{"primary":null,"secondary":null}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300}}}"#,
        ] {
            do {
                _ = try CodexUsageParser.parse(Data(json.utf8))
                Issue.record("Expected unavailable meters")
            } catch {
                guard case CodexUsageError.noMeters = error else { Issue.record("Expected unavailable meters"); return }
            }
        }
    }

    @Test func testExistingClaudeRowsKeepTheirLabelsAndWindows() throws {
        let json = #"{"usage_report":{"rate_limits":{"limits":[{"kind":"session","group":"session","percent":25,"resets_at":null,"scope":null,"severity":"normal","is_active":true}]}}}"#
        let rows = try UsageReportParser.parse(Data(json.utf8), cliVersion: "test")
        let meter = try #require(rows.first.map(Meter.init))
        #expect(meter.title == "5-hour limit")
        #expect(meter.window == 18000)
        #expect(meter.unit == .perHour)
    }

    @Test func testRPCPerformsOnlyUsageHandshakeWithProfileHome() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "codex")
        let record = folder.appending(path: "requests")
        try writeExecutable("""
        #!/bin/sh
        printf '%s\\n' "$CODEX_HOME" > '\(record.path)'
        IFS= read -r line
        printf '%s\\n' "$line" >> '\(record.path)'
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        printf '%s\\n' "$line" >> '\(record.path)'
        IFS= read -r line
        printf '%s\\n' "$line" >> '\(record.path)'
        printf '%s\\n' '{"method":"irrelevant/notification","params":{}}'
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300}}}}'
        """, to: script)
        let result = try await CodexUsageRPC.readLimits(executable: script, home: folder, timeout: 3)
        #expect(try CodexUsageParser.parse(result).first?.percent == 42)
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        #expect(String(lines[0]) == folder.path)
        let methods = try lines.dropFirst().map { line -> String? in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["method"] as? String
        }
        #expect(methods == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test func testRPCDoesNotExposeServerDiagnostics() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "codex")
        try writeExecutable("""
        #!/bin/sh
        IFS= read -r line
        printf '%s\\n' 'private diagnostic fixture' >&2
        printf '%s\\n' '{"id":1,"error":{"message":"private diagnostic fixture"}}'
        """, to: script)
        do {
            _ = try await CodexUsageRPC.readLimits(executable: script, home: folder, timeout: 3)
            Issue.record("Expected an unavailable account")
        } catch {
            guard case CodexUsageError.unavailable = error else { Issue.record("Expected an unavailable account"); return }
            #expect(!(error.localizedDescription.contains("private diagnostic fixture")))
        }
    }

    @Test func testUnresponsiveProcessIsKilledAtDeadline() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "codex")
        // Ignore polite termination to exercise the hard stop too; no child process is spawned.
        try writeExecutable("""
        #!/bin/sh
        trap '' TERM
        while IFS= read -r line; do :; done
        """, to: script)
        let start = Date()
        do {
            _ = try await CodexUsageRPC.readLimits(executable: script, home: folder, timeout: 0.2)
            Issue.record("Expected a timeout")
        } catch {
            guard case CodexUsageError.timedOut = error else { Issue.record("Expected a timeout"); return }
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempomat-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
