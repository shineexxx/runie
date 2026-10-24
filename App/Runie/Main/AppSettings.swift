import Foundation
import Observation
import RunieKit

/// Настройки, которые человек меняет в окне Runie.
@MainActor
@Observable
final class AppSettings {

    private enum Key {
        static let policy = "permissions.policy"
        static let model = "model.selected"
        static let models = "model.cache"
        static let disabledSkills = "skills.disabled"
        static let disabledServers = "mcp.disabledInRunie"
        static let sources = "mcp.suggestionSources"
    }

    /// Какие серверы и что именно учитывать в подсказках — по имени сервера.
    var mcpSources: [String: MCPSource] {
        didSet {
            if let data = try? JSONEncoder().encode(mcpSources) {
                UserDefaults.standard.set(data, forKey: Key.sources)
            }
        }
    }

    /// MCP-серверы, выключенные только в Runie.
    var disabledMCPServers: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledMCPServers).sorted(), forKey: Key.disabledServers)
            onDisabledMCPServersChange?(disabledMCPServers)
        }
    }

    @ObservationIgnored var onDisabledMCPServersChange: ((Set<String>) -> Void)?

    /// Навыки, выключенные в Runie.
    var disabledSkills: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledSkills).sorted(), forKey: Key.disabledSkills)
            onDisabledSkillsChange?(disabledSkills)
        }
    }

    @ObservationIgnored var onDisabledSkillsChange: ((Set<String>) -> Void)?

    /// Выбранная модель. `nil` — как в Claude Code.
    /// На каком языке Руни отвечает. Хранится в RunieKit: им пользуются и инструменты.
    var answerLanguage: AnswerLanguage = AnswerLanguage.current {
        didSet {
            guard answerLanguage != oldValue else { return }
            AnswerLanguage.current = answerLanguage
            onAnswerLanguageChange?(answerLanguage)
        }
    }
    var onAnswerLanguageChange: ((AnswerLanguage) -> Void)?

    /// На чём работает Руни: Claude Code или Codex от OpenAI.
    enum AgentEngine: String, CaseIterable, Sendable {
        case claude
        case codex

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            }
        }
    }

    nonisolated static let engineKey = "agent.engine"

    /// Выбранный агент — для мест, где настроек под рукой нет (сборка бэкенда).
    nonisolated static var storedEngine: AgentEngine {
        UserDefaults.standard.string(forKey: engineKey).flatMap(AgentEngine.init(rawValue:)) ?? .claude
    }

    var agentEngine: AgentEngine = AppSettings.storedEngine {
        didSet {
            guard agentEngine != oldValue else { return }
            UserDefaults.standard.set(agentEngine.rawValue, forKey: Self.engineKey)
            onAgentEngineChange?()
        }
    }
    @ObservationIgnored var onAgentEngineChange: (() -> Void)?

    /// Claude in Chrome: Руни может работать в настоящем Chrome через расширение.
    nonisolated static let chromeKey = "chrome.integration"

    var chromeIntegration: Bool = UserDefaults.standard.object(forKey: AppSettings.chromeKey) as? Bool ?? true {
        didSet {
            guard chromeIntegration != oldValue else { return }
            UserDefaults.standard.set(chromeIntegration, forKey: Self.chromeKey)
            onChromeIntegrationChange?()
        }
    }
    @ObservationIgnored var onChromeIntegrationChange: (() -> Void)?

    var selectedModel: String? {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Key.model) }
    }

    /// Последний список моделей от Claude Code — меню видно до его ответа.
    var cachedModels: [AgentModel] {
        get {
            UserDefaults.standard.data(forKey: Key.models)
                .flatMap { try? JSONDecoder().decode([AgentModel].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.models)
        }
    }

    /// Какие группы действий разрешать без вопроса. Сессия получает правила сразу:
    /// следующий же вопрос агента решается по новым правилам.
    var policy: PermissionPolicy {
        didSet {
            save()
            onPolicyChange?(policy)
        }
    }

    @ObservationIgnored var onPolicyChange: ((PermissionPolicy) -> Void)?

    init() {
        selectedModel = UserDefaults.standard.string(forKey: Key.model)
        disabledSkills = Set(UserDefaults.standard.stringArray(forKey: Key.disabledSkills) ?? [])
        disabledMCPServers = Set(UserDefaults.standard.stringArray(forKey: Key.disabledServers) ?? [])
        mcpSources = UserDefaults.standard.data(forKey: Key.sources)
            .flatMap { try? JSONDecoder().decode([String: MCPSource].self, from: $0) } ?? [:]
        if let data = UserDefaults.standard.data(forKey: Key.policy),
           let stored = try? JSONDecoder().decode(PermissionPolicy.self, from: data) {
            policy = stored
        } else {
            policy = PermissionPolicy()
        }
    }

    func setRule(_ rule: PermissionPolicy.Rule, for category: PermissionCategory) {
        policy.rules[category] = rule
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: Key.policy)
        }
    }
}
