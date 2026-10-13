import Foundation

/// When to spend a limit reset. It refills the account's limits but keeps the weekly reset day,
/// so it's worth most when the pool would otherwise run out with much of this account's week
/// still ahead, and nothing just before the week refills by itself.
struct ResetAdvice: Sendable {
    enum Action: Sendable, Equatable {
        /// You're out with enough of the week left to spend the refill.
        case useNow
        /// The pool is projected to run out then: use it at that point.
        case useAt(Date)
        /// It's lost after this, and the week won't refill first.
        case useBeforeExpiry(Date)
        case hold
    }

    let grant: ResetGrant
    let action: Action
    let reason: String
}

enum ResetPlanner {
    /// Running out with less of the week left than this isn't worth a once-off reset.
    static let minimumWeekLeft: TimeInterval = 6 * 3600

    static func advice(for account: AccountUsage, runway: Runway?, now: Date) -> ResetAdvice? {
        guard let grant = account.snapshot.resetGrants.first(where: \.isAvailable) else { return nil }
        let deadline = grant.endsAt ?? .distantFuture
        guard deadline > now else { return nil }
        let weekly = account.weeklyWindow
        let used = Int((weekly?.usedPercent ?? 0).rounded())
        let weekRefills = weekly?.resetsAt.flatMap { $0 > now ? $0 : nil }

        // Every account is out then, this one included; the reset puts it back in play.
        if let outage = runway?.outages.first(where: { $0.interval.start < deadline }) {
            let from = max(outage.interval.start, now)
            // The refill lasts until the week running at that point ends.
            let length = weekly?.windowLength ?? 7 * 86_400
            var refill = weekRefills ?? from.addingTimeInterval(length)
            while refill <= from { refill.addTimeInterval(length) }
            let span = refill.timeIntervalSince(from)
            // It expires before another week starts, so there's no later outage to save it for.
            let lastChance = deadline < refill
            guard span >= minimumWeekLeft || lastChance else {
                return ResetAdvice(grant: grant, action: .hold, reason: "Out \(ResetFormatter.clock(outage.interval.start)), but the week refills soon after")
            }
            if outage.interval.start <= now.addingTimeInterval(900) {
                return ResetAdvice(grant: grant, action: .useNow, reason: "Pool out until \(ResetFormatter.clock(outage.interval.end)) · \(ResetFormatter.duration(span)) of this week left to spend it")
            }
            return ResetAdvice(grant: grant, action: .useAt(outage.interval.start), reason: "Pool runs out then, \(ResetFormatter.duration(span)) before this week refills")
        }

        if deadline.timeIntervalSince(now) < 86_400, weekRefills.map({ $0 > deadline }) ?? true, used >= 20 {
            return ResetAdvice(grant: grant, action: .useBeforeExpiry(deadline), reason: "Unused it's lost · refills the \(used)% used this week")
        }
        if let weekRefills, weekRefills < deadline, used >= 50 {
            return ResetAdvice(grant: grant, action: .hold, reason: "Week refills by itself \(ResetFormatter.clock(weekRefills)) · keep it for a week you run out")
        }
        return ResetAdvice(grant: grant, action: .hold, reason: "No shortfall forecast · keep it for when the pool runs out")
    }
}
