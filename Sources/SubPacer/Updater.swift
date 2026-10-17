import AppKit
import CryptoKit
import Foundation

/// Keeps SubPacer current from its GitHub releases. Checks shortly after launch and every few hours;
/// unless turned off in settings, it downloads a newer release, checks it against the SHA-256 GitHub
/// publishes for the asset, swaps it in place of the running app and relaunches.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let autoInstallKey = "autoUpdate"
    nonisolated static let repository = "kcazin/SubPacer"

    struct Release: Equatable, Sendable {
        let version: String
        let zip: URL
        let sha256: String
        let notes: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    private(set) var state = State.idle
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"

    /// `./build.sh` stamps local builds 0.0.0-dev. Updating one would replace it with an older release.
    var isDevelopmentBuild: Bool { currentVersion.hasSuffix("-dev") }

    private var autoInstall: Bool { UserDefaults.standard.object(forKey: Self.autoInstallKey) as? Bool ?? true }
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil, !isDevelopmentBuild else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self else { return }
                await check(install: autoInstall)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check(install: Bool) async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await Self.latestRelease()
            guard release.version.compare(currentVersion, options: .numeric) == .orderedDescending else {
                state = .upToDate
                return
            }
            state = .available(release)
            if install { await self.install(release) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install(_ release: Release) async {
        let target = Bundle.main.bundleURL
        state = .installing(release.version)
        do {
            try Self.checkWritable(target)
            let app = try await Self.download(release, near: target)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            try Self.relaunch(target)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    enum UpdateError: LocalizedError {
        case http(Int)
        case noAsset(String)
        case checksum
        case wrongApp
        case translocated
        case notWritable(String)
        case tool(String, Int32)

        var errorDescription: String? {
            switch self {
            case .http(let code): "GitHub returned HTTP \(code)"
            case .noAsset(let version): "Release \(version) has no SubPacer zip with a checksum"
            case .checksum: "The download doesn't match its published SHA-256"
            case .wrongApp: "The download isn't the expected SubPacer version"
            case .translocated: "macOS is running SubPacer from a quarantined copy. Move it to Applications and open it from there."
            case .notWritable(let folder): "Can't write to \(folder). Install the update by hand or move SubPacer to ~/Applications."
            case .tool(let name, let status): "\(name) failed (\(status))"
            }
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
        }
    }

    private nonisolated static let session = URLSession(configuration: .ephemeral)

    private nonisolated static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let release = try JSONDecoder.snake.decode(GitHubRelease.self, from: data)
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard let asset = release.assets.first(where: { $0.name == "SubPacer-\(version).zip" }),
              let digest = asset.digest, digest.hasPrefix("sha256:")
        else { throw UpdateError.noAsset(version) }
        return Release(version: version, zip: asset.browserDownloadUrl, sha256: String(digest.dropFirst(7)).lowercased(), notes: release.htmlUrl)
    }

    /// Downloads and unpacks the release next to `target` (same volume, so the swap is a rename),
    /// returning the verified app.
    private nonisolated static func download(_ release: Release, near target: URL) async throws -> URL {
        let (file, response) = try await session.download(from: release.zip)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let hash = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        guard hash.map({ String(format: "%02x", $0) }).joined() == release.sha256 else { throw UpdateError.checksum }

        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        try run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
        let app = folder.appending(path: "SubPacer.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version
        else { throw UpdateError.wrongApp }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private static func checkWritable(_ target: URL) throws {
        if target.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        let folder = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else { throw UpdateError.notWritable(folder) }
    }

    /// Quits, and has a shell reopen the app once this process is gone.
    private static func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try process.run()
        NSApplication.shared.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.tool(URL(filePath: tool).lastPathComponent, process.terminationStatus) }
    }
}
