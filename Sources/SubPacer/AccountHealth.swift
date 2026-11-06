import Foundation

/// Notices proxy accounts that keep failing, such as a cancelled subscription or a revoked login, so routing
/// stops putting them first. Two signals, each with its own clock, kept across launches:
/// - the usage API failing for a reason other than rate limiting, until it reads again;
/// - the proxy's recent requests on the account all failing, until the proxy records a success. Reading usage
///   isn't enough to clear this one: a cancelled subscription may still report its usage.
enum AccountHealth {
    /// How long an account has to keep failing before routing uses it last.
    static let demoteAfter: TimeInterval = 3 * 3600

    private static let usageKey = "routing.usageFailingSince"
    private static let requestsKey = "routing.requestsFailingSince"

    /// Updates the clocks from this refresh for the accounts in `observed` (IDs), and returns, per account ID,
    /// since when each failing account has been failing.
    static func update(_ accounts: [AccountUsage], observed: Set<String>, now: Date) -> [String: Date] {
        var usage = load(usageKey)
        var requests = load(requestsKey)
        for account in accounts where account.source == .proxy && observed.contains(account.id) {
            let key = key(account)
            if account.error == nil {
                usage[key] = nil
            } else if !account.rateLimited {
                usage[key] = usage[key] ?? now
            }
            let succeeded = account.recentSuccess.reduce(0, +)
            let failed = account.recentFailed.reduce(0, +)
            if succeeded > 0 {
                requests[key] = nil
            } else if failed > 0 && !account.isBlocked {
                // Failures on an account whose limit is used up are just the limit.
                requests[key] = requests[key] ?? now
            }
        }
        save(usage, usageKey)
        save(requests, requestsKey)
        return accounts.reduce(into: [:]) { result, account in
            let since = [usage[key(account)], requests[key(account)]].compactMap { $0 }.min()
            if account.source == .proxy, let since { result[account.id] = since }
        }
    }

    /// Starts the account over, e.g. once you pick it to go first: routing trusts it again until it fails
    /// for another `demoteAfter`.
    static func forgive(providerID: String, email: String) {
        let key = "\(providerID):\(email.lowercased())"
        for storageKey in [usageKey, requestsKey] {
            var clocks = load(storageKey)
            clocks[key] = nil
            save(clocks, storageKey)
        }
    }

    private static func key(_ account: AccountUsage) -> String {
        "\(account.providerID):\(account.email.lowercased())"
    }

    private static func load(_ storageKey: String) -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func save(_ clocks: [String: Date], _ storageKey: String) {
        UserDefaults.standard.set(clocks.mapValues(\.timeIntervalSince1970), forKey: storageKey)
    }
}
