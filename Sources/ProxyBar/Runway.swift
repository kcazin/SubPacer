import Foundation

/// Whether a provider's accounts, pooled, keep you going until every limit has reset.
/// The proxy moves requests to another account when one is used up, so you only run out
/// when all of them are at once.
struct Runway: Identifiable, Sendable {
    struct Outage: Sendable {
        let interval: DateInterval
        /// The limit whose exhaustion left no account available.
        let window: String
    }

    var id: String { providerID }
    let providerID: String
    let accountCount: Int
    let start: Date
    /// The latest long-window (weekly) reset in the pool; past it every limit is fresh.
    let horizon: Date
    /// Long-window resets before `horizon`, where an account gets its quota back.
    let resets: [Date]
    /// Stretches before `horizon` where every account is projected to be used up.
    let outages: [Outage]
    /// Projected quota left across the pool (0–1), evenly spaced from `start` to `horizon`.
    /// Uses the weekly limits, so it steps down through each day and jumps when an account resets.
    let forecast: [Double]
    /// The largest multiple of your usual pace that still never runs out
    /// (below 1: how far you'd need to slow down). Nil when nothing can be gained by pacing.
    let headroom: Double?
    let basis: Projection.Basis
    /// Per account ID: how its current weekly window ends at your usual pace, with the load shared across the pool.
    let weeklyOutcomes: [String: Projection.Outcome]

    var provider: (any QuotaProvider.Type)? { QuotaProviders.provider(for: providerID) }
    var runsOutAt: Date? { outages.first?.interval.start }
}

enum RunwayForecast {
    private static let step: TimeInterval = 600
    private static let maxHeadroom = 8.0

    /// One primary limit of one account.
    private struct Lane {
        let account: Int
        let kind: String
        let label: String
        let length: TimeInterval
        let isLong: Bool
        var used: Double
        var reset: Date?
        /// Percent of this limit used per activity-weighted hour.
        let rate: Double
        /// The reset ending the current window, and how that window turns out.
        let firstReset: Date?
        var outcome: Projection.Outcome?
    }

    /// Simulates the pool forward in 10-minute steps: demand follows your activity pattern
    /// (or your current pace until the running session resets), is split across whichever
    /// accounts still have quota, and limits refill when they reset.
    @MainActor
    static func make(
        providerID: String,
        accounts: [AccountUsage],
        samples: (_ account: String, _ window: String) -> [UsageSample],
        profile: ActivityProfile,
        now: Date = Date()
    ) -> Runway? {
        // Accounts that have never reported quota can't be planned around.
        let pool = accounts.filter { !$0.snapshot.windows.isEmpty }
        guard !pool.isEmpty else { return nil }

        var lanes: [Lane] = []
        /// Per account: activity intensity relative to the profile, and until when, while a session is running.
        var currentPace: [Int: (intensity: Double, until: Date)] = [:]

        for (index, account) in pool.enumerated() {
            for window in account.snapshot.windows where window.isPrimary {
                guard let length = window.windowLength else { continue }
                let isLong = length >= 86_400
                let reset = window.resetsAt.flatMap { $0 > now ? $0 : nil }
                let history = samples(account.id, window.id)
                // Activity-weighted hours since the window started.
                let elapsed = reset.map { profile.weightedHours(from: $0.addingTimeInterval(-length), to: now) }
                let rate: Double? = isLong
                    // Early in the week a few minutes of data shouldn't extrapolate wildly.
                    ? elapsed.map { window.usedPercent / max($0, 2) } ?? 0
                    : historicalRate(history, profile: profile, now: now)
                        ?? elapsed.flatMap { $0 >= 0.25 ? window.usedPercent / $0 : nil }
                lanes.append(Lane(
                    account: index, kind: window.id, label: window.label, length: length, isLong: isLong,
                    used: reset == nil ? 0 : window.usedPercent, reset: reset, rate: rate ?? 0,
                    firstReset: reset, outcome: reset != nil && window.usedPercent >= 100 ? .limitReached : nil
                ))
                // How hard you're working right now, carried until the running session resets.
                if !isLong, let reset, let rate, rate > 0,
                   let recent = Projection.recentRate(for: window, samples: history, now: now) {
                    currentPace[index] = (recent.rate * 3600 / rate, reset)
                }
            }
        }

        let longResets = lanes.filter(\.isLong).compactMap(\.reset)
        guard let horizon = (longResets.max() ?? lanes.compactMap(\.reset).max())
            .map({ min($0, now.addingTimeInterval(8 * 86_400)) }) else { return nil }

        func intensity(account: Int, at date: Date) -> Double {
            if let pace = currentPace[account], date < pace.until { return pace.intensity }
            return profile.weight(at: date)
        }

        // The forecast follows the weekly limits; sessions refill too often to be worth drawing.
        let tracked = lanes.contains(where: \.isLong) ? lanes.indices.filter { lanes[$0].isLong } : Array(lanes.indices)
        func poolRemaining(_ lanes: [Lane]) -> Double {
            let perAccount = pool.indices.compactMap { account -> Double? in
                tracked.filter { lanes[$0].account == account }.map { max(0, 100 - lanes[$0].used) / 100 }.min()
            }
            return perAccount.isEmpty ? 0 : perAccount.reduce(0, +) / Double(perAccount.count)
        }

        func simulate(pace multiplier: Double, stopAtFirstOutage: Bool) -> (outages: [Runway.Outage], forecast: [Double], lanes: [Lane]) {
            var lanes = lanes
            var outages: [Runway.Outage] = []
            var forecast: [Double] = []
            var lastExhausted = lanes.first?.label ?? ""
            var cursor = now
            while cursor < horizon {
                let next = min(cursor.addingTimeInterval(step), horizon)
                let hours = next.timeIntervalSince(cursor) / 3600
                for index in lanes.indices {
                    if let reset = lanes[index].reset, reset <= cursor {
                        if reset == lanes[index].firstReset, lanes[index].outcome == nil {
                            lanes[index].outcome = .lastsUntilReset(usedAtReset: min(lanes[index].used, 100))
                        }
                        lanes[index].used = 0
                        lanes[index].reset = nil
                    }
                }
                if !stopAtFirstOutage { forecast.append(poolRemaining(lanes)) }
                let available = Set(pool.indices.filter { account in
                    !lanes.contains { $0.account == account && $0.used >= 100 }
                })
                if available.isEmpty {
                    if let last = outages.last, last.interval.end == cursor {
                        outages[outages.count - 1] = .init(interval: DateInterval(start: last.interval.start, end: next), window: last.window)
                    } else {
                        outages.append(.init(interval: DateInterval(start: cursor, end: next), window: lastExhausted))
                        if stopAtFirstOutage { return (outages, forecast, lanes) }
                    }
                } else {
                    // Demand for each limit is what every account would use, split over the available ones.
                    var demand: [String: Double] = [:]
                    for lane in lanes {
                        demand[lane.kind, default: 0] += lane.rate * intensity(account: lane.account, at: cursor) * hours * multiplier
                    }
                    for (kind, total) in demand where total > 0 {
                        let targets = lanes.indices.filter { lanes[$0].kind == kind && available.contains(lanes[$0].account) }
                        for index in targets {
                            let wasAvailable = lanes[index].used < 100
                            lanes[index].used += total / Double(targets.count)
                            if lanes[index].reset == nil { lanes[index].reset = cursor.addingTimeInterval(lanes[index].length) }
                            if wasAvailable && lanes[index].used >= 100 {
                                lastExhausted = lanes[index].label
                                if lanes[index].outcome == nil, let first = lanes[index].firstReset, cursor < first {
                                    lanes[index].outcome = .runsOut(at: next)
                                }
                            }
                        }
                    }
                }
                cursor = next
            }
            if !stopAtFirstOutage { forecast.append(poolRemaining(lanes)) }
            return (outages, forecast, lanes)
        }

        let (outages, forecast, finalLanes) = simulate(pace: 1, stopAtFirstOutage: false)
        var weeklyOutcomes: [String: Projection.Outcome] = [:]
        for lane in finalLanes where lane.firstReset != nil && lane.kind == pool[lane.account].weeklyWindow?.id {
            let used = min(lane.used, 100)
            weeklyOutcomes[pool[lane.account].id] = lane.outcome ?? (used > 0 ? .lastsUntilReset(usedAtReset: used) : .noUsage)
        }

        // Bisect for the fastest pace that never runs out. Pointless if even zero usage
        // runs out (every account is already used up) or there's no usage to scale.
        var headroom: Double?
        let hasDemand = lanes.contains { $0.rate > 0 }
        if hasDemand && simulate(pace: 0, stopAtFirstOutage: true).outages.isEmpty {
            if simulate(pace: maxHeadroom, stopAtFirstOutage: true).outages.isEmpty {
                headroom = maxHeadroom
            } else {
                var low = 0.0, high = maxHeadroom
                for _ in 0..<12 {
                    let middle = (low + high) / 2
                    if simulate(pace: middle, stopAtFirstOutage: true).outages.isEmpty { low = middle } else { high = middle }
                }
                headroom = low
            }
        }

        return Runway(
            providerID: providerID,
            accountCount: pool.count,
            start: now,
            horizon: horizon,
            resets: Array(Set(longResets.filter { $0 < horizon })).sorted(),
            outages: outages,
            forecast: forecast,
            headroom: headroom,
            basis: profile.learnedHours >= 12 ? .activityProfile : .defaultHours,
            weeklyOutcomes: weeklyOutcomes
        )
    }

    /// Percent per activity-weighted hour over the last day of readings, across any resets.
    private static func historicalRate(_ samples: [UsageSample], profile: ActivityProfile, now: Date) -> Double? {
        let recent = samples.filter { $0.date >= now.addingTimeInterval(-86_400) && $0.date <= now }
        guard let first = recent.first else { return nil }
        let hours = profile.weightedHours(from: first.date, to: now)
        guard hours >= 1 else { return nil }
        let increments = zip(recent, recent.dropFirst()).reduce(0) { $0 + max($1.1.used - $1.0.used, 0) }
        return increments / hours
    }
}
