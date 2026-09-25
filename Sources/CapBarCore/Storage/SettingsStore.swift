import Foundation

struct PopoverSize: Codable, Sendable, Equatable {
    static let minimumWidth = 448
    static let minimumHeight = 620

    let width: Int
    let height: Int

    init(width: Int = minimumWidth, height: Int = minimumHeight) {
        self.width = max(Self.minimumWidth, width)
        self.height = max(Self.minimumHeight, height)
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try values.decode(Int.self, forKey: .width),
            height: try values.decode(Int.self, forKey: .height)
        )
    }
}

struct UserSettings: Codable, Sendable {
    var accounts: [AccountID]
    var defaultsSeeded: Bool
    var autoRefreshOnOpen: Bool
    var refreshThresholdMinutes: Int
    var popoverSize: PopoverSize

    init(
        accounts: [AccountID],
        defaultsSeeded: Bool,
        autoRefreshOnOpen: Bool,
        refreshThresholdMinutes: Int,
        popoverSize: PopoverSize = PopoverSize()
    ) {
        self.accounts = accounts
        self.defaultsSeeded = defaultsSeeded
        self.autoRefreshOnOpen = autoRefreshOnOpen
        self.refreshThresholdMinutes = refreshThresholdMinutes
        self.popoverSize = popoverSize
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, defaultsSeeded, autoRefreshOnOpen, refreshThresholdMinutes, popoverSize
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accounts: try values.decode([AccountID].self, forKey: .accounts),
            defaultsSeeded: try values.decode(Bool.self, forKey: .defaultsSeeded),
            autoRefreshOnOpen: try values.decode(Bool.self, forKey: .autoRefreshOnOpen),
            refreshThresholdMinutes: try values.decode(Int.self, forKey: .refreshThresholdMinutes),
            popoverSize: try values.decodeIfPresent(PopoverSize.self, forKey: .popoverSize) ?? PopoverSize()
        )
    }
}

private struct SettingsFile: Codable {
    let schemaVersion: Int
    let settings: UserSettings
}

actor SettingsStore {
    private let url: URL

    init(url: URL = StorageSupport.appSupportURL("settings.json")) {
        self.url = url
    }

    func loadOrSeed() throws -> UserSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            let file = try StorageSupport.decoder().decode(SettingsFile.self, from: Data(contentsOf: url))
            guard file.schemaVersion == 1 else { throw StorageError.unsupportedSchema(file.schemaVersion) }
            guard file.settings.refreshThresholdMinutes > 0 else { throw StorageError.invalidSettings }
            return file.settings
        }

        let initial = UserSettings(
            accounts: [
                AccountID(provider: .claude, directory: "~/.claude"),
                AccountID(provider: .codex, directory: "~/.codex")
            ],
            defaultsSeeded: true,
            autoRefreshOnOpen: false,
            refreshThresholdMinutes: 5
        )
        try save(initial)
        return initial
    }

    func save(_ value: UserSettings) throws {
        guard value.refreshThresholdMinutes > 0 else { throw StorageError.invalidSettings }
        try StorageSupport.write(SettingsFile(schemaVersion: 1, settings: value), to: url)
    }
}
