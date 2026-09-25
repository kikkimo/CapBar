import AppKit
import Combine
import Foundation

@MainActor final class CapBarViewModel: ObservableObject {
    @Published var settings: UserSettings
    @Published private(set) var rows: [PopoverAccountRow] = []
    @Published var showsSettings = false
    @Published var selectedProvider: Provider = .claude
    @Published var directoryInput = ""
    @Published var settingsMessage: String?

    let settingsStore: SettingsStore
    let coordinator: RefreshCoordinator
    var onRowsChange: (([PopoverAccountRow]) -> Void)?

    private var timer: Timer?
    private var saveTask: Task<Void, Never>?

    init(settings: UserSettings, settingsStore: SettingsStore, coordinator: RefreshCoordinator) {
        self.settings = settings
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
        if panel.runModal() == .OK, let url = panel.url { directoryInput = url.path }
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
