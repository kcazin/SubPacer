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
    /// With smart routing using the accounts one at a time: how much weekly quota, in percent of one
    /// account's week, it keeps from resetting unused compared with an even split.
    var routingGain: Double?
    /// The emails of the accounts smart routing uses, first used first.
    var routeOrder: [String] = []
    /// Smart routing is on and has accounts to order, routed or not.
    var routingEnabled = false

    var routed: Bool { routingGain != nil }

    /// Weekly quota, in percent of one account's week, projected to reset unused across the pool.
    var unusedAtReset: Double {
        weeklyOutcomes.values.reduce(0) { total, outcome in
            if case .lastsUntilReset(let used) = outcome { total + max(0, 100 - used) } else { total }
        }
    }

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
    /// accounts still have quota, and limits refill when they reset. With `routeOrder` (account IDs,
    /// first used first) demand goes to the first account with quota and spills over to the next.
    @MainActor
    static func make(
        providerID: String,
        accounts: [AccountUsage],
        samples: (_ account: String, _ window: String) -> [UsageSample],
        profile: ActivityProfile,
        routeOrder: [String]? = nil,
        now: Date = Date()
    ) -> Runway? {
        // Accounts that have never reported quota can't be planned around.
        let pool = accounts.filter { !$0.snapshot.windows.isEmpty }
        guard !pool.isEmpty else { return nil }
        // Pool index to place in the routing order; accounts the proxy doesn't route come last.
        let routeRank: [Int: Int]? = routeOrder.map { order in
            Dictionary(uniqueKeysWithValues: pool.indices.map { ($0, order.firstIndex(of: pool[$0].id) ?? order.count + $0) })
        }

        var lanes: [Lane] = []
        /// Weekly usage per limit and account: recorded readings plus the window's start and current value.
        var longUsage: [String: [[UsageSample]]] = [:]
        /// Session use across the pool: lately (percent per hour) and usually (percent per weighted hour).
        var recentPace = 0.0, usualPace = 0.0
        var paceUntil: Date?

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
                if isLong {
                    var timeline = history.filter { $0.date < now }
                    if let reset { timeline.append(UsageSample(date: reset.addingTimeInterval(-length), used: 0)) }
                    timeline.append(UsageSample(date: now, used: window.usedPercent))
                    longUsage[window.id, default: []].append(timeline.sorted { $0.date < $1.date })
                }
                // How hard you're working right now, carried until the running session resets.
                if !isLong, let reset, let rate, rate > 0,
                   let recent = Projection.recentRate(for: window, samples: history, now: now) {
                    recentPace += recent.rate * 3600
                    usualPace += rate
                    paceUntil = min(paceUntil ?? reset, reset)
                }
            }
        }

        let longResets = lanes.filter(\.isLong).compactMap(\.reset)
        guard let horizon = (longResets.max() ?? lanes.compactMap(\.reset).max())
            .map({ min($0, now.addingTimeInterval(8 * 86_400)) }) else { return nil }

        // Pool-wide demand per limit, in percent of one account's limit per weighted hour.
        var demandRate: [String: Double] = [:]
        for lane in lanes { demandRate[lane.kind, default: 0] += lane.rate }
        var pooled = false
        for (kind, usage) in longUsage {
            if let rate = pooledRate(usage, profile: profile, now: now) {
                demandRate[kind] = rate
                pooled = true
            }
        }

        func intensity(at date: Date) -> Double {
            if let paceUntil, date < paceUntil { return recentPace / usualPace }
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

        /// How much of `total` each lane takes: an even split, or with routing, filling lanes in order.
        /// The order is worked out again at every step, the way SubPacer redoes it on each refresh: once an
        /// account's week resets, its fresh week goes behind the ones that reset sooner.
        func split(_ total: Double, over targets: [Int], lanes: [Lane]) -> [(lane: Int, amount: Double)] {
            guard let routeRank else { return targets.map { ($0, total / Double(targets.count)) } }
            func key(_ lane: Int) -> (Date, Int) {
                let account = lanes[lane].account
                let weekEnds = lanes.filter { $0.account == account && $0.isLong }.map { $0.reset ?? .distantFuture }.min()
                return (weekEnds ?? .distantFuture, routeRank[account]!)
            }
            let ordered = targets.sorted { key($0) < key($1) }
            var left = total
            var shares: [(lane: Int, amount: Double)] = []
            for index in ordered where left > 0 {
                let amount = index == ordered.last ? left : min(left, max(0, 100 - lanes[index].used))
                if amount > 0 { shares.append((index, amount)) }
                left -= amount
            }
            return shares
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
                    // Demand for each limit is split over the accounts that still have quota.
                    for (kind, rate) in demandRate where rate > 0 {
                        let total = rate * intensity(at: cursor) * hours * multiplier
                        let targets = lanes.indices.filter { lanes[$0].kind == kind && available.contains(lanes[$0].account) }
                        for (index, amount) in split(total, over: targets, lanes: lanes) {
                            let wasAvailable = lanes[index].used < 100
                            lanes[index].used += amount
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
        let hasDemand = demandRate.values.contains { $0 > 0 }
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
            basis: pooled ? .pooledUsage : profile.learnedHours >= 12 ? .activityProfile : .defaultHours,
            weeklyOutcomes: weeklyOutcomes
        )
    }

    /// The whole pool's use of one limit, in percent of an account's limit per weighted hour, averaged over
    /// the longest stretch (up to a week, at least a day) where every account's usage is known. Each timeline
    /// holds an account's readings, its window start (at 0) and its current value. Averaging over real time
    /// keeps hours the profile misjudges from skewing the rate; the profile only spreads it across the day.
    private static func pooledRate(_ usage: [[UsageSample]], profile: ActivityProfile, now: Date) -> Double? {
        let timelines = usage.filter { $0.count > 1 }
        guard let latestStart = timelines.map({ $0[0].date }).max() else { return nil }
        let start = max(latestStart, now.addingTimeInterval(-7 * 86_400))
        let days = now.timeIntervalSince(start) / 86_400
        let weightedHoursPerDay = profile.weights.reduce(0, +)
        guard days >= 1, weightedHoursPerDay > 0 else { return nil }
        let used = timelines.reduce(0.0) { total, timeline in
            let span = timeline[(timeline.lastIndex { $0.date <= start } ?? 0)...]
            return total + zip(span, span.dropFirst()).reduce(0) { $0 + max($1.1.used - $1.0.used, 0) }
        }
        return used / days / weightedHoursPerDay
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
