import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Palette

/// Muted tones with separate light/dark variants, so color stays legible on both
/// without shouting. Color only appears when something needs attention.
enum Palette {
    static let ok = adaptive(light: (0.44, 0.42, 0.56), dark: (0.44, 0.36, 0.82))
    static let warning = adaptive(light: (0.09, 0.62, 0.78), dark: (0.10, 0.46, 0.98))
    static let critical = adaptive(light: (0.01, 0.58, 0.76), dark: (0.01, 0.40, 1.00))
    static let track = Color.primary.opacity(0.08)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map { [.darkAqua, .vibrantDark].contains($0) } ?? false
            let (h, s, b) = isDark ? dark : light
            return NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
        })
    }
}

/// Severity drives color: how much is left, and whether the current pace runs out before reset.
enum Severity {
    case ok, warning, critical

    init(remaining: Double, projection: Projection?) {
        if remaining <= 0 {
            self = .critical
        } else if case .runsOut = projection?.outcome {
            self = remaining < 10 ? .critical : .warning
        } else if remaining < 10 {
            self = .critical
        } else if remaining < 30 {
            self = .warning
        } else {
            self = .ok
        }
    }

    var color: Color {
        switch self {
        case .ok: Palette.ok
        case .warning: Palette.warning
        case .critical: Palette.critical
        }
    }
}

// MARK: - Panel

struct UsagePanel: View {
    let store: UsageStore
    @State var showSettings = false
    /// Snapshots render the whole panel; on screen it scrolls once it would outgrow the display.
    var limitHeight = true
    @State private var cardsHeight: CGFloat = 0
    @AppStorage(PanelSection.runway.storageKey) private var showRunway = true
    @AppStorage(PanelSection.accounts.storageKey) private var showAccounts = true
    @AppStorage(PanelSection.tonight.storageKey) private var showTonight = true
    @AppStorage(PanelSection.proxy.storageKey) private var showProxy = true

    /// Room for the cards: the screen below the menu bar, minus the header, footer and a margin.
    private var maxCardsHeight: CGFloat {
        guard limitHeight, let screen = NSScreen.main else { return .infinity }
        return max(240, screen.visibleFrame.height - 110)
    }

    var body: some View {
        VStack(spacing: 10) {
            header

            // The glass container goes inside the scroll view so the cards clip at its edges.
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        if showSettings {
                            ConnectionCard(store: store)
                            SettingsCard(store: store)
                        } else if store.needsSetup {
                            ConnectionCard(store: store)
                        } else {
                            content
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(cardsHeight > maxCardsHeight ? .automatic : .hidden)
            .frame(height: min(cardsHeight, maxCardsHeight))

            footer
        }
        .padding(12)
        .frame(width: 340)
        .task { await store.refreshIfStale() }
        .onDisappear { Privacy.shared.revealed.removeAll() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.proxyError {
            Banner(text: error, symbol: "exclamationmark.triangle.fill", tint: Palette.warning)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        if showRunway && !store.runways.isEmpty {
            RunwayCard(runways: store.runways)
        }
        if showAccounts {
            ForEach(store.accounts) { account in
                AccountCard(account: account)
            }
        }
        if store.accounts.isEmpty && store.proxyError == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
        if showTonight && store.accounts.contains(where: { $0.offHours != nil }) {
            OffHoursCard(store: store)
        }
        if showProxy && store.accounts.contains(where: { $0.source == .proxy }) {
            ProxySection(store: store)
        }
        if !store.accounts.isEmpty && !(showRunway || showAccounts || showTonight || showProxy) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showSettings = true }
            } label: {
                Label("All sections are hidden. Show some in settings.", systemImage: "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Usage")
                .font(.system(size: 13, weight: .semibold))
            if let updated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(updated, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.25)) { showSettings.toggle() }
            } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .keyboardShortcut(",")
            .help(showSettings ? "Close settings" : "Settings (⌘,)")
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack {
            LaunchAtLoginToggle()
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut("q")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
    }
}

// MARK: - Account card

struct AccountCard: View {
    let account: AccountUsage

    private var tint: Color { account.provider?.tint ?? .gray }
    private var primary: [QuotaWindow] { account.snapshot.windows.filter(\.isPrimary) }
    private var secondary: [QuotaWindow] { account.snapshot.windows.filter { !$0.isPrimary } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identity

            if let error = account.error {
                Banner(text: error, symbol: "exclamationmark.circle.fill", tint: Palette.critical)
            } else if let notice = account.notice {
                Banner(text: notice, symbol: "clock", tint: .secondary)
            }

            if account.isBlocked {
                BlockedView(account: account)
            } else {
                ForEach(primary) { window in
                    WindowRow(window: window, projection: account.projections[window.id])
                }
            }

            if (!secondary.isEmpty && !account.isBlocked) || account.snapshot.credits != nil {
                VStack(spacing: 5) {
                    if !account.isBlocked {
                        ForEach(secondary) { window in
                            WindowRow(window: window, projection: nil, compact: true)
                        }
                    }
                    if let credits = account.snapshot.credits {
                        HStack {
                            Text("Credits").frame(width: WindowRow.labelWidth, alignment: .leading)
                            Text(credits)
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let advice = account.resetAdvice {
                ResetRow(advice: advice, email: account.email)
            } else if let spent = account.snapshot.resetGrants.first(where: { $0.resetsLeft == 0 }) {
                HStack {
                    Text("Reset").frame(width: WindowRow.labelWidth, alignment: .leading)
                    Text("Used · \(ResetRow.shortLabel(spent))").lineLimit(1)
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(spent.label)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(tint.opacity(0.05)), in: .rect(cornerRadius: 16))
    }

    private var identity: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: account.provider?.symbol ?? "circle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
            EmailText(email: account.email)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if account.source == .local {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help("Read from this Mac's \(account.providerID == ClaudeQuota.id ? "Claude Code" : "Codex") login, not the proxy")
            }
            Spacer(minLength: 4)
            Text(account.snapshot.plan ?? account.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }
}

// MARK: - Limit reset

/// An unused limit reset on the account, and whether now is the moment to spend it.
struct ResetRow: View {
    let advice: ResetAdvice
    let email: String
    @AppStorage(Privacy.blurKey) private var blurEmails = true

    private var grant: ResetGrant { advice.grant }

    private var tint: Color {
        switch advice.action {
        case .useNow: Palette.critical
        case .useAt, .useBeforeExpiry: Palette.warning
        case .hold: Palette.ok
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text("Limit reset")
                    .font(.system(size: 11, weight: .medium))
                Text(grant.resetsTotal > 1 ? "\(grant.resetsLeft) left" : "available")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(headline)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(advice.action == .hold ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            }
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .help("\(grant.label). Refills \(limits) at once; the weekly reset day stays the same. Use it with /limit-reset in Claude Code signed in as \(blurEmails && !Privacy.shared.revealed.contains(email) ? "this account" : email).")
    }

    private var headline: String {
        switch advice.action {
        case .useNow: "Use now"
        case .useAt(let date): "Use \(ResetFormatter.clock(date))"
        case .useBeforeExpiry(let date): "Use by \(ResetFormatter.clock(date))"
        case .hold: "Hold"
        }
    }

    private var detail: String {
        guard let ends = grant.endsAt, advice.action != .useBeforeExpiry(ends) else { return advice.reason }
        return "\(advice.reason) · expires \(Self.date(ends))"
    }

    private var limits: String {
        let names = grant.clears.compactMap { ["five_hour": "session", "seven_day": "weekly"][$0] }
        return names.isEmpty ? "your limits" : "your \(names.joined(separator: " and ")) limits"
    }

    /// "Claude Opus 5.5 launch" from "Claude Opus 5.5 launch: one usage-limit reset for Pro and Max".
    static func shortLabel(_ grant: ResetGrant) -> String {
        grant.label.split(separator: ":").first.map(String.init) ?? grant.label
    }

    /// Weekday within the week, otherwise the date.
    static func date(_ date: Date) -> String {
        date.timeIntervalSinceNow < 6 * 86_400
            ? ResetFormatter.clock(date)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - Blocked state

/// Replaces the gauges while a limit is used up: the only useful number is when it comes back.
struct BlockedView: View {
    let account: AccountUsage

    /// The exhausted window that resets last, which is the one being waited on.
    private var window: QuotaWindow? {
        account.exhaustedWindows.max { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("\(window?.label ?? "Limit") limit reached", systemImage: "pause.circle.fill")
                            .labelStyle(CompactLabelStyle())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.critical)
                        if let until = account.blockedUntil, until > context.date {
                            Text("Back in \(ResetFormatter.duration(until.timeIntervalSince(context.date)))")
                                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())
                        } else {
                            Text("Resetting…")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                        }
                    }
                    Spacer()
                    if let until = account.blockedUntil {
                        Text(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // Fills up as the reset approaches.
                if let elapsed = window?.elapsedFraction(now: context.date) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track)
                            Capsule()
                                .fill(Color.primary.opacity(0.3).gradient)
                                .frame(width: max(proxy.size.width * elapsed, 4))
                        }
                    }
                    .frame(height: 4)
                    .help("\(Int((elapsed * 100).rounded()))% of the \(window?.label.lowercased() ?? "") window has passed")
                }
            }
        }
    }
}

// MARK: - Window rows

struct WindowRow: View {
    static let labelWidth: CGFloat = 58
    static let valueWidth: CGFloat = 40

    let window: QuotaWindow
    let projection: Projection?
    var compact = false

    private var remaining: Double { 100 - min(max(window.usedPercent, 0), 100) }
    private var severity: Severity { Severity(remaining: remaining, projection: projection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(window.label)
                    .font(.system(size: 11, weight: compact ? .regular : .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: Self.labelWidth, alignment: .leading)
                UsageBar(remaining: remaining, elapsed: compact ? nil : window.elapsedFraction(), color: severity.color, height: compact ? 4 : 6)
                Text("\(Int(remaining.rounded(.down)))%")
                    .font(.system(size: compact ? 11 : 13, weight: compact ? .medium : .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(remaining <= 0 ? AnyShapeStyle(Palette.critical) : compact ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: Self.valueWidth, alignment: .trailing)
            }
            .help(window.label)

            if !compact {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 6) {
                        status(now: context.date)
                        Spacer(minLength: 4)
                        if let reset = window.resetsAt, reset > context.date {
                            Label(ResetFormatter.relative(from: context.date, to: reset), systemImage: "arrow.counterclockwise")
                                .labelStyle(CompactLabelStyle())
                                .foregroundStyle(.tertiary)
                                .help("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .padding(.leading, Self.labelWidth + 10)
                }
            }
        }
    }

    @ViewBuilder
    private func status(now: Date) -> some View {
        if let projection {
            ProjectionLabel(projection: projection, now: now)
        } else if window.resetsAt == nil {
            StatusLabel(text: "Not started", symbol: "moon.zzz", tint: .secondary)
        } else {
            StatusLabel(text: "Projecting…", symbol: "chart.line.uptrend.xyaxis", tint: .tertiary)
                .help("A projection appears after about 10 minutes of usage data.")
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5, weight: .semibold))
            configuration.title
        }
    }
}

struct StatusLabel<Tint: ShapeStyle>: View {
    let text: String
    let symbol: String
    let tint: Tint

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProjectionLabel: View {
    let projection: Projection
    let now: Date

    var body: some View {
        content
            .help(projection.basis.map { "Projected from \($0.rawValue)." } ?? "")
    }

    @ViewBuilder
    private var content: some View {
        switch projection.outcome {
        case .noUsage:
            StatusLabel(text: "Not used yet", symbol: "moon.zzz", tint: .secondary)
        case .limitReached:
            StatusLabel(text: "Limit reached", symbol: "pause.circle.fill", tint: Palette.critical)
        case .runsOut(let date):
            let remainingTime = date.timeIntervalSince(now)
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(remainingTime < 3600 ? Palette.critical : Palette.warning)
                Text("Runs out in \(ResetFormatter.duration(max(remainingTime, 60)))")
                    .foregroundStyle(.primary)
                Text(ResetFormatter.clock(date))
                    .foregroundStyle(.secondary)
            }
        case .lastsUntilReset(let atReset):
            StatusLabel(text: "Lasts · \(Int((100 - atReset).rounded()))% spare", symbol: "checkmark.circle.fill", tint: Palette.ok)
        }
    }
}

struct UsageBar: View {
    /// 0–100; the bar starts full and drains as quota is used.
    let remaining: Double
    /// Share of the window elapsed (0–1). The marker shows where the bar would be at an even pace.
    let elapsed: Double?
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: remaining > 0 ? max(width * remaining / 100, height) : 0)
                if let elapsed, elapsed > 0.01, elapsed < 0.99 {
                    let evenPace = 1 - elapsed
                    Capsule()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: height + 4)
                        .offset(x: width * evenPace - 1)
                        .help("At an even pace you'd have \(Int((evenPace * 100).rounded()))% left now")
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: height + 4)
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(.init(text))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Runway

/// The meta view: pooling each provider's accounts, do you make it to every reset without running out?
struct RunwayCard: View {
    let runways: [Runway]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "road.lanes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Runway")
                        .font(.system(size: 12, weight: .semibold))
                    Text("until every limit resets")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(runways) { runway in
                    RunwayRow(runway: runway, now: context.date)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct RunwayRow: View {
    let runway: Runway
    let now: Date

    private var tint: Color { runway.provider?.tint ?? .gray }

    private var severity: Severity {
        guard let runsOut = runway.runsOutAt else { return .ok }
        return runsOut.timeIntervalSince(now) < 86_400 ? .critical : .warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(runway.provider?.displayName ?? runway.providerID.capitalized)
                    .font(.system(size: 11, weight: .medium))
                if runway.accountCount > 1 {
                    Text("\(runway.accountCount) accounts pooled")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                headline
            }
            RunwayBar(runway: runway, now: now, color: severity.color)
                .frame(height: 10)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Projected from \(runway.basis.rawValue), split across accounts that still have quota.")
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let runsOut = runway.runsOutAt {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(severity.color)
                Text(runsOut <= now ? "Out now" : "Out \(ResetFormatter.clock(runsOut))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        } else {
            Label("Never runs out", systemImage: "checkmark.circle.fill")
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ok)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let outage = runway.outages.first {
            parts.append("\(outage.window) runs out · back \(ResetFormatter.clock(outage.interval.end))")
        } else {
            parts.append("Lasts to \(ResetFormatter.clock(runway.horizon))")
        }
        if let headroom = runway.headroom {
            let multiple = headroom.formatted(.number.precision(.fractionLength(1)))
            if headroom >= 8 {
                parts.append("pace could go 8×+")
            } else if headroom >= 1 && headroom < 1.1 {
                parts.append("just enough at your pace")
            } else if headroom >= 1 {
                parts.append("room for \(multiple)× your pace")
            } else {
                parts.append("slow to \(multiple)× to last")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// A timeline from now to the last weekly reset: filled while quota is projected to be
/// available, gaps where every account is used up, ticks where an account's week resets.
struct RunwayBar: View {
    let runway: Runway
    let now: Date
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height: CGFloat = 6
            let span = runway.horizon.timeIntervalSince(runway.start)
            let x = { (date: Date) -> CGFloat in
                span > 0 ? width * CGFloat(min(max(date.timeIntervalSince(runway.start) / span, 0), 1)) : 0
            }
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    ForEach(Array(runway.availableIntervals.enumerated()), id: \.offset) { _, segment in
                        let start = x(segment.start), end = x(segment.end)
                        Rectangle()
                            .fill(color.gradient)
                            .frame(width: max(end - start, 1))
                            .offset(x: start)
                    }
                    ForEach(midnights, id: \.self) { midnight in
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 1)
                            .offset(x: x(midnight))
                    }
                }
                .frame(height: height)
                .clipShape(Capsule())
                ForEach(runway.resets, id: \.self) { reset in
                    Capsule()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: height + 4)
                        .offset(x: x(reset) - 1)
                        .help("An account's weekly limit resets \(ResetFormatter.clock(reset))")
                }
            }
            .frame(height: proxy.size.height)
        }
        .help(runway.outages.isEmpty
              ? "Now → \(ResetFormatter.clock(runway.horizon)) (last weekly reset)"
              : "Gaps are when every account is projected to be used up: " + runway.outages.map {
                  "\(ResetFormatter.clock($0.interval.start))–\(ResetFormatter.clock($0.interval.end))"
              }.joined(separator: ", "))
    }

    private var midnights: [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        var day = calendar.startOfDay(for: runway.start)
        while let next = calendar.date(byAdding: .day, value: 1, to: day), next < runway.horizon {
            dates.append(next)
            day = next
        }
        return dates
    }
}

// MARK: - Settings

struct SettingsCard: View {
    let store: UsageStore
    @AppStorage("menuBarStyle") private var style = MenuBarStyle.forecast
    @AppStorage("menuBarColor") private var colored = true
    @AppStorage(MenuBarStyle.compactKey) private var compact = true
    @AppStorage(Privacy.blurKey) private var blurEmails = true
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Menu bar")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Color", isOn: $colored)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(MenuBarStyle.allCases) { option in
                        StyleTile(
                            style: option,
                            image: MenuBarRenderer.image(store: store, style: option, colored: colored, compact: compact, colorScheme: colorScheme, now: context.date),
                            selected: option == style
                        )
                        .onTapGesture { style = option }
                    }
                }
            }
            Text(style.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Compact with 2+ providers").font(.system(size: 11, weight: .medium))
                    Text("Just the graphic for each provider, without the text beside it.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Compact with 2+ providers", isOn: $compact)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Panel")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(PanelSection.allCases) { section in
                    SectionToggle(section: section)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Blur email addresses").font(.system(size: 11, weight: .medium))
                    Text("Click one to show it until the panel closes.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Blur email addresses", isOn: $blurEmails)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            Divider()
            UpdatesSection()
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

struct UpdatesSection: View {
    @AppStorage(Updater.autoInstallKey) private var autoInstall = true
    private let updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Updates")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                action
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Install automatically").font(.system(size: 11, weight: .medium))
                    Text(.init(status))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Install automatically", isOn: $autoInstall)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(updater.isDevelopmentBuild)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch updater.state {
        case .checking, .installing:
            ProgressView().controlSize(.mini)
        case .available(let release):
            Button("Install \(release.version)") { Task { await updater.install(release) } }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        default:
            Button("Check now") { Task { await updater.check(install: false) } }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(updater.isDevelopmentBuild)
        }
    }

    private var status: String {
        let version = "Version \(updater.currentVersion)"
        if updater.isDevelopmentBuild { return "\(version). Local builds update through `./build.sh`." }
        switch updater.state {
        case .idle: return "\(version). Checks GitHub every few hours."
        case .checking: return "\(version). Checking…"
        case .upToDate: return "\(version) is the latest."
        case .available(let release): return "\(release.version) is out. [What's new](\(release.notes.absoluteString))"
        case .installing(let next): return "Installing \(next). SubPacer will restart."
        case .failed(let error): return "Update failed: \(error)"
        }
    }
}

// MARK: - Panel sections

/// The cards the panel can show, each of which can be hidden in settings.
enum PanelSection: String, CaseIterable, Identifiable {
    case runway, accounts, tonight, proxy

    var id: String { rawValue }
    var storageKey: String { "show.\(rawValue)" }

    var title: String {
        switch self {
        case .runway: "Runway"
        case .accounts: "Accounts"
        case .tonight: "Tonight"
        case .proxy: "Proxy stats"
        }
    }

    var detail: String {
        switch self {
        case .runway: "pooled forecast per provider"
        case .accounts: "quota and limit resets per account"
        case .tonight: "quiet hours and spare weekly quota"
        case .proxy: "requests and failures, last 3h"
        }
    }
}

struct SectionToggle: View {
    let section: PanelSection
    @AppStorage private var isOn: Bool

    init(section: PanelSection) {
        self.section = section
        _isOn = AppStorage(wrappedValue: true, section.storageKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(section.title).font(.system(size: 11, weight: .medium))
            Text("· \(section.detail)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Toggle(section.title, isOn: $isOn.animation(.snappy(duration: 0.25)))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

// MARK: - Connection

/// Points SubPacer at a CLIProxyAPI: shown on first run, when the proxy refuses the
/// current settings, and in settings.
struct ConnectionCard: View {
    let store: UsageStore
    @State private var urlText = ""
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var working = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("CLIProxyAPI")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Find local") { Task { await detect() } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(working)
                    .help("Look for a proxy on this Mac (port 8317 and any port in its config.yaml)")
            }
            if store.needsSetup, message == nil, let error = store.proxyError {
                Banner(text: error, symbol: "exclamationmark.triangle.fill", tint: Palette.warning)
            }
            field("URL") {
                TextField("http://127.0.0.1:8317", text: $urlText)
                    .onSubmit { Task { await connect() } }
            }
            field("Key") {
                SecureField(hasSavedKey ? "Saved in Keychain" : "remote-management.secret-key", text: $key)
                    .onSubmit { Task { await connect() } }
            }
            HStack(spacing: 6) {
                if working {
                    ProgressView().controlSize(.mini)
                } else if let message {
                    Image(systemName: message.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.isError ? Palette.critical : Palette.ok)
                }
                Text(.init(message?.text ?? "The key stays in your login Keychain."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Connect") { Task { await connect() } }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || urlText.trimmingCharacters(in: .whitespaces).isEmpty || (key.isEmpty && !hasSavedKey))
            }
            .font(.system(size: 10.5))
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear {
            urlText = Connection.configuredURL ?? Connection.defaultURL.absoluteString
            hasSavedKey = Connection.loadKey() != nil
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            content()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(working)
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        do {
            try await store.connect(urlText: urlText, key: key)
            key = ""
            hasSavedKey = true
            message = ("Connected · \(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s")", false)
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    private func detect() async {
        working = true
        defer { working = false }
        switch await ProxyDiscovery.detect() {
        case .found(let url):
            urlText = url.absoluteString
            message = ("Found a proxy at \(url.host() ?? ""):\(url.port ?? 0). Add its key and connect.", false)
        case .managementOff(let url):
            urlText = url.absoluteString
            message = ("Found a proxy, but its management API is off. Set `remote-management.secret-key` in its config.yaml and restart it.", true)
        case .notFound:
            message = ("No proxy answering on this Mac. Enter its URL instead.", true)
        }
    }
}

// MARK: - Privacy

/// Which blurred addresses the user has clicked to show. Cleared when the panel closes.
@MainActor
@Observable
final class Privacy {
    static let shared = Privacy()
    static let blurKey = "blurEmails"
    var revealed: Set<String> = []
}

/// An account email, blurred by default so the panel can be screenshotted or shared. Click to show or hide it.
struct EmailText: View {
    let email: String
    @AppStorage(Privacy.blurKey) private var blurEmails = true
    private let privacy = Privacy.shared

    private var hidden: Bool { blurEmails && !privacy.revealed.contains(email) }

    var body: some View {
        Text(email)
            .blur(radius: hidden ? 4.5 : 0)
            .animation(.snappy(duration: 0.2), value: hidden)
            .contentShape(Rectangle())
            .onTapGesture {
                guard blurEmails else { return }
                if privacy.revealed.contains(email) { privacy.revealed.remove(email) } else { privacy.revealed.insert(email) }
            }
            .help(blurEmails ? (hidden ? "Click to show" : "Click to hide") : "")
            .accessibilityLabel(hidden ? "Hidden email address" : email)
            .accessibilityAddTraits(blurEmails ? .isButton : [])
    }
}

/// A live preview of one menu bar style, with your current numbers.
struct StyleTile: View {
    let style: MenuBarStyle
    let image: NSImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let image {
                    // Shrinks to fit when several providers make the label wider than the tile.
                    Image(nsImage: image)
                        .renderingMode(image.isTemplate ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Text(style.title)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .help(style.summary)
    }
}

// MARK: - Off-hours

/// How much weekly quota will expire unused, and what that means for each quiet night left.
struct OffHoursCard: View {
    let store: UsageStore

    private var profile: ActivityProfile { store.profile }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 9) {
                header(now: context.date)
                HourProfile(profile: profile, now: context.date)
                    .frame(height: 18)
                VStack(spacing: 7) {
                    ForEach(store.accounts) { account in
                        if let insight = account.offHours {
                            InsightRow(account: account, insight: insight, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(Color.indigo.opacity(0.06)), in: .rect(cornerRadius: 16))
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.indigo.opacity(0.8))
            Text(profile.isQuiet(now) ? "Quiet hours" : "Tonight")
                .font(.system(size: 12, weight: .semibold))
            if let quiet = profile.quiet {
                Text(Self.range(quiet))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(profile.isLearned ? "learned" : "learning \(profile.learnedHours)/24h")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(profile.isLearned
                      ? "Quiet hours come from when requests hit your proxy."
                      : "Each hour of the day needs proxy activity seen on \(ActivityProfile.daysToLearn) different days. Until then 23:00–08:00 is assumed quiet.")
        }
    }

    static func range(_ quiet: (start: Int, length: Int)) -> String {
        let end = (quiet.start + quiet.length) % 24
        return String(format: "%02d:00–%02d:00", quiet.start, end)
    }
}

struct InsightRow: View {
    let account: AccountUsage
    let insight: OffHoursInsight
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(account.provider?.tint ?? .gray)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                EmailText(email: account.email)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            headline
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch insight {
        case .spare:
            if let perNight = insight.perNight {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("~\(Int(perNight.rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.indigo.opacity(0.9))
                    Text("/night")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                    .help("Weekly quota you can spend each quiet night without cutting into what your normal pace needs.")
            } else {
                Text("no nights left").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        case .noSpare:
            Text("needs it all").font(.system(size: 10.5)).foregroundStyle(.secondary)
        case .usedUp(let until, let resetsTonight):
            if resetsTonight {
                Text("from \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.indigo.opacity(0.9))
                    .help("The weekly limit resets during tonight's quiet hours, so a full week is available from then.")
            } else {
                Text("none tonight").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        switch insight {
        case .spare(let percent, let reset, let nights):
            let count = nights.count
            return "\(Int(percent.rounded()))% expires \(ResetFormatter.clock(reset)) · \(count) night\(count == 1 ? "" : "s") left"
        case .noSpare(let reset):
            return "On pace to use the week by \(ResetFormatter.clock(reset))"
        case .usedUp(let until, let resetsTonight):
            return resetsTonight
                ? "Weekly resets during tonight's quiet hours"
                : "Weekly used up · back \(ResetFormatter.clock(until))"
        }
    }
}

/// 24 bars of activity by hour of day; quiet hours dimmed, unlearned hours hollow.
struct HourProfile: View {
    let profile: ActivityProfile
    let now: Date

    var body: some View {
        let currentHour = Calendar.current.component(.hour, from: now)
        let peak = max(profile.rates.compactMap { $0 }.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                let quiet = profile.weights[hour] < ActivityProfile.quietThreshold
                let height: CGFloat = profile.rates[hour].map { max(2, 18 * CGFloat($0 / peak)) } ?? 18 * CGFloat(profile.weights[hour]) * 0.35 + 2
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(profile.rates[hour] == nil
                          ? AnyShapeStyle(Color.primary.opacity(0.1))
                          : AnyShapeStyle(quiet ? Color.indigo.opacity(0.35) : Color.primary.opacity(0.4)))
                    .frame(height: height)
                    .overlay(alignment: .bottom) {
                        if hour == currentHour {
                            Capsule().fill(Color.primary.opacity(0.7)).frame(height: 2).offset(y: 4)
                        }
                    }
                    .help(String(format: "%02d:00", hour) + (profile.rates[hour].map { " · \(Int($0.rounded())) req/h" } ?? " · learning"))
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Proxy stats (secondary)

struct ProxySection: View {
    let store: UsageStore
    @AppStorage("proxyExpanded") private var expanded = false

    private var ok: Int { store.accounts.reduce(0) { $0 + $1.recentSuccess.reduce(0, +) } }
    private var failed: Int { store.accounts.reduce(0) { $0 + $1.recentFailed.reduce(0, +) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.proxyError == nil ? Palette.ok : Palette.critical)
                        .frame(width: 6, height: 6)
                    Text(store.baseURL.host()?.split(separator: ".").first.map(String.init) ?? "Proxy")
                        .foregroundStyle(.primary)
                    Text("proxy").foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(ok.formatted()) ok")
                    if failed > 0 {
                        Text("\(failed.formatted()) failed").foregroundStyle(Palette.critical)
                    }
                    Text("3h").foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .help(store.baseURL.absoluteString)

            if expanded {
                VStack(spacing: 6) {
                    ForEach(store.accounts.filter { $0.source == .proxy }) { account in
                        ProxyAccountRow(account: account)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}

struct ProxyAccountRow: View {
    let account: AccountUsage

    private var ok: Int { account.recentSuccess.reduce(0, +) }
    private var failed: Int { account.recentFailed.reduce(0, +) }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.provider?.tint ?? .gray)
                .frame(width: 5, height: 5)
            EmailText(email: account.email)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(success: account.recentSuccess, failed: account.recentFailed)
                .frame(width: 72, height: 12)
            Group {
                if account.unavailable {
                    Text("cooling").foregroundStyle(Palette.warning)
                } else if let status = account.proxyStatus, status != "active" {
                    Text(status).foregroundStyle(Palette.warning)
                } else if failed > 0 {
                    Text("\(ok) \(Text("/ \(failed)").foregroundStyle(Palette.critical))")
                } else {
                    Text("\(ok)")
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .help(account.proxyStatusMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "\(ok) ok, \(failed) failed in the last ~3h")
    }
}

struct Sparkline: View {
    let success: [Int]
    let failed: [Int]

    var body: some View {
        let pairs = Array(zip(success, failed))
        let peak = max(pairs.map { $0.0 + $0.1 }.max() ?? 0, 1)
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(pairs.indices, id: \.self) { index in
                    let (ok, bad) = pairs[index]
                    let total = ok + bad
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if bad > 0 {
                            Rectangle().fill(Palette.critical)
                                .frame(height: proxy.size.height * CGFloat(bad) / CGFloat(peak))
                        }
                        Rectangle().fill(Color.primary.opacity(total > 0 ? 0.4 : 0.12))
                            .frame(height: total > 0 ? max(1, proxy.size.height * CGFloat(ok) / CGFloat(peak)) : 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                }
            }
        }
    }
}

// MARK: - Helpers

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .onChange(of: enabled) { _, newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}

enum ResetFormatter {
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    static func string(from now: Date, to date: Date) -> String {
        duration(date.timeIntervalSince(now))
    }

    /// "4h 57m" within a day, otherwise "Wed 12:00".
    static func relative(from now: Date, to date: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 86_400 { return duration(interval) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Compact time for the menu bar: "14:00" today, otherwise "Thu".
    static func short(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Time of day, with the weekday when it isn't today.
    static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
