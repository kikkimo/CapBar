import Foundation
import Darwin

struct ExternalHTTPRequest {
    let method: String
    let path: String
    let token: String
    let body: APIValue
    static let headerLimit = 16 * 1024
    static let bodyLimit = 64 * 1024

    static func header(_ data: Data) throws -> (String, String, [String: String], Int, Int)? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > headerLimit { throw APIError.argument }; return nil
        }
        guard split.upperBound <= headerLimit,
              let text = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw APIError.argument }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(first[0]),
              first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw APIError.argument }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw APIError.argument }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil else { throw APIError.argument }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "capbar.local", headers["origin"] == nil,
              headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw APIError.argument }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(raw) else { throw APIError.argument }
            guard number <= bodyLimit else { throw APIError(status: 413, code: "REQUEST_TOO_LARGE", message: "请求体超过限制") }
            length = number
        } else { length = 0 }
        return (String(first[0]), String(first[1]), headers, split.upperBound, length)
    }
    static func parse(_ data: Data) throws -> Self {
        guard let (method, target, headers, offset, length) = try header(data), data.count == offset + length,
              let parts = URLComponents(string: "http://capbar.local" + target), parts.fragment == nil else { throw APIError.argument }
        let body: APIValue
        if method == "GET" {
            guard length == 0 else { throw APIError.argument }
            var fields: [String: APIValue] = [:]
            for item in parts.queryItems ?? [] {
                guard fields[item.name] == nil, let value = item.value else { throw APIError.argument }
                fields[item.name] = .string(value)
            }
            body = .object(fields)
        } else {
            guard parts.query == nil, headers["content-type"]?.lowercased().split(separator: ";").first == "application/json", length > 0 else { throw APIError.argument }
            do { body = try JSONDecoder().decode(APIValue.self, from: Data(data[offset...])) }
            catch { throw APIError.argument }
            guard body.object != nil else { throw APIError.argument }
        }
        let auth = headers["authorization"] ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        return Self(method: method, path: parts.path, token: token, body: body)
    }
}

enum UnixSocketIO {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw APIError.argument }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func configure(_ fd: Int32) {
        // Darwin accepts can inherit O_NONBLOCK from the listening descriptor.
        // Each bounded worker needs blocking I/O with the timeouts below.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += n
            }
        }
    }
    static func receiveRequest(_ fd: Int32) throws -> ExternalHTTPRequest {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(8)
        while data.count <= ExternalHTTPRequest.headerLimit + ExternalHTTPRequest.bodyLimit {
            guard Date() < deadline else { throw APIError.argument }
            let n = recv(fd, &bytes, bytes.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw APIError.argument }
            data.append(contentsOf: bytes[..<n])
            if let h = try ExternalHTTPRequest.header(data), data.count >= h.3 + h.4 { return try .parse(data) }
        }
        throw APIError.argument
    }
    static func response(_ response: ExternalResponse) -> Data {
        let body = response.value.encoded()
        let phrase = response.status < 300 ? "OK" : "Error"
        let retry = response.status == 429 || response.status == 503 ? "Retry-After: 5\r\n" : ""
        return Data("HTTP/1.1 \(response.status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(retry)\r\n".utf8) + body
    }
}

// Only descriptor lifecycle is lock-protected; async application state lives in ExternalService.
final class UnixHTTPServer: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let fd: Int32
    private let lock = NSLock()
    private var connections = 0
    private var stopped = false
    private let handler: @Sendable (ExternalHTTPRequest) async -> ExternalResponse

    init(path: String, handler: @escaping @Sendable (ExternalHTTPRequest) async -> ExternalResponse) throws {
        self.handler = handler
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try ExternalCredentials.prepareDirectory(parent)
        let lockFD = open(parent.appendingPathComponent("server.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); throw CocoaError(.fileLocking)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { close(lockFD); throw CocoaError(.fileWriteUnknown) }
        do {
            var address = try UnixSocketIO.address(path)
            if lstat(path, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw CocoaError(.fileWriteNoPermission) }
                guard unlink(path) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            }
            let result = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else { throw CocoaError(.fileWriteUnknown) }
            UnixSocketIO.configure(descriptor)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        } catch { close(descriptor); close(lockFD); throw error }
        fd = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "CapBar.ExternalAccept"))
        source.setEventHandler { [weak self] in self?.acceptAvailable() }
        source.setCancelHandler { close(descriptor); unlink(path); close(lockFD) }
        source.resume()
    }
    func stop() { lock.lock(); stopped = true; lock.unlock(); source.cancel() }
    deinit { source.cancel() }
    private func acceptAvailable() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            lock.lock()
            let permitted = !stopped && connections < 16
            if permitted { connections += 1 }
            lock.unlock()
            guard permitted else { close(client); continue }
            UnixSocketIO.configure(client)
            // Blocking socket I/O belongs to a bounded GCD worker, never the main actor.
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { close(client); lock.lock(); connections -= 1; lock.unlock() }
                let response: ExternalResponse
                do {
                    let request = try UnixSocketIO.receiveRequest(client)
                    let box = ResponseBox()
                    let done = DispatchSemaphore(value: 0)
                    Task { box.set(await self.handler(request)); done.signal() }
                    if done.wait(timeout: .now() + 10) == .success, let result = box.get() { response = result }
                    else { response = .failure(503, "SERVICE_UNAVAILABLE", "请求超时，请读取状态后重试") }
                } catch let error as APIError { response = .failure(error.status, error.code, error.message) }
                catch { response = .failure(400, "INVALID_ARGUMENT", "无效的本地请求") }
                try? UnixSocketIO.write(UnixSocketIO.response(response), to: client)
            }
        }
    }
    private final class ResponseBox: @unchecked Sendable {
        let lock = NSLock(); var value: ExternalResponse?
        func set(_ v: ExternalResponse) { lock.lock(); value = v; lock.unlock() }
        func get() -> ExternalResponse? { lock.lock(); defer { lock.unlock() }; return value }
    }
}

enum UnixHTTPClient {
    static func call(path: String, token: String, method: String, route: String, body: APIValue = .object([:])) throws -> ExternalResponse {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0,
              lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        UnixSocketIO.configure(fd)
        var address = try UnixSocketIO.address(path)
        let connected = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw CocoaError(.fileReadNoPermission) }
        var target = route
        if method == "GET", let fields = body.object, !fields.isEmpty {
            var components = URLComponents(); components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value.string) }
            target += "?" + (components.percentEncodedQuery ?? "")
        }
        let payload = method == "GET" ? Data() : body.encoded()
        let headers = "\(method) \(target) HTTP/1.1\r\nHost: capbar.local\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        try UnixSocketIO.write(Data(headers.utf8) + payload, to: fd)
        var response = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while response.count <= 4 * 1024 * 1024 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n == 0 { break }
            guard n > 0 else { throw CocoaError(.fileReadUnknown) }
            response.append(contentsOf: buffer[..<n])
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: response[..<split.lowerBound], encoding: .utf8),
              let code = header.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw CocoaError(.fileReadCorruptFile) }
        return ExternalResponse(status: code, value: try JSONDecoder().decode(APIValue.self, from: response[split.upperBound...]))
    }
}
