import Foundation
import SwiftUI

struct QuotaWindow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// 0–100.
    let usedPercent: Double
    let resetsAt: Date?
    /// Total length of the rolling window, used to infer when it started.
    let windowLength: TimeInterval?
    /// Primary windows drive the menu bar figure; secondary ones (per-model, extra) only show in the card.
    let isPrimary: Bool
}

struct QuotaSnapshot: Sendable {
    var plan: String?
    var windows: [QuotaWindow] = []
    var credits: String?
    var resetGrants: [ResetGrant] = []
}

/// A one-off limit reset granted to the account (e.g. at a model launch). Using it refills the
/// limits in `clears` at once; the weekly reset day stays where it was.
struct ResetGrant: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let resetsLeft: Int
    let resetsTotal: Int
    /// Last moment it can be used.
    let endsAt: Date?
    /// Limit IDs it refills, e.g. `five_hour`, `seven_day`.
    let clears: [String]
    let paused: Bool
    let usableNow: Bool
    /// Only usable while a limit is reached.
    let requiresLimit: Bool

    var isAvailable: Bool { resetsLeft > 0 && !paused }
}

/// A request to a provider's API. Headers carry `$TOKEN$`, which the proxy fills in server-side,
/// or `LocalLogins` does for a login on this Mac.
struct QuotaRequest: Sendable {
    var url: String
    var headers: [String: String]
    var method = "GET"
    var body: String?
}

/// What identifies an account to its provider beyond the token.
struct AccountKeys: Sendable {
    /// Codex's ChatGPT account, sent as `ChatGPT-Account-Id`.
    var accountID: String?
    /// The Google Cloud project Gemini bills the account's quota to.
    var projectID: String?
}

/// Knows how to ask a provider for quota and how to read the answer.
protocol QuotaProvider {
    static var id: String { get }
    static var displayName: String { get }
    static var symbol: String { get }
    static var tint: Color { get }
    static func request(for account: AccountKeys) -> QuotaRequest
    static func parse(_ data: Data) throws -> QuotaSnapshot
    static var reloginHint: String { get }
    /// Where to ask whether the account still pays for a plan, when its usage doesn't say.
    static var planRequest: QuotaRequest? { get }
    /// Whether the account pays for a plan, from `planRequest`'s answer; nil when it can't tell.
    static func hasPlan(profile: Data) -> Bool?
    /// Whether the account pays for a plan, from its usage; nil when usage doesn't say.
    static func hasPlan(_ snapshot: QuotaSnapshot) -> Bool?
}

extension QuotaProvider {
    static var planRequest: QuotaRequest? { nil }
    static func hasPlan(profile: Data) -> Bool? { nil }
    static func hasPlan(_ snapshot: QuotaSnapshot) -> Bool? { nil }
}

enum QuotaProviders {
    static let all: [any QuotaProvider.Type] = [ClaudeQuota.self, CodexQuota.self, GeminiQuota.self]

    static func provider(for id: String) -> (any QuotaProvider.Type)? {
        all.first { $0.id == id }
    }
}

struct ParseError: LocalizedError {
    var errorDescription: String? { "Unexpected quota response" }
}

// MARK: - Claude

enum ClaudeQuota: QuotaProvider {
    static let id = "claude"
    static let displayName = "Claude"
    static let symbol = "asterisk"
    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let reloginHint = "Run `cliproxyapi -claude-login` to sign in again."

    static func request(for account: AccountKeys) -> QuotaRequest {
        // `cedar_ember=1` adds limit-reset grants, which are only offered to a recent Claude Code.
        QuotaRequest(url: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1", headers: [
            "Authorization": "Bearer $TOKEN$",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "claude-cli/\(ClaudeCodeVersion.installed) (external, cli)",
        ])
    }

    /// A lapsed subscription still answers usage, with a 429 that never clears, so the profile tells.
    static var planRequest: QuotaRequest? {
        QuotaRequest(url: "https://api.anthropic.com/api/oauth/profile", headers: request(for: AccountKeys()).headers)
    }

    /// An account without a subscription belongs to a `claude_free` organization; Pro, Max, Team and
    /// Enterprise each have their own type.
    static func hasPlan(profile: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: profile) as? [String: Any],
              let type = (object["organization"] as? [String: Any])?["organization_type"] as? String else { return nil }
        return type != "claude_free"
    }

    private static let labels: [String: String] = [
        "five_hour": "Session",
        "seven_day": "Weekly",
        "seven_day_opus": "Weekly · Opus",
        "seven_day_sonnet": "Weekly · Sonnet",
        "seven_day_oauth_apps": "Weekly · Apps",
        "extra_usage": "Extra usage",
    ]
    private static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
    private static let primary: Set<String> = ["five_hour", "seven_day"]

    static func parse(_ data: Data) throws -> QuotaSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError() }
        var windows: [QuotaWindow] = []
        // Codenamed fields (e.g. `iguana_necktie`) are undocumented; only show limits we can name.
        for (key, value) in object where labels[key] != nil || key.hasPrefix("seven_day_") {
            guard let dict = value as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { continue }
            if let enabled = dict["is_enabled"] as? Bool, !enabled { continue }
            windows.append(QuotaWindow(
                id: key,
                label: labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized,
                usedPercent: utilization,
                resetsAt: (dict["resets_at"] as? String).flatMap(DateParsing.iso8601),
                windowLength: key == "five_hour" ? 5 * 3600 : key.hasPrefix("seven_day") ? 7 * 86_400 : nil,
                isPrimary: primary.contains(key)
            ))
        }
        windows.sort { (order.firstIndex(of: $0.id) ?? .max, $0.id) < (order.firstIndex(of: $1.id) ?? .max, $1.id) }
        return QuotaSnapshot(windows: windows, resetGrants: resetGrants(in: object["cedar_ember"]))
    }

    private static func resetGrants(in status: Any?) -> [ResetGrant] {
        guard let grants = (status as? [String: Any])?["grants"] as? [[String: Any]] else { return [] }
        return grants.compactMap { grant in
            guard let id = grant["id"] as? String, let left = (grant["resets_left"] as? NSNumber)?.intValue else { return nil }
            return ResetGrant(
                id: id,
                label: grant["label"] as? String ?? "Limit reset",
                resetsLeft: left,
                resetsTotal: (grant["resets_total"] as? NSNumber)?.intValue ?? left,
                endsAt: (grant["ends_at"] as? String).flatMap(DateParsing.iso8601),
                clears: grant["clears"] as? [String] ?? [],
                paused: grant["paused"] as? Bool ?? false,
                usableNow: grant["usable_now"] as? Bool ?? false,
                requiresLimit: grant["use_requires_limit"] as? Bool ?? true
            )
        }
    }
}

/// The newest Claude Code installed here; Anthropic gates some usage fields on the client version.
enum ClaudeCodeVersion {
    static let installed: String = {
        let fallback = "2.1.296"
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/claude/versions")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return versions
            .filter { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
            .map { $0.compare(fallback, options: .numeric) == .orderedAscending ? fallback : $0 } ?? fallback
    }()
}

// MARK: - Codex

enum CodexQuota: QuotaProvider {
    static let id = "codex"
    static let displayName = "Codex"
    static let symbol = "terminal"
    static let tint = Color(red: 0.25, green: 0.55, blue: 0.95)
    static let reloginHint = "Run `cliproxyapi -codex-login` to sign in again."

    static func request(for account: AccountKeys) -> QuotaRequest {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "User-Agent": "codex_cli_rs",
        ]
        if let accountID = account.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return QuotaRequest(url: "https://chatgpt.com/backend-api/wham/usage", headers: headers)
    }

    static func parse(_ data: Data) throws -> QuotaSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError() }
        var snapshot = QuotaSnapshot(plan: (object["plan_type"] as? String)?.capitalized)

        if let limits = object["rate_limit"] as? [String: Any] {
            snapshot.windows += windows(from: limits, prefix: nil, isPrimary: true)
        }
        for extra in object["additional_rate_limits"] as? [[String: Any]] ?? [] {
            guard let limits = extra["rate_limit"] as? [String: Any] else { continue }
            let name = (extra["limit_name"] as? String) ?? (extra["normal_model_slug"] as? String) ?? "Extra"
            snapshot.windows += windows(from: limits, prefix: name, isPrimary: false)
        }
        if let credits = object["credits"] as? [String: Any], credits["has_credits"] as? Bool == true {
            if credits["unlimited"] as? Bool == true {
                snapshot.credits = "Unlimited credits"
            } else if let balance = (credits["balance"] as? String).flatMap(Double.init) ?? (credits["balance"] as? NSNumber)?.doubleValue {
                snapshot.credits = "\(balance.formatted(.number.precision(.fractionLength(0)))) credits"
            }
        }
        return snapshot
    }

    /// A ChatGPT subscription that lapses leaves the account on the free plan.
    static func hasPlan(_ snapshot: QuotaSnapshot) -> Bool? {
        snapshot.plan.map { $0.lowercased() != "free" }
    }

    private static func windows(from limits: [String: Any], prefix: String?, isPrimary: Bool) -> [QuotaWindow] {
        ["primary_window", "secondary_window"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let seconds = (window["limit_window_seconds"] as? NSNumber)?.intValue ?? 0
            let span = spanLabel(seconds: seconds)
            let reset = (window["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(
                id: "\(prefix ?? "main").\(key)",
                label: prefix.map { "\($0) · \(span)" } ?? span,
                usedPercent: used,
                resetsAt: reset,
                windowLength: seconds > 0 ? TimeInterval(seconds) : nil,
                isPrimary: isPrimary
            )
        }
    }

    private static func spanLabel(seconds: Int) -> String {
        switch seconds {
        case 18_000: "Session"
        case 604_800: "Weekly"
        case 0: "Window"
        case ..<86_400: "\(seconds / 3600)h"
        default: "\(seconds / 86_400)d"
        }
    }
}

// MARK: - Gemini

/// Gemini through the proxy's Antigravity logins. Each model reports the fraction of its quota left and
/// when it refills; the Gemini models share one pool, so it's the most used of them.
enum GeminiQuota: QuotaProvider {
    static let id = "antigravity"
    static let displayName = "Gemini"
    static let symbol = "sparkle"
    static let tint = Color(red: 0.55, green: 0.42, blue: 0.95)
    static let reloginHint = "Run `cliproxyapi -antigravity-login` to sign in again."

    /// The endpoint the proxy itself sends Antigravity requests to; the production one reports every
    /// pool as unused.
    static func request(for account: AccountKeys) -> QuotaRequest {
        let body = (try? JSONSerialization.data(withJSONObject: account.projectID.map { ["project": $0] } ?? [:]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return QuotaRequest(
            url: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
            headers: [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "antigravity/1.15.8 darwin/arm64",
            ],
            method: "POST",
            body: body
        )
    }

    static let session: TimeInterval = 5 * 3600

    /// Only the Gemini models, which share one pool; the Claude and GPT-OSS models Antigravity also serves are
    /// left out, as are internal ones like autocomplete.
    static func parse(_ data: Data) throws -> QuotaSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [String: [String: Any]] else { throw ParseError() }
        let usage: [(used: Double, resetsAt: Date)] = models.compactMap { id, model in
            guard id.hasPrefix("gemini-"), model["modelProvider"] as? String == "MODEL_PROVIDER_GOOGLE",
                  let quota = model["quotaInfo"] as? [String: Any],
                  let reset = (quota["resetTime"] as? String).flatMap(DateParsing.iso8601) else { return nil }
            // An exhausted model drops `remainingFraction`.
            let left = (quota["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
            return (min(100, max(0, (1 - left) * 100)), reset)
        }
        guard let tightest = usage.max(by: { ($0.used, -$0.resetsAt.timeIntervalSince1970) < ($1.used, -$1.resetsAt.timeIntervalSince1970) }) else {
            throw ParseError()
        }
        // Google only reports the pool that refills 5 hours after first use; a reset further out is a weekly lockout.
        let length = tightest.resetsAt.timeIntervalSinceNow > session + 600 ? 7 * 86_400 : session
        return QuotaSnapshot(windows: [QuotaWindow(
            id: "gemini",
            label: length == session ? "Session" : "Weekly",
            usedPercent: tightest.used,
            resetsAt: tightest.resetsAt,
            windowLength: length,
            isPrimary: true
        )])
    }
}

// MARK: - Helpers

enum DateParsing {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Accepts ISO 8601 timestamps with any number of fractional-second digits.
    static func iso8601(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}
