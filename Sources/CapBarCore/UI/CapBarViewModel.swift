import AppKit
import Combine
import Foundation

@MainActor final class CapBarViewModel: ObservableObject {
    @Published var settings: UserSettings
    @Published private(set) var rows: [PopoverAccountRow] = []
    @Published private(set) var trends: [AccountID: UsageTrendSeries] = [:]
    @Published var showsSettings = false
    @Published private(set) var showsTrend = false
    @Published var selectedProvider: Provider = .claude
    @Published var directoryInput = ""
    @Published var popoverWidthInput: String
    @Published var popoverHeightInput: String
    @Published var settingsMessage: String?

    let settingsStore: SettingsStore
    let coordinator: RefreshCoordinator
    let historyStore: UsageHistoryStore?
    let samplingController: UsageSamplingController?
    var historySampleLoader: (@Sendable (AccountID, Date, Date) async throws -> [UsageHistorySample])?
    var onRowsChange: (([PopoverAccountRow]) -> Void)?
    var onPopoverSizeChange: ((PopoverSize) -> Void)?
    var onFolderPickerWillOpen: (() -> Void)?
    var onFolderPickerFinished: (() -> Void)?
    var onSamplingSettingsChange: ((UserSettings) -> Void)?

    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private struct TrendKey: Equatable {
        let capturedAt: Date?
        let gridEnd: TimeInterval
        let intervalHours: Int
    }
    private var trendKeys: [AccountID: TrendKey] = [:]
    private var trendReloadGeneration = 0

    var maximumPopoverWidth: Int {
        max(PopoverSize.minimumWidth, Int(NSScreen.main?.visibleFrame.width ?? 1200) - 32)
    }

    var maximumPopoverHeight: Int {
        max(PopoverSize.minimumHeight, Int(NSScreen.main?.visibleFrame.height ?? 900) - 24)
    }

    init(
        settings: UserSettings, settingsStore: SettingsStore, coordinator: RefreshCoordinator,
        historyStore: UsageHistoryStore? = nil, samplingController: UsageSamplingController? = nil
    ) {
        self.settings = settings
        self.popoverWidthInput = String(settings.popoverSize.width)
        self.popoverHeightInput = String(settings.popoverSize.height)
        self.settingsStore = settingsStore
        self.coordinator = coordinator
        self.historyStore = historyStore
        self.samplingController = samplingController
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
        if showsTrend && settings.usageStatisticsEnabled { await reloadTrends() }
    }

    func refreshAll() {
        let currentSettings = settings
        Task {
            _ = await coordinator.requestRefreshAll(settings: currentSettings)
            await reloadRows()
        }
    }

    func refresh(_ account: AccountID) {
        let recordHistory = settings.usageStatisticsEnabled
        Task {
            _ = await coordinator.requestRefresh(account, recordHistory: recordHistory)
            await reloadRows()
        }
    }

    func setTrendMode(_ enabled: Bool, reload: Bool = true) {
        trendReloadGeneration += 1
        showsTrend = enabled && settings.usageStatisticsEnabled
        if showsTrend && reload { Task { await reloadTrends() } }
    }

    func setUsageStatisticsEnabled(_ enabled: Bool, now: Date = Date()) {
        guard settings.usageStatisticsEnabled != enabled else { return }
        trendReloadGeneration += 1
        settings.usageStatisticsEnabled = enabled
        settings.samplingScheduleStartedAt = enabled ? now : nil
        if !enabled {
            showsTrend = false
            trends.removeAll()
            trendKeys.removeAll()
        }
        onSamplingSettingsChange?(settings)
        enqueueSave()
    }

    func setSamplingInterval(_ hours: Int, now: Date = Date()) {
        guard SamplingInterval.isValid(hours), settings.samplingIntervalHours != hours else { return }
        trendReloadGeneration += 1
        settings.samplingIntervalHours = hours
        if settings.usageStatisticsEnabled { settings.samplingScheduleStartedAt = now }
        trendKeys.removeAll()
        if showsTrend { Task { await reloadTrends() } }
        onSamplingSettingsChange?(settings)
        enqueueSave()
    }

    func reloadTrends(endingAt now: Date = Date()) async {
        guard settings.usageStatisticsEnabled, showsTrend,
              historyStore != nil || historySampleLoader != nil else { return }
        trendReloadGeneration += 1
        let generation = trendReloadGeneration
        let gridEnd = floor(now.timeIntervalSince1970 / 7_200) * 7_200
        let records = await coordinator.viewState().records
        let accounts = settings.accounts
        let intervalHours = settings.samplingIntervalHours
        var result = trends.filter { accounts.contains($0.key) }
        var newKeys = trendKeys.filter { accounts.contains($0.key) }
        for account in accounts {
            let nextSampleAt = await samplingController?.nextDue(for: account)
            if var existing = result[account] {
                existing.nextSampleAt = nextSampleAt
                result[account] = existing
            }
            let key = TrendKey(
                capturedAt: records[account]?.snapshot?.capturedAt,
                gridEnd: gridEnd,
                intervalHours: intervalHours
            )
            if trendKeys[account] == key, result[account] != nil { continue }
            let start = Date(timeIntervalSince1970: gridEnd - 84 * 7_200 - Double(intervalHours) * 3_600 - 900)
            do {
                let samples: [UsageHistorySample]
                if let historySampleLoader {
                    samples = try await historySampleLoader(account, start, now)
                } else if let historyStore {
                    samples = try await historyStore.samples(account: account, from: start, through: now)
                } else {
                    return
                }
                var series = UsageTrendCalculator.calculate(
                    samples: samples, intervalHours: intervalHours, endingAt: now
                )
                series.nextSampleAt = nextSampleAt
                result[account] = series
                newKeys[account] = key
            } catch {
                result.removeValue(forKey: account)
                newKeys.removeValue(forKey: account)
            }
        }
        if generation == trendReloadGeneration && settings.usageStatisticsEnabled && showsTrend {
            trendKeys = newKeys
            trends = result
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
        trendReloadGeneration += 1
        directoryInput = ""
        settingsMessage = nil
        onSamplingSettingsChange?(settings)
        enqueueSave()
        updateRows()
    }

    func removeAccount(_ account: AccountID) {
        guard !rows.contains(where: { $0.account == account && $0.isRefreshing }) else { return }
        settings.accounts.removeAll { $0 == account }
        trendReloadGeneration += 1
        settingsMessage = nil
        onSamplingSettingsChange?(settings)
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
