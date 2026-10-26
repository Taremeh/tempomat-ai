import Foundation

/// One meter row from the CLI's `/usage` report: `usage_report.rate_limits.limits[]`.
/// Decoded with `.convertFromSnakeCase`.
struct LimitRow: Decodable, Sendable {
    struct Scope: Decodable, Sendable {
        struct Named: Decodable, Sendable { let displayName: String }
        let model: Named?
        let surface: Named?
    }

    let kind: String        // "session", "weekly_all", "weekly_scoped", …
    let group: String       // "session", "weekly"
    let percent: Double     // 0–100
    let resetsAt: String?   // ISO 8601
    let scope: Scope?
    let severity: String    // "normal", "warning", "critical"
    let isActive: Bool      // the server's pick for a single-value indicator
}

enum UsageError: Error {
    case cliNotFound
    case unsupportedCLI(version: String?)
    /// Not signed in to a Claude plan; `claude` is the binary that said so, when known.
    case notSignedIn(claude: URL?)
    case noMeters
    case cliFailed(String)
    case timedOut
}

enum UsageReportParser {
    private struct Envelope: Decodable {
        struct Report: Decodable {
            struct RateLimits: Decodable { let limits: [LimitRow]? }
            let rateLimits: RateLimits?
        }
        let usageReport: Report?
    }

    /// Picks the `usage_report` out of `claude -p "/usage" --output-format stream-json` output.
    static func parse(_ output: Data, cliVersion: String?) throws -> [LimitRow] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let text = String(decoding: output, as: UTF8.self)

        for line in text.split(separator: "\n") where line.contains("\"usage_report\"") {
            let envelope: Envelope
            do {
                envelope = try decoder.decode(Envelope.self, from: Data(line.utf8))
            } catch {
                throw UsageError.cliFailed("Unexpected usage report format: \(error.localizedDescription)")
            }
            // rate_limits is null when the CLI has no plan login (or a token without the profile scope).
            guard let rateLimits = envelope.usageReport?.rateLimits else { throw UsageError.notSignedIn(claude: nil) }
            guard let limits = rateLimits.limits, !limits.isEmpty else { throw UsageError.noMeters }
            return limits
        }
        throw UsageError.unsupportedCLI(version: cliVersion)
    }
}

/// A plan limit window, ready for display.
struct Meter: Identifiable, Sendable {
    enum RateUnit: Sendable {
        case perHour, perDay

        var label: String { self == .perHour ? "%/h" : "%/day" }
        /// Converts a rate in %/h into this unit.
        func display(_ perHour: Double) -> Double { self == .perHour ? perHour : perHour * 24 }
    }

    let id: String
    let title: String
    var percent: Double     // var so history can replay a past reading
    let resetsAt: Date?
    let severity: String
    let isActive: Bool
    /// Length of the rolling window, when known from its group.
    let window: TimeInterval?
    let unit: RateUnit

    init(_ row: LimitRow) {
        let scopeName = row.scope?.model?.displayName ?? row.scope?.surface?.displayName
        id = [row.kind, scopeName].compactMap { $0 }.joined(separator: ":")
        title = switch row.kind {
        case "session": "5-hour limit"
        case "weekly_all": "Weekly · all models"
        case "weekly_scoped": "Weekly · \(scopeName ?? "scoped")"
        default: [row.kind.replacingOccurrences(of: "_", with: " ").capitalized, scopeName]
            .compactMap { $0 }.joined(separator: " · ")
        }
        percent = row.percent
        resetsAt = row.resetsAt.flatMap(Meter.parseDate)
        severity = row.severity
        isActive = row.isActive
        window = switch row.group {
        case "session": 5 * 3600
        case "weekly": 7 * 86400
        default: nil
        }
        unit = row.group == "weekly" ? .perDay : .perHour
    }

    /// A past window's reading, for the History page.
    init(id: String, title: String, percent: Double, resetsAt: Date, window: TimeInterval, unit: RateUnit, severity: String) {
        self.id = id
        self.title = title
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        isActive = false
        self.window = window
        self.unit = unit
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
