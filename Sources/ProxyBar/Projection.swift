import Foundation

struct UsageSample: Codable, Sendable {
    let date: Date
    let used: Double
}

/// Rolling record of quota readings, persisted so projections survive restarts.
@MainActor
final class UsageHistory {
    private var series: [String: [UsageSample]] = [:]
    private let url: URL
    private let retention: TimeInterval = 8 * 86_400

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ProxyBar")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "history.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [UsageSample]].self, from: data) {
            series = decoded
        }
    }

    static func key(account: String, window: String) -> String { "\(account)|\(window)" }

    func record(_ used: Double, key: String, at date: Date) {
        var samples = series[key] ?? []
        samples.append(UsageSample(date: date, used: used))
        samples.removeAll { $0.date < date.addingTimeInterval(-retention) }
        series[key] = samples
    }

    func samples(for key: String) -> [UsageSample] { series[key] ?? [] }

    func save() {
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct Projection: Sendable {
    enum Outcome: Sendable {
        case noUsage
        case limitReached
        /// At the current pace the limit is hit before the window resets.
        case runsOut(at: Date)
        /// The window resets first; `usedAtReset` is the projected usage at that point.
        case lastsUntilReset(usedAtReset: Double)
    }

    enum Basis: String, Sendable {
        case recent = "your pace over the last hour"
        case recentDay = "your pace over the last 24h"
        case windowAverage = "your average pace since the window started"
        case activityProfile = "your pace during the hours you're usually active"
        case defaultHours = "your pace during 8:00–23:00 (still learning your actual hours)"
        case pooledUsage = "what your accounts used together over recent days, spread over the hours you're usually active"
    }

    let outcome: Outcome
    let basis: Basis?
    /// Share of the window already elapsed (0–1): where usage would be at an even pace.
    let elapsedFraction: Double?

    static func make(for window: QuotaWindow, samples: [UsageSample], now: Date = Date()) -> Projection? {
        guard let reset = window.resetsAt, let length = window.windowLength, reset > now else { return nil }
        let start = reset.addingTimeInterval(-length)
        let elapsed = min(max(now.timeIntervalSince(start), 0), length)
        let elapsedFraction = elapsed / length
        let used = window.usedPercent

        if used >= 100 {
            return Projection(outcome: .limitReached, basis: nil, elapsedFraction: elapsedFraction)
        }

        guard let estimate = recentRate(for: window, samples: samples, now: now) else { return nil }
        let (rate, basis) = estimate
        if used == 0 && rate == 0 {
            return Projection(outcome: .noUsage, basis: basis, elapsedFraction: elapsedFraction)
        }
        let remainingTime = reset.timeIntervalSince(now)
        if rate > 0 {
            let runOut = now.addingTimeInterval((100 - used) / rate)
            if runOut < reset {
                return Projection(outcome: .runsOut(at: runOut), basis: basis, elapsedFraction: elapsedFraction)
            }
        }
        let atReset = min(100, used + rate * remainingTime)
        return Projection(outcome: .lastsUntilReset(usedAtReset: atReset), basis: basis, elapsedFraction: elapsedFraction)
    }

    /// Current pace in percent per second: the trend of recent readings, or the average
    /// since the window started when there aren't enough of them.
    static func recentRate(for window: QuotaWindow, samples: [UsageSample], now: Date = Date()) -> (rate: Double, basis: Basis)? {
        guard let reset = window.resetsAt, let length = window.windowLength, reset > now else { return nil }
        let start = reset.addingTimeInterval(-length)
        let elapsed = min(max(now.timeIntervalSince(start), 0), length)

        // Prefer recent readings: they reflect how you're working right now.
        let isSession = length <= 6 * 3600
        let lookback: TimeInterval = isSession ? 3600 : 86_400
        let minimumSpan: TimeInterval = isSession ? 10 * 60 : 2 * 3600
        let recent = samples.filter { $0.date >= max(start, now.addingTimeInterval(-lookback)) && $0.date <= now }

        if let first = recent.first, let last = recent.last,
           last.date.timeIntervalSince(first.date) >= minimumSpan,
           let slope = slope(of: recent) {
            return (max(slope, 0), isSession ? .recent : .recentDay)
        } else if elapsed >= 10 * 60 {
            return (window.usedPercent / elapsed, .windowAverage)
        }
        return nil
    }

    /// Least-squares slope of usage over time, in percent per second.
    private static func slope(of samples: [UsageSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let origin = samples[0].date.timeIntervalSince1970
        let xs = samples.map { $0.date.timeIntervalSince1970 - origin }
        let ys = samples.map(\.used)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        let denominator = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard denominator > 0 else { return nil }
        let numerator = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        return numerator / denominator
    }
}

extension QuotaWindow {
    /// Share of the window already elapsed (0–1), or nil when its start can't be inferred.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let reset = resetsAt, let length = windowLength, reset > now else { return nil }
        return min(max(1 - reset.timeIntervalSince(now) / length, 0), 1)
    }
}
