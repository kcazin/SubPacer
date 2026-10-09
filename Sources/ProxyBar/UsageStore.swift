import Foundation
import Observation

struct AccountUsage: Identifiable, Sendable {
    let id: String
    let providerID: String
    let email: String
    var snapshot = QuotaSnapshot()
    var error: String?

    // Proxy-side stats (secondary info).
    var proxyStatus: String?
    var proxyStatusMessage: String?
    var unavailable = false
    var recentSuccess: [Int] = []
    var recentFailed: [Int] = []

    /// Keyed by `QuotaWindow.id`.
    var projections: [String: Projection] = [:]
    var offHours: OffHoursInsight?

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
}

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var accounts: [AccountUsage] = []
    private(set) var proxyError: String?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var profile = ActivityProfile.default
    /// Updated every minute for time-based UI that lives outside a TimelineView.
    private(set) var clock = Date()

    let baseURL: URL = {
        let configured = UserDefaults.standard.string(forKey: "proxyURL") ?? "http://127.0.0.1:8317"
        return URL(string: configured) ?? URL(string: "http://127.0.0.1:8317")!
    }()

    private var key: String?
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

        if key == nil { key = ManagementClient.loadKey() }
        guard let key else {
            proxyError = "No management key in Keychain (service “ProxyBar”, account “management-key”)."
            return
        }
        let client = ManagementClient(baseURL: baseURL, key: key)

        let files: [AuthFile]
        do {
            files = try await client.authFiles()
            proxyError = nil
        } catch {
            proxyError = error.localizedDescription
            if case ManagementClient.ClientError.unauthorized = error { self.key = nil }
            return
        }

        activity.record(files.filter { $0.disabled != true }.compactMap { $0.recentRequests?.map { $0.success + $0.failed } }, now: Date())
        activity.save()
        profile = ActivityProfile.build(from: activity.counts)

        let tracked = files.filter { $0.disabled != true && $0.authIndex != nil && QuotaProviders.provider(for: $0.providerID) != nil }
        let now = Date()
        let backoff = backoffUntil
        let fetched = await withTaskGroup(of: FetchResult.self) { group in
            for file in tracked {
                let skipUntil = file.authIndex.flatMap { backoff[$0] }.flatMap { $0 > now ? $0 : nil }
                group.addTask { await Self.fetchUsage(file, client: client, skipUntil: skipUntil) }
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
            if usage.error == nil {
                lastGood[usage.id] = usage.snapshot
            } else if let previous = lastGood[usage.id] {
                // Keep showing the last known numbers; the error explains why they're stale.
                usage.snapshot = previous
            }
            merged.append(usage)
        }

        let recordedAt = Date()
        for index in merged.indices {
            let account = merged[index]
            for window in account.snapshot.windows {
                let key = UsageHistory.key(account: account.id, window: window.id)
                if account.error == nil { history.record(window.usedPercent, key: key, at: recordedAt) }
                // Long windows follow your activity pattern; the 5-hour window follows recent pace.
                merged[index].projections[window.id] = (window.windowLength ?? 0) >= 86_400
                    ? ActivityForecast.projection(for: window, profile: profile, now: recordedAt)
                    : Projection.make(for: window, samples: history.samples(for: key), now: recordedAt)
            }
            merged[index].offHours = OffHoursInsight.make(for: merged[index], profile: profile, now: recordedAt)
        }
        history.save()

        let providerOrder = QuotaProviders.all.map { $0.id }
        accounts = merged.sorted {
            (providerOrder.firstIndex(of: $0.providerID) ?? .max, $0.email) < (providerOrder.firstIndex(of: $1.providerID) ?? .max, $1.email)
        }
        lastUpdated = Date()
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

        let request = provider.request(for: file)
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

    nonisolated private static func rateLimitMessage(_ provider: any QuotaProvider.Type, until: Date) -> String {
        "\(provider.displayName) usage API rate limited; retrying in \(ResetFormatter.string(from: Date(), to: until))."
    }
}
