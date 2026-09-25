import Foundation

struct AccountRecord: Codable, Sendable {
    let id: AccountID
    var snapshot: UsageSnapshot?
    var lastAttemptAt: Date?
    var lastError: String?
}

private struct SnapshotsFile: Codable {
    let schemaVersion: Int
    let records: [AccountRecord]
}

actor SnapshotStore {
    private let url: URL

    init(url: URL = StorageSupport.appSupportURL("snapshots.json")) {
        self.url = url
    }

    func load() throws -> [AccountID: AccountRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let file = try StorageSupport.decoder().decode(SnapshotsFile.self, from: Data(contentsOf: url))
        guard file.schemaVersion == 1 else { throw StorageError.unsupportedSchema(file.schemaVersion) }
        return Dictionary(uniqueKeysWithValues: file.records.map { ($0.id, $0) })
    }

    func update(_ record: AccountRecord) throws {
        var records = try load()
        records[record.id] = record
        try StorageSupport.write(
            SnapshotsFile(schemaVersion: 1, records: records.values.sorted { $0.id.directory < $1.id.directory }),
            to: url
        )
    }
}
