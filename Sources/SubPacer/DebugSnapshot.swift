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

            let hosting = NSHostingView(rootView: UsagePanel(
                store: store, showSettings: ProcessInfo.processInfo.environment["SUBPACER_SETTINGS"] != nil, limitHeight: false
            ))
            // The cards measure themselves on the first layout pass, so size the window after it.
            hosting.frame.size = hosting.fittingSize
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
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
            // On the sharpest screen, so the capture is 2x even with a 1x display attached.
            if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
            } else {
                window.center()
            }
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1.5))

            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
            try? capture.run()
            capture.waitUntilExit()

            if let menuBarPath = ProcessInfo.processInfo.environment["SUBPACER_MENUBAR"] {
                writeMenuBar(store: store, dark: appearance?.name == .darkAqua, to: menuBarPath)
            }

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

    /// The menu bar label on a menu-bar-like strip, for the README.
    @MainActor
    private static func writeMenuBar(store: UsageStore, dark: Bool, to path: String) {
        let style = UserDefaults.standard.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .forecast
        let compact = UserDefaults.standard.object(forKey: MenuBarStyle.compactKey) == nil || UserDefaults.standard.bool(forKey: MenuBarStyle.compactKey)
        guard let image = MenuBarRenderer.image(store: store, style: style, colored: true, compact: compact, colorScheme: dark ? .dark : .light, now: Date()) else { return }
        let size = NSSize(width: image.size.width + 24, height: 26)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(at: NSPoint(x: 12, y: (size.height - image.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
