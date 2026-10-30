import Foundation

/// `SUBPACER_DEMO=1` runs on made-up accounts (two Claude, one Codex) with a week of synthetic
/// history, for screenshots and trying the app without a proxy. The real forecasting code runs
/// on it unchanged; only the proxy's answers and the stored history are invented.
enum Demo {
    static let isActive = ProcessInfo.processInfo.environment["SUBPACER_DEMO"] != nil
    static let proxyURL = URL(string: "demo://localhost:8317")!

    private struct Account {
        let index: String
        let provider: String
        let email: String
        /// Window ID → (used percent, seconds until reset, window length).
        let windows: [(id: String, used: Double, resetsIn: TimeInterval, length: TimeInterval)]
        let hasResetGrant: Bool
        /// Share of the proxy's traffic this account gets.
        let share: Double
    }

    private static let now = Date()

    private static let accounts = [
        Account(index: "1", provider: "claude", email: "alex@example.com", windows: [
            ("five_hour", 46, 2 * 3600 + 10 * 60, 5 * 3600),
            ("seven_day", 71, 2 * 86_400 + 5 * 3600, 7 * 86_400),
        ], hasResetGrant: true, share: 0.45),
        Account(index: "2", provider: "claude", email: "sam@example.com", windows: [
            ("five_hour", 12, 3 * 3600 + 40 * 60, 5 * 3600),
            ("seven_day", 38, 4 * 86_400 + 13 * 3600, 7 * 86_400),
        ], hasResetGrant: false, share: 0.3),
        Account(index: "3", provider: "codex", email: "jordan@example.com", windows: [
            ("main.primary_window", 27, 1 * 3600 + 50 * 60, 5 * 3600),
            ("main.secondary_window", 54, 3 * 86_400 + 2 * 3600, 7 * 86_400),
        ], hasResetGrant: false, share: 0.25),
    ]

    /// Relative activity by hour of day: a working day with a late evening, quiet 01:00–09:00.
    private static let hourly: [Double] = [
        0.2, 0.02, 0, 0, 0, 0, 0, 0, 0.03, 0.5, 0.9, 1.0,
        0.7, 0.6, 0.9, 1.0, 0.95, 0.8, 0.5, 0.4, 0.6, 0.8, 0.7, 0.45,
    ]

    private static func activity(at date: Date) -> Double {
        let hour = Calendar.current.component(.hour, from: date)
        // Deterministic jitter so the profile doesn't look synthetic.
        let bucket = Int(date.timeIntervalSince1970 / ActivityLog.bucketLength)
        let jitter = 0.75 + 0.5 * Double((bucket &* 2_654_435_761) & 0xff) / 255
        return hourly[hour] * jitter
    }

    /// Seeds history and activity before the store loads them.
    @MainActor
    static func prepare() {
        Privacy.shared.revealed.insert("alex@example.com")

        let bucket = ActivityLog.bucketLength
        let current = Int(now.timeIntervalSince1970 / bucket)
        var counts: [String: Int] = [:]
        for index in (current - 7 * 144)...current {
            counts[String(index)] = Int((activity(at: Date(timeIntervalSince1970: Double(index) * bucket)) * 60).rounded())
        }

        var history: [String: [UsageSample]] = [:]
        for account in accounts {
            for window in account.windows {
                let reset = now.addingTimeInterval(window.resetsIn)
                let start = max(reset.addingTimeInterval(-window.length), now.addingTimeInterval(-min(window.length, 2 * 86_400)))
                // Usage accumulates with activity, ending at the current reading.
                var times: [Date] = []
                var cursor = start
                while cursor < now { times.append(cursor); cursor.addTimeInterval(window.length > 86_400 ? 1800 : 300) }
                let weights = times.map(activity(at:))
                let total = max(weights.reduce(0, +), 0.001)
                let base = window.length > 86_400 ? window.used * 0.55 : 0
                var running = 0.0
                history["\(account.index)|\(window.id)"] = zip(times, weights).map { time, weight in
                    running += weight
                    return UsageSample(date: time, used: base + (window.used - base) * running / total)
                } + [UsageSample(date: now, used: window.used)]
            }
        }

        let encoder = JSONEncoder()
        try? encoder.encode(counts).write(to: AppPaths.support.appending(path: "activity.json"))
        try? encoder.encode(history).write(to: AppPaths.support.appending(path: "history.json"))
    }

    // MARK: Proxy

    static func respond(path: String, body: Data?) throws -> Data {
        switch path {
        case "auth-files":
            return try JSONSerialization.data(withJSONObject: ["files": accounts.map(authFile)])
        case "api-call":
            let request = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let index = request?["auth_index"] as? String,
                  let account = accounts.first(where: { $0.index == index }) else { throw ManagementClient.ClientError.http(400, "unknown auth_index") }
            let usage = account.provider == "claude" ? claudeUsage(account) : codexUsage(account)
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: usage), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["status_code": 200, "header": [String: [String]](), "body": payload])
        case "auth-files/fields":
            return try JSONSerialization.data(withJSONObject: ["status": "ok"])
        default:
            throw ManagementClient.ClientError.http(404, nil)
        }
    }

    private static func authFile(_ account: Account) -> [String: Any] {
        let bucket = ActivityLog.bucketLength
        let current = Int(now.timeIntervalSince1970 / bucket)
        let recent: [[String: Any]] = ((current - 19)...current).map { index in
            let date = Date(timeIntervalSince1970: Double(index) * bucket)
            let requests = Int((activity(at: date) * 60 * account.share).rounded())
            let failed = index % 7 == 0 && requests > 0 ? 1 : 0
            return ["time": ISO8601DateFormatter().string(from: date), "success": requests - failed, "failed": failed]
        }
        var file: [String: Any] = [
            "name": "\(account.provider)-\(account.index).json",
            "auth_index": account.index,
            "provider": account.provider,
            "email": account.email,
            "status": "active",
            "recent_requests": recent,
        ]
        if account.provider == "codex" {
            file["id_token"] = ["chatgpt_account_id": "demo", "plan_type": "pro"]
        }
        return file
    }

    private static func claudeUsage(_ account: Account) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var usage: [String: Any] = [:]
        for window in account.windows {
            usage[window.id] = ["utilization": window.used, "resets_at": iso.string(from: now.addingTimeInterval(window.resetsIn))]
        }
        if account.hasResetGrant {
            usage["cedar_ember"] = ["grants": [[
                "id": "demo-launch",
                "label": "Model launch: one usage-limit reset for Pro and Max",
                "resets_left": 1,
                "resets_total": 1,
                "ends_at": iso.string(from: now.addingTimeInterval(9 * 86_400)),
                "clears": ["five_hour", "seven_day"],
                "paused": false,
                "usable_now": false,
                "use_requires_limit": true,
            ]]]
        }
        return usage
    }

    private static func codexUsage(_ account: Account) -> [String: Any] {
        func window(_ id: String) -> [String: Any] {
            let window = account.windows.first { $0.id == id }!
            return [
                "used_percent": Int(window.used),
                "limit_window_seconds": Int(window.length),
                "reset_after_seconds": Int(window.resetsIn),
                "reset_at": Int(now.addingTimeInterval(window.resetsIn).timeIntervalSince1970),
            ]
        }
        return [
            "plan_type": "pro",
            "rate_limit": [
                "allowed": true,
                "limit_reached": false,
                "primary_window": window("main.primary_window"),
                "secondary_window": window("main.secondary_window"),
            ],
            "credits": ["has_credits": false, "unlimited": false],
        ]
    }
}
