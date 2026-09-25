import AppKit
import Combine
import Foundation

@MainActor final class CapBarViewModel: ObservableObject {
    @Published var settings: UserSettings
    @Published private(set) var rows: [PopoverAccountRow] = []
    @Published var showsSettings = false
    @Published var selectedProvider: Provider = .claude
    @Published var directoryInput = ""
    @Published var popoverWidthInput: String
    @Published var popoverHeightInput: String
    @Published var settingsMessage: String?

    let settingsStore: SettingsStore
    let coordinator: RefreshCoordinator
    var onRowsChange: (([PopoverAccountRow]) -> Void)?
    var onPopoverSizeChange: ((PopoverSize) -> Void)?
    var onFolderPickerWillOpen: (() -> Void)?
    var onFolderPickerFinished: (() -> Void)?

    private var timer: Timer?
    private var saveTask: Task<Void, Never>?

    var maximumPopoverWidth: Int {
        max(PopoverSize.minimumWidth, Int(NSScreen.main?.visibleFrame.width ?? 1200) - 32)
    }

    var maximumPopoverHeight: Int {
        max(PopoverSize.minimumHeight, Int(NSScreen.main?.visibleFrame.height ?? 900) - 24)
    }

    init(settings: UserSettings, settingsStore: SettingsStore, coordinator: RefreshCoordinator) {
        self.settings = settings
        self.popoverWidthInput = String(settings.popoverSize.width)
        self.popoverHeightInput = String(settings.popoverSize.height)
        self.settingsStore = settingsStore
        self.coordinator = coordinator
    }

    func opened() {
        updateRows()
        let currentSettings = settings
        Task {
            _ = await coordinator.openedPopover(settings: currentSettings)
            await reloadRows()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRows() }
        }
    }

    func closed() {
        timer?.invalidate()
        timer = nil
        commitPopoverWidthInput(maximum: maximumPopoverWidth)
        commitPopoverHeightInput(maximum: maximumPopoverHeight)
    }

    func updateRows() {
        Task { await reloadRows() }
    }

    private func reloadRows() async {
        let state = await coordinator.viewState()
        rows = PopoverPresentation.rows(settings: settings, state: state, now: Date(), calendar: .current)
        onRowsChange?(rows)
    }

    func refreshAll() {
        let currentSettings = settings
        Task {
            _ = await coordinator.requestRefreshAll(settings: currentSettings)
            await reloadRows()
        }
    }

    func refresh(_ account: AccountID) {
        Task {
            _ = await coordinator.requestRefresh(account)
            await reloadRows()
        }
    }

    func setAutoRefresh(_ enabled: Bool) {
        settings.autoRefreshOnOpen = enabled
        enqueueSave()
    }

    func setThreshold(_ minutes: Int) {
        settings.refreshThresholdMinutes = max(1, minutes)
        enqueueSave()
    }

    func setPopoverWidth(_ width: Int) {
        settings.popoverSize = PopoverSize(width: width, height: settings.popoverSize.height)
        popoverWidthInput = String(settings.popoverSize.width)
        onPopoverSizeChange?(settings.popoverSize)
        enqueueSave()
    }

    func setPopoverHeight(_ height: Int) {
        settings.popoverSize = PopoverSize(width: settings.popoverSize.width, height: height)
        popoverHeightInput = String(settings.popoverSize.height)
        onPopoverSizeChange?(settings.popoverSize)
        enqueueSave()
    }

    func setPopoverSize(width: Int, height: Int) {
        settings.popoverSize = PopoverSize(width: width, height: height)
        popoverWidthInput = String(settings.popoverSize.width)
        popoverHeightInput = String(settings.popoverSize.height)
        onPopoverSizeChange?(settings.popoverSize)
        enqueueSave()
    }

    func editPopoverWidthInput(_ text: String) {
        popoverWidthInput = text
    }

    func editPopoverHeightInput(_ text: String) {
        popoverHeightInput = text
    }

    func commitPopoverWidthInput(maximum: Int) {
        guard let value = Int(popoverWidthInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            popoverWidthInput = String(settings.popoverSize.width)
            return
        }
        let width = min(maximum, value)
        if width == settings.popoverSize.width {
            popoverWidthInput = String(width)
        } else {
            setPopoverWidth(width)
        }
    }

    func commitPopoverHeightInput(maximum: Int) {
        guard let value = Int(popoverHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            popoverHeightInput = String(settings.popoverSize.height)
            return
        }
        let height = min(maximum, value)
        if height == settings.popoverSize.height {
            popoverHeightInput = String(height)
        } else {
            setPopoverHeight(height)
        }
    }

    func addAccount() {
        let input = directoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { settingsMessage = "请输入配置目录"; return }
        let account = AccountID(provider: selectedProvider, directory: input)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: account.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            settingsMessage = "目录不存在，请检查路径"
            return
        }
        guard !settings.accounts.contains(account) else {
            settingsMessage = "这个目录已经添加"
            return
        }
        settings.accounts.append(account)
        directoryInput = ""
        settingsMessage = nil
        enqueueSave()
        updateRows()
    }

    func removeAccount(_ account: AccountID) {
        guard !rows.contains(where: { $0.account == account && $0.isRefreshing }) else { return }
        settings.accounts.removeAll { $0 == account }
        settingsMessage = nil
        enqueueSave()
        updateRows()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        prepareDirectorySelection()
        panel.begin { [weak self] response in
            let chosenURL = response == .OK ? panel.url : nil
            Task { @MainActor [weak self] in
                self?.finishDirectorySelection(chosenURL)
            }
        }
    }

    func prepareDirectorySelection() {
        onFolderPickerWillOpen?()
    }

    func finishDirectorySelection(_ url: URL?) {
        if let url { directoryInput = url.path }
        showsSettings = true
        onFolderPickerFinished?()
    }

    private func enqueueSave() {
        let previous = saveTask
        let value = settings
        let store = settingsStore
        saveTask = Task {
            await previous?.value
            do {
                try await store.save(value)
            } catch {
                settingsMessage = "设置未能保存"
            }
        }
    }

    func flushSettings() async {
        await saveTask?.value
    }
}
