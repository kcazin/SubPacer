import AppKit
import ServiceManagement
import SwiftUI

@main
struct SubPacerApp: App {
    private let store: UsageStore

    init() {
        if Demo.isActive { Demo.prepare() } else { LegacyMigration.run() }
        store = UsageStore.shared
        if let path = ProcessInfo.processInfo.environment["SUBPACER_SNAPSHOT"] {
            DebugSnapshot.run(to: path)
            return
        }
        UsageStore.shared.start()
        if !Demo.isActive { Updater.shared.start() }
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
        if let image = MenuBarRenderer.image(store: store, style: style, colored: colored, colorScheme: colorScheme, now: store.clock) {
            Image(nsImage: image)
        } else {
            Image(systemName: store.proxyError == nil ? "gauge.with.dots.needle.33percent" : "exclamationmark.triangle")
        }
    }
}

/// MenuBarExtra labels drop inline SF Symbols from Text, so the whole label is rendered as an image:
/// a template image in monochrome, or drawn for the given appearance in color.
/// The settings previews use the same image, so they show exactly what the menu bar will.
enum MenuBarRenderer {
    @MainActor
    static func image(store: UsageStore, style: MenuBarStyle, colored: Bool, colorScheme: ColorScheme, now: Date) -> NSImage? {
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
        .fixedSize()
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
