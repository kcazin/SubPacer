import AppKit
import ServiceManagement
import SwiftUI

@main
struct SubPacerApp: App {
    private let store: UsageStore

    init() {
        LegacyMigration.run()
        store = UsageStore.shared
        if let path = ProcessInfo.processInfo.environment["SUBPACER_SNAPSHOT"] {
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
    @AppStorage("menuBarStyle") private var style = MenuBarStyle.forecast
    @AppStorage("menuBarColor") private var colored = true
    /// The menu bar's own appearance, which follows the wallpaper rather than the system theme.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // `clock` ticks every minute so reset countdowns stay current between refreshes.
        // (A TimelineView inside a MenuBarExtra label causes a layout loop.)
        if let image = rendered(now: store.clock) {
            Image(nsImage: image)
        } else {
            Image(systemName: store.proxyError == nil ? "gauge.with.dots.needle.33percent" : "exclamationmark.triangle")
        }
    }

    /// MenuBarExtra labels drop inline SF Symbols from Text, so render the whole label as an image:
    /// a template image in monochrome, or drawn for the current menu bar appearance in color.
    @MainActor
    private func rendered(now: Date) -> NSImage? {
        guard !store.accounts.isEmpty else { return nil }
        let foreground: Color = colored && colorScheme == .dark ? .white : .black
        let content = HStack(spacing: 8) {
            ForEach(store.menuBarItems(now: now)) { item in
                MenuBarItemView(item: item, style: style, colored: colored, foreground: foreground)
            }
            // A limit reset should be spent now: the pool is out with plenty of the week left.
            if store.accounts.contains(where: { $0.resetAdvice?.action == .useNow }) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colored ? Palette.critical : foreground)
            }
        }
        .environment(\.colorScheme, colorScheme)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        image.isTemplate = !colored
        return image
    }
}
