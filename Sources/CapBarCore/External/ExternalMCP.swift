import Foundation

final class ExternalMCP {
    let call: (String, String, APIValue) -> ExternalResponse
    private var initialized = false
    init(call: @escaping (String, String, APIValue) -> ExternalResponse) { self.call = call }

    func receive(_ value: APIValue) -> APIValue? {
        let id = value["id"]
        guard value["jsonrpc"].string == "2.0", let method = value["method"].string else {
            return error(id: id, code: -32600, message: "Invalid JSON-RPC request")
        }
        // tools/call is a request, never an executable notification.
        guard value.object?["id"] != nil else { return nil }
        guard id.string != nil || id.number != nil else { return error(id: .null, code: -32600, message: "Invalid request id") }
        let params = value.object?["params"] ?? .object([:])
        let result: APIValue
        switch method {
        case "initialize":
            guard !initialized, params["protocolVersion"].string != nil,
                  params["capabilities"].object != nil, params["clientInfo"].object != nil else {
                return error(id: id, code: -32602, message: "Invalid initialization")
            }
            initialized = true
            result = .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("capbar"), "version": .string("1.0.0")]),
                "instructions": .string("查询仅读取已有数据。只有用户要求更新且已开启许可时，才调用单次刷新；不可创建定时任务或修改配置。")
            ])
        case "ping": result = .object([:])
        default:
            guard initialized else { return error(id: id, code: -32002, message: "Initialize first") }
            switch method {
            case "tools/list":
                guard (try? params.fields(["_meta"])) != nil else { return error(id: id, code: -32602, message: "Invalid parameters") }
                let status = call("GET", "/v1/status", .object([:]))
                let refresh = status.value["data"]["one_shot_refresh_allowed"].bool == true
                result = .object(["tools": .array(Self.tools(refreshAllowed: refresh))])
            case "tools/call":
                guard (try? params.fields(["name", "arguments", "_meta"], required: ["name"])) != nil,
                      let name = params["name"].string else { return error(id: id, code: -32602, message: "Invalid tool call") }
                let arguments = params.object?["arguments"] ?? .object([:])
                guard arguments.object != nil else { return error(id: id, code: -32602, message: "Arguments must be an object") }
                let method: String, route: String, body: APIValue
                switch name {
                case "capbar_get_status": method = "GET"; route = "/v1/status"; body = arguments
                case "capbar_list_accounts": method = "GET"; route = "/v1/accounts"; body = arguments
                case "capbar_get_quotas": method = "POST"; route = "/v1/quotas/query"; body = arguments
                case "capbar_get_usage": method = "POST"; route = "/v1/usage/query"; body = arguments
                case "capbar_get_statistics": method = "POST"; route = "/v1/statistics/query"; body = arguments
                case "capbar_get_records": method = "POST"; route = "/v1/records/query"; body = arguments
                case "capbar_refresh_once": method = "POST"; route = "/v1/refresh-jobs"; body = arguments
                case "capbar_get_refresh_status":
                    guard (try? arguments.fields(["job_id"], required: ["job_id"])) != nil,
                          let job = arguments["job_id"].string, job.hasPrefix("job_"),
                          UUID(uuidString: String(job.dropFirst(4))) != nil else { return error(id: id, code: -32602, message: "Invalid job_id") }
                    method = "GET"; route = "/v1/refresh-jobs/" + job; body = .object([:])
                default: return error(id: id, code: -32602, message: "Unknown tool")
                }
                let response = call(method, route, body)
                result = .object([
                    "isError": .bool(response.status >= 400), "structuredContent": response.value,
                    "content": .array([.object(["type": .string("text"), "text": .string(String(decoding: response.value.encoded(), as: UTF8.self))])])
                ])
            default: return error(id: id, code: -32601, message: "Method not found")
            }
        }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    func error(id: APIValue, code: Int, message: String) -> APIValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    static func schema(_ fields: [String: APIValue], required: [String] = []) -> APIValue {
        .object(["type": .string("object"), "properties": .object(fields), "required": .array(required.map(APIValue.string)), "additionalProperties": .bool(false)])
    }
    static func tools(refreshAllowed: Bool) -> [APIValue] {
        let string: APIValue = .object(["type": .string("string")])
        let provider: APIValue = .object(["type": .string("string"), "enum": .array([.string("claude"), .string("codex")])])
        let selector: APIValue = .object(["oneOf": .array([
            schema(["all": .object(["const": .bool(true)])], required: ["all"]),
            schema(["provider": provider], required: ["provider"]),
            schema(["account_ids": .object(["type": .string("array"), "items": string, "minItems": .number(1), "maxItems": .number(200)])], required: ["account_ids"])
        ])])
        let target: APIValue = .object(["oneOf": .array([
            schema(["account_id": string], required: ["account_id"]), schema(["provider": provider], required: ["provider"])
        ])])
        var definitions: [(String, String, APIValue)] = [
            ("capbar_get_status", "只读查询 CapBar 状态、instance_id 和是否允许单次刷新，不发起探测。", schema([:])),
            ("capbar_list_accounts", "只读列出已配置账号的 ID、邮箱、组织和套餐，不返回目录或凭据。", schema(["provider": provider])),
            ("capbar_get_quotas", "只读查询上次额度快照与采集时间；数据陈旧也不会自动刷新。", schema(["selector": selector], required: ["selector"])),
            ("capbar_get_usage", "只读查询近七日区间用量；provider 汇总以首账号为基准，缺测保留 null。", schema(["target": target, "include_contributions": .object(["type": .string("boolean")])], required: ["target"])),
            ("capbar_get_statistics", "只读查询服务的近七日统计、贡献最多账号和高低用量时段。", schema(["provider": provider], required: ["provider"])),
            ("capbar_get_records", "只读查询历史纪录；连续七个已结束本地自然日，缺测计零。", schema(["provider": provider], required: ["provider"])),
            ("capbar_get_refresh_status", "只读查询一次刷新任务进度，不重复刷新。终态后停止轮询。", schema(["job_id": string], required: ["job_id"]))
        ]
        if refreshAllowed {
            definitions.append(("capbar_refresh_once", "用户要求更新时发起一次刷新，可能消耗少量 token；不设置定时任务。先获取 instance_id，每次逻辑请求生成 UUID request_key，网络重试复用同一键。", schema([
                "selector": selector, "instance_id": string,
                "request_key": .object(["type": .string("string"), "format": .string("uuid")])
            ], required: ["selector", "instance_id", "request_key"])))
        }
        return definitions.map { name, description, input in .object([
            "name": .string(name), "description": .string(description), "inputSchema": input,
            "outputSchema": .object(["type": .string("object"), "properties": .object([
                "api_version": .object(["const": .string("v1")]), "request_id": string,
                "generated_at": string, "data": .object(["type": .string("object")]),
                "error": .object(["type": .string("object")]), "warnings": .object(["type": .string("array")])
            ])]),
            "annotations": .object(["readOnlyHint": .bool(name != "capbar_refresh_once"),
                "destructiveHint": .bool(false), "idempotentHint": .bool(true), "openWorldHint": .bool(name == "capbar_refresh_once")])
        ]) }
    }
}

public enum CapBarMCPLauncher {
    public static func run() {
        if CommandLine.arguments.contains("--self-check") { print("CapBar MCP OK"); return }
        let mcp = ExternalMCP { method, route, body in
            do {
                let token = try ExternalCredentials.load()
                return try UnixHTTPClient.call(path: ExternalCredentials.socketPath, token: token, method: method, route: route, body: body)
            } catch { return .failure(503, "SERVICE_UNAVAILABLE", "请启动 CapBar 并开启外部访问") }
        }
        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let frame = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard frame.count <= 65536 else { return }
                let response: APIValue?
                if let value = try? JSONDecoder().decode(APIValue.self, from: frame) { response = mcp.receive(value) }
                else { response = mcp.error(id: .null, code: -32700, message: "Invalid JSON") }
                if let response { FileHandle.standardOutput.write(response.encoded() + Data([10])) }
            }
            if buffer.count > 65536 { return }
        }
    }
}
