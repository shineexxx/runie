import Foundation

// MARK: - Codex

/// Codex от OpenAI вместо Claude Code: тот же чат, те же «руки» и разрешения.
///
/// Говорим с `codex app-server` — JSON-RPC по строкам в stdin/stdout, тот же режим,
/// которым Codex подключают к редакторам. Всё, что здесь знает про его протокол,
/// превращается в общие события `AgentEvent`: лента, разрешения и фоновые
/// разговоры не отличают Codex от Claude Code.
///
/// Инструменты Руни (память, указатель, календарь, свой браузер…) Codex получает
/// как «динамические» — их вызов приходит сюда, Руни спрашивает разрешение по
/// своим правилам и выполняет инструмент у себя. Codex передаёт их только при
/// создании разговора, поэтому продолженный после перезапуска разговор их может
/// не видеть.
public struct CodexBackend: AgentBackend {

    public var executable: URL
    public var workingDirectory: URL?
    /// Дописывается к инструкциям Codex — как `--append-system-prompt` у Claude Code.
    public var developerInstructions: String?
    /// Хвост инструкций, который считается заново при каждом подключении (память).
    public var promptSupplement: (@Sendable () -> String)?
    public var extraEnvironment: (@Sendable () -> [String: String])?
    /// Встроенный MCP-сервер приложения: его инструменты уходят Codex динамическими.
    public var hostToolServer: String?

    public init(executable: URL, workingDirectory: URL? = nil) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    public func connect(resuming sessionID: String?, disallowedTools: [String]) throws -> AgentConnectionHandle {
        var instructions = developerInstructions ?? ""
        if let supplement = promptSupplement?().trimmingCharacters(in: .whitespacesAndNewlines), !supplement.isEmpty {
            instructions = [instructions, supplement].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let runtime = AgentRuntime(configuration: .init(
            executable: executable,
            arguments: ["app-server"],
            workingDirectory: workingDirectory,
            environment: extraEnvironment.map { extra in
                ProcessInfo.processInfo.environment.merging(extra()) { _, new in new }
            }
        ))
        let raw = try runtime.start()
        let connection = CodexConnection(
            runtime: runtime,
            resuming: sessionID,
            instructions: instructions.isEmpty ? nil : instructions,
            workingDirectory: (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path,
            hostToolServer: hostToolServer
        )
        let stream = AsyncStream<AgentStreamItem> { continuation in
            connection.attach(continuation)
            let pump = Task {
                for await output in raw {
                    connection.ingest(output)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        connection.begin()
        return AgentConnectionHandle(connection: connection, stream: stream)
    }
}

/// Живое соединение с `codex app-server`.
final class CodexConnection: AgentConnection, @unchecked Sendable {

    private enum Command {
        case message(UserMessage)
        case control(ControlRequest, String)
    }

    /// О чём Codex спрашивает разрешение — от этого зависит форма ответа.
    private enum Approval {
        case command
        case fileChange
        case permissions(JSONValue)
        case elicitation
        case legacy
        case toolCall(tool: String, arguments: JSONValue)
    }

    private let runtime: AgentRuntime
    private let resuming: String?
    private let instructions: String?
    private let workingDirectory: String
    private let hostToolServer: String?

    private let lock = NSLock()
    private var continuation: AsyncStream<AgentStreamItem>.Continuation?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var mcpPending: [String: CheckedContinuation<JSONValue?, Never>] = [:]
    private var approvals: [String: (rpcID: JSONValue, kind: Approval)] = [:]
    private var fileChanges: [String: JSONValue] = [:]
    private var threadID: String?
    private var model: String?
    private var activeTurn: String?
    private var lastAgentText: String?
    private var context: ContextUsage?
    private var stopped = false

    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation

    init(runtime: AgentRuntime, resuming: String?, instructions: String?, workingDirectory: String, hostToolServer: String?) {
        self.runtime = runtime
        self.resuming = resuming
        self.instructions = instructions
        self.workingDirectory = workingDirectory
        self.hostToolServer = hostToolServer
        (commands, commandSink) = AsyncStream<Command>.makeStream()
    }

    func attach(_ continuation: AsyncStream<AgentStreamItem>.Continuation) {
        lock.withLock { self.continuation = continuation }
    }

    private func emit(_ item: AgentStreamItem) {
        let sink = lock.withLock { continuation }
        sink?.yield(item)
    }

    private func emit(_ event: AgentEvent) {
        emit(.event(event))
    }

    // MARK: AgentConnection

    func send(_ message: UserMessage) throws {
        guard !lock.withLock({ stopped }) else { throw AgentRuntime.Failure.notRunning }
        commandSink.yield(.message(message))
    }

    func send(_ request: ControlRequest, requestID: String) throws {
        guard !lock.withLock({ stopped }) else { throw AgentRuntime.Failure.notRunning }
        commandSink.yield(.control(request, requestID))
    }

    func respondToMCP(_ reply: MCPReply) throws {
        let waiter = lock.withLock { mcpPending.removeValue(forKey: reply.requestID) }
        waiter?.resume(returning: reply.response)
    }

    func respond(to request: PermissionRequest, with decision: PermissionDecision) throws {
        guard let approval = lock.withLock({ approvals.removeValue(forKey: request.requestID) }) else { return }
        let allow = decision == .allow
        switch approval.kind {
        case .command, .fileChange:
            try reply(approval.rpcID, ["decision": .string(allow ? "accept" : "decline")])
        case .permissions(let requested):
            try reply(approval.rpcID, ["permissions": allow ? requested : .object([:]), "scope": .string("turn")])
        case .elicitation:
            try reply(approval.rpcID, [
                "action": .string(allow ? "accept" : "decline"),
                "content": allow ? .object([:]) : .null,
                "_meta": .null
            ])
        case .legacy:
            try reply(approval.rpcID, ["decision": .string(allow ? "approved" : "denied")])
        case .toolCall(let tool, let arguments):
            let rpcID = approval.rpcID
            guard allow else {
                try reply(rpcID, Self.toolReply(text: "Человек не разрешил это действие.", success: false))
                return
            }
            Task {
                let (text, isError) = await self.callHostTool(tool, arguments: arguments)
                try? self.reply(rpcID, Self.toolReply(text: text, success: !isError))
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        commandSink.finish()
        runtime.stop()
    }

    // MARK: Запуск

    func begin() {
        Task {
            do {
                try await handshake()
            } catch {
                emit(.diagnostic("codex: \(error.localizedDescription)"))
                emit(.turnFailed(TurnFailure(reason: "error", message: error.localizedDescription)))
                return
            }
            for await command in commands {
                await perform(command)
            }
        }
    }

    private func handshake() async throws {
        _ = try await request("initialize", [
            "clientInfo": .object(["name": .string("runie"), "title": .string("Runie"), "version": .string("1")]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "requestAttestation": .bool(false),
                "optOutNotificationMethods": .array(["remoteControl/status/changed", "fs/changed"].map(JSONValue.string))
            ])
        ])
        try notify("initialized")

        // Codex сам решает, что безопасно (чтение), а обо всём остальном спрашивает —
        // и тогда решают правила Руни. Одобренное выполняется без песочницы, как в Claude Code.
        var settings: [String: JSONValue] = [
            "cwd": .string(workingDirectory),
            "approvalPolicy": .string("untrusted"),
            "sandbox": .string("danger-full-access")
        ]
        if let instructions { settings["developerInstructions"] = .string(instructions) }

        var result: JSONValue?
        if let resuming {
            var params = settings
            params["threadId"] = .string(resuming)
            params["excludeTurns"] = .bool(true)
            // Разговор, в котором ещё не было хода, Codex не сохраняет — тогда новый.
            result = try? await request("thread/resume", params)
        }
        if result == nil {
            var params = settings
            let tools = await hostTools()
            if !tools.isEmpty { params["dynamicTools"] = .array(tools) }
            result = try await request("thread/start", params)
        }
        guard let thread = result?["thread"], let id = thread["id"]?.stringValue else {
            throw AgentRuntime.Failure.launchFailed("Codex не начал разговор")
        }
        lock.withLock { threadID = id }
        emit(.sessionStarted(SessionInfo(
            sessionID: id,
            model: result?["model"]?.stringValue,
            tools: [],
            workingDirectory: result?["cwd"]?.stringValue,
            permissionMode: nil,
            cliVersion: "codex"
        )))
        // Лимиты подписки — сразу, не дожидаясь первого хода.
        if let limits = try? await request("account/rateLimits/read", [:]) {
            if let usage = Self.subscriptionUsage(limits["rateLimits"]) { emit(.subscriptionUsage(usage)) }
        }
    }

    private func perform(_ command: Command) async {
        switch command {
        case .message(let message):
            await startTurn(message)
        case .control(let request, let requestID):
            await control(request, requestID: requestID)
        }
    }

    private func startTurn(_ message: UserMessage) async {
        guard let threadID = lock.withLock({ threadID }) else { return }
        do {
            // `/compact` из Руни — сжатие разговора средствами Codex.
            if message.text.trimmingCharacters(in: .whitespaces) == "/compact" {
                _ = try await request("thread/compact/start", ["threadId": .string(threadID)])
                return
            }
            var input: [JSONValue] = [.object([
                "type": .string("text"), "text": .string(message.text), "text_elements": .array([])
            ])]
            for image in message.images {
                if let path = Self.temporaryFile(for: image) {
                    input.append(.object(["type": .string("localImage"), "path": .string(path)]))
                }
            }
            var params: [String: JSONValue] = ["threadId": .string(threadID), "input": .array(input)]
            if let model = lock.withLock({ model }) { params["model"] = .string(model) }
            _ = try await request("turn/start", params)
        } catch {
            emit(.turnFailed(TurnFailure(reason: "error", message: error.localizedDescription)))
        }
    }

    private func control(_ request: ControlRequest, requestID: String) async {
        switch request {
        case .initialize, .initializeWithHostServers:
            var models: [JSONValue] = []
            if let list = try? await self.request("model/list", ["includeHidden": .bool(false)]) {
                models = (list["data"]?.arrayValue ?? []).compactMap { entry in
                    guard let value = entry["model"]?.stringValue ?? entry["id"]?.stringValue else { return nil }
                    return .object([
                        "value": .string(value),
                        "displayName": .string(entry["displayName"]?.stringValue ?? value),
                        "description": .string(entry["description"]?.stringValue ?? "")
                    ])
                }
            }
            emit(.controlResponse(ControlResponse(
                requestID: requestID, isSuccess: true,
                body: .object(["models": .array(models), "commands": .array([])]), error: nil
            )))
        case .setModel(let value):
            lock.withLock { model = value == "default" ? nil : value }
            emit(.controlResponse(ControlResponse(requestID: requestID, isSuccess: true, body: nil, error: nil)))
        case .mcpStatus:
            var servers: [JSONValue] = []
            if let list = try? await self.request("mcpServerStatus/list", [:]) {
                let entries = list["data"]?.arrayValue ?? list["servers"]?.arrayValue ?? []
                servers = entries.compactMap { entry in
                    guard let name = entry["name"]?.stringValue else { return nil }
                    return .object([
                        "name": .string(name),
                        "status": .string(Self.mcpStatus(entry["status"]?.stringValue ?? entry["authStatus"]?.stringValue)),
                        "config": .object([:])
                    ])
                }
            }
            emit(.controlResponse(ControlResponse(
                requestID: requestID, isSuccess: true, body: .object(["mcpServers": .array(servers)]), error: nil
            )))
        case .mcpToggle:
            emit(.controlResponse(ControlResponse(requestID: requestID, isSuccess: true, body: nil, error: nil)))
        }
    }

    // MARK: Инструменты Руни

    /// Инструменты встроенного сервера в форме динамических инструментов Codex.
    private func hostTools() async -> [JSONValue] {
        guard hostToolServer != nil,
              let response = await mcp(["method": .string("tools/list")]),
              let tools = response.path("result", "tools")?.arrayValue
        else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            return .object([
                "type": .string("function"),
                "name": .string(name),
                "description": .string(tool["description"]?.stringValue ?? ""),
                "inputSchema": tool["inputSchema"] ?? .object(["type": .string("object")])
            ])
        }
    }

    private func callHostTool(_ tool: String, arguments: JSONValue) async -> (String, Bool) {
        guard let response = await mcp([
            "method": .string("tools/call"),
            "params": .object(["name": .string(tool), "arguments": arguments])
        ]) else { return ("Инструмент не ответил.", true) }
        let result = response["result"]
        let text = (result?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return (text, result?["isError"]?.boolValue ?? false)
    }

    /// Запрос к встроенному серверу через приложение — тем же путём, что у Claude Code.
    private func mcp(_ body: [String: JSONValue]) async -> JSONValue? {
        guard let server = hostToolServer else { return nil }
        let number = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let requestID = "codex-mcp-\(number)"
        var message = body
        message["jsonrpc"] = .string("2.0")
        message["id"] = .int(number)
        return await withCheckedContinuation { (waiter: CheckedContinuation<JSONValue?, Never>) in
            lock.withLock { mcpPending[requestID] = waiter }
            emit(.mcpMessage(MCPMessage(requestID: requestID, serverName: server, message: .object(message))))
            // Приложение не ответило — не висим вечно.
            Task {
                try? await Task.sleep(for: .seconds(120))
                let late = self.lock.withLock { self.mcpPending.removeValue(forKey: requestID) }
                late?.resume(returning: nil)
            }
        }
    }

    private static func toolReply(text: String, success: Bool) -> [String: JSONValue] {
        [
            "contentItems": .array([.object(["type": .string("inputText"), "text": .string(text)])]),
            "success": .bool(success)
        ]
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        return try await withCheckedThrowingContinuation { waiter in
            lock.withLock { pending[id] = waiter }
            do {
                try write(.object(["id": .int(id), "method": .string(method), "params": .object(params)]))
            } catch {
                let waiting = lock.withLock { pending.removeValue(forKey: id) }
                waiting?.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String) throws {
        try write(.object(["method": .string(method)]))
    }

    private func reply(_ id: JSONValue, _ result: [String: JSONValue]) throws {
        try write(.object(["id": id, "result": .object(result)]))
    }

    private func write(_ message: JSONValue) throws {
        var line = Data(message.jsonString().utf8)
        line.append(UInt8(ascii: "\n"))
        try runtime.sendLine(line)
    }

    struct RPCError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Входящее

    func ingest(_ output: RuntimeOutput) {
        switch output {
        case .event(let raw):
            let message = raw.payload
            if let method = message["method"]?.stringValue {
                if let id = message["id"] {
                    serverRequest(method, id: id, params: message["params"] ?? .object([:]))
                } else {
                    notification(method, params: message["params"] ?? .object([:]))
                }
            } else if let id = message["id"]?.intValue {
                let waiter = lock.withLock { pending.removeValue(forKey: id) }
                if let error = message["error"] {
                    waiter?.resume(throwing: RPCError(message: error["message"]?.stringValue ?? "ошибка Codex"))
                } else {
                    waiter?.resume(returning: message["result"] ?? .null)
                }
            }
        case .malformedLine(let line):
            emit(.diagnostic("codex stdout: \(line)"))
        case .diagnostic(let line):
            emit(.diagnostic(line))
        case .terminated(let code, let reason):
            let (waiters, tools) = lock.withLock { () -> ([CheckedContinuation<JSONValue, Error>], [CheckedContinuation<JSONValue?, Never>]) in
                stopped = true
                defer { pending.removeAll(); mcpPending.removeAll() }
                return (Array(pending.values), Array(mcpPending.values))
            }
            waiters.forEach { $0.resume(throwing: AgentRuntime.Failure.notRunning) }
            tools.forEach { $0.resume(returning: nil) }
            commandSink.finish()
            emit(.ended(exitCode: code, stoppedByUser: reason == .stopped))
        }
    }

    private func notification(_ method: String, params: JSONValue) {
        switch method {
        case "turn/started":
            lock.withLock { activeTurn = params.path("turn", "id")?.stringValue }
        case "item/started":
            if let item = params["item"] { itemStarted(item) }
        case "item/completed":
            if let item = params["item"] { itemCompleted(item) }
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue {
                emit(.textDelta(TextDelta(blockIndex: 0, text: delta, parentToolUseID: nil)))
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            if let window = usage?["modelContextWindow"]?.intValue, window > 0,
               let used = usage?.path("last", "totalTokens")?.intValue ?? usage?.path("last", "inputTokens")?.intValue {
                lock.withLock { context = ContextUsage(used: used, window: window) }
            }
        case "turn/completed":
            turnCompleted(params["turn"] ?? .null)
        case "serverRequest/resolved":
            if let requestID = params["requestId"] {
                let resolved = lock.withLock { () -> [String] in
                    let keys = approvals.filter { $0.value.rpcID == requestID }.map(\.key)
                    keys.forEach { approvals.removeValue(forKey: $0) }
                    return keys
                }
                resolved.forEach { emit(.permissionRequestCancelled(requestID: $0)) }
            }
        case "account/rateLimits/updated":
            if let usage = Self.subscriptionUsage(params["rateLimits"]) { emit(.subscriptionUsage(usage)) }
        case "error":
            if params["willRetry"]?.boolValue != true {
                emit(.diagnostic("codex error: \(params.path("error", "message")?.stringValue ?? "")"))
            }
        default:
            break
        }
    }

    private func turnCompleted(_ turn: JSONValue) {
        let (text, usage) = lock.withLock { () -> (String?, ContextUsage?) in
            activeTurn = nil
            defer { lastAgentText = nil }
            return (lastAgentText, context)
        }
        if turn["status"]?.stringValue == "failed" {
            let error = turn["error"]
            let info = error?["codexErrorInfo"]
            let reason = info?.stringValue ?? info?.objectValue?.keys.first ?? "error"
            emit(.turnFailed(TurnFailure(reason: reason, message: error?["message"]?.stringValue)))
        } else {
            emit(.turnCompleted(TurnSummary(
                result: text,
                durationMilliseconds: turn["durationMs"]?.intValue,
                costUSD: nil,
                turnCount: nil,
                permissionDenialCount: 0,
                context: usage
            )))
        }
    }

    private func itemStarted(_ item: JSONValue) {
        guard let id = item["id"]?.stringValue else { return }
        switch item["type"]?.stringValue {
        case "agentMessage":
            emit(.messageStarted(messageID: id, parentToolUseID: nil))
        case "reasoning":
            emit(.thinking(parentToolUseID: nil))
        case "commandExecution":
            let command = Self.unwrapShell(item["command"]?.stringValue ?? "")
            emit(.toolUse(ToolUse(id: id, name: "Bash", input: .object(["command": .string(command)]), parentToolUseID: nil)))
        case "fileChange":
            let changes = item["changes"] ?? .array([])
            lock.withLock { fileChanges[id] = changes }
            let (name, input) = Self.fileTool(changes)
            emit(.toolUse(ToolUse(id: id, name: name, input: input, parentToolUseID: nil)))
        case "mcpToolCall":
            let name = "mcp__\(item["server"]?.stringValue ?? "server")__\(item["tool"]?.stringValue ?? "tool")"
            emit(.toolUse(ToolUse(id: id, name: name, input: item["arguments"] ?? .object([:]), parentToolUseID: nil)))
        case "dynamicToolCall":
            let name = "mcp__\(hostToolServer ?? "runie")__\(item["tool"]?.stringValue ?? "tool")"
            emit(.toolUse(ToolUse(id: id, name: name, input: item["arguments"] ?? .object([:]), parentToolUseID: nil)))
        case "webSearch":
            let query = item["query"]?.stringValue ?? item.path("action", "query")?.stringValue ?? ""
            emit(.toolUse(ToolUse(id: id, name: "WebSearch", input: .object(["query": .string(query)]), parentToolUseID: nil)))
        case "imageGeneration":
            emit(.toolUse(ToolUse(id: id, name: "ImageGeneration", input: .object([:]), parentToolUseID: nil)))
        case "contextCompaction":
            emit(.progress(t("Сжимаю разговор…")))
        default:
            break
        }
    }

    private func itemCompleted(_ item: JSONValue) {
        guard let id = item["id"]?.stringValue else { return }
        let status = item["status"]?.stringValue
        switch item["type"]?.stringValue {
        case "agentMessage":
            let text = item["text"]?.stringValue ?? ""
            lock.withLock { lastAgentText = text }
            emit(.assistantText(AssistantText(text: text, messageID: id, parentToolUseID: nil)))
        case "commandExecution":
            let failed = status != "completed" || (item["exitCode"]?.intValue ?? 0) != 0
            emit(.toolResult(ToolResult(
                toolUseID: id, isError: failed,
                text: item["aggregatedOutput"]?.stringValue ?? "", parentToolUseID: nil
            )))
        case "fileChange":
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            emit(.toolResult(ToolResult(
                toolUseID: id, isError: status != "completed",
                text: paths.joined(separator: "\n"), parentToolUseID: nil
            )))
        case "mcpToolCall":
            let content = (item.path("result", "content")?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            let error = item.path("error", "message")?.stringValue
            emit(.toolResult(ToolResult(
                toolUseID: id, isError: error != nil || status == "failed",
                text: error ?? content.joined(separator: "\n"), parentToolUseID: nil
            )))
        case "dynamicToolCall":
            let content = (item["contentItems"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            emit(.toolResult(ToolResult(
                toolUseID: id, isError: item["success"]?.boolValue == false,
                text: content.joined(separator: "\n"), parentToolUseID: nil
            )))
        case "webSearch":
            emit(.toolResult(ToolResult(toolUseID: id, isError: false, text: item["query"]?.stringValue ?? "", parentToolUseID: nil)))
        case "imageGeneration":
            let path = item["savedPath"]?.stringValue
            emit(.toolResult(ToolResult(
                toolUseID: id, isError: path == nil && item["failure"] != nil && item["failure"] != .null,
                text: path ?? item["revisedPrompt"]?.stringValue ?? "", parentToolUseID: nil
            )))
        case "contextCompaction":
            // Сжатие вне хода: Codex не пришлёт `turn/completed`, а Руни ждёт конца хода.
            if lock.withLock({ activeTurn }) == nil {
                emit(.turnCompleted(TurnSummary(
                    result: nil, durationMilliseconds: nil, costUSD: nil, turnCount: nil, permissionDenialCount: 0
                )))
            }
        default:
            break
        }
    }

    private func serverRequest(_ method: String, id: JSONValue, params: JSONValue) {
        let requestID = "codex-\(id.jsonString())"
        func ask(_ kind: Approval, tool: String, input: JSONValue, toolUseID: String?) {
            lock.withLock { approvals[requestID] = (id, kind) }
            emit(.permissionRequested(PermissionRequest(
                requestID: requestID, toolUseID: toolUseID, toolName: tool, input: input,
                reason: params["reason"]?.stringValue
            )))
        }
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let raw = params["command"]?.stringValue
                ?? (params["command"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " ")
            ask(method == "execCommandApproval" ? .legacy : .command,
                tool: "Bash", input: .object(["command": .string(Self.unwrapShell(raw))]),
                toolUseID: params["itemId"]?.stringValue)
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let itemID = params["itemId"]?.stringValue ?? ""
            let changes = lock.withLock { fileChanges[itemID] } ?? params["changes"] ?? .array([])
            let (name, input) = Self.fileTool(changes)
            ask(method == "applyPatchApproval" ? .legacy : .fileChange, tool: name, input: input, toolUseID: itemID)
        case "item/permissions/requestApproval":
            ask(.permissions(params["permissions"] ?? .object([:])),
                tool: "Bash", input: .object(["command": .string(params["reason"]?.stringValue ?? "")]),
                toolUseID: params["itemId"]?.stringValue)
        case "mcpServer/elicitation/request":
            ask(.elicitation, tool: "mcp__\(params["serverName"]?.stringValue ?? "server")",
                input: .object(["message": params["message"] ?? .null]), toolUseID: nil)
        case "item/tool/call":
            let tool = params["tool"]?.stringValue ?? ""
            let arguments = params["arguments"] ?? .object([:])
            ask(.toolCall(tool: tool, arguments: arguments),
                tool: "mcp__\(hostToolServer ?? "runie")__\(tool)", input: arguments,
                toolUseID: params["callId"]?.stringValue)
        case "item/tool/requestUserInput":
            // Вопросы человеку Руни задаёт своим инструментом ask_user — здесь отвечаем пусто.
            try? reply(id, ["answers": .object([:])])
        default:
            try? write(.object(["id": id, "error": .object([
                "code": .int(-32601), "message": .string("Runie does not support \(method)")
            ])]))
        }
    }

    // MARK: Мелочи

    /// `/bin/zsh -lc 'ls -la'` → `ls -la`: правила разрешений смотрят на саму команду.
    static func unwrapShell(_ command: String) -> String {
        let pattern = #"^(?:/bin/|/usr/bin/)?(?:ba|z)?sh\s+-l?c\s+(['"])([\s\S]*)\1\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 2), in: command)
        else { return command }
        return String(command[range])
    }

    /// Правка файлов как инструмент Claude Code: новый файл — `Write`, остальное — `Edit`.
    static func fileTool(_ changes: JSONValue) -> (String, JSONValue) {
        let list = changes.arrayValue ?? []
        let path = list.first?["path"]?.stringValue ?? ""
        let added = list.first?.path("kind", "type")?.stringValue == "add"
        var input: [String: JSONValue] = ["file_path": .string(path)]
        if list.count > 1 { input["files"] = .int(list.count) }
        if let diff = list.first?["diff"]?.stringValue { input[added ? "content" : "diff"] = .string(diff) }
        return (added ? "Write" : "Edit", .object(input))
    }

    static func mcpStatus(_ codex: String?) -> String {
        switch codex?.lowercased() {
        case "ready", "connected", "running": "connected"
        case "starting", "pending": "pending"
        case "failed", "error": "failed"
        case "notloggedin", "unauthenticated", "needsauth": "needs-auth"
        default: "connected"
        }
    }

    /// Лимиты Codex в той же форме, что у Claude: основное окно — «пять часов».
    static func subscriptionUsage(_ limits: JSONValue?) -> SubscriptionUsage? {
        guard let limits else { return nil }
        var windows: [SubscriptionUsage.Window] = []
        for (key, kind) in [("primary", "five_hour"), ("secondary", "seven_day")] {
            guard let window = limits[key], let percent = window["usedPercent"]?.doubleValue else { continue }
            let resets = window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            windows.append(SubscriptionUsage.Window(kind: kind, utilization: percent / 100, resetsAt: resets))
        }
        guard !windows.isEmpty else { return nil }
        return SubscriptionUsage(status: "allowed", windows: windows)
    }

    /// Картинку из сообщения Codex принимает файлом.
    static func temporaryFile(for image: MessageImage) -> String? {
        let ext = switch image.mediaType {
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "png"
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "runie-codex-\(UUID().uuidString).\(ext)")
        do {
            try image.data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}
