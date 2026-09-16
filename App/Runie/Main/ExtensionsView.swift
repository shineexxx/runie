import RunieKit
import SwiftUI

/// Навыки и MCP-серверы Claude Code — посмотреть, включить, выключить, добавить.
struct ExtensionsView: View {
    let session: ChatSession
    let settings: AppSettings

    @State private var query = ""
    @State private var showsAddServer = false
    @State private var pendingRemoval: MCPServerInfo?
    @State private var removalError: String?

    var body: some View {
        Form {
            serversSection
            skillsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(BrandGlowBackground())
        .onAppear { session.refreshExtensions() }
        // Серверы поднимаются не сразу: пока кто-то «подключается», переспрашиваем.
        .task {
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                guard session.mcpServers.isEmpty || session.mcpServers.contains(where: { $0.status == .pending }) else { break }
                session.refreshExtensions()
            }
        }
        .sheet(isPresented: $showsAddServer) {
            AddServerSheet { session.reloadAgent(); session.refreshExtensions() }
        }
        .confirmationDialog(
            "Удалить сервер?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { server in
            Button("Удалить", role: .destructive) { remove(server) }
        } message: { server in
            Text("«\(server.name)» пропадёт из Claude Code — и в Runie, и в терминале.")
        }
        .alert("Не получилось", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("Понятно") { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    // MARK: Серверы

    private var serversSection: some View {
        Section {
            if session.mcpServers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Спрашиваю Claude Code…").foregroundStyle(.secondary)
                }
            }
            ForEach(session.mcpServers) { server in
                ServerRow(
                    server: server,
                    onToggle: { session.setMCPServer(server.name, enabled: $0) },
                    onRemove: server.isRemovable ? { pendingRemoval = server } : nil
                )
            }
        } header: {
            HStack {
                Text("MCP-серверы")
                Spacer()
                Button {
                    session.refreshExtensions()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button {
                    showsAddServer = true
                } label: {
                    Label("Добавить…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Серверы дают Руни новые возможности: Notion, GitHub, Slack и другие. Это настройки самого Claude Code — выключенный здесь сервер выключается и в Claude Code, запущенном из домашней папки. Коннекторы claude.ai подключаются на claude.ai в разделе «Коннекторы».")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remove(_ server: MCPServerInfo) {
        pendingRemoval = nil
        Task {
            let result = await ClaudeCLI.run(["mcp", "remove", "--scope", server.scope ?? "user", server.name])
            if result.status != 0 {
                removalError = result.output.isEmpty ? "Claude Code не удалил сервер." : result.output
            }
            session.reloadAgent()
            session.refreshExtensions()
        }
    }

    // MARK: Навыки

    private var skills: [SkillInfo] {
        let all = session.skillInfos
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || ($0.description ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var skillsSection: some View {
        Section {
            TextField("Найти навык", text: $query)
                .textFieldStyle(.roundedBorder)
            if session.skillInfos.isEmpty {
                Text("Навыков пока нет. Навыки лежат в папке ~/.claude/skills.")
                    .foregroundStyle(.secondary)
            }
            ForEach(skills) { skill in
                SkillRow(
                    skill: skill,
                    isEnabled: Binding(
                        get: { !settings.disabledSkills.contains(skill.name) },
                        set: { enabled in
                            if enabled { settings.disabledSkills.remove(skill.name) } else { settings.disabledSkills.insert(skill.name) }
                        }
                    )
                )
            }
        } header: {
            Text("Навыки · \(session.skillInfos.count)")
        } footer: {
            Text("Навык — инструкция, которую Руни подгружает для особых задач. Выключенный навык недоступен только в Runie, в Claude Code он остаётся. Изменения применяются, когда Руни свободен.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension MCPServerInfo {
    /// Встроенный сервер Runie — тот, что живёт в самом приложении.
    var isRunie: Bool { transport == "sdk" || name == RunieTools.server.name }

    /// Свои серверы можно удалить; коннекторы claude.ai и серверы плагинов — нет.
    var isRemovable: Bool {
        scope == "user" || scope == "local" || scope == "project"
    }
}

private struct ServerRow: View {
    let server: MCPServerInfo
    let onToggle: (Bool) -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OrbPalette.teal)
                .frame(width: 28, height: 28)
                .background(OrbPalette.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName).font(.system(size: 13, weight: .semibold))
                    StatusBadge(status: server.status)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if server.status == .needsAuth {
                    Text("Нужно войти: откройте claude.ai → Настройки → Коннекторы.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Удалить сервер")
            }
            Toggle("", isOn: Binding(get: { server.status != .disabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private var displayName: String {
        if server.isRunie { return "Инструменты Runie" }
        return server.name.hasPrefix("claude.ai ") ? String(server.name.dropFirst("claude.ai ".count)) : server.name
    }

    private var symbol: String {
        if server.isRunie { return "sparkles" }
        return switch server.transport {
        case "claudeai-proxy": "cloud"
        case "http", "sse": "globe"
        case "sdk": "sparkles"
        default: "terminal"
        }
    }

    private var subtitle: String {
        let source = switch server.scope {
        case "claudeai": "Коннектор claude.ai"
        case "user": "Мой сервер"
        case "project", "local": "Сервер проекта"
        case "plugin": "Из плагина"
        default: server.isRunie ? "Файлы, Календарь, отправка — встроено в Runie" : (server.scope ?? "")
        }
        return [source, server.target].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct StatusBadge: View {
    let status: MCPServerInfo.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch status {
        case .connected: "подключён"
        case .pending: "подключается"
        case .needsAuth: "нужен вход"
        case .failed: "ошибка"
        case .disabled: "выключен"
        case .unknown: "неизвестно"
        }
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .needsAuth: .orange
        case .failed: .red
        default: .gray
        }
    }
}

private struct SkillRow: View {
    let skill: SkillInfo
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(skill.source)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(OrbPalette.teal.opacity(0.14), in: Capsule())
                }
                if let description = skill.description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(description)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            Spacer(minLength: 8)
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Добавление сервера

private struct AddServerSheet: View {
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = Kind.command
    @State private var command = ""
    @State private var url = ""
    @State private var environment = ""
    @State private var isWorking = false
    @State private var error: String?

    enum Kind: String, CaseIterable {
        case command = "Команда"
        case url = "Адрес"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                RunieOrb(mood: isWorking ? .working : .idle, size: 22)
                    .frame(width: 28, height: 28)
                Text("Новый MCP-сервер")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }

            Form {
                TextField("Имя", text: $name, prompt: Text("например, notion"))
                Picker("Как подключить", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if kind == .command {
                    TextField("Команда", text: $command, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                    TextField("Переменные", text: $environment, prompt: Text("API_KEY=… (через пробел)"))
                } else {
                    TextField("Адрес", text: $url, prompt: Text("https://mcp.example.com/mcp"))
                }
            }
            .formStyle(.grouped)
            .frame(height: 190)

            Label("Сервер — это чужая программа с доступом к вашему Mac. Добавляйте только те, которым доверяете.",
                  systemImage: "exclamationmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(4)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") { add() }
                    .buttonStyle(.borderedProminent)
                    .tint(OrbPalette.deep)
                    .disabled(!isValid || isWorking)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (kind == .command ? !command.trimmingCharacters(in: .whitespaces).isEmpty : URL(string: url)?.scheme?.hasPrefix("http") == true)
    }

    private func add() {
        isWorking = true
        error = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var arguments = ["mcp", "add", "--scope", "user"]
        if kind == .url {
            arguments += ["--transport", "http", trimmedName, url.trimmingCharacters(in: .whitespaces)]
        } else {
            for pair in environment.split(separator: " ") where pair.contains("=") {
                arguments += ["-e", String(pair)]
            }
            let parts = command.split(separator: " ").map(String.init)
            arguments += [trimmedName, "--"] + parts
        }
        Task {
            let result = await ClaudeCLI.run(arguments)
            isWorking = false
            if result.status == 0 {
                onAdded()
                dismiss()
            } else {
                error = result.output.isEmpty ? "Claude Code не добавил сервер." : result.output
            }
        }
    }
}

// MARK: - Claude Code из приложения

enum ClaudeCLI {
    /// Команда `claude …` с выводом. Для настроек: `mcp add`, `mcp remove`.
    static func run(_ arguments: [String]) async -> (status: Int32, output: String) {
        guard let executable = try? ClaudeCodeLocator().locate() else { return (-1, "Claude Code не найден.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus, output))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
