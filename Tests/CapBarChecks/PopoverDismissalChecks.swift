import AppKit
@testable import CapBarCore

@MainActor func runPopoverDismissalChecks() {
    _ = NSApplication.shared
    let popover = NSPopover()
    let dismissal = PopoverDismissalController(popover: popover)
    check(popover.behavior == .transient && dismissal.shouldClose, "popover normally closes when focus moves outside")
    check(dismissal.shouldDismissOutsideClick(isShown: true, pointerInsidePopover: false), "outside click dismisses a visible popover")
    check(!dismissal.shouldDismissOutsideClick(isShown: true, pointerInsidePopover: true), "clicking inside the popover keeps it open")
    check(!dismissal.shouldDismissOutsideClick(isShown: false, pointerInsidePopover: false), "outside click does nothing when popover is hidden")
    dismissal.beginDirectorySelection()
    check(popover.behavior == .applicationDefined && !dismissal.shouldClose, "only an open folder picker suppresses focus dismissal")
    check(!dismissal.shouldDismissOutsideClick(isShown: true, pointerInsidePopover: false), "outside click does not dismiss while the folder picker is open")
    dismissal.endDirectorySelection()
    check(popover.behavior == .transient && dismissal.shouldClose, "selecting or cancelling restores normal focus dismissal")
    check(dismissal.shouldDismissOutsideClick(isShown: true, pointerInsidePopover: false), "outside click dismisses again after folder selection")
}
