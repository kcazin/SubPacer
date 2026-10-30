import Foundation

/// Talks to CLIProxyAPI's management API. Credentials never leave the proxy:
/// quota requests go through `/api-call`, which substitutes `$TOKEN$` server-side.
struct ManagementClient: Sendable {
    let baseURL: URL
    let key: String

    enum ClientError: LocalizedError {
        case unreachable(String)
        case unauthorized(String?)
        case remoteDisabled
        case disabled
        case http(Int, String?)

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail): "Proxy not reachable (\(detail))"
            case .unauthorized(let detail): "Management key rejected\(detail.map { " (\($0))" } ?? ""). Paused until the key changes: the proxy bans an address after 5 failed attempts."
            case .remoteDisabled: "Remote management is off. Set `remote-management.allow-remote: true` in the proxy's config.yaml, or run SubPacer on the proxy's machine."
            case .disabled: "Management API is off. Set `remote-management.secret-key` in the proxy's config.yaml and restart it."
            case .http(let code, let detail): "Proxy returned HTTP \(code)\(detail.map { ": \($0)" } ?? "")"
            }
        }

        /// Errors that retrying with the same settings won't fix, and that count toward the proxy's ban.
        var needsSetup: Bool {
            switch self {
            case .unauthorized, .remoteDisabled, .disabled: true
            case .unreachable, .http: false
            }
        }
    }

    func authFiles() async throws -> [AuthFile] {
        let data = try await send(path: "auth-files", method: "GET", body: nil)
        return try JSONDecoder.snake.decode(AuthFilesResponse.self, from: data).files
    }

    /// Sets an account's routing priority. The proxy uses the highest-priority account that isn't
    /// cooling down, round-robin among equals; 0 is the default.
    func setPriority(_ priority: Int, file name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "priority": priority])
        _ = try await send(path: "auth-files/fields", method: "PATCH", body: body)
    }

    /// Performs an upstream request using the stored credential for `authIndex`.
    func apiCall(authIndex: String, url: String, headers: [String: String]) async throws -> (status: Int, body: Data, retryAfter: TimeInterval?) {
        let request = APICallRequest(authIndex: authIndex, method: "GET", url: url, header: headers)
        let body = try JSONEncoder.snake.encode(request)
        let data = try await send(path: "api-call", method: "POST", body: body)
        let response = try JSONDecoder.snake.decode(APICallResponse.self, from: data)
        let retryAfter = response.header?.first { $0.key.lowercased() == "retry-after" }?.value.first.flatMap(TimeInterval.init)
        return (response.statusCode, Data(response.body.utf8), retryAfter)
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        if baseURL == Demo.proxyURL { return try Demo.respond(path: path, body: body) }
        var request = URLRequest(url: baseURL.appending(path: "v0/management/\(path)"))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ClientError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        switch status {
        case 200..<300: return data
        case 401: throw ClientError.unauthorized(message)
        case 403 where message?.contains("remote management disabled") == true: throw ClientError.remoteDisabled
        case 404: throw ClientError.disabled
        default: throw ClientError.http(status, message)
        }
    }

    private struct ErrorBody: Decodable { let error: String }

    /// Ephemeral, so responses (which carry account emails) never land in the on-disk URL cache,
    /// and redirects are refused so the management key is only ever sent to the configured host.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}

// MARK: - Wire types

struct AuthFilesResponse: Decodable {
    let files: [AuthFile]
}

struct AuthFile: Decodable {
    let name: String
    let authIndex: String?
    let provider: String?
    let type: String?
    let email: String?
    let label: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool?
    let unavailable: Bool?
    let priority: Int?
    let success: Int?
    let failed: Int?
    let recentRequests: [Bucket]?
    let idToken: IDToken?

    struct Bucket: Decodable {
        let time: String
        let success: Int
        let failed: Int
    }

    struct IDToken: Decodable {
        let chatgptAccountId: String?
        let planType: String?
    }

    enum CodingKeys: String, CodingKey {
        case name, authIndex, provider, type, email, label, status, statusMessage
        case disabled, unavailable, priority, success, failed, recentRequests, idToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        authIndex = try? c.decodeIfPresent(String.self, forKey: .authIndex)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try? c.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try? c.decodeIfPresent(Bool.self, forKey: .disabled)
        unavailable = try? c.decodeIfPresent(Bool.self, forKey: .unavailable)
        priority = try? c.decodeIfPresent(Int.self, forKey: .priority)
        success = try? c.decodeIfPresent(Int.self, forKey: .success)
        failed = try? c.decodeIfPresent(Int.self, forKey: .failed)
        recentRequests = try? c.decodeIfPresent([Bucket].self, forKey: .recentRequests)
        // id_token is an object for Codex auths but may be absent or a raw string elsewhere.
        idToken = try? c.decodeIfPresent(IDToken.self, forKey: .idToken)
    }

    var providerID: String { (provider ?? type ?? "").lowercased() }
}

struct APICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
}

struct APICallResponse: Decodable {
    let statusCode: Int
    let header: [String: [String]]?
    let body: String
}

extension JSONDecoder {
    static let snake: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension JSONEncoder {
    static let snake: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
