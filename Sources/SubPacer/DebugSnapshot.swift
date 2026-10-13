import AppKit
import SwiftUI

/// `SUBPACER_SNAPSHOT=/tmp/panel.png [SUBPACER_APPEARANCE=dark] SubPacer` refreshes once,
/// shows the panel in an on-screen window (so glass effects render), captures it and exits.
enum DebugSnapshot {
    @MainActor
    static func run(to path: String) {
        Task { @MainActor in
            let store = UsageStore.shared
            await store.refresh()

            let appearance: NSAppearance? = switch ProcessInfo.processInfo.environment["SUBPACER_APPEARANCE"] {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }

            let hosting = NSHostingView(rootView: UsagePanel(store: store, showSettings: ProcessInfo.processInfo.environment["SUBPACER_SETTINGS"] != nil))
            hosting.frame.size = hosting.fittingSize
            let background = NSVisualEffectView(frame: hosting.frame)
            background.material = .popover
            background.state = .active
            background.blendingMode = .behindWindow
            background.addSubview(hosting)

            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.contentView = background
            window.center()
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1.5))

            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
            try? capture.run()
            capture.waitUntilExit()

            for account in store.accounts {
                let windows = account.snapshot.windows.map { "\($0.label)=\(Int($0.usedPercent))%" }.joined(separator: ", ")
                print("\(account.providerID) \(account.email) error=\(account.error ?? "-") [\(windows)]")
            }
            for runway in store.runways {
                let outages = runway.outages.map { "\($0.window) \($0.interval.start.formatted())–\($0.interval.end.formatted())" }
                print("runway \(runway.providerID) accounts=\(runway.accountCount) horizon=\(runway.horizon.formatted()) headroom=\(runway.headroom.map { String(format: "%.2f", $0) } ?? "-") outages=\(outages)")
            }
            print("proxyError=\(store.proxyError ?? "-")")
            NSApplication.shared.terminate(nil)
        }
    }
}
