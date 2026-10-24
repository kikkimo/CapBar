import Foundation
@testable import CapBarCore

@MainActor func runExternalMCPChecks() {
    for (requested, expected) in [("2025-06-18", "2025-06-18"), ("unknown", "2025-11-25")] {
        let bridge = ExternalMCP { _, _, _ in .failure(500, "UNEXPECTED", "unused") }
        let response = bridge.receive(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string(requested), "capabilities": .object([:]), "clientInfo": .object([:])])]))
        check(response?["result"]["protocolVersion"].string == expected, "MCP negotiates requested version or supported fallback")
    }
    var calls = 0
    var allowed = false
    let mcp = ExternalMCP { method, path, body in
        calls += 1
        if path == "/v1/status" { return ExternalResponse(status: 200, value: .object(["data": .object(["one_shot_refresh_allowed": .bool(allowed)])])) }
        return ExternalResponse(status: 200, value: .object(["data": body]))
    }
    func request(_ method: String, _ params: APIValue = .object([:]), id: Double = 1) -> APIValue? {
        mcp.receive(.object(["jsonrpc": .string("2.0"), "id": .number(id), "method": .string(method), "params": params]))
    }
    check(request("tools/list")?["error"].object != nil, "MCP refuses tools before initialization")
    let initialized = request("initialize", .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])]))
    check(initialized?["result"]["protocolVersion"].string == "2025-11-25", "MCP negotiates supported version")
    let list = request("tools/list")?["result"]["tools"].array ?? []
    check(list.count == 7 && !list.contains { $0["name"].string == "capbar_refresh_once" }, "readonly mode exposes seven read tools")
    allowed = true
    let enabled = request("tools/list")?["result"]["tools"].array ?? []
    check(enabled.count == 8, "one-shot refresh tool only exposed when allowed")
    let result = request("tools/call", .object(["name": .string("capbar_get_quotas"), "arguments": .object(["selector": .object(["all": .bool(true)])])]))
    check(result?["result"]["structuredContent"]["data"]["selector"]["all"].bool == true, "MCP returns structured API result")
    let before = calls
    _ = mcp.receive(.object(["jsonrpc": .string("2.0"), "method": .string("tools/call"), "params": .object(["name": .string("capbar_refresh_once"), "arguments": .object([:])])]))
    check(calls == before, "notification cannot silently trigger a refresh")
    check(request("tools/call", .object(["name": .string("capbar_set_settings"), "arguments": .object([:])]))?["error"].object != nil, "no MCP configuration tools")
}
