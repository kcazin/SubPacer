import Foundation

/// Talks to CLIProxyAPI's management API. Credentials never leave the proxy:
/// quota requests go through `/api-call`, which substitutes `$TOKEN$` server-side.
struct ManagementClient: Sendable {
    let baseURL: URL
    let key: String

    enum ClientError: LocalizedError {
        case unreachable(String)
        case unauthorized
        case disabled
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail): "Proxy not reachable (\(detail))"
            case .unauthorized: "Management key rejected"
            case .disabled: "Management API disabled (no secret-key in proxy config)"
            case .http(let code): "Proxy returned HTTP \(code)"
            }
        }
    }

    func authFiles() async throws -> [AuthFile] {
        let data = try await send(path: "auth-files", method: "GET", body: nil)
        return try JSONDecoder.snake.decode(AuthFilesResponse.self, from: data).files
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
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw ClientError.unauthorized
        case 404: throw ClientError.disabled
        default: throw ClientError.http(status)
        }
    }

    /// Reads the management key from the login Keychain via `security`, which avoids
    /// re-prompting for Keychain access every time the ad-hoc signed app is rebuilt.
    static func loadKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["PROXYBAR_MANAGEMENT_KEY"], !env.isEmpty {
            return env
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "ProxyBar", "-a", "management-key", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
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
        case disabled, unavailable, success, failed, recentRequests, idToken
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
