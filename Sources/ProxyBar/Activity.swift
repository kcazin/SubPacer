import Foundation

/// Request activity in 10-minute buckets, reconstructed from the proxy's per-account
/// `recent_requests` (the last ~200 minutes) on every refresh. Each refresh sees 3h20 of
/// history, so short gaps such as the Mac sleeping are backfilled; longer gaps stay
/// unobserved instead of counting as idle.
@MainActor
final class ActivityLog {
    nonisolated static let bucketLength: TimeInterval = 600

    private(set) var counts: [Int: Int] = [:]
    private let url: URL
    private let retentionBuckets = 28 * 86_400 / 600

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ProxyBar")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "activity.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Int(key).map { ($0, value) } })
        }
    }

    /// `series` holds one array of per-bucket request counts per account, oldest first,
    /// with the last element being the bucket that contains `now`.
    func record(_ series: [[Int]], now: Date) {
        let current = Int(now.timeIntervalSince1970 / Self.bucketLength)
        var totals: [Int: Int] = [:]
        for buckets in series {
            for (offset, count) in buckets.reversed().enumerated() {
                totals[current - offset, default: 0] += count
            }
        }
        // Buckets only grow while they're current, so keep the largest value seen.
        for (index, total) in totals {
            counts[index] = max(counts[index] ?? 0, total)
        }
        counts = counts.filter { $0.key >= current - retentionBuckets }
    }

    func save() {
        let encoded = Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// When you're usually active, by hour of day, learned from `ActivityLog`.
struct ActivityProfile: Sendable {
    /// Hours of day assumed quiet until there's enough data: 23:00–08:00.
    static let defaultQuietHours: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6, 7]
    /// An hour needs observations on this many different days before it counts as learned.
    static let daysToLearn = 2
    /// Hours with less than this share of the busiest hour's activity count as quiet.
    static let quietThreshold = 0.15

    /// Requests per hour for each hour of day, or nil while that hour is still being learned.
    let rates: [Double?]
    /// Relative activity per hour of day (0–1): learned where possible, default otherwise.
    let weights: [Double]
    /// The longest run of quiet hours: start hour and length in hours (wrapping past midnight).
    let quiet: (start: Int, length: Int)?

    var learnedHours: Int { rates.compactMap { $0 }.count }
    var isLearned: Bool { learnedHours == 24 }

    static let `default` = build(from: [:])

    static func build(from counts: [Int: Int], calendar: Calendar = .current) -> ActivityProfile {
        var requests = [Int](repeating: 0, count: 24)
        var observed = [Int](repeating: 0, count: 24)
        var days = [Set<Int>](repeating: [], count: 24)
        for (index, count) in counts {
            let date = Date(timeIntervalSince1970: Double(index) * ActivityLog.bucketLength)
            let hour = calendar.component(.hour, from: date)
            requests[hour] += count
            observed[hour] += 1
            days[hour].insert(calendar.ordinality(of: .day, in: .era, for: date) ?? 0)
        }

        let rates: [Double?] = (0..<24).map { hour in
            guard days[hour].count >= daysToLearn, observed[hour] >= 6 else { return nil }
            return Double(requests[hour]) / (Double(observed[hour]) / 6)
        }
        let peak = rates.compactMap { $0 }.max() ?? 0
        let weights: [Double] = (0..<24).map { hour in
            if let rate = rates[hour], peak > 0 { return rate / peak }
            return defaultQuietHours.contains(hour) ? 0 : 1
        }
        return ActivityProfile(rates: rates, weights: weights, quiet: longestQuietRun(weights))
    }

    private static func longestQuietRun(_ weights: [Double]) -> (start: Int, length: Int)? {
        let quiet = weights.map { $0 < quietThreshold }
        guard quiet.contains(true) else { return nil }
        if !quiet.contains(false) { return (0, 24) }
        var best: (start: Int, length: Int)?
        // Start scanning just after an active hour so runs that wrap midnight stay whole.
        let origin = (quiet.firstIndex(of: false)! + 1) % 24
        var runStart: Int?
        for step in 0..<24 {
            let hour = (origin + step) % 24
            if quiet[hour] {
                if runStart == nil { runStart = step }
                let length = step - runStart! + 1
                if length > (best?.length ?? 0) { best = ((origin + runStart!) % 24, length) }
            } else {
                runStart = nil
            }
        }
        return best
    }

    func weight(at date: Date, calendar: Calendar = .current) -> Double {
        weights[calendar.component(.hour, from: date)]
    }

    /// Activity-weighted hours between two dates.
    func weightedHours(from start: Date, to end: Date, calendar: Calendar = .current) -> Double {
        var total = 0.0
        var cursor = start
        while cursor < end {
            let next = min(cursor.addingTimeInterval(ActivityLog.bucketLength), end)
            total += weight(at: cursor, calendar: calendar) * next.timeIntervalSince(cursor) / 3600
            cursor = next
        }
        return total
    }

    /// Quiet periods that overlap `start..<end`, clipped to it.
    func quietPeriods(from start: Date, to end: Date, calendar: Calendar = .current) -> [DateInterval] {
        guard let quiet, quiet.length < 24, end > start else { return [] }
        var periods: [DateInterval] = []
        var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start))!
        while day < end {
            if let blockStart = calendar.date(bySettingHour: quiet.start, minute: 0, second: 0, of: day) {
                let blockEnd = blockStart.addingTimeInterval(TimeInterval(quiet.length) * 3600)
                let clippedStart = max(blockStart, start)
                let clippedEnd = min(blockEnd, end)
                if clippedEnd > clippedStart { periods.append(DateInterval(start: clippedStart, end: clippedEnd)) }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return periods
    }

    func isQuiet(_ date: Date) -> Bool { weight(at: date) < Self.quietThreshold }
}

// MARK: - Forecasts

enum ActivityForecast {
    /// Projects a long window (e.g. weekly) by assuming future usage follows your activity
    /// pattern at the same rate per active hour as so far in this window.
    static func projection(for window: QuotaWindow, profile: ActivityProfile, now: Date = Date()) -> Projection? {
        guard let reset = window.resetsAt, let length = window.windowLength, reset > now else { return nil }
        let start = reset.addingTimeInterval(-length)
        let elapsedFraction = window.elapsedFraction(now: now)
        let used = window.usedPercent
        let basis: Projection.Basis = profile.learnedHours >= 12 ? .activityProfile : .defaultHours

        if used >= 100 {
            return Projection(outcome: .limitReached, basis: nil, elapsedFraction: elapsedFraction)
        }
        let elapsedWeight = profile.weightedHours(from: start, to: now)
        guard elapsedWeight >= 2 else { return nil }
        if used == 0 {
            return Projection(outcome: .noUsage, basis: basis, elapsedFraction: elapsedFraction)
        }

        let ratePerWeightedHour = used / elapsedWeight
        var cumulative = used
        var cursor = now
        while cursor < reset {
            let next = min(cursor.addingTimeInterval(ActivityLog.bucketLength), reset)
            cumulative += ratePerWeightedHour * profile.weight(at: cursor) * next.timeIntervalSince(cursor) / 3600
            if cumulative >= 100 {
                return Projection(outcome: .runsOut(at: next), basis: basis, elapsedFraction: elapsedFraction)
            }
            cursor = next
        }
        return Projection(outcome: .lastsUntilReset(usedAtReset: cumulative), basis: basis, elapsedFraction: elapsedFraction)
    }

}

/// What your quiet hours mean for one account's weekly quota.
enum OffHoursInsight: Sendable {
    /// Quota projected to expire unused, spread over the quiet periods left before reset.
    case spare(percent: Double, reset: Date, nights: [DateInterval])
    /// You're on track to use it all; nothing to gain overnight.
    case noSpare(reset: Date)
    /// The account is used up. `resetsTonight` when the weekly reset falls inside tonight's quiet hours.
    case usedUp(until: Date, resetsTonight: Bool)

    var perNight: Double? {
        if case .spare(let percent, _, let nights) = self, !nights.isEmpty { return percent / Double(nights.count) }
        return nil
    }

    static func make(for account: AccountUsage, profile: ActivityProfile, now: Date = Date()) -> OffHoursInsight? {
        guard let weekly = account.weeklyWindow, let reset = weekly.resetsAt, reset > now else { return nil }

        if account.isBlocked {
            guard let until = account.blockedUntil else { return nil }
            let tonight = profile.quietPeriods(from: now, to: now.addingTimeInterval(36 * 3600)).first
            return .usedUp(until: until, resetsTonight: tonight?.contains(until) ?? false)
        }
        guard let projection = account.projections[weekly.id] else { return nil }
        switch projection.outcome {
        case .lastsUntilReset(let usedAtReset):
            let spare = 100 - usedAtReset
            guard spare >= 3 else { return .noSpare(reset: reset) }
            return .spare(percent: spare, reset: reset, nights: profile.quietPeriods(from: now, to: reset))
        case .noUsage:
            return .spare(percent: 100, reset: reset, nights: profile.quietPeriods(from: now, to: reset))
        case .runsOut, .limitReached:
            return .noSpare(reset: reset)
        }
    }
}
