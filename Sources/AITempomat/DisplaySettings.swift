import Foundation

/// What the big dial and the menu bar show.
enum DisplayMode: String, CaseIterable {
    /// Fuel gauge: how much of the limit is left (or used).
    case total
    /// Speedometer: burn rate relative to the pace that runs out exactly at reset.
    case relative
}

/// Whether amounts read as fuel left in the tank or fuel burned.
enum AmountShown: String, CaseIterable {
    case left, used

    func value(_ percentUsed: Double) -> Double { self == .left ? 100 - percentUsed : percentUsed }
}

/// How the burn rate is measured.
enum PaceMethod: String, CaseIterable {
    /// Everything used since the window opened, over all the time since then.
    case overall
    /// The slope over a short recent window, so it reacts to what you're doing now.
    case sensitive
}

/// How much the panel shows.
enum PanelLayout: String, CaseIterable {
    /// The tempomat alone.
    case reduced
    /// History on the left, the tempomat in the middle, running sessions and the outlook on the right.
    case expanded

    var width: CGFloat { self == .expanded ? 994 : 340 }
}

/// UserDefaults keys, shared by the panel and the menu bar label.
enum SettingsKey {
    static let panelLayout = "panelLayout"
    static let mode = "displayMode"
    static let amount = "amountShown"
    static let paceMethod = "paceMethod"
    /// The meter swapped onto the big gauge and the server's pick it replaced.
    static let gaugeChoice = "gaugeChoice"
    /// Whether the app asks once a day if a newer version is out. On unless turned off.
    static let checkForUpdates = "checkForUpdates"
    /// When the server last answered an update check, so the day, week and month flags go out until one is answered.
    static let updateCheckCounted = "updateCheckCounted"
    /// A check URL in place of the one built into the app, for testing a server or a fork's.
    static let updateCheckURL = "updateCheckURL"
    /// When that server last answered a check, kept apart from the app's own server's.
    static let updateCheckCountedOverride = "updateCheckCountedOverride"
}
