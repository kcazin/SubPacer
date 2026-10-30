import Foundation

/// Has the proxy use each provider's accounts one at a time, the one whose weekly limit resets soonest
/// first, so quota that's about to reset is spent before quota that keeps. Round-robin spreads the load
/// evenly instead, and a week ending tomorrow can reset half-used while another account still has days.
/// Works through each account's `priority` in the proxy, which always picks the highest-priority account
/// that isn't cooling down, so when one runs out it moves on to the next.
enum SmartRouting {
    static let storageKey = "smartRouting"
    /// Auth files whose priority SubPacer set, put back to the default when routing is turned off.
    private static let appliedKey = "smartRouting.applied"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    /// A provider's accounts in the order they should be used: the soonest weekly reset first, then weeks
    /// that haven't started, then accounts whose week is used up or unknown.
    static func order(_ accounts: [AccountUsage], now: Date = Date()) -> [AccountUsage] {
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
        let gain = even.unusedAtReset - routed.unusedAtReset
        guard gain >= (alreadyRouting ? 0.5 : 2) else { return nil }
        if let routedOut = routed.runsOutAt, routedOut < even.runsOutAt ?? .distantFuture { return nil }
        return gain
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
