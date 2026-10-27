import Foundation

/// A Claude Code or Codex login on this Mac, read so quota works without a proxy.
struct LocalLogin: Sendable {
    let providerID: String
    let email: String?
    let token: String
    let expiresAt: Date?
    /// Codex's ChatGPT account, sent as `ChatGPT-Account-Id`.
    let accountID: String?
    let plan: String?

    var id: String { "local.\(providerID)" + (email.map { ".\($0.lowercased())" } ?? "") }

    func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }

    var cliName: String { providerID == ClaudeQuota.id ? "Claude Code" : "Codex" }
}

/// The logins the CLIs keep on this Mac. Only ever read: renewing a token rotates it, which would
/// sign the CLI out, and each CLI renews its own the next time it runs.
enum LocalLogins {
    static func load() -> [LocalLogin] {
        if Demo.isActive { return [] }
        return [claude(), codex()].compactMap { $0 }
    }

    /// The same request the proxy would make, with the token filled in here.
    static func fetch(_ login: LocalLogin, provider: any QuotaProvider.Type) async throws -> (status: Int, body: Data, retryAfter: TimeInterval?) {
        let request = provider.request(accountID: login.accountID)
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 20
        for (name, value) in request.headers {
            urlRequest.setValue(value.replacingOccurrences(of: "$TOKEN$", with: login.token), forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, data, http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }

    /// Ephemeral and without redirects, like the proxy's, so tokens only go to the provider's host.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: ManagementClient.NoRedirects(), delegateQueue: nil)
    }()

    // MARK: Claude Code

    /// In the login Keychain, read through `security`, which created the item and so reads it without a prompt.
    /// `~/.claude/.credentials.json` holds it where Claude Code couldn't use the Keychain.
    private static func claude() -> LocalLogin? {
        let stored = Connection.runSecurity(["find-generic-password", "-s", "Claude Code-credentials", "-w"]).map { Data($0.utf8) }
        let oauth = [stored, read(".claude/.credentials.json")]
            .lazy.compactMap { $0.flatMap(object)?["claudeAiOauth"] as? [String: Any] }.first
        guard let oauth, let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let account = read(".claude.json").flatMap(object)?["oauthAccount"] as? [String: Any]
        return LocalLogin(
            providerID: ClaudeQuota.id,
            email: account?["emailAddress"] as? String,
            token: token,
            expiresAt: (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
            accountID: nil,
            plan: (oauth["subscriptionType"] as? String)?.capitalized
        )
    }

    // MARK: Codex

    /// `~/.codex/auth.json`, or under `$CODEX_HOME`. API-key logins have no tokens and no quota to show.
    private static func codex() -> LocalLogin? {
        let directory = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        guard let root = (try? Data(contentsOf: directory.appending(path: "auth.json"))).flatMap(object),
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        let identity = (tokens["id_token"] as? String).flatMap(claims)
        let auth = identity?["https://api.openai.com/auth"] as? [String: Any]
        return LocalLogin(
            providerID: CodexQuota.id,
            email: identity?["email"] as? String,
            token: token,
            expiresAt: (claims(token)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            accountID: tokens["account_id"] as? String ?? auth?["chatgpt_account_id"] as? String,
            plan: (auth?["chatgpt_plan_type"] as? String)?.capitalized
        )
    }

    // MARK: Helpers

    private static func read(_ path: String) -> Data? {
        try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: path))
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JWT's payload. Only read for names and expiry; the provider checks the signature.
    private static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap(object)
    }
}
