import Foundation
import Security
import Darwin

struct ExternalIdentityRegistry: Codable {
    struct Entry: Codable { let account: AccountID; let id: String }
    var entries: [Entry] = []
    mutating func synchronize(_ accounts: [AccountID], url: URL) throws {
        var changed = false
        for account in accounts where !entries.contains(where: { $0.account == account }) {
            entries.append(Entry(account: account, id: "acc_" + UUID().uuidString.lowercased()))
            changed = true
        }
        if changed { try StorageSupport.write(self, to: url) }
    }
    func id(_ account: AccountID) -> String { entries.first { $0.account == account }!.id }
}

struct ExternalCredentials {
    static var directory: URL { StorageSupport.appSupportURL("ExternalAccess") }
    static var socketDirectory: String { "/tmp/capbar-\(getuid())" }
    static var socketPath: String { socketDirectory + "/api.sock" }
    static func prepareDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        } else {
            guard mkdir(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
    }
    static func load(directory: URL = directory) throws -> String {
        let file = directory.appendingPathComponent("token")
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        guard lstat(file.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let value = try String(contentsOf: file, encoding: .utf8)
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    static func create(directory: URL = directory, rotate: Bool = false) throws -> String {
        try prepareDirectory(directory)
        if !rotate, FileManager.default.fileExists(atPath: directory.appendingPathComponent("token").path) {
            return try load(directory: directory)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        for (name, content) in [("token", token), ("authorization.header", "Authorization: Bearer " + token + "\n")] {
            let file = directory.appendingPathComponent(name)
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporary.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            guard rename(temporary.path, file.path) == 0 else { try? FileManager.default.removeItem(at: temporary); throw CocoaError(.fileWriteUnknown) }
        }
        return token
    }
    static func matches(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
