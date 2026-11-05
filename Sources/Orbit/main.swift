import AppKit
import Combine
import SwiftUI

/// Menu bar only, with a transient popover that dismisses on Escape or an outside click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = GalaxyModel()
    private let updater = AppUpdater()
    private lazy var refresher = AccountRefresher(model: model)
    private let scanner = TokenScanner()
    private var scanningTokens = false
    private var rescanTokens = false
    private var timer: Timer?
    private var lastRefresh: Date = .distantPast
    private var blurSink: AnyCancellable?
    private var configureSink: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Thin overlay scrollers that show only while scrolling, even with a mouse plugged in (this app only).
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua) // dark native material, as in Sideline
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: GalaxyPanel(
            model: model,
            updater: updater,
            refresh: { [weak self] in self?.refresh() },
            resize: { [weak self] in self?.resizePanel(to: $0) }))
        fitPopover()
        blurSink = model.$blur.sink { [weak self] in self?.fadeGlass($0) }
        // The open panel and Terminal sign-in take focus from a transient popover, which would close it and the sheet.
        // The sheet's text fields also need the menu bar app to be active to take typing.
        configureSink = model.$configuring.sink { [weak self] provider in
            self?.popover.behavior = provider == nil ? .transient : .applicationDefined
            if provider != nil { NSApp.activate(ignoringOtherApps: true) }
        }
        refresher.resultApplied = { [weak self] in self?.fitPopover() }
        model.accountsChanged = { [weak self] added in
            self?.refresher.sync()
            self?.fitPopover()
            if added { self?.refresh() }
            self?.scanTokens()
        }
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.toolTip = String(localized: "Orbit, open the usage dashboard")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        refresh()
        scanTokens() // no need to wait for slow quota tools; the end of each refresh scans with the real windows
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 60
    }

    @objc private func togglePopover() {
        if popover.isShown {
            // A sheet is open on the popover: bring it back rather than closing under it.
            if model.configuring != nil { NSApp.activate(ignoringOtherApps: true); return }
            popover.performClose(nil)
        } else if let button = statusItem.button {
            updater.checkIfDue()
            if Date().timeIntervalSince(lastRefresh) > 60 { refresh() }
            model.visible = true
            fitPopover()
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            fadeGlass(model.blur)
        }
    }

    /// Sideline's GlassFade: the blur is a private backdrop layer in the popover frame; no public API or view alpha reaches it,
    /// so fading it leaves the cards and the material tint alone.
    private func fadeGlass(_ blur: Double) {
        func walk(_ layer: CALayer) {
            if layer.className == "CABackdropLayer" { layer.opacity = Float(blur) }
            layer.sublayers?.forEach(walk)
        }
        // The backdrop exists only after the popover's first layout pass.
        DispatchQueue.main.async { [weak self] in
            (self?.popover.contentViewController?.view.window?.contentView?.superview?.layer).map(walk)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.visible = false
        model.showingSettings = false
        model.configuring = nil
    }

    private func resizePanel(to scale: PanelScale) {
        model.panelScale = scale
        UserDefaults.standard.set(scale.rawValue, forKey: "panelSize")
        fitPopover()
    }

    private func fitPopover() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Leave room for the popover arrow and screen edges above the Dock.
        let available = NSSize(width: visibleFrame.width - 32, height: visibleFrame.height - 32)
        model.panelSize = GalaxyPanel.fittedSize(model: model, available: available)
        popover.contentSize = model.panelSize
    }

    private func refresh() {
        updater.checkIfDue()
        if !model.refreshing { lastRefresh = Date() }
        refresher.refresh { [weak self] in
            self?.fitPopover()
            self?.scanTokens()
        }
    }

    /// One scan at a time; a request during a scan runs once after it, with the latest accounts and quota windows.
    private func scanTokens() {
        guard !scanningTokens else {
            rescanTokens = true
            return
        }
        scanningTokens = true
        let now = Date()
        var starts: [Provider: Date] = [:]
        for provider in Provider.allCases {
            let windows = model.accounts(for: provider).compactMap { model.usage[$0.id]?.session }
            starts[provider] = TokenLogs.sessionStart(windows: windows, now: now)
        }
        let roots = AccountStore.logRoots(model.accounts)
        Task {
            model.tokens = await scanner.scan(roots: roots, sessionStarts: starts, now: now)
            scanningTokens = false
            self.fitPopover()
            if rescanTokens {
                rescanTokens = false
                self.scanTokens()
            }
        }
    }
}

/// `--dump` prints what each account returns and exits. Used to check data sources without the menu bar.
func dumpUsage() {
    func describe(_ window: UsageWindow?) -> String {
        guard let window else { return "none" }
        let pct = window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "?"
        let reset = window.resetsAt.map { Format.reset($0) } ?? "no reset"
        return "\(pct), \(reset)"
    }
    Task {
        for account in AccountStore.load() {
            let result = await account.makeSource().fetch()
            print("\(account.provider.name) (\(account.name)): session [\(describe(result.session))] weekly [\(describe(result.weekly))] error [\(result.error ?? "-")]")
        }
        exit(0)
    }
    RunLoop.main.run()
}

/// `--tokens` prints each provider's token totals from local logs and exits. No credentials, no network.
/// With no quota data the session is the rolling 5 hours.
func printTokens() {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let totals = TokenScanner().scanNow(roots: AccountStore.logRoots(AccountStore.load()), sessionStarts: [:])
    for provider in Provider.allCases {
        guard let tokens = totals[provider] else {
            print("\(provider.name): not reported")
            continue
        }
        print("\(provider.name): session (rolling 5h) \(tokens.session), last 7 days \(tokens.week)")
        for day in tokens.days { print("  \(formatter.string(from: day.day)) \(day.tokens)") }
    }
    exit(0)
}

/// Two accounts per provider in every card state, for visual QA. Touches no credentials, network, logs or saved settings.
@MainActor
func fillDemo(_ model: GalaxyModel) {
    func hours(_ count: Double) -> Date { Date(timeIntervalSinceNow: count * 3600) }
    func usage(_ provider: Provider, _ session: Double, _ weekly: Double) -> ProviderUsage {
        ProviderUsage(provider: provider, session: UsageWindow(usedPercent: session, resetsAt: hours(2.2)),
                      weekly: UsageWindow(usedPercent: weekly, resetsAt: hours(70)), updatedAt: Date())
    }
    let folders: [Provider: String] = [.claude: "/Users/you/.claude-work", .codex: "/Users/you/.codex-work",
                                       .antigravity: "/Users/you/.antigravity-work"]
    model.accounts = Provider.allCases.flatMap { provider in
        [Account.defaultAccount(provider, name: "Personal"),
         Account(id: UUID(), provider: provider, name: "Work", folder: folders[provider])]
    }
    let accounts = Dictionary(grouping: model.accounts, by: \.provider)
    model.usage[accounts[.claude]![0].id] = usage(.claude, 42, 18)
    model.usage[accounts[.claude]![1].id] = ProviderUsage(provider: .claude, error: String(localized: "Claude login not found"), needsConnection: true)
    model.usage[accounts[.codex]![0].id] = usage(.codex, 74, 91)
    var stale = usage(.codex, 31, 52)
    stale.error = "HTTP 503"
    stale.updatedAt = hours(-1)
    model.usage[accounts[.codex]![1].id] = stale
    model.usage[accounts[.antigravity]![0].id] = usage(.antigravity, 12, 24)
    // The second Antigravity account stays unset, which is the Checking state.
    func tokens(_ session: Int, _ values: [Int]) -> ProviderTokens {
        ProviderTokens(session: session, days: zip(TokenLogs.dayStarts(now: Date()), values).map { TokenDay(day: $0, tokens: $1) })
    }
    model.tokens[.claude] = tokens(3_482_110, [1_204_000, 812_000, 0, 2_431_000, 16_000, 10_412_000, 3_982_110])
    model.tokens[.codex] = tokens(182_400, [0, 94_000, 742_100, 1_438_000, 0, 61_500, 182_400])
    model.selectedProvider = option("--tab").flatMap(Provider.init(rawValue:)) ?? .claude
    model.refreshedAt = Date()
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

/// Renders the production panel. --demo avoids credentials and network access for visual QA;
/// --tab picks the provider, and --configure renders its sheet directly, since a .sheet doesn't draw offscreen.
func snapshotUsage(to path: String, demo: Bool) {
    Task { @MainActor in
        _ = NSApplication.shared
        let model = GalaxyModel()
        if demo {
            fillDemo(model)
        } else {
            model.selectedProvider = option("--tab").flatMap(Provider.init(rawValue:)) ?? model.selectedProvider
            for account in model.accounts {
                model.usage[account.id] = await account.makeSource().fetch()
            }
            model.tokens = TokenScanner().scanNow(roots: AccountStore.logRoots(model.accounts), sessionStarts: [:])
        }
        model.refreshedAt = Date()
        if let scale = option("--size").flatMap(PanelScale.init(rawValue:)) {
            model.panelScale = scale
        }
        model.showingSettings = CommandLine.arguments.contains("--settings")
        model.panelSize = GalaxyPanel.fittedSize(model: model, available: NSSize(width: 2000, height: 2000))
        let view: NSView
        if CommandLine.arguments.contains("--configure") {
            model.addingAccount = CommandLine.arguments.contains("--add")
            let sheet = ProviderAccounts(model: model, provider: model.selectedProvider, refresh: {})
            view = NSHostingController(rootView: sheet).view
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
        } else {
            view = NSHostingController(rootView: GalaxyPanel(model: model, refresh: {})).view
            view.frame = NSRect(origin: .zero, size: model.panelSize)
        }
        // Offscreen capture has no popover material behind it; paint its dark tone.
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        } catch {
            fputs("Snapshot failed: \(error)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--dump") {
    dumpUsage()
}

if CommandLine.arguments.contains("--tokens") {
    printTokens()
}

if let path = option("--snapshot") {
    snapshotUsage(to: path, demo: CommandLine.arguments.contains("--demo"))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
