import AppKit
import SwiftUI

/// Sideline's S/M/L/XL scale. Raw values are the stored "panelSize" preference, so older choices still load.
enum PanelScale: String, CaseIterable {
    case small, normal, larger, largest

    var title: String {
        switch self {
        case .small: return "S"
        case .normal: return "M"
        case .larger: return "L"
        case .largest: return "XL"
        }
    }
    var factor: CGFloat {
        switch self {
        case .small: return 0.85
        case .normal: return 1
        case .larger: return 1.15
        case .largest: return 1.3
        }
    }
    /// One step larger or smaller (Command-= / Command-minus), clamped at the ends.
    func stepped(_ by: Int) -> PanelScale {
        let all = Self.allCases
        return all[min(max(all.firstIndex(of: self)! + by, 0), all.count - 1)]
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
    @Published var showingSettings = false
    /// Sideline's Blur and Darkness pair: how opaque the popover blur is, and how dark the tint over it.
    /// Blur falls back to the old Transparency setting, inverted.
    @Published var blur = UserDefaults.standard.object(forKey: "blur") as? Double
        ?? (UserDefaults.standard.object(forKey: "panelTransparency") as? Double).map { 1 - $0 } ?? 1 {
        didSet { UserDefaults.standard.set(blur, forKey: "blur") }
    }
    @Published var darkness = min(UserDefaults.standard.object(forKey: "darkness") as? Double ?? 0, 0.9) {
        didSet { UserDefaults.standard.set(darkness, forKey: "darkness") }
    }
    /// "system", "en" or "pt-BR". macOS reads AppleLanguages at launch, so changing it restarts the app (as in Sideline).
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "system" {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language, forKey: "language")
            if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([language], forKey: "AppleLanguages") }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
}

enum Galaxy {
    // Sideline's look: native popover material, faint cards, T3 accent for app state.
    static let accent = Color(red: 0x34 / 255, green: 0x6b / 255, blue: 0xf1 / 255) // #346bf1
    /// Accent as text: #346bf1 is under 4.5:1 on the dark cards, this tint is ~7:1.
    static let accentText = Color(red: 0x7d / 255, green: 0xa1 / 255, blue: 0xfa / 255) // #7da1fa
    static let card = Color.white.opacity(0.04)
    /// Bars stay grey until a quota nears its limit, so warnings are the only color in the meters.
    static let bar = Color.white.opacity(0.7)
    static func accent(_ provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 1, green: 0.64, blue: 0.46)
        case .codex: return Color(red: 0.48, green: 0.88, blue: 0.79)
        case .antigravity: return Color(red: 0.69, green: 0.59, blue: 1)
        }
    }
}

struct GalaxyPanel: View {
    static let width: CGFloat = 460
    @ObservedObject var model: GalaxyModel
    @ObservedObject var updater = AppUpdater()
    let refresh: () -> Void
    var resize: (PanelScale) -> Void = { _ in }
    var measuring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scale: CGFloat { measuring ? 1 : model.panelSize.width / Self.width }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if measuring {
                cards
            } else if model.showingSettings {
                settingsView.transition(screen)
            } else {
                ViewThatFits(in: .vertical) {
                    cards.fixedSize(horizontal: false, vertical: true)
                    // The overlay scroll bar's lane, clear of the percentages.
                    ScrollView { cards.padding(.trailing, 12) }
                }
                .transition(screen)
            }
        }
        .animation(reduceMotion || measuring ? nil : .easeOut(duration: 0.2), value: model.showingSettings)
        .padding(16)
        .frame(width: Self.width, height: measuring ? nil : model.panelSize.height / scale, alignment: .top)
        .fixedSize(horizontal: false, vertical: measuring)
        .scaleEffect(scale)
        .frame(width: measuring ? Self.width : model.panelSize.width,
               height: measuring ? nil : model.panelSize.height)
        .background(Color.black.opacity(model.darkness))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingConnections) {
            ProviderConnections(model: model, refresh: refresh)
        }
    }

    private var screen: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)) }

    private var status: String {
        if updater.busy { return updater.message }
        if model.refreshing { return String(localized: "Refreshing…") }
        return model.refreshedAt.map { String(localized: "Updated \(Format.clockTime($0))") } ?? String(localized: "Waiting for first update")
    }

    private var cards: some View {
        VStack(spacing: 16) {
            ForEach(Array(Provider.allCases.enumerated()), id: \.offset) { index, provider in
                ProviderCard(provider: provider, usage: model.usage[provider], active: !measuring && model.visible && !reduceMotion,
                             connect: { model.showingConnections = true })
                    .opacity(measuring || model.visible || !model.usage.isEmpty ? 1 : 0)
                    .offset(y: measuring || model.visible || !model.usage.isEmpty ? 0 : 4)
                    .animation(reduceMotion || measuring ? nil : .easeOut(duration: 0.2).delay(Double(index) * 0.05), value: model.visible)
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
        HStack(spacing: 8) {
            Circle().fill(model.refreshing ? Color.orange : Color.green).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(status)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            // Sideline's PillBar: icon buttons in one faint capsule.
            HStack(spacing: 2) {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 26).contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(model.refreshing).opacity(model.refreshing ? 0.4 : 1)
                .keyboardShortcut("r")
                .help("Fetch the latest usage from all providers")
                .accessibilityLabel("Refresh")
                settings
            }
            .foregroundStyle(.secondary)
            .padding(4)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(alignment: .topTrailing) {
                if updater.release != nil && !updater.busy {
                    Circle().fill(Galaxy.accent).frame(width: 8, height: 8).accessibilityLabel("Update available")
                }
            }
        }
        // Menu items don't own shortcuts while closed, so Command-Q and the size keys need live (invisible) buttons.
        .background {
            Group {
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
                Button("Larger") { resize(model.panelScale.stepped(1)) }.keyboardShortcut("=")
                Button("Smaller") { resize(model.panelScale.stepped(-1)) }.keyboardShortcut("-")
            }
            .opacity(0).accessibilityHidden(true)
        }
    }

    // Sideline's gear is a tab, not a dropdown: a menu can't hold a slider.
    private var settings: some View {
        Button { model.showingSettings.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(model.showingSettings ? Color.white : .secondary)
                .background { if model.showingSettings { Capsule().fill(Galaxy.accent) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",")
        .help("Settings")
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(model.showingSettings ? .isSelected : [])
    }

    // Sideline's settings: a native grouped form on the panel's glass.
    private var settingsView: some View {
        Form {
            Section("Display") {
                Picker("Language", selection: $model.language) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Português (Brasil)").tag("pt-BR")
                }
                .help("Orbit restarts to change the language")
                Picker("Size", selection: Binding(get: { model.panelScale }, set: { resize($0) })) {
                    ForEach(PanelScale.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Command-= and Command-minus also change the size")
                Slider(value: $model.blur, in: 0...1) { Text("Blur") }
                Slider(value: $model.darkness, in: 0...0.9) { Text("Darkness") }
            }
            Section("Providers") {
                HStack {
                    Text("Sign-in for Claude, Codex and Antigravity").foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect") { model.showingConnections = true }
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                HStack {
                    Text(updater.message).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let release = updater.release {
                        Button("Update to \(release.version)") { updater.install() }.disabled(updater.busy)
                    } else {
                        Button("Check for updates") { updater.checkIfDue(force: true) }.disabled(updater.busy)
                    }
                }
                HStack {
                    Text("What Orbit reads and sends").foregroundStyle(.secondary)
                    Spacer()
                    Button("Privacy") {
                        if let url = Bundle.main.url(forResource: "Privacy", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        } else {
                            NSWorkspace.shared.open(URL(string: "https://github.com/pkielblock/orbit/blob/main/Resources/Privacy.txt")!)
                        }
                    }
                }
            }
            Button("Quit Orbit") { NSApp.terminate(nil) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(.system(size: 13))
        .padding(.horizontal, -16) // the form brings its own insets
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let usage: ProviderUsage?
    let active: Bool
    var connect: () -> Void = {}
    private var accent: Color { Galaxy.accent(provider) }

    var body: some View {
        // Sideline layout: a bold section title, then the content in a faint card.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: Logos.image(for: provider, height: 18))
                    .resizable().frame(width: 18, height: 18).foregroundStyle(accent)
                    .accessibilityHidden(true)
                Link(destination: provider.dashboardURL) {
                    HStack(spacing: 4) {
                        Text(provider.name).font(.system(size: 15, weight: .medium))
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(provider.name) dashboard in your browser")
                .accessibilityLabel("Open \(provider.name) dashboard in your browser")
                Spacer()
                if usage == nil {
                    Text("Connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if usage?.error != nil {
                    Text("Check connection").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.orange)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                UsageMeter(title: String(localized: "Session"), window: usage?.session, active: active)
                UsageMeter(title: String(localized: "Weekly"), window: usage?.weekly, active: active)
                if let error = usage?.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(Color.orange)
                        .lineLimit(1).truncationMode(.middle).help(error)
                        .accessibilityLabel("Provider error: \(error). Displayed quotas may be stale.")
                }
                if usage?.needsConnection == true {
                    Button("Connect \(provider.name)", action: connect)
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                        .foregroundStyle(accent)
                } else if usage?.error != nil, let date = usage?.updatedAt {
                    Text("Quota from \(Format.clockTime(date))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct UsageMeter: View {
    let title: String
    let window: UsageWindow?
    let active: Bool
    private var percent: Double? { window?.usedPercent.flatMap { $0.isFinite ? $0 : nil } }
    private var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }
    private var tint: Color { (percent ?? 0) >= 90 ? .red : (percent ?? 0) >= 70 ? .orange : Galaxy.bar }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(percent == nil ? String(localized: "not reported") : Format.reset(window?.resetsAt))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if (percent ?? 0) >= 90 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(tint)
                        .help("Near limit")
                }
                Text(Format.percent(percent)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle((percent ?? 0) >= 70 ? tint : .white)
                    .contentTransition(.numericText())
                    .animation(active ? .spring(response: 0.4, dampingFraction: 0.85) : nil, value: percent)
            }
            OrbitBar(fraction: fraction, tint: tint, active: active)
                .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title), \(Format.percent(percent)) used, \(Format.reset(window?.resetsAt))")
                            + ((percent ?? 0) >= 90 ? String(localized: ", near limit") : ""))
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
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.white.opacity(0.08)))
                if width > 0 {
                    let fill = Path(roundedRect: CGRect(x: 0, y: 4, width: width, height: 4), cornerRadius: 2)
                    context.fill(fill, with: .color(tint))
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
