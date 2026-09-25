import AppKit
@testable import CapBarCore

@MainActor func runStatusMenuChecks() {
    _ = NSApplication.shared
    var selected: [String] = []
    let contextMenu = StatusContextMenu(
        onRefreshAll: { selected.append("refresh") },
        onOpenSettings: { selected.append("settings") },
        onQuit: { selected.append("quit") }
    )
    check(contextMenu.menu.items.map(\.title) == ["全部刷新", "进入配置", "退出 CapBar"],
          "right-click menu offers exactly the three requested actions")

    for (index, expected) in ["refresh", "settings", "quit"].enumerated() {
        let item = contextMenu.menu.items[index]
        check(NSApplication.shared.sendAction(item.action!, to: item.target, from: item),
              "right-click menu item \(index) has a working AppKit action")
        check(selected.last == expected, "right-click menu item \(index) invokes its matching action")
    }

    let bounds = NSRect(x: 0, y: 0, width: 100, height: 24)
    let point = NSPoint(x: 50, y: 12)
    check(StatusRightClick.shouldShowMenu(eventType: .rightMouseDown, eventWindowNumber: 7,
                                          buttonWindowNumber: 7, point: point, bounds: bounds),
          "right-click on the menu bar button opens the context menu")
    check(!StatusRightClick.shouldShowMenu(eventType: .leftMouseDown, eventWindowNumber: 7,
                                           buttonWindowNumber: 7, point: point, bounds: bounds),
          "left-click keeps the existing popover action")
    check(!StatusRightClick.shouldShowMenu(eventType: .rightMouseDown, eventWindowNumber: 8,
                                           buttonWindowNumber: 7, point: point, bounds: bounds),
          "right-click in another window does not open the CapBar menu")
    check(!StatusRightClick.shouldShowMenu(eventType: .rightMouseDown, eventWindowNumber: 7,
                                           buttonWindowNumber: 7, point: NSPoint(x: 150, y: 12), bounds: bounds),
          "right-click outside the button does not open the CapBar menu")
}
