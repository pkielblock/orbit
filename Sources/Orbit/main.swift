import AppKit
import SwiftUI

/// Menu bar only, with a transient popover that dismisses on Escape or an outside click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = GalaxyModel()
    private let updater = AppUpdater()
    private let sources: [UsageSource] = [ClaudeSource(), CodexSource(), AntigravitySource()]
    private var timer: Timer?
    private var lastRefresh: Date = .distantPast
    private var checkedConnections = false
    private var pendingConnections = false

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
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.toolTip = "Orbit — open usage dashboard"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 60
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            updater.checkIfDue()
            if Date().timeIntervalSince(lastRefresh) > 60 { refresh() }
            model.visible = true
            fitPopover()
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if pendingConnections {
                pendingConnections = false
                model.showingConnections = true
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.visible = false
        model.showingSettings = false
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
        guard !model.refreshing else { return }
        model.refreshing = true
        lastRefresh = Date()
        Task {
            var results: [ProviderUsage] = []
            await withTaskGroup(of: ProviderUsage.self) { group in
                for source in sources { group.addTask { await source.fetch() } }
                for await result in group { results.append(result) }
            }
            for var result in results {
                // Preserve last good quota values during temporary provider failures.
                if result.error != nil, !result.needsConnection, let old = model.usage[result.provider] {
                    result.session = result.session ?? old.session
                    result.weekly = result.weekly ?? old.weekly
                    result.updatedAt = result.updatedAt ?? old.updatedAt
                }
                model.usage[result.provider] = result
            }
            model.refreshedAt = Date()
            model.refreshing = false
            if !checkedConnections {
                checkedConnections = true
                pendingConnections = results.contains { $0.needsConnection }
                if model.visible, pendingConnections {
                    pendingConnections = false
                    model.showingConnections = true
                }
            }
            self.fitPopover()
        }
    }
}

/// `--dump` prints what each provider returns and exits. Used to check data sources without the menu bar.
func dumpUsage() {
    func describe(_ window: UsageWindow?) -> String {
        guard let window else { return "none" }
        let pct = window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "?"
        let reset = window.resetsAt.map { Format.reset($0) } ?? "no reset"
        return "\(pct), \(reset)"
    }
    Task {
        for source in [ClaudeSource(), CodexSource(), AntigravitySource()] as [UsageSource] {
            let result = await source.fetch()
            print("\(result.provider.name): session [\(describe(result.session))] weekly [\(describe(result.weekly))] error [\(result.error ?? "-")]")
        }
        exit(0)
    }
    RunLoop.main.run()
}

/// Renders the production panel. --demo avoids credentials and network access for visual QA.
func snapshotUsage(to path: String, demo: Bool) {
    Task { @MainActor in
        _ = NSApplication.shared
        let model = GalaxyModel()
        if demo {
            for (index, provider) in Provider.allCases.enumerated() {
                model.usage[provider] = ProviderUsage(provider: provider,
                    session: UsageWindow(usedPercent: [32.0, 74.0, 12.0][index], resetsAt: Date(timeIntervalSinceNow: 7200)),
                    weekly: UsageWindow(usedPercent: [58.0, 91.0, 24.0][index], resetsAt: Date(timeIntervalSinceNow: 172800)),
                    updatedAt: Date())
            }
        } else {
            for source in [ClaudeSource(), CodexSource(), AntigravitySource()] as [UsageSource] {
                let result = await source.fetch()
                model.usage[result.provider] = result
            }
        }
        model.refreshedAt = Date()
        if let index = CommandLine.arguments.firstIndex(of: "--size"), index + 1 < CommandLine.arguments.count,
           let scale = PanelScale(rawValue: CommandLine.arguments[index + 1]) {
            model.panelScale = scale
        }
        model.panelSize = GalaxyPanel.fittedSize(model: model, available: NSSize(width: 2000, height: 2000))
        model.showingSettings = CommandLine.arguments.contains("--settings")
        let controller = NSHostingController(rootView: GalaxyPanel(model: model, refresh: {}))
        let view = controller.view
        // Offscreen capture has no popover material behind it; paint its dark tone.
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        view.frame = NSRect(origin: .zero, size: model.panelSize)
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

if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    snapshotUsage(to: CommandLine.arguments[index + 1], demo: CommandLine.arguments.contains("--demo"))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
