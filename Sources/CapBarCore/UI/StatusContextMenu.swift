import AppKit

@MainActor final class StatusContextMenu: NSObject {
    let menu = NSMenu()
    private let onRefreshAll: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(onRefreshAll: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.onRefreshAll = onRefreshAll
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init()
        menu.autoenablesItems = false
        addItem("全部刷新", action: #selector(refreshAll))
        addItem("进入配置", action: #selector(openSettings))
        addItem("退出 CapBar", action: #selector(quit))
    }

    private func addItem(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshAll() { onRefreshAll() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
}

enum StatusRightClick {
    static func shouldShowMenu(eventType: NSEvent.EventType,
                               eventWindowNumber: Int,
                               buttonWindowNumber: Int?,
                               point: NSPoint,
                               bounds: NSRect) -> Bool {
        eventType == .rightMouseDown &&
            eventWindowNumber == buttonWindowNumber &&
            bounds.contains(point)
    }
}
