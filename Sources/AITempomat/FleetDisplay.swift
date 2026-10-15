import SwiftUI

/// Times on round clock values (every 15 minutes, hour, 3 hours or day) inside `window`,
/// in local time.
func clockTicks(in window: ClosedRange<Date>, every step: TimeInterval) -> [Date] {
    let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: window.lowerBound))
    var tick = ((window.lowerBound.timeIntervalSince1970 + offset) / step).rounded(.up) * step - offset
    var result: [Date] = []
    while tick <= window.upperBound.timeIntervalSince1970 {
        result.append(Date(timeIntervalSince1970: tick))
        tick += step
    }
    return result
}

/// How much history the trajectories cover.
enum TrajectoryRange: String, CaseIterable {
    case hour = "1h", threeHours = "3h", twelveHours = "12h"

    var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .threeHours: 3 * 3600
        case .twelveHours: 12 * 3600
        }
    }

    /// Spacing of the time axis labels.
    var tickMinutes: Int {
        switch self {
        case .hour: 15
        case .threeHours: 60
        case .twelveHours: 180
        }
    }

    var caption: String {
        switch self {
        case .hour: "last hour"
        case .threeHours: "last 3 hours"
        case .twelveHours: "last 12 hours"
        }
    }
}

/// Which tokens a count includes.
enum TokenMetric: String, CaseIterable {
    /// Everything each request processed: input, cache writes, cache reads and output.
    case all
    /// What the models wrote, thinking included.
    case output

    func count(_ request: FleetSession.Request) -> Int { self == .all ? request.total : request.output }
}

extension SettingsKey {
    static let trajectoryRange = "trajectoryRange"
}

/// Categorical colors for sessions, in fixed order, stepped separately for light and dark.
/// Validated for colorblind separation on the panel's light and dark surfaces.
enum SeriesPalette {
    static let count = 8
    private static let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4, 0x008300, 0x4A3AA7, 0xE34948]
    private static let dark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181, 0x008300, 0x9085E9, 0xE66767]

    /// Past the eighth session, the rest share gray.
    static func color(_ slot: Int?, _ scheme: ColorScheme) -> Color {
        guard let slot, slot < count else { return .gray }
        let hex = scheme == .dark ? dark[slot] : light[slot]
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension FleetSession {
    /// Tokens of the requests made inside `window`.
    func tokens(in window: ClosedRange<Date>, metric: TokenMetric = .all) -> Int {
        requests.reduce(0) { window.contains($1.t) ? $0 + metric.count($1) : $0 }
    }

    /// The current burn rate: tokens per minute over the last `span` before `now`.
    func tokensPerMinute(now: Date, over span: TimeInterval, metric: TokenMetric = .all) -> Double {
        Double(tokens(in: now.addingTimeInterval(-span)...now, metric: metric)) / (span / 60)
    }

    /// Tasks still open, or nil when the session lists none.
    var tasksLeft: Int? { tasks.total > 0 ? tasks.active + tasks.pending : nil }
}

/// "1 task", "3 tasks".
func counted(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
