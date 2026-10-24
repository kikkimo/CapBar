import Foundation
@testable import CapBarCore

@MainActor func runExternalHTTPChecks() {
    func parse(_ request: String) throws -> ExternalHTTPRequest { try .parse(Data(request.utf8)) }
    do {
        let get = try parse("GET /v1/status HTTP/1.1\r\nHost: capbar.local\r\nAuthorization: Bearer example\r\n\r\n")
        check(get.method == "GET" && get.path == "/v1/status" && get.token == "example", "socket HTTP reads method and bearer token")
        let body = "{\"selector\":{\"all\":true}}"
        let post = try parse("POST /v1/quotas/query HTTP/1.1\r\nHost: capbar.local\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body)
        check(post.body["selector"]["all"].bool == true, "socket HTTP parses bounded JSON body")
        let query = try parse("GET /v1/accounts?provider=claude HTTP/1.1\r\nHost: capbar.local\r\n\r\n")
        check(query.body["provider"].string == "claude", "GET provider query maps to same service schema")
    } catch { check(false, "valid HTTP requests accepted: \(error)") }
    for malformed in [
        "GET /v1/status HTTP/1.1\r\nHost: evil.example\r\n\r\n",
        "GET /v1/status HTTP/1.1\r\nHost: capbar.local\r\nOrigin: https://evil.example\r\n\r\n",
        "POST /v1/refresh-jobs HTTP/1.1\r\nHost: capbar.local\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST /v1/refresh-jobs HTTP/1.1\r\nHost: capbar.local\r\nContent-Length: 2\r\nContent-Length: 0\r\n\r\n{}",
        "POST /v1/refresh-jobs HTTP/1.1\r\nHost: capbar.local\r\nContent-Length: 65537\r\n\r\n",
        "GET /v1/accounts?provider=claude&provider=codex HTTP/1.1\r\nHost: capbar.local\r\n\r\n",
        "GET /v1/status HTTP/1.1\r\nHost: capbar.local\r\n\r\nGET /v1/status HTTP/1.1\r\n\r\n"
    ] { checkThrows("reject malformed, browser-origin or ambiguous HTTP request") { _ = try parse(malformed) } }
}
