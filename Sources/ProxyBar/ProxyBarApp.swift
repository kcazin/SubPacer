import AppKit
import ServiceManagement
import SwiftUI

@main
struct ProxyBarApp: App {
    private let store = UsageStore.shared

    init() {
        if let path = ProcessInfo.processInfo.environment["PROXYBAR_SNAPSHOT"] {
            DebugSnapshot.run(to: path)
            return
        }
        UsageStore.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        // `clock` ticks every minute so reset countdowns stay current between refreshes.
        // (A TimelineView inside a MenuBarExtra label causes a layout loop.)
        if let image = rendered(now: store.clock) {
            Image(nsImage: image)
        } else {
            Image(systemName: store.proxyError == nil ? "gauge.with.dots.needle.33percent" : "exclamationmark.triangle")
        }
    }

    /// Remaining quota, or the wait until a used-up account is usable again.
    private func menuValue(for account: AccountUsage, now: Date) -> String {
        if let until = account.blockedUntil {
            return until > now ? ResetFormatter.duration(until.timeIntervalSince(now)).replacingOccurrences(of: " ", with: "") : "…"
        }
        return account.remainingPercent.map { "\(Int($0.rounded(.down)))%" } ?? "–"
    }

    /// MenuBarExtra labels drop inline SF Symbols from Text, so render the whole label as a template image.
    @MainActor
    private func rendered(now: Date) -> NSImage? {
        guard !store.accounts.isEmpty else { return nil }
        let content = HStack(spacing: 8) {
            ForEach(store.accounts) { account in
                HStack(spacing: 3) {
                    Image(systemName: account.isBlocked ? "hourglass" : account.provider?.symbol ?? "circle")
                        .font(.system(size: 11, weight: .bold))
                    Text(menuValue(for: account, now: now))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                }
            }
        }
        .foregroundStyle(.black)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        image.isTemplate = true
        return image
    }
}
