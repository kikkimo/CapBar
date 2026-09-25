import AppKit
import SwiftUI

@MainActor final class PopoverDismissalController {
    private weak var popover: NSPopover?
    private(set) var isChoosingDirectory = false

    init(popover: NSPopover) {
        self.popover = popover
        popover.behavior = .transient
    }

    var shouldClose: Bool { !isChoosingDirectory }

    func shouldDismissOutsideClick(isShown: Bool) -> Bool {
        isShown && shouldClose
    }

    func beginDirectorySelection() {
        isChoosingDirectory = true
        popover?.behavior = .applicationDefined
    }

    func endDirectorySelection() {
        isChoosingDirectory = false
        popover?.behavior = .transient
    }
}

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
    private let titleGap = "\u{2009}"
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var dismissalController: PopoverDismissalController?
    private var viewModel: CapBarViewModel?
    private var statusTimer: Timer?
    private var outsideClickMonitor: Any?
    private var statusRightClickMonitor: Any?
    private var contextMenu: StatusContextMenu?
    private var resignActiveObserver: NSObjectProtocol?

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
            button.title = titleGap + "CapBar"
            button.target = self
            button.action = #selector(togglePopover)
        }
        installContextMenu()
        Task { await initialize() }
    }

    private func installContextMenu() {
        contextMenu = StatusContextMenu(
            onRefreshAll: { [weak self] in self?.viewModel?.refreshAll() },
            onOpenSettings: { [weak self] in
                guard let self, let model = self.viewModel else { return }
                model.showsSettings = true
                self.showPopover()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        statusRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let button = self.statusItem?.button,
                  StatusRightClick.shouldShowMenu(
                    eventType: event.type,
                    eventWindowNumber: event.windowNumber,
                    buttonWindowNumber: button.window?.windowNumber,
                    point: button.convert(event.locationInWindow, from: nil),
                    bounds: button.bounds
                  ) else { return event }
            if self.popover?.isShown == true, self.dismissalController?.shouldClose == true {
                self.popover?.close()
            }
            if let menu = self.contextMenu?.menu {
                NSMenu.popUpContextMenu(menu, with: event, for: button)
            }
            return nil
        }
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
            model.onPopoverSizeChange = { [weak self] size in self?.resizePopover(size) }
            model.onFolderPickerWillOpen = { [weak self] in self?.dismissalController?.beginDirectorySelection() }
            model.onFolderPickerFinished = { [weak self] in self?.dismissalController?.endDirectorySelection() }
            viewModel = model

            let panel = NSPopover()
            dismissalController = PopoverDismissalController(popover: panel)
            panel.animates = true
            panel.contentSize = NSSize(width: CGFloat(settings.popoverSize.width), height: CGFloat(settings.popoverSize.height))
            panel.contentViewController = NSHostingController(rootView: CapBarPopoverView(model: model))
            panel.delegate = self
            popover = panel
            installFocusDismissal()

            model.updateRows()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak model] _ in
                Task { @MainActor in model?.updateRows() }
            }
        } catch {
            statusItem?.button?.title = titleGap + "CapBar ⚠"
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
        statusItem?.button?.title = titleGap + (exhausted > 0
            ? "\(rows.count) 账号 · \(exhausted) 耗尽"
            : "\(rows.count) 账号")
    }

    private func resizePopover(_ size: PopoverSize) {
        popover?.contentSize = NSSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.isOpaque = false
        popover.contentViewController?.view.window?.backgroundColor = .clear
        viewModel?.opened()
    }

    private func installFocusDismissal() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissForOutsideClick() }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissForAppDeactivation() }
        }
    }

    private func dismissForOutsideClick() {
        guard let popover,
              dismissalController?.shouldDismissOutsideClick(isShown: popover.isShown) == true else { return }
        popover.close()
    }

    private func dismissForAppDeactivation() {
        guard let popover, popover.isShown,
              dismissalController?.shouldClose == true else { return }
        popover.close()
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        viewModel?.closed()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        dismissalController?.shouldClose ?? true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let statusRightClickMonitor { NSEvent.removeMonitor(statusRightClickMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
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
