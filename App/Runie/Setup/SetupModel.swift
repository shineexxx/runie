import AppKit
import Observation
import RunieKit

/// Первый запуск и всё, без чего Руни не работает: установлен ли Claude Code, выполнен
/// ли вход и выбрано ли, насколько Руни доверять. Пока что-то не так, чат вместо
/// обычной ленты ведёт человека по шагам.
@MainActor
@Observable
final class SetupModel {

    enum Stage: Equatable {
        case checking
        case needsClaude
        case installing
        case needsLogin
        case loggingIn
        case chooseTrust
        /// Предложение скачать модель смыслового поиска по памяти.
        case offerMemory
        case ready
    }

    private(set) var stage: Stage = .checking
    /// Страница входа, если CLI её напечатал: на случай, если браузер не открылся.
    private(set) var loginURL: URL?
    /// Последняя строка установщика — видно, что дело идёт.
    private(set) var installProgress: String?
    /// Чем закончилась неудачная установка.
    private(set) var installError: String?

    /// Чат работает. Предложение скачать модель памяти — не препятствие:
    /// оно стоит карточкой над полем ввода, писать можно и не отвечая на него.
    var isReady: Bool { stage == .ready || stage == .offerMemory }

    var offersMemory: Bool { stage == .offerMemory }

    /// Claude Code нашёлся после запуска приложения — пора подменить заглушку.
    @ObservationIgnored var onClaudeFound: ((URL) -> Void)?
    /// Первая проверка закончилась, а Руни ещё не готов — орб зовёт человека.
    @ObservationIgnored var onNeedsAttention: (() -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var executable: URL?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var loginProcess: Process?
    @ObservationIgnored private var installProcess: Process?
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var didFinishFirstCheck = false

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    private static let trustKey = "setup.trustChosen"

    init(settings: AppSettings) {
        self.settings = settings
        // Кто уже настраивал разрешения, того про доверие не спрашиваем.
        if settings.policy != PermissionPolicy() {
            UserDefaults.standard.set(true, forKey: Self.trustKey)
        }
        // Всё было в порядке в прошлый раз — чат открывается сразу, проверка идёт в фоне.
        if UserDefaults.standard.bool(forKey: Self.trustKey), (try? ClaudeCodeLocator().locate()) != nil {
            stage = Self.settled
        }
        #if DEBUG
        // `-RunieSetupStage needsLogin` — показать шаг знакомства, ничего не проверяя.
        if let forced = UserDefaults.standard.string(forKey: "RunieSetupStage") {
            isForced = true
            stage = switch forced {
            case "needsClaude": .needsClaude
            case "installing": .installing
            case "needsLogin": .needsLogin
            case "loggingIn": .loggingIn
            case "chooseTrust": .chooseTrust
            case "offerMemory": .offerMemory
            default: .checking
            }
        }
        // `-RunieInstallNow YES` — сразу нажать «Установить» (вместе с HOME во временной папке).
        if UserDefaults.standard.bool(forKey: "RunieInstallNow") {
            Task { @MainActor in self.install() }
        }
        #endif
    }

    @ObservationIgnored private var isForced = false

    // MARK: Проверка

    /// Проверяет всё заново. При открытии чата — не чаще раза в несколько минут:
    /// выйти из аккаунта могли и в терминале.
    func check(force: Bool = true) {
        guard force || Date().timeIntervalSince(lastCheck) > 5 * 60 else { return }
        lastCheck = Date()
        Task { await evaluate() }
    }

    private func evaluate() async {
        guard !isForced else { return }
        let found = try? ClaudeCodeLocator().locate()
        if let found, executable == nil {
            executable = found
            onClaudeFound?(found)
        }
        guard let found else {
            // Установка идёт — не сбивать экран с ходом установки.
            transition(to: installProcess == nil ? .needsClaude : .installing)
            return
        }
        let loggedIn = await Self.isLoggedIn(executable: found)
        if !loggedIn {
            // Вход идёт — ждём его, а не показываем кнопку заново.
            transition(to: stage == .loggingIn ? .loggingIn : .needsLogin)
        } else if !UserDefaults.standard.bool(forKey: Self.trustKey) {
            finishLogin()
            transition(to: .chooseTrust)
        } else {
            finishLogin()
            transition(to: Self.settled)
        }
    }

    /// Куда попадает знакомство, когда всё настроено: обычно сразу в чат, но один
    /// раз по дороге спрашиваем про память. Про неё спрашивают и тех, кто настроил
    /// Руни раньше, чем она появилась.
    private static var settled: Stage {
        UserDefaults.standard.bool(forKey: memoryKey) || MemoryModel.isInstalled() ? .ready : .offerMemory
    }

    private func transition(to next: Stage) {
        stage = next
        if !didFinishFirstCheck {
            didFinishFirstCheck = true
            // Ради предложения скачать модель орб человека не дёргает.
            if next != .ready, next != .offerMemory { onNeedsAttention?() }
        }
        // Пока ждём установку или вход, проверяем сами — человеку ничего нажимать не нужно.
        let waiting = [.needsClaude, .needsLogin, .loggingIn].contains(next)
        if waiting, poll == nil {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled else { return }
                    await self.evaluate()
                }
            }
        } else if !waiting {
            poll?.cancel()
            poll = nil
        }
    }

    /// `claude auth status` печатает JSON с `loggedIn`. Если ответ не разобрать
    /// (старая версия CLI), считаем, что вход есть: лучше ошибка при первом сообщении,
    /// чем закрытый навсегда чат.
    nonisolated private static func isLoggedIn(executable: URL) async -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                continuation.resume(returning: (json?["loggedIn"] as? Bool) ?? true)
            }
            do { try process.run() } catch { continuation.resume(returning: true) }
        }
    }

    // MARK: Установка

    /// Ставит Claude Code официальным установщиком с claude.ai — по кнопке, без
    /// Терминала. Он кладёт программу в `~/.local/bin`, где её и ищет Runie.
    func install() {
        guard installProcess == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -o pipefail; " + Self.installCommand]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // У приложения из Finder PATH короткий — curl и системные утилиты должны находиться.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let log = InstallLog()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let line = log.append(data)
            Task { @MainActor in
                if let line { self?.installProgress = line }
            }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let tail = log.tail
            Task { @MainActor in
                guard let self else { return }
                self.installProcess = nil
                self.installProgress = nil
                if status != 0 || (try? ClaudeCodeLocator().locate()) == nil {
                    self.installError = tail.isEmpty ? String(localized: "Установщик завершился с ошибкой (код \(status)).") : tail
                    self.stage = .needsClaude
                }
                await self.evaluate()
            }
        }
        do {
            try process.run()
            installProcess = process
            installError = nil
            installProgress = nil
            stage = .installing
        } catch {
            installError = error.localizedDescription
        }
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    func openTerminal() {
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Вход

    /// `claude auth login` сам открывает страницу входа в браузере и ждёт, пока
    /// человек войдёт. Проверка раз в три секунды заметит вход.
    func login() {
        guard let executable, loginProcess == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "login"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let url = Self.firstURL(in: text) else { return }
            Task { @MainActor in
                if self?.loginURL == nil { self?.loginURL = url }
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.loginProcess = nil
                await self.evaluate()
                // CLI закончил, а входа нет — вернуть кнопку.
                if self.stage == .loggingIn { self.stage = .needsLogin }
            }
        }
        do {
            try process.run()
            loginProcess = process
            loginURL = nil
            stage = .loggingIn
        } catch {
            stage = .needsLogin
        }
    }

    func cancelLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        stage = .needsLogin
    }

    func openLoginPage() {
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }

    private func finishLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        loginURL = nil
    }

    nonisolated static func firstURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    // MARK: Доверие

    /// `cautious` — спрашивать только о рискованном: читать и смотреть можно без вопроса.
    func chooseTrust(cautious: Bool) {
        settings.policy = cautious ? .safe : PermissionPolicy()
        UserDefaults.standard.set(true, forKey: Self.trustKey)
        stage = Self.settled
    }

    private static let memoryKey = "setup.memoryAsked"

    /// Ответ на предложение скачать модель. Загрузка идёт фоном — знакомство её не ждёт.
    func offerMemory(download: Bool) {
        UserDefaults.standard.set(true, forKey: Self.memoryKey)
        if download { MemoryModelInstaller.shared.install() }
        stage = .ready
    }
}

/// Вывод установщика: копится из фонового потока, наружу — последняя осмысленная
/// строка и хвост для сообщения об ошибке.
private final class InstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    /// Добавляет кусок вывода и возвращает последнюю непустую строку.
    func append(_ data: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        text += String(decoding: data, as: UTF8.self)
        return Self.lines(text).last
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.lines(text).suffix(4).joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            // Цветовые коды терминала и рамки прогресса в интерфейсе не нужны.
            .map { $0.replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
