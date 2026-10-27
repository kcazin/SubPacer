import Foundation

/// Where the proxy is and how to authenticate, from the environment, user defaults and the Keychain.
enum Connection {
    static let defaultURL = URL(string: "http://127.0.0.1:8317")!

    static var configuredURL: String? {
        if Demo.isActive { return defaultURL.absoluteString }
        return ProcessInfo.processInfo.environment["SUBPACER_URL"] ?? UserDefaults.standard.string(forKey: "proxyURL")
    }

    /// Throws when the configured URL is unusable, rather than quietly talking to a different proxy.
    static func proxyURL() throws -> URL {
        if Demo.isActive { return Demo.proxyURL }
        return try configuredURL.map(parse) ?? defaultURL
    }

    static func saveProxyURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: "proxyURL")
    }

    enum URLError: LocalizedError {
        case invalid, scheme, insecure

        var errorDescription: String? {
            switch self {
            case .invalid: "Enter a URL like http://127.0.0.1:8317."
            case .scheme: "The URL must start with http:// or https://."
            case .insecure: "Use https:// for a proxy on another machine; the management key would otherwise be sent in the clear."
            }
        }
    }

    /// Accepts "host:port" and full URLs; plain HTTP only for this machine, since the key travels with every request.
    static func parse(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              let url = components.url else { throw URLError.invalid }
        switch components.scheme?.lowercased() {
        case "https": return url
        case "http": guard isLoopback(host) else { throw URLError.insecure }; return url
        default: throw URLError.scheme
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    // MARK: Management key

    private static let service = "SubPacer"
    private static let account = "management-key"

    /// The key goes through `security` rather than SecItem, so rebuilding the ad-hoc signed app
    /// doesn't make the Keychain prompt for access again.
    static func loadKey() -> String? {
        if Demo.isActive { return "demo" }
        if let env = ProcessInfo.processInfo.environment["SUBPACER_MANAGEMENT_KEY"], !env.isEmpty {
            return env
        }
        return keychainKey()
    }

    private static func keychainKey() -> String? {
        guard let output = runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"]) else { return nil }
        let key = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Copies a key saved under an earlier service name, then removes the old item.
    static func migrateKey(fromService oldService: String) {
        guard keychainKey() == nil,
              let output = runSecurity(["find-generic-password", "-s", oldService, "-a", account, "-w"]) else { return }
        let key = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, saveKey(key) else { return }
        runSecurity(["delete-generic-password", "-s", oldService, "-a", account])
    }

    /// Fed to `security -i` on stdin so the key never appears in a process's arguments.
    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        guard !key.isEmpty, !key.contains(where: \.isNewline) else { return false }
        let quoted = "\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return runSecurity(["-i"], input: "add-generic-password -U -s \(service) -a \(account) -w \(quoted)\n") != nil
            && keychainKey() == key
    }

    @discardableResult
    static func runSecurity(_ arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        do { try process.run() } catch { return nil }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Finds a CLIProxyAPI running on this machine without spending a login attempt:
/// an unauthenticated request answers 401 when management is on and 404 when it's off.
enum ProxyDiscovery {
    enum Result {
        case found(URL)
        case managementOff(URL)
        case notFound
    }

    static func detect() async -> Result {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var managementOff: URL?
        for port in candidatePorts() {
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { continue }
            var request = URLRequest(url: url.appending(path: "v0/management/auth-files"))
            request.timeoutInterval = 2
            guard let (_, response) = try? await session.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { continue }
            switch status {
            case 401, 403: return .found(url)
            case 404: managementOff = managementOff ?? url
            default: continue
            }
        }
        return managementOff.map(Result.managementOff) ?? .notFound
    }

    /// The default port, plus any `port:` from a config.yaml in the usual places.
    private static func candidatePorts() -> [Int] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let paths = [
            "\(home)/.cli-proxy-api/config.yaml",
            "\(home)/.config/cliproxyapi/config.yaml",
            "\(home)/.config/cli-proxy-api/config.yaml",
            "/opt/homebrew/etc/cliproxyapi.conf",
            "/usr/local/etc/cliproxyapi.conf",
        ]
        var ports = [8317]
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let range = text.range(of: #"(?m)^port:\s*\d+"#, options: .regularExpression),
                  let port = Int(text[range].drop { !$0.isNumber }), !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }
}
