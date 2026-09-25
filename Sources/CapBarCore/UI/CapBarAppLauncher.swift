import AppKit
import SwiftUI

@MainActor public enum CapBarAppLauncher {
    private static var retainedDelegate: CapBarAppDelegate?

    public static func selfCheck() -> Bool {
        guard (try? ProbePolicy.bundled()) != nil,
              CapBarResources.url(forResource: "capbar-menubar-template", withExtension: "png") != nil,
              Bundle.main.url(forResource: "CapBar", withExtension: "icns") != nil else {
            return false
        }
        return true
    }

    public static func run() {
        let application = NSApplication.shared
        let delegate = CapBarAppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor private final class CapBarAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var viewModel: CapBarViewModel?
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            if let url = CapBarResources.url(forResource: "capbar-menubar-template", withExtension: "png"),
               let source = NSImage(contentsOf: url),
               let pixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let cropped = pixels.cropping(to: CGRect(x: 245, y: 245, width: 764, height: 764)) {
                // The supplied asset has wide transparent margins; crop them
                // for a legible 18-point menu bar image.
                let icon = NSImage(cgImage: cropped, size: NSSize(width: 18, height: 18))
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageLeading
            }
            button.title = "CapBar"
            button.target = self
            button.action = #selector(togglePopover)
        }
        Task { await initialize() }
    }

    private func initialize() async {
        do {
            let settingsStore = SettingsStore()
            let snapshotStore = SnapshotStore()
            let settings = try await settingsStore.loadOrSeed()
            let coordinator = try await RefreshCoordinator(
                settingsStore: settingsStore,
                snapshotStore: snapshotStore,
                providers: [.claude: ClaudeClient(), .codex: CodexClient()],
                policy: ProbePolicy.bundled()
            )
            let model = CapBarViewModel(settings: settings, settingsStore: settingsStore, coordinator: coordinator)
            model.onRowsChange = { [weak self] rows in self?.updateStatusItem(rows) }
            viewModel = model

            let panel = NSPopover()
            panel.behavior = .transient
            panel.animates = true
            panel.contentSize = NSSize(width: 448, height: 620)
            panel.contentViewController = NSHostingController(rootView: CapBarPopoverView(model: model))
            panel.delegate = self
            popover = panel

            model.updateRows()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak model] _ in
                Task { @MainActor in model?.updateRows() }
            }
        } catch {
            statusItem?.button?.title = "CapBar ⚠"
            let panel = NSPopover()
            panel.behavior = .transient
            panel.contentSize = NSSize(width: 300, height: 100)
            panel.contentViewController = NSHostingController(rootView:
                Text("CapBar 无法读取设置或快照，请检查配置文件。")
                    .padding(18).frame(width: 300, height: 100)
            )
            popover = panel
        }
    }

    private func updateStatusItem(_ rows: [PopoverAccountRow]) {
        let exhausted = PopoverPresentation.exhaustedCount(rows: rows)
        statusItem?.button?.title = exhausted > 0
            ? "\(rows.count) 账号 · \(exhausted) 耗尽"
            : "\(rows.count) 账号"
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            viewModel?.opened()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        viewModel?.closed()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        viewModel?.closed()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = viewModel?.coordinator else { return .terminateNow }
        statusTimer?.invalidate()
        viewModel?.closed()
        Task {
            await viewModel?.flushSettings()
            await coordinator.cancelAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
