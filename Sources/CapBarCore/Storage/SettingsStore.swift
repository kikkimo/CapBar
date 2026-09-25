import Foundation

struct UserSettings: Codable, Sendable {
    var accounts: [AccountID]
    var defaultsSeeded: Bool
    var autoRefreshOnOpen: Bool
    var refreshThresholdMinutes: Int
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
