import Foundation
@testable import CapBarCore

@MainActor func runViewModelChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let snapshotStore = SnapshotStore(url: root.appendingPathComponent("snapshots.json"))
        let settings = try await settingsStore.loadOrSeed()
        let coordinator = try await RefreshCoordinator(settingsStore: settingsStore, snapshotStore: snapshotStore, providers: [:], policy: ProbePolicy.bundled())
        let model = CapBarViewModel(settings: settings, settingsStore: settingsStore, coordinator: coordinator)
        var reported: [PopoverSize] = []
        model.onPopoverSizeChange = { reported.append($0) }
        model.setPopoverWidth(703)
        model.setPopoverHeight(823)
        check(model.settings.popoverSize.width == 703 && model.settings.popoverSize.height == 823, "exact size values update the model without rounding")
        check(reported.map(\.width) == [703, 703] && reported.map(\.height) == [620, 823], "each size edit resizes the live popover")
        model.setPopoverWidth(10)
        model.setPopoverHeight(10)
        check(model.settings.popoverSize.width == 448 && model.settings.popoverSize.height == 620, "UI edits respect the minimum dimensions")
        await model.flushSettings()
        let saved = try await SettingsStore(url: root.appendingPathComponent("settings.json")).loadOrSeed()
        check(saved.popoverSize.width == 448 && saved.popoverSize.height == 620, "size edits persist to settings JSON")

        reported.removeAll()
        model.editPopoverWidthInput("7")
        check(model.settings.popoverSize.width == 448 && reported.isEmpty, "partial width typing does not resize the popover")
        model.editPopoverWidthInput("703")
        model.commitPopoverWidthInput(maximum: 1200)
        check(model.settings.popoverSize.width == 703 && model.popoverWidthInput == "703", "return or focus loss applies an exact width")
        model.editPopoverWidthInput("not a number")
        model.commitPopoverWidthInput(maximum: 1200)
        check(model.settings.popoverSize.width == 703 && model.popoverWidthInput == "703", "invalid width input reverts without resizing")
        model.setPopoverWidth(713)
        check(model.settings.popoverSize.width == 713 && model.popoverWidthInput == "713", "width stepper applies immediately and syncs its text")
        model.editPopoverHeightInput("8")
        check(model.settings.popoverSize.height == 620, "partial height typing does not resize the popover")
        model.editPopoverHeightInput("823")
        model.commitPopoverHeightInput(maximum: 1000)
        check(model.settings.popoverSize.height == 823 && model.popoverHeightInput == "823", "return or focus loss applies an exact height")
        model.editPopoverWidthInput("731")
        model.editPopoverHeightInput("851")
        model.closed()
        check(model.settings.popoverSize.width == 731 && model.settings.popoverSize.height == 851,
              "closing the popover commits valid pending size inputs (max=\(model.maximumPopoverWidth)x\(model.maximumPopoverHeight), actual=\(model.settings.popoverSize.width)x\(model.settings.popoverSize.height))")

        var pickerEvents: [String] = []
        model.onFolderPickerWillOpen = { pickerEvents.append("opened") }
        var returned = 0
        model.onFolderPickerFinished = { returned += 1 }
        model.showsSettings = true
        model.prepareDirectorySelection()
        check(pickerEvents == ["opened"], "folder picker announces its opening before display")
        model.finishDirectorySelection(URL(fileURLWithPath: "/tmp/example-claude"))
        check(model.directoryInput == "/tmp/example-claude", "chosen folder fills the directory field")
        check(model.showsSettings && returned == 1, "folder picker returns to the settings popover")
        model.prepareDirectorySelection()
        model.finishDirectorySelection(nil)
        check(returned == 2 && model.showsSettings, "cancelling the picker also restores normal popover behavior")
    } catch {
        check(false, "view model checks setup succeeds: \(error)")
    }
}
