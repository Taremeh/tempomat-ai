import Foundation
import Darwin

/// Reads the limits exposed by the signed-in ChatGPT/Codex account. The app-server owns
/// authentication; Tempomat never opens its credential files or starts a model turn.
actor CodexUsageSource: UsageSource {
    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex") }
    private let home: URL

    init(home: URL = CodexUsageSource.defaultHome) { self.home = home }

    func fetch() async throws -> [LimitRow] {
        guard let binary = Self.candidates().first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CodexUsageError.cliNotFound
        }
        let result = try await CodexUsageRPC.readLimits(executable: binary, home: home)
        return try CodexUsageParser.parse(result)
    }

    private static func candidates() -> [URL] {
        if let custom = UserDefaults.standard.string(forKey: "codexPath"), !custom.isEmpty {
            return [URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        ].map { URL(fileURLWithPath: $0) }
        paths += [
            "Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Applications/Codex.app/Contents/Resources/codex", ".local/bin/codex", ".npm-global/bin/codex",
        ].map { home.appending(path: $0) }
        return paths
    }
}

enum CodexUsageError: LocalizedError {
    case cliNotFound, unavailable, noMeters, timedOut, malformedResponse

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Install ChatGPT or Codex, or set the codexPath preference to your Codex CLI executable."
        case .unavailable:
            "ChatGPT usage is unavailable. Open ChatGPT or Codex and sign in to the account for this profile."
        case .noMeters:
            "This ChatGPT account did not report any usage windows. API-key accounts do not expose subscription limits."
        case .timedOut:
            "The ChatGPT usage check timed out. It will retry automatically."
        case .malformedResponse:
            "The installed Codex CLI returned an unsupported usage response. Update ChatGPT or Codex and try again."
        }
    }
}

/// Decodes the documented account/rateLimits/read result (not the JSON-RPC envelope).
enum CodexUsageParser {
    private struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }
    private struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }
    private struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Double?
        let resetsAt: Double?
    }

    static func parse(_ data: Data) throws -> [LimitRow] {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw CodexUsageError.malformedResponse }
        let buckets: [(String, Bucket)]
        if let map = response.rateLimitsByLimitId, !map.isEmpty {
            buckets = map.sorted { lhs, rhs in
                if (lhs.key == "codex") != (rhs.key == "codex") { return lhs.key == "codex" }
                return lhs.key < rhs.key
            }
        } else if let legacy = response.rateLimits {
            buckets = [(legacy.limitId ?? "codex", legacy)]
        } else { throw CodexUsageError.noMeters }

        let iso = ISO8601DateFormatter()
        var rows: [LimitRow] = []
        for (id, bucket) in buckets {
            for (name, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                // An absent percentage is unknown, never 0% used.
                guard let window, let percent = window.usedPercent, percent.isFinite else { continue }
                let minutes = window.windowDurationMins.flatMap { $0.isFinite && $0 > 0 && $0 < Double(Int.max) / 60 ? $0 : nil }
                let duration = minutes.map { $0 * 60 }
                let reset = window.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                let label = durationTitle(minutes: minutes, fallback: name)
                let title = buckets.count > 1 ? "\(bucket.limitName ?? id) · \(label)" : label
                rows.append(LimitRow(
                    kind: "codex_\(id)_\(name)", group: "codex", percent: min(100, max(0, percent)),
                    resetsAt: reset.map { iso.string(from: $0) }, scope: nil,
                    severity: percent >= 90 ? "critical" : percent >= 70 ? "warning" : "normal",
                    isActive: false, displayTitle: title, windowDuration: duration
                ))
            }
        }
        guard !rows.isEmpty else { throw CodexUsageError.noMeters }
        // The endpoint doesn't designate an active window; put the fullest one on the gauge.
        let active = rows.indices.max { rows[$0].percent < rows[$1].percent } ?? 0
        rows[active].isActive = true
        return rows
    }

    private static func durationTitle(minutes: Double?, fallback: String) -> String {
        guard let minutes else { return "\(fallback.capitalized) limit" }
        switch minutes {
        case 10080: return "Weekly limit"
        case 1440: return "Daily limit"
        case _ where minutes.truncatingRemainder(dividingBy: 1440) == 0:
            return "\(Int(minutes / 1440))-day limit"
        case _ where minutes.truncatingRemainder(dividingBy: 60) == 0:
            return "\(Int(minutes / 60))-hour limit"
        default: return "\(minutes.formatted(.number.precision(.fractionLength(0...1))))-minute limit"
        }
    }
}

/// One short stdio connection: initialize, acknowledge, read limits, then close. No thread
/// or turn is created. Stderr is discarded so auth diagnostics cannot leak into the UI.
enum CodexUsageRPC {
    static func readLimits(executable: URL, home: URL, timeout: TimeInterval = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try read(executable: executable, home: home, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func read(executable: URL, home: URL, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CODEX_") && !key.hasPrefix("OPENAI_")
        }
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"]]
            .compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        // A child exiting during the handshake must throw EPIPE, never signal the host app.
        _ = Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw CodexUsageError.unavailable }

        let deadline = Date().addingTimeInterval(timeout)
        let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let kill = DispatchWorkItem { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1, execute: kill)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let cleanupKill = DispatchWorkItem {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: cleanupKill)
            // Keep the hard deadline armed until the child has actually exited.
            process.waitUntilExit()
            cleanupKill.cancel()
            terminate.cancel()
            kill.cancel()
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        var pending = Data()
        func response(id: Int) throws -> Data {
            while true {
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
                        throw CodexUsageError.unavailable
                    }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else {
                    throw Date() >= deadline ? CodexUsageError.timedOut : CodexUsageError.unavailable
                }
                pending.append(chunk)
                guard pending.count <= 1_048_576 else { throw CodexUsageError.malformedResponse }
            }
        }
        do {
            try send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "tempomat_ai", "title": "Tempomat AI", "version": "1.0"]
            ]])
            _ = try response(id: 1)
            try send(["method": "initialized", "params": [:]])
            try send(["id": 2, "method": "account/rateLimits/read"])
            return try response(id: 2)
        } catch let error as CodexUsageError { throw error }
        catch { throw Date() >= deadline ? CodexUsageError.timedOut : CodexUsageError.unavailable }
    }
}
