import AppKit
import SwiftUI

enum PanelScale: String, CaseIterable {
    case normal, larger, largest

    var title: String { rawValue.capitalized }
    var factor: CGFloat {
        switch self {
        case .normal: return 1
        case .larger: return 1.15
        case .largest: return 1.3
        }
    }
}

@MainActor
final class GalaxyModel: ObservableObject {
    @Published var usage: [Provider: ProviderUsage] = [:]
    @Published var refreshing = false
    @Published var refreshedAt: Date?
    @Published var visible = false
    @Published var panelScale = PanelScale(rawValue: UserDefaults.standard.string(forKey: "panelSize") ?? "") ?? .normal
    @Published var panelSize = NSSize(width: 380, height: 700)
    @Published var showingConnections = false
}

private enum Galaxy {
    static let ink = Color.black
    static let muted = Color(red: 0.66, green: 0.69, blue: 0.79)
    static func accent(_ provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 1, green: 0.64, blue: 0.46)
        case .codex: return Color(red: 0.48, green: 0.88, blue: 0.79)
        case .antigravity: return Color(red: 0.69, green: 0.59, blue: 1)
        }
    }
}

struct GalaxyPanel: View {
    static let width: CGFloat = 380
    @ObservedObject var model: GalaxyModel
    @ObservedObject var updater = AppUpdater()
    let refresh: () -> Void
    var resize: (PanelScale) -> Void = { _ in }
    var measuring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scale: CGFloat { measuring ? 1 : model.panelSize.width / Self.width }

    var body: some View {
        ZStack {
            Galaxy.ink
            Starfield(active: !measuring && model.visible && !reduceMotion)
            VStack(alignment: .leading, spacing: 12) {
                header
                HStack(spacing: 6) {
                    Circle().fill(model.refreshing ? Color.orange : Color.mint).frame(width: 5, height: 5)
                    Text(model.refreshing ? "SYNCING YOUR UNIVERSE" : "YOUR USAGE, IN ORBIT")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.7)
                        .foregroundStyle(Galaxy.muted)
                    Spacer()
                    Text("3 PROVIDERS").font(.system(size: 9, weight: .medium)).foregroundStyle(Galaxy.muted)
                }
                if measuring {
                    cards
                } else {
                    ViewThatFits(in: .vertical) {
                        cards.fixedSize(horizontal: false, vertical: true)
                        ScrollView(showsIndicators: false) { cards }
                    }
                }
                footer
            }
            .padding(22)
        }
        .frame(width: Self.width, height: measuring ? nil : model.panelSize.height / scale)
        .fixedSize(horizontal: false, vertical: measuring)
        .scaleEffect(scale)
        .frame(width: measuring ? Self.width : model.panelSize.width,
               height: measuring ? nil : model.panelSize.height)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingConnections) {
            ProviderConnections(model: model, refresh: refresh)
        }
    }

    private var cards: some View {
        VStack(spacing: 12) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.offset) { index, provider in
                ProviderCard(provider: provider, usage: model.usage[provider], active: !measuring && model.visible && !reduceMotion,
                             connect: { model.showingConnections = true })
                    .opacity(measuring || model.visible || !model.usage.isEmpty ? 1 : 0)
                    .offset(y: measuring || model.visible || !model.usage.isEmpty ? 0 : 8)
                    .animation(reduceMotion || measuring ? nil : .easeOut(duration: 0.35).delay(Double(index) * 0.06), value: model.visible)
            }
        }
        .padding(1)
    }

    static func fittedSize(model: GalaxyModel, available: NSSize) -> NSSize {
        let view = NSHostingView(rootView: GalaxyPanel(model: model, refresh: {}, measuring: true))
        let naturalHeight = ceil(view.fittingSize.height)
        let scale = min(model.panelScale.factor, available.width / width)
        return NSSize(width: width * scale, height: min(ceil(naturalHeight * scale), available.height))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Orbit").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text("A little space for your limits.").font(.system(size: 11)).foregroundStyle(Galaxy.muted)
            }
            Spacer()
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 1).frame(width: 48, height: 48)
                Ellipse().stroke(Color.purple.opacity(0.7), lineWidth: 1).frame(width: 58, height: 20).rotationEffect(.degrees(-35))
                Image(systemName: "sparkles").font(.system(size: 21)).foregroundStyle(Color(red: 0.8, green: 0.72, blue: 1))
            }
            .accessibilityHidden(true)
        }.padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                Text(updater.message).font(.system(size: 9)).foregroundStyle(Galaxy.muted)
                    .lineLimit(2).help(updater.message)
                Spacer()
                Button(updater.release == nil ? "Check for updates" : "Update & restart") {
                    if updater.release == nil { updater.checkIfDue(force: true) }
                    else { updater.install() }
                }
                .font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                .disabled(updater.busy)
                .help("Checks the private GitHub repository; updates download, install and restart Orbit")
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.refreshing ? "Refreshing…" : model.refreshedAt.map { "Updated \(Format.clockTime($0))" } ?? "Waiting for first update")
                        .font(.system(size: 10, weight: .medium))
                    Text("Auto-refresh every 5 minutes").font(.system(size: 9)).foregroundStyle(Galaxy.muted)
                }
                Spacer()
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain).disabled(model.refreshing).keyboardShortcut("r")
                .help("Fetch the latest usage from all providers")
            }
            HStack {
                Menu {
                    ForEach(PanelScale.allCases, id: \.self) { size in
                        Button {
                            resize(size)
                        } label: {
                            if size == model.panelScale {
                                Label(size.title, systemImage: "checkmark")
                            } else {
                                Text(size.title)
                            }
                        }
                    }
                } label: {
                    Label("Size", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change the dashboard size")
                Spacer()
                Text("LOCAL APP · NO ANALYTICS").font(.system(size: 8)).tracking(1)
            }
            .font(.system(size: 9)).foregroundStyle(Galaxy.muted)
            HStack {
                Button("Connect providers") { model.showingConnections = true }
                Spacer()
                Button("Privacy") {
                    if let url = Bundle.main.url(forResource: "Privacy", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.open(URL(string: "https://github.com/pkielblock/orbit/blob/main/Resources/Privacy.txt")!)
                    }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .font(.system(size: 9)).foregroundStyle(Galaxy.muted).buttonStyle(.plain)
        }
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let usage: ProviderUsage?
    let active: Bool
    var connect: () -> Void = {}
    private var accent: Color { Galaxy.accent(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(nsImage: Logos.image(for: provider, height: 18))
                    .resizable().frame(width: 18, height: 18).foregroundStyle(accent)
                    .padding(7).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Link(destination: provider.dashboardURL) {
                    HStack(spacing: 4) {
                        Text(provider.name).font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(provider.name) dashboard in your browser")
                .accessibilityLabel("Open \(provider.name) dashboard in your browser")
                Spacer()
                Text(usage == nil ? "CONNECTING" : usage?.error != nil ? "CHECK CONNECTION" : "CONNECTED")
                    .font(.system(size: 8, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(usage?.error != nil ? Color.orange : accent)
            }
            UsageMeter(title: "Session", window: usage?.session, accent: accent, active: active)
            UsageMeter(title: "Weekly", window: usage?.weekly, accent: accent, active: active)
            if let error = usage?.error {
                Text(error).font(.system(size: 9)).foregroundStyle(Color.orange)
                    .lineLimit(1).truncationMode(.middle).help(error)
                    .accessibilityLabel("Provider error: \(error). Displayed quotas may be stale.")
            }
            if usage?.needsConnection == true {
                Button("Connect \(provider.name)", action: connect)
                    .font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                    .foregroundStyle(accent)
            } else if usage?.error != nil, let date = usage?.updatedAt {
                Text("Last quota: \(Format.clockTime(date))")
                    .font(.system(size: 9)).foregroundStyle(Galaxy.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.025, green: 0.03, blue: 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [accent.opacity(0.3), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

private struct UsageMeter: View {
    let title: String
    let window: UsageWindow?
    let accent: Color
    let active: Bool
    private var percent: Double? { window?.usedPercent.flatMap { $0.isFinite ? $0 : nil } }
    private var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }
    private var tint: Color { (percent ?? 0) >= 90 ? .red : (percent ?? 0) >= 70 ? .orange : accent }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Galaxy.muted)
                Spacer()
                Text(Format.percent(percent)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text("used").font(.system(size: 9)).foregroundStyle(Galaxy.muted)
            }
            OrbitBar(fraction: fraction, tint: tint, active: active)
                .frame(height: 12)
            HStack {
                Text(percent == nil ? "Quota not reported" : Format.reset(window?.resetsAt))
                    .font(.system(size: 9)).foregroundStyle(Galaxy.muted)
                Spacer()
                if (percent ?? 0) >= 90 {
                    Text("Near limit").font(.system(size: 9, weight: .medium)).foregroundStyle(tint)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(Format.percent(percent)) used, \(Format.reset(window?.resetsAt))")
    }
}

/// Quota is accurate at rest; the highlight flows continuously without changing the value.
/// An increasing quota launches a rocket that follows the interpolated leading edge.
// Explicit wrapper alias also supports command-line SDKs without the new State macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct OrbitBar: View {
    let fraction: Double
    let tint: Color
    let active: Bool
    @ViewState private var origin = 0.0
    @ViewState private var destination = 0.0
    @ViewState private var launchedAt = Date.distantPast
    private let duration = 1.6

    private func displayed(at date: Date) -> Double {
        let progress = min(max(date.timeIntervalSince(launchedAt) / duration, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        return origin + (destination - origin) * eased
    }

    private func transition(to value: Double, from start: Double? = nil) {
        origin = start ?? displayed(at: Date())
        destination = value
        launchedAt = Date()
    }

    var body: some View {
        // Read state in the view body so Canvas captures the latest transition on first appearance.
        let start = origin
        let end = destination
        let began = launchedAt
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            Canvas { context, size in
                let progress = min(max(timeline.date.timeIntervalSince(began) / duration, 0), 1)
                let current = active ? start + (end - start) * progress * progress * (3 - 2 * progress) : fraction
                let width = size.width * current
                let track = CGRect(x: 0, y: 4, width: size.width, height: 4)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.white.opacity(0.09)))
                if width > 0 {
                    let fill = Path(roundedRect: CGRect(x: 0, y: 4, width: width, height: 4), cornerRadius: 2)
                    context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.55), tint]), startPoint: .zero, endPoint: CGPoint(x: width, y: 0)))
                    if active {
                        var sheen = context
                        sheen.clip(to: fill)
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                        let x = phase * (width + 60) - 30
                        sheen.fill(Path(CGRect(x: x - 24, y: 3, width: 48, height: 6)), with: .linearGradient(
                            Gradient(colors: [.clear, .white.opacity(0.7), .clear]),
                            startPoint: CGPoint(x: x - 24, y: 0), endPoint: CGPoint(x: x + 24, y: 0)))
                    }
                }
                let elapsed = timeline.date.timeIntervalSince(began)
                if active && end > start && elapsed >= 0 && elapsed < duration {
                    var rocket = context
                    rocket.opacity = min(1, (duration - elapsed) / 0.2)
                    rocket.translateBy(x: min(max(width, 10), size.width - 10), y: 6)
                    let flicker = 2 + sin(elapsed * 50) * 1.5
                    var flame = Path()
                    flame.move(to: CGPoint(x: -5, y: -2))
                    flame.addLine(to: CGPoint(x: -11 - flicker, y: 0))
                    flame.addLine(to: CGPoint(x: -5, y: 2))
                    flame.closeSubpath()
                    rocket.fill(flame, with: .color(.orange))
                    var body = Path()
                    body.move(to: CGPoint(x: 9, y: 0))
                    body.addQuadCurve(to: CGPoint(x: -5, y: -3), control: CGPoint(x: 3, y: -5))
                    body.addLine(to: CGPoint(x: -8, y: -6))
                    body.addLine(to: CGPoint(x: -7, y: 0))
                    body.addLine(to: CGPoint(x: -8, y: 6))
                    body.addLine(to: CGPoint(x: -5, y: 3))
                    body.addQuadCurve(to: CGPoint(x: 9, y: 0), control: CGPoint(x: 3, y: 5))
                    rocket.fill(body, with: .color(.white))
                    rocket.fill(Path(ellipseIn: CGRect(x: 0, y: -1.5, width: 3, height: 3)), with: .color(tint))
                }
            }
        }
        .onAppear { transition(to: fraction, from: active ? 0 : fraction) }
        .onChange(of: fraction) { value in transition(to: value) }
        .onChange(of: active) { visible in
            // Replay the entry flight on open; no offscreen animations or delayed tasks.
            transition(to: fraction, from: visible ? 0 : fraction)
        }
        .accessibilityHidden(true)
    }
}

/// Nebula clouds, spiral dust and stars move together only while the popover is visible.
private struct Starfield: View {
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            let time = active ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                for index in 0..<3 {
                    let phase = time * 0.14 + Double(index) * 2.1
                    let center = CGPoint(x: size.width * (0.5 + sin(phase) * 0.3), y: size.height * (0.35 + cos(phase * 0.8) * 0.25))
                    let radius = 180.0 + sin(phase) * 35
                    let color: Color = index == 0 ? .purple : index == 1 ? .blue : .pink
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .radialGradient(
                        Gradient(colors: [color.opacity(0.32), color.opacity(0.08), .clear]),
                        center: center, startRadius: 0, endRadius: radius))
                }
                // A slowly rotating spiral gives the nebula depth rather than a flat gradient.
                let center = CGPoint(x: size.width * 0.7, y: size.height * 0.3)
                for index in 0..<180 {
                    let distance = Double(index % 60) * 3
                    let angle = distance * 0.035 + Double(index / 60) * 2.094 + time * 0.045
                    let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance * 0.55)
                    context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 2, height: 2)), with: .color(Color.purple.opacity(0.18)))
                }
                for index in 0..<85 {
                    let speed = Double(index % 3 + 1)
                    let x = (Double((index * 73 + 19) % 379) / 379 * size.width + time * speed * 1.5).truncatingRemainder(dividingBy: size.width)
                    let y = (Double((index * 137 + 31) % 659) / 659 * size.height + time * speed * 0.5).truncatingRemainder(dividingBy: size.height)
                    let radius: Double = index % 7 == 0 ? 1.5 : 0.7
                    let opacity = 0.2 + (sin(time * 1.4 + Double(index)) + 1) * 0.25
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(opacity)))
                    if index % 17 == 0 {
                        var sparkle = Path()
                        sparkle.move(to: CGPoint(x: x + radius, y: y - 3))
                        sparkle.addLine(to: CGPoint(x: x + radius, y: y + 5))
                        sparkle.move(to: CGPoint(x: x - 3, y: y + radius))
                        sparkle.addLine(to: CGPoint(x: x + 5, y: y + radius))
                        context.stroke(sparkle, with: .color(.white.opacity(opacity * 0.5)), lineWidth: 0.6)
                    }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
