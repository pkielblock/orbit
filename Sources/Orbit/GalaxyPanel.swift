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
    @Published var panelSize = NSSize(width: 340, height: 600)
    @Published var showingConnections = false
}

private enum Galaxy {
    // T3 Black neutrals; provider accents stay as data color on logos and bars.
    static let ink = Color.black
    static let surface = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let line = Color.white.opacity(0.07)
    static let muted = Color.white.opacity(0.5)
    static func accent(_ provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 1, green: 0.64, blue: 0.46)
        case .codex: return Color(red: 0.48, green: 0.88, blue: 0.79)
        case .antigravity: return Color(red: 0.69, green: 0.59, blue: 1)
        }
    }
}

struct GalaxyPanel: View {
    static let width: CGFloat = 340
    @ObservedObject var model: GalaxyModel
    @ObservedObject var updater = AppUpdater()
    let refresh: () -> Void
    var resize: (PanelScale) -> Void = { _ in }
    var measuring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scale: CGFloat { measuring ? 1 : model.panelSize.width / Self.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
        .padding(14)
        .frame(width: Self.width, height: measuring ? nil : model.panelSize.height / scale, alignment: .top)
        .fixedSize(horizontal: false, vertical: measuring)
        .background(Galaxy.ink)
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
        VStack(spacing: 8) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.offset) { index, provider in
                ProviderCard(provider: provider, usage: model.usage[provider], active: !measuring && model.visible && !reduceMotion,
                             connect: { model.showingConnections = true })
                    .opacity(measuring || model.visible || !model.usage.isEmpty ? 1 : 0)
                    .offset(y: measuring || model.visible || !model.usage.isEmpty ? 0 : 6)
                    .animation(reduceMotion || measuring ? nil : .easeOut(duration: 0.25).delay(Double(index) * 0.05), value: model.visible)
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
        HStack(spacing: 7) {
            Image(nsImage: StatusIcon.image()).resizable().frame(width: 14, height: 14)
                .foregroundStyle(Galaxy.muted).accessibilityHidden(true)
            Text("Orbit").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Galaxy.surface, in: Circle())
                    .overlay(Circle().stroke(Galaxy.line))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(model.refreshing).opacity(model.refreshing ? 0.4 : 1)
            .keyboardShortcut("r")
            .help("Fetch the latest usage from all providers")
            .accessibilityLabel("Refresh")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.refreshing ? Color.orange : Color.green).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(updater.busy ? updater.message
                 : model.refreshing ? "Refreshing…"
                 : model.refreshedAt.map { "Updated \(Format.clockTime($0))" } ?? "Waiting for first update")
                .lineLimit(1).truncationMode(.middle)
            if let release = updater.release, !updater.busy {
                Button("Update to \(release.version)") { updater.install() }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .help("Downloads, installs and restarts Orbit")
            }
            Spacer()
            Menu {
                Text(updater.message)
                Button(updater.release == nil ? "Check for updates" : "Update & restart") {
                    if updater.release == nil { updater.checkIfDue(force: true) }
                    else { updater.install() }
                }
                .disabled(updater.busy)
                Divider()
                Picker("Size", selection: Binding(get: { model.panelScale }, set: { resize($0) })) {
                    ForEach(PanelScale.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Connect providers…") { model.showingConnections = true }
                Button("Privacy") {
                    if let url = Bundle.main.url(forResource: "Privacy", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.open(URL(string: "https://github.com/pkielblock/orbit/blob/main/Resources/Privacy.txt")!)
                    }
                }
                Divider()
                Button("Quit Orbit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(.system(size: 10)).foregroundStyle(Galaxy.muted)
        .padding(.horizontal, 2)
        // Menu items don't own shortcuts while closed, so Command-Q needs a live (invisible) button.
        .background(Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q").opacity(0).accessibilityHidden(true))
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let usage: ProviderUsage?
    let active: Bool
    var connect: () -> Void = {}
    private var accent: Color { Galaxy.accent(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(nsImage: Logos.image(for: provider, height: 14))
                    .resizable().frame(width: 14, height: 14).foregroundStyle(accent)
                    .accessibilityHidden(true)
                Link(destination: provider.dashboardURL) {
                    HStack(spacing: 3) {
                        Text(provider.name).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Galaxy.muted)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(provider.name) dashboard in your browser")
                .accessibilityLabel("Open \(provider.name) dashboard in your browser")
                Spacer()
                if usage == nil {
                    Text("Connecting…").font(.system(size: 10)).foregroundStyle(Galaxy.muted)
                } else if usage?.error != nil {
                    Text("Check connection").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.orange)
                }
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Galaxy.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Galaxy.line))
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
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(.system(size: 10, weight: .medium))
                Text(percent == nil ? "not reported" : Format.reset(window?.resetsAt))
                    .font(.system(size: 9)).foregroundStyle(Galaxy.muted).lineLimit(1)
                Spacer()
                if (percent ?? 0) >= 90 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(tint)
                        .help("Near limit")
                }
                Text(Format.percent(percent)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle((percent ?? 0) >= 70 ? tint : .white)
            }
            OrbitBar(fraction: fraction, tint: tint, active: active)
                .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(Format.percent(percent)) used, \(Format.reset(window?.resetsAt))\((percent ?? 0) >= 90 ? ", near limit" : "")")
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
                let track = CGRect(x: 0, y: 3, width: size.width, height: 4)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.white.opacity(0.08)))
                if width > 0 {
                    let fill = Path(roundedRect: CGRect(x: 0, y: 3, width: width, height: 4), cornerRadius: 2)
                    context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.55), tint]), startPoint: .zero, endPoint: CGPoint(x: width, y: 0)))
                }
                let elapsed = timeline.date.timeIntervalSince(began)
                if active && end > start && elapsed >= 0 && elapsed < duration {
                    var rocket = context
                    rocket.opacity = min(1, (duration - elapsed) / 0.2)
                    rocket.translateBy(x: min(max(width, 10), size.width - 10), y: 5)
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
