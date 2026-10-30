import Foundation
import Observation

struct AccountUsage: Identifiable, Sendable {
    let id: String
    let providerID: String
    let email: String
    var snapshot = QuotaSnapshot()
    var error: String?
    /// Why the numbers aren't fresh when nothing is wrong, e.g. a CLI that hasn't renewed its login yet.
    var notice: String?
    var source = Source.proxy

    enum Source: Sendable { case proxy, local }

    // Proxy-side stats (secondary info).
    var proxyStatus: String?
    var proxyStatusMessage: String?
    var unavailable = false
    var recentSuccess: [Int] = []
    var recentFailed: [Int] = []

    /// Keyed by `QuotaWindow.id`.
    var projections: [String: Projection] = [:]
    var offHours: OffHoursInsight?
    var resetAdvice: ResetAdvice?
    /// Place in smart routing's order among the provider's proxy accounts, 0 used first.
    var routeRank: Int?

    var provider: (any QuotaProvider.Type)? { QuotaProviders.provider(for: providerID) }
    var displayName: String { provider?.displayName ?? providerID.capitalized }

    /// The tightest primary limit, which is what actually blocks requests.
    var bindingWindow: QuotaWindow? {
        let primary = snapshot.windows.filter(\.isPrimary)
        return (primary.isEmpty ? snapshot.windows : primary).max { $0.usedPercent < $1.usedPercent }
    }

    var remainingPercent: Double? { bindingWindow.map { max(0, 100 - $0.usedPercent) } }

    /// Primary limits that are used up. While any is, the account can't be used at all.
    var exhaustedWindows: [QuotaWindow] { snapshot.windows.filter { $0.isPrimary && $0.usedPercent >= 100 } }

    /// When every exhausted limit has reset and the account is usable again.
    var blockedUntil: Date? {
        let exhausted = exhaustedWindows
        guard !exhausted.isEmpty else { return nil }
        return exhausted.compactMap(\.resetsAt).max()
    }

    var isBlocked: Bool { !exhaustedWindows.isEmpty }

    /// The longest primary window (e.g. weekly): the one whose quota can expire unused.
    var weeklyWindow: QuotaWindow? {
        snapshot.windows
            .filter { $0.isPrimary && ($0.windowLength ?? 0) >= 86_400 }
            .max { ($0.windowLength ?? 0) < ($1.windowLength ?? 0) }
    }
}

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var accounts: [AccountUsage] = []
    /// One per provider, pooling its accounts. Same order as `accounts`.
    private(set) var runways: [Runway] = []
    private(set) var proxyError: String?
    /// Why the proxy didn't take smart routing's account priorities.
    private(set) var routingError: String?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var profile = ActivityProfile.default
    /// Updated every minute for time-based UI that lives outside a TimelineView.
    private(set) var clock = Date()

    private(set) var baseURL = Connection.defaultURL
    /// The proxy can't be used as configured (no key, key rejected, management off); the panel shows setup.
    private(set) var needsSetup = false

    /// Settings that failed in a way retrying won't fix. Not retried until the URL or key changes,
    /// because the proxy bans an address after 5 failed logins.
    private var paused: (url: URL, key: String)?

    private var loop: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private let interval: Duration = .seconds(300)

    func start() {
        guard loop == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.clock = Date()
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(300))
            }
        }
    }

    /// Refreshes unless data is fresher than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let source = Connection.source
        let logins = source.usesLocal ? LocalLogins.load() : []
        let proxy: (client: ManagementClient, files: [AuthFile])?
        if source.usesProxy {
            proxy = await loadProxy(hasLocal: !logins.isEmpty)
        } else {
            proxy = nil
            if logins.isEmpty {
                fail("Sign in to Claude Code or Codex on this Mac.", needsSetup: true)
            } else {
                proxyError = nil
                needsSetup = false
            }
        }
        // Nothing to refresh; keep what's shown, `proxyError` says why.
        if proxy == nil && logins.isEmpty { return }

        if let files = proxy?.files {
            activity.record(files.filter { $0.disabled != true }.compactMap { $0.recentRequests?.map { $0.success + $0.failed } }, now: Date())
            activity.save()
            profile = ActivityProfile.build(from: activity.counts)
        }

        let tracked = proxy?.files.filter { $0.disabled != true && $0.authIndex != nil && QuotaProviders.provider(for: $0.providerID) != nil } ?? []
        // While the proxy is down, its accounts stay as last seen.
        let carried = proxy == nil && source.usesProxy ? accounts.filter { $0.source == .proxy } : []
        // A login the proxy also has shows once, with the proxy's stats.
        let proxied = Set(tracked.map { Self.identity($0.providerID, $0.email) } + carried.map { Self.identity($0.providerID, $0.email) })
        let local = logins.filter { !proxied.contains(Self.identity($0.providerID, $0.email)) }

        let now = Date()
        let backoff = backoffUntil.filter { $0.value > now }
        let fetched = await withTaskGroup(of: FetchResult.self) { group in
            if let client = proxy?.client {
                for file in tracked {
                    let skipUntil = file.authIndex.flatMap { backoff[$0] }
                    group.addTask { await Self.fetchUsage(file, client: client, skipUntil: skipUntil) }
                }
            }
            for login in local {
                let skipUntil = backoff[login.id]
                group.addTask { await Self.fetchUsage(login, skipUntil: skipUntil) }
            }
            var results: [FetchResult] = []
            for await result in group { results.append(result) }
            return results
        }

        var merged: [AccountUsage] = []
        for result in fetched {
            var usage = result.usage
            if let retryAfter = result.retryAfter {
                backoffUntil[usage.id] = Date().addingTimeInterval(retryAfter)
            }
            if usage.error == nil && usage.notice == nil {
                lastGood[usage.id] = usage.snapshot
            } else if let previous = lastGood[usage.id] {
                // Keep showing the last known numbers; the error or notice explains why they're stale.
                usage.snapshot = previous
            }
            merged.append(usage)
        }
        merged += carried
        let carriedIDs = Set(carried.map(\.id))

        let recordedAt = Date()
        for index in merged.indices {
            let account = merged[index]
            for window in account.snapshot.windows {
                let key = UsageHistory.key(account: account.id, window: window.id)
                if account.error == nil && account.notice == nil && !carriedIDs.contains(account.id) { history.record(window.usedPercent, length: window.windowLength, key: key, at: recordedAt) }
                // Long windows follow your activity pattern; the 5-hour window follows recent pace.
                merged[index].projections[window.id] = (window.windowLength ?? 0) >= 86_400
                    ? ActivityForecast.projection(for: window, profile: profile, now: recordedAt)
                    : Projection.make(for: window, samples: history.samples(for: key), now: recordedAt)
            }
        }
        history.save()

        let providerOrder = QuotaProviders.all.map { $0.id }
        merged.sort {
            (providerOrder.firstIndex(of: $0.providerID) ?? .max, $0.email) < (providerOrder.firstIndex(of: $1.providerID) ?? .max, $1.email)
        }
        // Provider ID to proxy account IDs, first used first, where smart routing beats an even split.
        var routeOrder: [String: [String]] = [:]
        var forecasts: [Runway] = []
        for providerID in providerOrder {
            let accounts = merged.filter { $0.providerID == providerID }
            guard let even = forecast(providerID, accounts: accounts, order: nil, now: recordedAt) else { continue }
            let proxied = accounts.filter { $0.source == .proxy }
            let order = SmartRouting.order(proxied, now: recordedAt).map(\.id)
            if SmartRouting.isOn, source.usesProxy, proxied.count > 1,
               var routed = forecast(providerID, accounts: accounts, order: order, now: recordedAt),
               let gain = SmartRouting.gain(routed, over: even, alreadyRouting: runways.contains { $0.providerID == providerID && $0.routed }) {
                routed.routingGain = gain
                routeOrder[providerID] = order
                forecasts.append(routed)
            } else {
                forecasts.append(even)
            }
        }
        runways = forecasts
        for index in merged.indices {
            merged[index].routeRank = routeOrder[merged[index].providerID]?.firstIndex(of: merged[index].id)
        }
        if let proxy {
            routingError = await SmartRouting.apply(order: routeOrder, files: tracked, client: proxy.client)
        }
        // Weekly projections come from the runway, which knows the accounts share your load.
        let weeklyOutcomes = runways.reduce(into: [String: (Projection.Outcome, Projection.Basis)]()) { result, runway in
            for (id, outcome) in runway.weeklyOutcomes { result[id] = (outcome, runway.basis) }
        }
        for index in merged.indices {
            if let weekly = merged[index].weeklyWindow, let (outcome, basis) = weeklyOutcomes[merged[index].id] {
                let reached = if case .limitReached = outcome { true } else { false }
                merged[index].projections[weekly.id] = Projection(
                    outcome: outcome, basis: reached ? nil : basis, elapsedFraction: weekly.elapsedFraction(now: recordedAt)
                )
            }
            merged[index].offHours = OffHoursInsight.make(for: merged[index], profile: profile, now: recordedAt)
            merged[index].resetAdvice = ResetPlanner.advice(
                for: merged[index], runway: runways.first { $0.providerID == merged[index].providerID }, now: recordedAt
            )
        }
        accounts = merged
        lastUpdated = Date()
    }

    private func forecast(_ providerID: String, accounts: [AccountUsage], order: [String]?, now: Date) -> Runway? {
        RunwayForecast.make(
            providerID: providerID,
            accounts: accounts,
            samples: { history.samples(for: UsageHistory.key(account: $0, window: $1)) },
            profile: profile,
            routeOrder: order,
            now: now
        )
    }

    /// The proxy's accounts, or nil when there's no proxy to use; sets `proxyError` and `needsSetup`.
    /// With logins on this Mac to show, a proxy that needs setup doesn't take over the panel.
    private func loadProxy(hasLocal: Bool) async -> (client: ManagementClient, files: [AuthFile])? {
        let url: URL
        do {
            url = try Connection.proxyURL()
        } catch {
            fail(error.localizedDescription, needsSetup: !hasLocal)
            return nil
        }
        baseURL = url
        guard let key = Connection.loadKey() else {
            // No key means no proxy here, which is fine when the CLIs are signed in.
            if hasLocal {
                proxyError = nil
                needsSetup = false
            } else if Connection.source == .proxy {
                fail("Add the proxy's management key to connect.", needsSetup: true)
            } else {
                fail("Sign in to Claude Code or Codex on this Mac, or add your proxy's management key.", needsSetup: true)
            }
            return nil
        }
        if let paused, paused.url == url, paused.key == key {
            if hasLocal { needsSetup = false }
            return nil
        }
        let client = ManagementClient(baseURL: url, key: key)
        do {
            let files = try await client.authFiles()
            proxyError = nil
            needsSetup = false
            return (client, files)
        } catch {
            let setup = (error as? ManagementClient.ClientError)?.needsSetup ?? false
            if setup { paused = (url, key) }
            fail(error.localizedDescription, needsSetup: setup && !hasLocal)
            return nil
        }
    }

    /// Starts over from the newly chosen source, so accounts it leaves out don't linger.
    func sourceChanged() async {
        accounts = []
        runways = []
        lastUpdated = nil
        await refresh()
    }

    nonisolated private static func identity(_ providerID: String, _ email: String?) -> String {
        "\(providerID):\(email?.lowercased() ?? "")"
    }

    /// Checks the settings against the proxy and saves them only if they work.
    /// An empty `key` keeps the one already in the Keychain.
    func connect(urlText: String, key newKey: String) async throws {
        let url = try Connection.parse(urlText)
        let key = newKey.isEmpty ? Connection.loadKey() : newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw SetupError.noKey }
        _ = try await ManagementClient(baseURL: url, key: key).authFiles()
        if !newKey.isEmpty, !Connection.saveKey(key) { throw SetupError.keychain }
        Connection.saveProxyURL(url)
        paused = nil
        if url != baseURL {
            // Another proxy means other accounts; drop what belonged to the old one.
            accounts = accounts.filter { $0.source == .local }
            runways = []
            lastGood = lastGood.filter { $0.key.hasPrefix("local.") }
            backoffUntil = backoffUntil.filter { $0.key.hasPrefix("local.") }
        }
        await refresh()
    }

    enum SetupError: LocalizedError {
        case noKey, keychain
        var errorDescription: String? {
            switch self {
            case .noKey: "Enter the management key (`remote-management.secret-key` in the proxy's config.yaml)."
            case .keychain: "Couldn't save the key to the Keychain."
            }
        }
    }

    private func fail(_ message: String, needsSetup: Bool) {
        proxyError = message
        self.needsSetup = needsSetup
    }

    private let history = UsageHistory()
    private let activity = ActivityLog()
    private var backoffUntil: [String: Date] = [:]
    private var lastGood: [String: QuotaSnapshot] = [:]

    private struct FetchResult: Sendable {
        var usage: AccountUsage
        var retryAfter: TimeInterval?
    }

    nonisolated private static func fetchUsage(_ file: AuthFile, client: ManagementClient, skipUntil: Date?) async -> FetchResult {
        var usage = AccountUsage(
            id: file.authIndex ?? file.name,
            providerID: file.providerID,
            email: file.email ?? file.label ?? file.name
        )
        usage.proxyStatus = file.status
        usage.proxyStatusMessage = file.statusMessage
        usage.unavailable = file.unavailable ?? false
        usage.recentSuccess = file.recentRequests?.map(\.success) ?? []
        usage.recentFailed = file.recentRequests?.map(\.failed) ?? []

        guard let provider = QuotaProviders.provider(for: file.providerID), let authIndex = file.authIndex else {
            return FetchResult(usage: usage)
        }
        if let skipUntil {
            usage.error = rateLimitMessage(provider, until: skipUntil)
            return FetchResult(usage: usage)
        }

        let request = provider.request(accountID: file.idToken?.chatgptAccountId)
        do {
            let response = try await client.apiCall(authIndex: authIndex, url: request.url, headers: request.headers)
            switch response.status {
            case 200..<300:
                usage.snapshot = try provider.parse(response.body)
                if usage.snapshot.plan == nil, let plan = file.idToken?.planType { usage.snapshot.plan = plan.capitalized }
            case 401, 403:
                usage.error = "Login expired. \(provider.reloginHint)"
            case 429:
                let retryAfter = response.retryAfter ?? 600
                usage.error = rateLimitMessage(provider, until: Date().addingTimeInterval(retryAfter))
                return FetchResult(usage: usage, retryAfter: retryAfter)
            default:
                usage.error = "\(provider.displayName) returned HTTP \(response.status)"
            }
        } catch {
            usage.error = error.localizedDescription
        }
        return FetchResult(usage: usage)
    }

    nonisolated private static func fetchUsage(_ login: LocalLogin, skipUntil: Date?) async -> FetchResult {
        var usage = AccountUsage(id: login.id, providerID: login.providerID, email: login.email ?? login.cliName)
        usage.source = .local
        guard let provider = QuotaProviders.provider(for: login.providerID) else { return FetchResult(usage: usage) }
        if let skipUntil {
            usage.error = rateLimitMessage(provider, until: skipUntil)
            return FetchResult(usage: usage)
        }
        // Not an error: the CLI renews it the next time it runs, and usage can't move until then.
        let waiting = "\(login.cliName) renews its login the next time you use it; until then these are the last numbers seen."
        if login.isExpired(at: Date()) {
            usage.notice = waiting
            return FetchResult(usage: usage)
        }
        do {
            let response = try await LocalLogins.fetch(login, provider: provider)
            switch response.status {
            case 200..<300:
                usage.snapshot = try provider.parse(response.body)
                if usage.snapshot.plan == nil { usage.snapshot.plan = login.plan }
            case 401 where login.expiresAt == nil:
                usage.notice = waiting
            case 401, 403:
                usage.error = "\(login.cliName)'s login was rejected. Sign in to \(login.cliName) again."
            case 429:
                let retryAfter = response.retryAfter ?? 600
                usage.error = rateLimitMessage(provider, until: Date().addingTimeInterval(retryAfter))
                return FetchResult(usage: usage, retryAfter: retryAfter)
            default:
                usage.error = "\(provider.displayName) returned HTTP \(response.status)"
            }
        } catch {
            usage.error = error.localizedDescription
        }
        return FetchResult(usage: usage)
    }

    nonisolated private static func rateLimitMessage(_ provider: any QuotaProvider.Type, until: Date) -> String {
        "\(provider.displayName) usage API rate limited; retrying in \(ResetFormatter.string(from: Date(), to: until))."
    }
}
