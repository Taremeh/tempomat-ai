import Foundation

/// How fast a meter is filling, and where that pace leads.
struct Pace: Sendable {
    enum Basis: Sendable {
        case recent(TimeInterval)   // slope over this much recent history
        case windowAverage          // percent used ÷ time since the window opened
        case unknown
    }

    enum Status: Sendable { case cruising, overPace, limitReached, unknown }

    /// Current burn rate in %/h.
    let rate: Double?
    let basis: Basis
    /// The %/h that lands exactly on 100% at reset: the cruise-control set speed.
    let setpoint: Double?
    /// When 100% is reached at the current rate, if that is before the reset.
    let limitAt: Date?
    /// Percent used at reset at the current rate, capped at 100.
    let projectedAtReset: Double?
    var reached = false

    /// Burn rate as a share of the set speed: 100% runs out exactly at reset.
    var relative: Double? {
        guard let rate, let setpoint, setpoint > 0 else { return nil }
        return rate / setpoint * 100
    }

    var status: Status {
        if reached { return .limitReached }
        guard let rate else { return .unknown }
        if limitAt != nil { return .overPace }
        if let setpoint, rate > setpoint { return .overPace }
        return .cruising
    }
}

/// Timestamped usage samples per meter, used to measure the burn rate.
struct History: Codable, Sendable {
    struct Sample: Codable, Sendable { let t: Date; let p: Double }
    struct Track: Codable, Sendable { var resetsAt: Date?; var samples: [Sample] }

    private(set) var tracks: [String: Track] = [:]

    init() {}

    /// One past window's readings, to replay them in the history charts.
    init(_ samples: [Sample], of meter: Meter) {
        tracks[meter.id] = Track(resetsAt: meter.resetsAt, samples: samples)
    }

    /// Adds a reading. When it opens a new window, returns the window that ended, so it can be kept.
    @discardableResult
    mutating func record(_ meter: Meter, at now: Date, percent: Double? = nil) -> Track? {
        let percent = percent ?? meter.percent
        var track = tracks[meter.id] ?? Track(resetsAt: meter.resetsAt, samples: [])

        // A new window started: usage dropped, or the reset time moved (it jitters by a second or so).
        let usageDropped = track.samples.last.map { percent + 0.5 < $0.p } ?? false
        let resetMoved = both(track.resetsAt, meter.resetsAt).map { abs($0.0.timeIntervalSince($0.1)) > 120 } ?? false
        var ended: Track?
        if usageDropped || resetMoved {
            ended = track
            track.samples.removeAll()
        }

        track.resetsAt = meter.resetsAt
        track.samples.append(Sample(t: now, p: percent))
        let horizon = now.addingTimeInterval(-(meter.window ?? 86400))
        track.samples.removeAll { $0.t < horizon }
        tracks[meter.id] = track
        return ended
    }

    func pace(for meter: Meter, at now: Date, method: PaceMethod) -> Pace {
        if meter.percent >= 100 {
            return Pace(rate: nil, basis: .unknown, setpoint: nil, limitAt: nil, projectedAtReset: 100, reached: true)
        }

        // Each method falls back to the other when it has nothing to go on.
        let overall = overallRate(for: meter, at: now).map { ($0, Pace.Basis.windowAverage) }
        let recent = recentRate(for: meter, at: now).map { ($0.rate, Pace.Basis.recent($0.span)) }
        let picked = method == .overall ? overall ?? recent : recent ?? overall
        let rate = picked?.0
        let basis = picked?.1 ?? .unknown

        let hoursLeft = meter.resetsAt.map { max(0, $0.timeIntervalSince(now) / 3600) }
        let setpoint = hoursLeft.flatMap { $0 > 0 ? (100 - meter.percent) / $0 : nil }

        var limitAt: Date?
        if let rate, rate > 0 {
            let hit = now.addingTimeInterval((100 - meter.percent) / rate * 3600)
            if meter.resetsAt.map({ hit < $0 }) ?? true { limitAt = hit }
        }
        let projected = both(rate, hoursLeft).map { min(100, meter.percent + $0.0 * $0.1) }

        return Pace(rate: rate, basis: basis, setpoint: setpoint, limitAt: limitAt, projectedAtReset: projected)
    }

    /// One recorded sample, with the relative pace as it read at that moment.
    struct PacePoint: Sendable {
        let t: Date
        let used: Double
        let relative: Double?
    }

    /// A meter's recorded samples, at most about `limit` of them, each with the pace computed
    /// from what had been recorded by then.
    func trajectory(for meter: Meter, method: PaceMethod, limit: Int = 200) -> [PacePoint] {
        guard let samples = tracks[meter.id]?.samples, !samples.isEmpty else { return [] }
        var indices = Array(stride(from: 0, to: samples.count, by: max(1, samples.count / limit)))
        if indices.last != samples.count - 1 { indices.append(samples.count - 1) }
        return indices.map { index in
            let sample = samples[index]
            var past = self
            past.tracks[meter.id]?.samples = Array(samples[...index])
            var then = meter
            then.percent = sample.p
            return PacePoint(t: sample.t, used: sample.p,
                             relative: past.pace(for: then, at: sample.t, method: method).relative)
        }
    }

    /// Percent used ÷ time since the window opened.
    private func overallRate(for meter: Meter, at now: Date) -> Double? {
        guard let window = meter.window, let resetsAt = meter.resetsAt else { return nil }
        let elapsed = window - resetsAt.timeIntervalSince(now)
        return elapsed >= 5 * 60 ? meter.percent / (elapsed / 3600) : nil
    }

    /// Slope over recent samples: 30 minutes for the session, 12 hours for the week,
    /// long enough to see several 1% steps.
    private func recentRate(for meter: Meter, at now: Date) -> (rate: Double, span: TimeInterval)? {
        let lookback: TimeInterval = meter.unit == .perDay ? 12 * 3600 : 30 * 60
        let samples = tracks[meter.id]?.samples ?? []
        guard let latest = samples.last, let first = samples.first else { return nil }
        let anchor = samples.last { $0.t <= now.addingTimeInterval(-lookback) } ?? first
        let span = latest.t.timeIntervalSince(anchor.t)
        guard span >= lookback / 2 else { return nil }
        return (max(0, latest.p - anchor.p) / (span / 3600), span)
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
