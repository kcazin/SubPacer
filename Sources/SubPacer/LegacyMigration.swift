import Foundation

/// One-time move of settings, the management key and history from when the app was called ProxyBar.
/// Each step only runs when SubPacer has nothing of its own yet, so it's safe on every launch.
enum LegacyMigration {
    private static let oldName = "ProxyBar"
    private static let oldDefaults = "dev.killian.proxybar"

    static func run() {
        migrateDefaults()
        Connection.migrateKey(fromService: oldName)
        migrateSupportDirectory()
    }

    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "migratedFromProxyBar") == nil else { return }
        if let old = UserDefaults(suiteName: oldDefaults)?.persistentDomain(forName: oldDefaults) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromProxyBar")
    }

    private static func migrateSupportDirectory() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appending(path: oldName)
        let new = support.appending(path: "SubPacer")
        guard FileManager.default.fileExists(atPath: old.path(percentEncoded: false)), !FileManager.default.fileExists(atPath: new.path(percentEncoded: false)) else { return }
        try? FileManager.default.moveItem(at: old, to: new)
    }
}
