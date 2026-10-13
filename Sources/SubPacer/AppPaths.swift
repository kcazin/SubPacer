import Foundation

enum AppPaths {
    /// Where history and the activity profile live. Demo mode uses a throwaway folder.
    static let support: URL = {
        let directory = Demo.isActive
            ? FileManager.default.temporaryDirectory.appending(path: "SubPacer-demo-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SubPacer")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}
