import Foundation
import CoreFoundation

private struct RPCError: Error {
    let code: Int
    let message: String
}

@MainActor struct JSONRPCServer {
    let colorTools: ColorTools

    func run() throws {
        while let line = readLine() {
            if let response = response(to: line) {
                let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }

    private func response(to line: String) -> [String: Any]? {
        var id: Any = NSNull()
        var notification = false
        do {
            let value: Any
            do { value = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) }
            catch { throw RPCError(code: -32700, message: "Parse error: \(error)") }
            guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0",
                  let method = request["method"] as? String else {
                throw RPCError(code: -32600, message: "Invalid JSON-RPC request")
            }
            if let requestID = request["id"] {
                guard validID(requestID) else { throw RPCError(code: -32600, message: "Invalid request ID") }
                id = requestID
            } else {
                notification = true
            }
            guard request["params"] == nil || request["params"] is [String: Any] else {
                throw RPCError(code: -32602, message: "params must be an object")
            }
            if notification { return nil }
            let result = try dispatch(method, params: request["params"] as? [String: Any] ?? [:])
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch {
            if notification { return nil }
            let rpc = error as? RPCError ?? RPCError(code: -32603, message: String(reflecting: error))
            return ["jsonrpc": "2.0", "id": id, "error": ["code": rpc.code, "message": rpc.message]]
        }
    }

    private func validID(_ id: Any) -> Bool {
        if id is String || id is NSNull { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private func dispatch(_ method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            guard params["protocolVersion"] is String, params["capabilities"] is [String: Any],
                  let client = params["clientInfo"] as? [String: Any], client["name"] is String,
                  client["version"] is String else {
                throw RPCError(code: -32602, message: "initialize requires protocolVersion, capabilities and clientInfo")
            }
            return ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "keeps-color", "version": "0.1.0"]]
        case "ping": return [:]
        case "tools/list": return ["tools": tools.map { definition in
            var tool = definition
            let name = definition["name"] as? String ?? ""
            tool["annotations"] = ["readOnlyHint": name != "set_adjustments", "destructiveHint": false, "openWorldHint": false, "idempotentHint": true]
            return tool
        }]
        case "tools/call": return try callTool(params)
        default: throw RPCError(code: -32601, message: "Unknown method \(method)")
        }
    }

    private func callTool(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String,
              tools.contains(where: { $0["name"] as? String == name }),
              params["arguments"] == nil || params["arguments"] is [String: Any] else {
            throw RPCError(code: -32602, message: "tools/call requires a known tool name and object arguments")
        }
        do { return ["content": try colorTools.call(name, params["arguments"] as? [String: Any] ?? [:])] }
        catch { return ["content": [["type": "text", "text": String(reflecting: error)]], "isError": true] }
    }
}
