import Foundation

/// Has the proxy use each provider's accounts one at a time, the one whose weekly limit resets soonest
/// first, so quota that's about to reset is spent before quota that keeps. Round-robin spreads the load
/// evenly instead, and a week ending tomorrow can reset half-used while another account still has days.
/// Works through each account's `priority` in the proxy, which always picks the highest-priority account
/// that isn't cooling down, so when one runs out it moves on to the next.
enum SmartRouting {
    /// How the proxy shares a provider's accounts.
    enum Mode: String, CaseIterable, Identifiable {
        /// The proxy's own round-robin; SubPacer leaves priorities alone.
        case even
        /// Soonest reset first, but only when the forecast shows that saves quota without running out sooner.
        case smart
        /// Soonest reset first, always, whatever the forecast says.
        case ordered
        /// Latest reset first, keeping the weeks about to end for last.
        case latest
        /// An account you pick first (say, a subscription you're cancelling), then the rest soonest reset first.
        case pinned

        static let storageKey = "routingMode"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .even: "Even split"
            case .smart: "Smart"
            case .ordered: "Soonest reset first"
            case .latest: "Latest reset first"
            case .pinned: "Account first"
            }
        }

        /// How each provider's accounts are lined up, for the status lines.
        var orderPhrase: String {
            switch self {
            case .even: "shared evenly"
            case .smart, .ordered: "soonest reset first"
            case .latest: "latest reset first"
            case .pinned: "first"
            }
        }

        /// How the forecast re-sorts accounts as weeks reset, matching what each refresh would do.
        var resort: Resort {
            switch self {
            case .even, .smart, .ordered: .soonestReset
            case .latest: .latestReset
            case .pinned: .fixed
            }
        }

        var summary: String {
            switch self {
            case .even: "The proxy splits requests evenly between accounts. SubPacer leaves account priorities alone."
            case .smart: "When an even split would leave quota unused at a weekly reset, the proxy uses the account that resets soonest first, then the next."
            case .ordered: "The proxy always uses the account whose week resets soonest first, then the next, even when the forecast says an even split would do as well."
            case .latest: "The proxy uses the account whose week resets last first, then the next, leaving the weeks about to end for last."
            case .pinned: "The proxy uses the account you pick first, until it runs out, then the rest soonest reset first. Handy for draining a subscription you're about to cancel."
            }
        }
    }

    /// How the forecast orders accounts at each step.
    enum Resort { case soonestReset, latestReset, fixed }

    /// Provider ID to the email of the account `pinned` uses first.
    private static let pinsKey = "routingPins"

    static var pins: [String: String] {
        UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:]
    }

    static func pin(_ email: String, for providerID: String) {
        var pins = pins
        pins[providerID] = email
        UserDefaults.standard.set(pins, forKey: pinsKey)
    }

    /// Provider ID to the account IDs routing last used, first used first.
    static var lastOrder: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "routing.lastOrder") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "routing.lastOrder") }
    }

    /// The old on/off setting, read once to pick the mode for anyone who had it on.
    private static let legacyKey = "smartRouting"
    /// Auth files whose priority SubPacer set, put back to the default when routing is turned off.
    private static let appliedKey = "smartRouting.applied"

    static var mode: Mode {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: Mode.storageKey).flatMap(Mode.init) { return mode }
        return defaults.bool(forKey: legacyKey) ? .smart : .even
    }

    static var isOn: Bool { mode != .even }

    /// A provider's accounts in the order they should be used: the soonest weekly reset first, then weeks
    /// that haven't started, then accounts whose week is used up or unknown.
    static func order(_ accounts: [AccountUsage], mode: Mode, now: Date = Date()) -> [AccountUsage] {
        let soonest = order(accounts, now: now)
        switch mode {
        case .even, .smart, .ordered:
            return soonest
        case .latest:
            // Weeks not started yet end last of all once they start, so they go first.
            func key(_ account: AccountUsage) -> (Int, Double, String) {
                let weekUsedUp = account.exhaustedWindows.contains { ($0.windowLength ?? 0) >= 86_400 }
                guard let weekly = account.weeklyWindow, !weekUsedUp else { return (1, 0, account.email) }
                guard let reset = weekly.resetsAt, reset > now else { return (0, -.infinity, account.email) }
                return (0, -reset.timeIntervalSinceReferenceDate, account.email)
            }
            return accounts.sorted { key($0) < key($1) }
        case .pinned:
            guard let email = accounts.first.flatMap({ pins[$0.providerID] }),
                  let first = soonest.firstIndex(where: { $0.email == email }) else { return soonest }
            var ordered = soonest
            ordered.insert(ordered.remove(at: first), at: 0)
            return ordered
        }
    }

    private static func order(_ accounts: [AccountUsage], now: Date) -> [AccountUsage] {
        func key(_ account: AccountUsage) -> (Int, Date, String) {
            let weekUsedUp = account.exhaustedWindows.contains { ($0.windowLength ?? 0) >= 86_400 }
            guard let weekly = account.weeklyWindow, !weekUsedUp else { return (2, .distantFuture, account.email) }
            guard let reset = weekly.resetsAt, reset > now else { return (1, .distantFuture, account.email) }
            return (0, reset, account.email)
        }
        return accounts.sorted { key($0) < key($1) }
    }

    /// How much quota routing in order saves over an even split, when it's worth doing: at least a little,
    /// and without running out any sooner (filling one account at a time bunches up its session limits).
    /// Already routing, it keeps on for less, so the proxy's priorities don't flip back and forth.
    static func gain(_ routed: Runway, over even: Runway, alreadyRouting: Bool) -> Double? {
        let gain = rawGain(routed, over: even)
        guard gain >= (alreadyRouting ? 0.5 : 2) else { return nil }
        if let routedOut = routed.runsOutAt, routedOut < even.runsOutAt ?? .distantFuture { return nil }
        return gain
    }

    /// Weekly quota routing in order keeps from going unused, in percent of one account's week; below 0 when it
    /// wastes more than an even split.
    static func rawGain(_ routed: Runway, over even: Runway) -> Double {
        even.unusedAtReset - routed.unusedAtReset
    }

    /// Brings the proxy's priorities in line with `order` (provider ID to account IDs, first used first):
    /// n for the first of n accounts, down to 1. Priorities it set before and no longer wants, or all of
    /// them with routing off, go back to 0. Returns why the proxy refused, if it did.
    @MainActor
    static func apply(order: [String: [String]], files: [AuthFile], client: ManagementClient) async -> String? {
        let applied = Set(UserDefaults.standard.stringArray(forKey: appliedKey) ?? [])
        let byIndex = Dictionary(files.compactMap { file in file.authIndex.map { ($0, file) } }) { first, _ in first }
        var wanted: [String: Int] = [:]
        if isOn {
            for ids in order.values {
                for (rank, id) in ids.enumerated() {
                    if let file = byIndex[id] { wanted[file.name] = ids.count - rank }
                }
            }
        }
        let names = Set(files.map(\.name))
        for name in applied where wanted[name] == nil && names.contains(name) { wanted[name] = 0 }

        var failure: String?
        var nowApplied = applied.intersection(names)
        for file in files {
            guard let priority = wanted[file.name] else { continue }
            if (file.priority ?? 0) != priority {
                do {
                    try await client.setPriority(priority, file: file.name)
                } catch {
                    failure = failure ?? message(for: error)
                    continue
                }
            }
            if priority == 0 { nowApplied.remove(file.name) } else { nowApplied.insert(file.name) }
        }
        UserDefaults.standard.set(nowApplied.sorted(), forKey: appliedKey)
        return failure
    }

    private static func message(for error: Error) -> String {
        // A proxy without the fields endpoint answers 404, which the client reads as management being off.
        if case .disabled = error as? ManagementClient.ClientError {
            return "The proxy doesn't accept account priorities. Update CLIProxyAPI to use smart routing."
        }
        return "Couldn't set account priorities: \(error.localizedDescription)"
    }
}
