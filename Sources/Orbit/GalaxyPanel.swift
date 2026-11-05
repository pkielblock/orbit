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
    @Published var accounts = AccountStore.load()
    /// Keyed by account id. Results for a removed account are dropped before they get here.
    @Published var usage: [UUID: ProviderUsage] = [:]
    /// Per provider across its accounts; nil until the first scan ends.
    @Published var tokens: [Provider: ProviderTokens] = [:]
    @Published var selectedProvider = Provider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .claude
    @Published var refreshing = false
    @Published var refreshedAt: Date?
    @Published var visible = false
    @Published var panelScale = PanelScale(rawValue: UserDefaults.standard.string(forKey: "panelSize") ?? "") ?? .normal
    @Published var panelSize = NSSize(width: 340, height: 600)
    /// The provider whose Configure sheet is open.
    @Published var configuring: Provider?
    /// The account the sheet opens on, from a card's "Sign in…".
    var configuringAccount: UUID?
    /// The sheet's Add form is open.
    @Published var addingAccount = false
    /// Tells the app the account list changed; true when one was added.
    var accountsChanged: (Bool) -> Void = { _ in }
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

    func accounts(for provider: Provider) -> [Account] { accounts.filter { $0.provider == provider } }

    func select(_ provider: Provider) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
    }

    func configure(_ provider: Provider, account: UUID? = nil) {
        configuringAccount = account
        addingAccount = false
        configuring = provider
    }

    func addAccount(_ account: Account) {
        accounts.append(account)
        AccountStore.save(accounts)
        accountsChanged(true)
    }

    func renameAccount(_ id: UUID, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name
        AccountStore.save(accounts)
    }

    /// Only forgets the account: its folder and credentials stay where they are, even a folder Orbit created.
    func removeAccount(_ id: UUID) {
        accounts.removeAll { $0.id == id && $0.folder != nil }
        usage[id] = nil
        AccountStore.save(accounts)
        accountsChanged(false)
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
    /// Toned red for bad news; orange stays reserved for the 70-89% meter state.
    static let errorText = Color(red: 240 / 255, green: 92 / 255, blue: 92 / 255)

    static func status(_ usage: ProviderUsage?) -> String {
        guard let usage else { return String(localized: "Not checked") }
        if usage.needsConnection { return String(localized: "Sign-in needed") }
        return usage.error == nil ? String(localized: "Connected") : String(localized: "Check connection")
    }
}

struct GalaxyPanel: View {
    static let width: CGFloat = 460
    /// Settings keeps its room when the selected tab is short.
    private static let settingsHeight: CGFloat = 480
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
                if model.showingSettings { Color.clear.frame(height: Self.settingsHeight) } else { tabs }
            } else if model.showingSettings {
                settingsView.transition(screen)
            } else {
                tabs.transition(screen)
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
        .translatesProviderText()
        // The measuring copy must never present.
        .sheet(item: measuring ? .constant(nil) : $model.configuring) { provider in
            ProviderAccounts(model: model, provider: provider, refresh: refresh)
        }
    }

    private var screen: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)) }

    private var status: String {
        if updater.busy { return updater.message }
        if model.refreshing { return String(localized: "Refreshing…") }
        return model.refreshedAt.map { String(localized: "Updated \(Format.clockTime($0))") } ?? String(localized: "Waiting for first update")
    }

    private func select(_ provider: Provider) {
        model.showingSettings = false
        model.select(provider)
        resize(model.panelScale) // measures the new tab
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderTabs(selection: model.selectedProvider, select: select)
            if measuring {
                tabContent
            } else {
                // A ZStack, so the outgoing tab fades in place instead of stacking above the new one.
                ZStack(alignment: .topLeading) {
                    ViewThatFits(in: .vertical) {
                        tabContent.fixedSize(horizontal: false, vertical: true)
                        // The overlay scroll bar's lane, clear of the percentages.
                        ScrollView { tabContent.padding(.trailing, 12) }
                    }
                    .id(model.selectedProvider)
                    .transition(screen)
                }
            }
        }
        .animation(reduceMotion || measuring ? nil : .easeOut(duration: 0.2), value: model.selectedProvider)
    }

    private var tabContent: some View {
        let provider = model.selectedProvider
        let accounts = model.accounts(for: provider)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Link(destination: provider.dashboardURL) {
                        HStack(spacing: 4) {
                            Text(provider.name).font(.system(size: 15, weight: .medium))
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open \(provider.name) dashboard in your browser")
                    .accessibilityLabel("Open \(provider.name) dashboard in your browser")
                    Spacer()
                    Button("Configure") { model.configure(provider) }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Galaxy.accentText)
                        .buttonStyle(.plain)
                        .help("Add, rename or remove \(provider.name) accounts")
                        .accessibilityLabel("Configure \(provider.name) accounts")
                }
                ForEach(accounts) { account in
                    AccountCard(account: account, usage: model.usage[account.id], animated: model.visible && !measuring,
                                signIn: { model.configure(provider, account: account.id) })
                }
            }
            TokensSection(provider: provider, tokens: model.tokens[provider], accountCount: accounts.count,
                          animated: model.visible && !measuring)
        }
    }

    static func fittedSize(model: GalaxyModel, available: NSSize) -> NSSize {
        let view = NSHostingView(rootView: GalaxyPanel(model: model, refresh: {}, measuring: true))
        let naturalHeight = ceil(view.fittingSize.height)
        let scale = min(model.panelScale.factor, available.width / width)
        return NSSize(width: width * scale, height: min(ceil(naturalHeight * scale), available.height))
    }

    private var header: some View {
        HStack(spacing: 8) {
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
                ForEach(Array(Provider.allCases.enumerated()), id: \.offset) { index, provider in
                    Button(provider.name) { select(provider) }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
            .opacity(0).accessibilityHidden(true)
        }
    }

    // Sideline's gear is a tab, not a dropdown: a menu can't hold a slider.
    private var settings: some View {
        Button {
            model.showingSettings.toggle()
            resize(model.panelScale) // settings needs its own height
        } label: {
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

/// Sideline's tab bar: one faint capsule, the selection an accent capsule that slides between the segments.
private struct ProviderTabs: View {
    let selection: Provider
    let select: (Provider) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Provider.allCases) { provider in
                let selected = provider == selection
                Button { select(provider) } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: Logos.image(for: provider, height: 14))
                            .resizable().frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                        Text(provider.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? Color.white : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background {
                        if selected { Capsule().fill(Galaxy.accent).matchedGeometryEffect(id: "tab", in: namespace) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(provider.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }
}

private struct AccountCard: View {
    let account: Account
    let usage: ProviderUsage?
    let animated: Bool
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(account.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                if usage == nil {
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if usage?.needsConnection == true {
                    Text("Sign-in needed").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if usage?.error != nil {
                    Text("Check connection").font(.system(size: 11, weight: .medium)).foregroundStyle(Galaxy.errorText)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(account.name + ", " + Galaxy.status(usage))
            if usage?.needsConnection != true {
                UsageMeter(title: String(localized: "Session"), window: usage?.session, animated: animated)
                UsageMeter(title: String(localized: "Weekly"), window: usage?.weekly, animated: animated)
            }
            if let error = usage?.error.map(translated) {
                Text(error).font(.system(size: 11)).foregroundStyle(Galaxy.errorText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Provider error: \(error). Displayed quotas may be stale.")
            }
            if usage?.needsConnection == true {
                Button("Sign in…", action: signIn)
                    .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                    .foregroundStyle(Galaxy.accentText)
            } else if usage?.error != nil, let date = usage?.updatedAt {
                Text("Quota from \(Format.clockTime(date))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

private struct UsageMeter: View {
    let title: String
    let window: UsageWindow?
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var percent: Double? { window?.usedPercent.flatMap { $0.isFinite ? $0 : nil } }
    private var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }
    private var tint: Color { (percent ?? 0) >= 90 ? .red : (percent ?? 0) >= 70 ? .orange : Galaxy.bar }
    private var moves: Bool { animated && !reduceMotion }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(percent == nil ? String(localized: "not reported") : Format.reset(window?.resetsAt))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if (percent ?? 0) >= 90 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(tint)
                        .help("Near limit")
                }
                Text(Format.percent(percent)).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle((percent ?? 0) >= 70 ? tint : .white)
                    .contentTransition(.numericText())
                    .animation(moves ? .easeOut(duration: 0.2) : nil, value: percent)
            }
            GeometryReader { track in
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(tint).frame(width: track.size.width * fraction)
                    .animation(moves ? .easeOut(duration: 0.3) : nil, value: fraction)
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title), \(Format.percent(percent)) used, \(Format.reset(window?.resetsAt))")
                            + ((percent ?? 0) >= 90 ? String(localized: ", near limit") : ""))
    }
}

private struct TokensSection: View {
    let provider: Provider
    let tokens: ProviderTokens?
    let accountCount: Int
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens").font(.system(size: 15, weight: .medium))
                Spacer()
                if accountCount >= 2 {
                    Text("All accounts").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if provider == .antigravity {
                empty(String(localized: "Antigravity does not report token counts"))
            } else if let tokens, tokens.isEmpty {
                empty(String(localized: "No token logs yet"))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    stats
                    chart
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Galaxy.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tokens.map { Format.tokens($0.session) } ?? "—")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .fixedSize()
                    .contentTransition(.numericText())
                    .animation(animated && !reduceMotion ? .easeOut(duration: 0.2) : nil, value: tokens?.session)
                    .help(tokens.map { Format.tokensFull($0.session) } ?? "")
                    .accessibilityLabel(tokens.map { String(localized: "Tokens this session, \(Format.tokensFull($0.session))") } ?? String(localized: "This session"))
                Spacer()
                Text("Last 7 days").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(tokens.map { Format.tokens($0.week) } ?? "—")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .fixedSize()
                    .help(tokens.map { Format.tokensFull($0.week) } ?? "")
            }
            Text("This session").font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var chart: some View {
        let days = tokens?.days ?? TokenLogs.dayStarts(now: Date()).map { TokenDay(day: $0, tokens: 0) }
        let maximum = days.map(\.tokens).max() ?? 0
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(days) { day in
                TokenColumn(day: day.day, value: tokens == nil ? nil : day.tokens, maximum: maximum,
                            isToday: day.id == days.last?.id, grown: grown || !animated || reduceMotion)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tokens per day, last 7 days")
        .onAppear {
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) { grown = true }
            } else {
                grown = true
            }
        }
    }
}

private struct TokenColumn: View {
    let day: Date
    let value: Int?
    let maximum: Int
    let isToday: Bool
    let grown: Bool
    @State private var hovering = false

    var body: some View {
        let full = Format.tokensFull(value ?? 0)
        VStack(spacing: 4) {
            Text(value.map { Format.tokens($0) } ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : .secondary)
                .lineLimit(1).fixedSize()
            // Bars share one baseline; a zero day has none.
            ZStack(alignment: .bottom) {
                Color.clear
                if let value, value > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isToday ? Galaxy.accent : Color.white.opacity(hovering ? 0.45 : 0.3))
                        .frame(height: TokenLogs.barHeight(value, maximum: maximum))
                        .scaleEffect(y: grown ? 1 : 0, anchor: .bottom)
                }
            }
            .frame(height: 64)
            Text(isToday ? String(localized: "Today") : Format.shortWeekday(day))
                .font(.system(size: 11))
                .foregroundStyle(isToday ? Color.white : .secondary)
                .lineLimit(1).fixedSize()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(Format.longWeekday(day)) \(Format.monthDay(day)): \(full) tokens")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.longWeekday(day)), \(full) tokens")
    }
}
