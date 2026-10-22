import SwiftUI

/// How each provider is drawn in the menu bar. Picked in the panel's settings.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case forecast, ring, ringHeadroom, sessionWeekly, perAccount, runway, battery, daily, gauge, headroom, checkmark, percent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forecast: "Forecast graph"
        case .ring: "Ring"
        case .ringHeadroom: "Ring + headroom"
        case .sessionWeekly: "Session | weekly"
        case .perAccount: "Per account"
        case .runway: "Mini runway"
        case .battery: "Battery"
        case .daily: "Day by day"
        case .gauge: "Pace gauge"
        case .headroom: "Headroom"
        case .checkmark: "Checkmark"
        case .percent: "Remaining %"
        }
    }

    var summary: String {
        switch self {
        case .forecast: "Projected quota left until the weekly reset. It steps down each day and jumps back up when an account resets; a heavy baseline means you'd be out."
        case .ring: "Weekly quota left across your accounts right now."
        case .ringHeadroom: "Weekly quota left, plus how much faster you could go and still never run out."
        case .sessionWeekly: "Left bar: the 5-hour session. Right bar: the weekly limit across your accounts."
        case .perAccount: "Weekly quota left on each account; the proxy falls back between them."
        case .runway: "Solid while you have quota, gaps where you'd be out, ticks where an account resets."
        case .battery: "Weekly quota left across your accounts. ↻ when an account resets within a day."
        case .daily: "Projected quota left at the end of each day until the reset. A hollow mark is a day you'd run out."
        case .gauge: "Your pace. The needle crosses the top into the dashed zone when you're going too fast to last."
        case .headroom: "How much faster you could go and still never run out. Under 1× means slow down."
        case .checkmark: "A ✓ while you'll last until every reset, otherwise when you run out."
        case .percent: "Quota left on the tightest limit of your best account."
        }
    }

    /// Styles that only make sense with a projection; they show remaining % until there is one.
    var needsRunway: Bool {
        switch self {
        case .forecast, .ringHeadroom, .runway, .daily, .gauge, .headroom, .checkmark: true
        case .ring, .sessionWeekly, .perAccount, .battery, .percent: false
        }
    }

    /// Styles whose reading is all text, so compact mode keeps it.
    var isTextOnly: Bool {
        switch self {
        case .headroom, .checkmark, .percent: true
        default: false
        }
    }

    /// With several providers, compact mode drops the text beside each graphic and narrows the wide ones.
    static let compactKey = "menuBarCompact"
}

/// Everything the menu bar shows for one provider, with its accounts pooled.
struct MenuBarItem: Identifiable {
    enum Tail {
        /// Every account is used up; the wait until one is back.
        case wait(String)
        /// When the pool is projected to run out.
        case runsOut(String)
    }

    let id: String
    let symbol: String
    let runway: Runway?
    let severity: Severity
    /// Weekly quota left across the pool right now (0–1).
    let weeklyLeft: Double
    /// Session quota left across the pool (0–1); used-up accounts count as empty.
    let sessionLeft: Double?
    /// Weekly quota left per account (0–1).
    let accountsLeft: [Double]
    /// An account's weekly limit resets within a day.
    let resetSoon: Bool
    let tail: Tail?
    let remaining: String
}

extension AccountUsage {
    /// Share left (0–1) of the tightest primary limit that is (or isn't) a long, weekly-style window.
    func left(long: Bool) -> Double? {
        snapshot.windows
            .filter { $0.isPrimary && (($0.windowLength ?? 0) >= 86_400) == long }
            .map { max(0, 100 - $0.usedPercent) / 100 }
            .min()
    }
}

extension UsageStore {
    func menuBarItems(now: Date) -> [MenuBarItem] {
        QuotaProviders.all.compactMap { provider in
            let pool = accounts.filter { $0.providerID == provider.id }
            guard !pool.isEmpty else { return nil }
            let runway = runways.first { $0.providerID == provider.id }
            let blocked = pool.allSatisfy(\.isBlocked)

            let accountsLeft = pool.map { $0.left(long: true) ?? ($0.remainingPercent ?? 0) / 100 }
            let sessions = pool.compactMap { $0.isBlocked ? 0 : $0.left(long: false) }
            let best = pool.filter { !$0.isBlocked }.compactMap(\.remainingPercent).max()

            var tail: MenuBarItem.Tail?
            if blocked {
                let until = pool.compactMap(\.blockedUntil).min()
                tail = .wait(until.map { $0 > now ? ResetFormatter.duration($0.timeIntervalSince(now)).replacingOccurrences(of: " ", with: "") : "…" } ?? "…")
            } else if let runsOut = runway?.runsOutAt {
                tail = .runsOut(ResetFormatter.short(runsOut, now: now))
            }

            let severity: Severity
            if blocked {
                severity = .critical
            } else if let runsOut = runway?.runsOutAt {
                severity = runsOut.timeIntervalSince(now) < 86_400 ? .critical : .warning
            } else if let runway {
                severity = (runway.headroom ?? 2) < 1.1 ? .warning : .ok
            } else {
                severity = Severity(remaining: best ?? 0, projection: nil)
            }

            return MenuBarItem(
                id: provider.id,
                symbol: provider.symbol,
                runway: runway,
                severity: severity,
                weeklyLeft: runway?.forecast.first ?? accountsLeft.reduce(0, +) / Double(accountsLeft.count),
                sessionLeft: sessions.isEmpty ? nil : sessions.reduce(0, +) / Double(sessions.count),
                accountsLeft: accountsLeft,
                resetSoon: runway?.resets.contains { $0.timeIntervalSince(now) < 86_400 } ?? false,
                tail: tail,
                remaining: best.map { "\(Int($0.rounded(.down)))%" } ?? "–"
            )
        }
    }
}

// MARK: - Item view

/// One provider in a given style. `foreground` is the menu bar's text color; with `colored`
/// the graphic takes the severity color, otherwise everything is drawn in `foreground`.
/// `compact` keeps only the graphic (and an hourglass while used up) to save room for other providers.
struct MenuBarItemView: View {
    let item: MenuBarItem
    let style: MenuBarStyle
    let colored: Bool
    let foreground: Color
    var compact = false

    private var ink: GlyphInk {
        GlyphInk(base: foreground, accent: colored ? item.severity.color : foreground, alert: colored ? Severity.critical.color : foreground)
    }

    /// Styles that need a projection fall back to remaining % until there is one.
    private var fallback: Bool { style.needsRunway && item.runway == nil }

    /// Compact mode only applies where a graphic still carries the reading without its text.
    private var graphicOnly: Bool { compact && !fallback && !style.isTextOnly }

    var body: some View {
        HStack(spacing: 3) {
            if !fallback && (style == .ring || style == .ringHeadroom) {
                RingGlyph(fraction: item.weeklyLeft, symbol: item.symbol, ink: ink)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 1)
            } else if case .wait = item.tail, style == .percent {
                // The original style: just the hourglass and countdown while everything is used up.
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .bold))
            }
            if !fallback {
                graphic
            }
            trailing
        }
        .foregroundStyle(foreground)
    }

    @ViewBuilder
    private var graphic: some View {
        switch style {
        case .forecast:
            if let runway = item.runway {
                ForecastGraph(runway: runway, ink: ink).frame(width: compact ? 24 : 36, height: 15).padding(.leading, 1)
            }
        case .sessionWeekly:
            LevelBars(values: [item.sessionLeft ?? 0, item.weeklyLeft], ink: ink)
        case .perAccount:
            LevelBars(values: item.accountsLeft, ink: ink)
        case .runway:
            if let runway = item.runway {
                MiniRunway(runway: runway, ink: ink).frame(width: compact ? 20 : 30, height: 15).padding(.leading, 1)
            }
        case .battery:
            BatteryGlyph(fraction: item.weeklyLeft, resetSoon: item.resetSoon, ink: ink).frame(width: 27, height: 15)
        case .daily:
            if let runway = item.runway {
                DailyBars(runway: runway, ink: ink, barWidth: compact ? 2.5 : 3.5)
            }
        case .gauge:
            PaceGauge(headroom: item.runway?.headroom, ink: ink).frame(width: 20, height: 15)
        case .ring, .ringHeadroom, .headroom, .checkmark, .percent:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if graphicOnly {
            if case .wait = item.tail {
                Image(systemName: "hourglass").font(.system(size: 11, weight: .bold))
            }
        } else {
            fullTrailing
        }
    }

    @ViewBuilder
    private var fullTrailing: some View {
        switch item.tail {
        case .wait(let countdown):
            Image(systemName: "hourglass").font(.system(size: 11, weight: .bold))
            label(countdown)
        case .runsOut(let when) where style != .percent:
            label(when)
        default:
            if fallback || style == .percent {
                label(item.remaining)
            } else if style == .ringHeadroom || style == .headroom {
                label(Self.headroom(item.runway?.headroom))
            } else if style == .checkmark {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium).monospacedDigit())
    }

    static func headroom(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value >= 8 ? "8×+" : "\(value.formatted(.number.precision(.fractionLength(1))))×"
    }
}

/// Colors for a glyph: `base` for outlines and tracks, `accent` for the value, `alert` for outages.
struct GlyphInk {
    let base: Color
    let accent: Color
    let alert: Color
    var track: Color { base.opacity(0.3) }
}

// MARK: - Glyphs

struct RingGlyph: View {
    let fraction: Double
    let symbol: String
    let ink: GlyphInk

    var body: some View {
        ZStack {
            Circle().inset(by: 1).stroke(ink.track, lineWidth: 2)
            Circle().inset(by: 1)
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(ink.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol).font(.system(size: 6.5, weight: .heavy))
        }
    }
}

/// Vertical level meters, bottom-aligned like signal bars.
struct LevelBars: View {
    let values: [Double]
    let ink: GlyphInk

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values.indices, id: \.self) { index in
                let value = min(max(values[index], 0), 1)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.2).fill(ink.track)
                    if value > 0 {
                        RoundedRectangle(cornerRadius: 1.2).fill(ink.accent).frame(height: max(15 * value, 1.5))
                    }
                }
                .frame(width: 3.5, height: 15)
            }
        }
    }
}

/// Projected pooled quota from now to the last weekly reset: it steps down through each day,
/// jumps when an account resets, and a heavy baseline marks outages.
struct ForecastGraph: View {
    let runway: Runway
    let ink: GlyphInk

    var body: some View {
        Canvas { context, size in
            let values = runway.forecast
            let baseline = size.height - 0.75
            // Keep low numbers readable rather than squashed against a 100% ceiling.
            let ceiling = max(0.6, values.max() ?? 0)
            let x = { (fraction: Double) in size.width * fraction }
            let y = { (value: Double) in baseline - (baseline - 1) * min(value / ceiling, 1) }

            context.fill(Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)), with: .color(ink.track))
            if values.count > 1 {
                var line = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: x(Double(index) / Double(values.count - 1)), y: y(value))
                    index == 0 ? line.move(to: point) : line.addLine(to: point)
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: baseline))
                area.addLine(to: CGPoint(x: 0, y: baseline))
                area.closeSubpath()
                context.fill(area, with: .color(ink.accent.opacity(0.35)))
                context.stroke(line, with: .color(ink.accent), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }

            for outage in runway.outages {
                let start = x(runway.fraction(of: outage.interval.start))
                let end = x(runway.fraction(of: outage.interval.end))
                var mark = Path()
                mark.move(to: CGPoint(x: start, y: baseline + 0.5))
                mark.addLine(to: CGPoint(x: max(end, start + 1), y: baseline + 0.5))
                context.stroke(mark, with: .color(ink.alert), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
    }
}

/// The panel's runway timeline, shrunk to the menu bar.
struct MiniRunway: View {
    let runway: Runway
    let ink: GlyphInk

    var body: some View {
        Canvas { context, size in
            let bar = CGRect(x: 0, y: (size.height - 5) / 2, width: size.width, height: 5)
            context.fill(Path(roundedRect: bar, cornerRadius: 2.5), with: .color(ink.track))
            for segment in runway.availableIntervals {
                let start = size.width * runway.fraction(of: segment.start)
                let end = size.width * runway.fraction(of: segment.end)
                let rect = CGRect(x: start, y: bar.minY, width: max(end - start, 1), height: bar.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(ink.accent))
            }
            for reset in runway.resets {
                let x = size.width * runway.fraction(of: reset)
                context.fill(Path(roundedRect: CGRect(x: x - 0.75, y: bar.minY - 2.5, width: 1.5, height: 10), cornerRadius: 0.75), with: .color(ink.base))
            }
        }
    }
}

struct BatteryGlyph: View {
    let fraction: Double
    let resetSoon: Bool
    let ink: GlyphInk

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(ink.base.opacity(0.5), lineWidth: 1.3)
                RoundedRectangle(cornerRadius: 1.6)
                    .fill(ink.accent)
                    .frame(width: max(18.5 * min(max(fraction, 0), 1), fraction > 0 ? 1.5 : 0))
                    .padding(1.75)
                if resetSoon {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 6.5, weight: .heavy))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 23, height: 11)
            RoundedRectangle(cornerRadius: 0.8).fill(ink.base.opacity(0.5)).frame(width: 1.6, height: 4)
        }
    }
}

/// One bar per day until the reset: projected quota left at the end of that day.
struct DailyBars: View {
    let runway: Runway
    let ink: GlyphInk
    var barWidth = 3.5

    private var values: [Double] {
        let calendar = Calendar.current
        var ends: [Date] = []
        var day = calendar.startOfDay(for: runway.start)
        while let next = calendar.date(byAdding: .day, value: 1, to: day), next < runway.horizon {
            ends.append(next)
            day = next
        }
        ends.append(runway.horizon)
        return ends.map(runway.forecastValue(at:))
    }

    var body: some View {
        let values = values
        let ceiling = max(0.5, values.max() ?? 0)
        HStack(alignment: .bottom, spacing: barWidth < 3 ? 1 : 1.5) {
            ForEach(values.indices, id: \.self) { index in
                if values[index] > 0.005 {
                    RoundedRectangle(cornerRadius: 1).fill(ink.accent)
                        .frame(width: barWidth, height: max(15 * values[index] / ceiling, 1.5))
                } else {
                    RoundedRectangle(cornerRadius: 0.6).stroke(ink.alert, lineWidth: 1)
                        .frame(width: 2.5, height: 2.5)
                        .frame(width: barWidth)
                }
            }
        }
        .frame(height: 15, alignment: .bottom)
    }
}

/// Speedometer for your pace relative to what lasts: the top mark is exactly sustainable.
struct PaceGauge: View {
    let headroom: Double?
    let ink: GlyphInk

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width / 2, size.height) - 1
            let center = CGPoint(x: size.width / 2, y: size.height - 1)
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(ink.track), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            var danger = Path()
            danger.addArc(center: center, radius: radius, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
            context.stroke(danger, with: .color(ink.alert.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1.5, 2]))

            // Pace as a share of what lasts: 1 points straight up, 2 or more fully right.
            let pace = headroom.map { min(1 / max($0, 0.01), 2) } ?? 0
            let angle = Double.pi - pace / 2 * .pi
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + (radius - 2) * cos(angle), y: center.y - (radius - 2) * sin(angle)))
            context.stroke(needle, with: .color(ink.accent), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)), with: .color(ink.base))
        }
    }
}

extension Runway {
    /// Position of `date` between `start` (0) and `horizon` (1).
    func fraction(of date: Date) -> Double {
        let span = horizon.timeIntervalSince(start)
        return span > 0 ? min(max(date.timeIntervalSince(start) / span, 0), 1) : 0
    }

    func forecastValue(at date: Date) -> Double {
        guard !forecast.isEmpty else { return 0 }
        return forecast[Int((fraction(of: date) * Double(forecast.count - 1)).rounded())]
    }

    /// The stretches between outages.
    var availableIntervals: [DateInterval] {
        var segments: [DateInterval] = []
        var cursor = start
        for outage in outages {
            if outage.interval.start > cursor { segments.append(DateInterval(start: cursor, end: outage.interval.start)) }
            cursor = max(cursor, outage.interval.end)
        }
        if horizon > cursor { segments.append(DateInterval(start: cursor, end: horizon)) }
        return segments
    }
}
