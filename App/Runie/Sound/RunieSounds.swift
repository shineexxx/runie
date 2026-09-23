import AVFoundation
import Observation

/// Какой звук играть. Отдельно от `RunieSounds`: вложенный тип унаследовал бы
/// привязку класса к главному потоку, а вьюхи SwiftUI проверяют её на лету —
/// и чат падал, едва облачко приветствия его касалось.
enum RunieSoundCue: CaseIterable, Sendable {
    /// Чат вышел из орба.
    case open
    /// Чат ушёл обратно.
    case close
    /// Сообщение ушло Руни.
    case send
    /// Руни ответил.
    case reply
    /// Руни поздоровался при запуске.
    case greeting
    /// Руни прощается перед выходом.
    case farewell
    /// Руни спрашивает или ждёт разрешения.
    case attention
    /// Что-то не получилось.
    case error
}

/// Звуки Руни: короткие стеклянные колокольчики в тон бирюзовому орбу.
///
/// Всё синтезируется здесь же, из синусов: ни чужих файлов, ни вопросов о
/// лицензии. У каждой ноты несколько обертонов с быстрым затуханием верхних —
/// так синус звучит как стекло, а не как писк. Сверху — немного реверберации.
///
/// Аудиодвижок засыпает через пару секунд тишины: работающий движок держит
/// процессор, даже когда ничего не играет, а орб только что стал лёгким.
@MainActor
@Observable
final class RunieSounds {

    static let shared = RunieSounds()

    typealias Cue = RunieSoundCue

    private enum Key {
        static let enabled = "sounds.enabled"
        static let volume = "sounds.volume"
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.enabled) }
    }

    /// Громкость от 0 до 1 поверх системной.
    var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: Key.volume)
            engine.mainMixerNode.outputVolume = Float(volume)
        }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let reverb = AVAudioUnitReverb()
    @ObservationIgnored private let submix = AVAudioMixerNode()
    /// Несколько проигрывателей: звуки могут накладываться — «отправлено» и сразу «ответ».
    @ObservationIgnored private var players: [AVAudioPlayerNode] = []
    @ObservationIgnored private var nextPlayer = 0
    @ObservationIgnored private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Стерео, хотя звук одинаков в обоих каналах: реверберация моно не принимает,
    /// и движок падает прямо при подключении.
    @ObservationIgnored private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        volume = defaults.object(forKey: Key.volume) as? Double ?? 0.6

        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 16
        engine.attach(reverb)
        // У реверберации один вход: проигрыватели сходятся в своём микшере, а уже
        // он идёт в реверберацию. Подключённые к ней напрямую, они вытесняли друг
        // друга, и запуск отключённого ронял приложение.
        engine.attach(submix)
        engine.connect(submix, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        for _ in 0..<4 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: submix, fromBus: 0, toBus: submix.nextAvailableInputBus, format: format)
            players.append(player)
        }
        engine.mainMixerNode.outputVolume = Float(volume)
    }

    func play(_ cue: Cue) {
        guard isEnabled, volume > 0 else { return }
        let buffer = buffers[cue] ?? {
            let made = Self.render(cue, format: format)
            buffers[cue] = made
            return made
        }()
        guard wake() else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer, at: nil)
        player.play()
        scheduleSleep(after: Double(buffer.frameLength) / format.sampleRate + 1.5)
    }

    /// Прослушать в настройках: всё по очереди, как оно звучит в работе.
    func preview() {
        let order: [Cue] = [.greeting, .open, .send, .reply, .attention, .close, .error, .farewell]
        Task { @MainActor in
            for cue in order {
                play(cue)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    // MARK: Движок

    private func wake() -> Bool {
        sleepTask?.cancel()
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func scheduleSleep(after seconds: Double) {
        sleepTask?.cancel()
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            players.forEach { $0.stop() }
            engine.pause()
        }
    }

    // MARK: Синтез

    /// Нота: частота, когда вступает и насколько громко.
    private struct Note {
        let frequency: Double
        let start: Double
        let amplitude: Double
        var decay = 0.32
    }

    private static func notes(for cue: Cue) -> [Note] {
        switch cue {
        case .open:
            // Две ноты вверх, квинта: чат «раскрывается».
            [Note(frequency: 1318.5, start: 0, amplitude: 0.5),
             Note(frequency: 1975.5, start: 0.06, amplitude: 0.36)]
        case .close:
            // Те же ноты вниз и тише.
            [Note(frequency: 987.8, start: 0, amplitude: 0.34, decay: 0.24),
             Note(frequency: 659.3, start: 0.055, amplitude: 0.3, decay: 0.26)]
        case .send:
            // Короткая высокая капля — сообщение улетело.
            [Note(frequency: 1567.98, start: 0, amplitude: 0.34, decay: 0.12),
             Note(frequency: 2349.3, start: 0.035, amplitude: 0.22, decay: 0.14)]
        case .reply:
            // Мягкий аккорд вверх: готово.
            [Note(frequency: 784.0, start: 0, amplitude: 0.36, decay: 0.45),
             Note(frequency: 1174.7, start: 0.07, amplitude: 0.3, decay: 0.45),
             Note(frequency: 1568.0, start: 0.14, amplitude: 0.24, decay: 0.55)]
        case .greeting:
            // Светлое арпеджио до мажор с септимой — «привет».
            [Note(frequency: 1046.5, start: 0, amplitude: 0.38, decay: 0.5),
             Note(frequency: 1318.5, start: 0.08, amplitude: 0.32, decay: 0.5),
             Note(frequency: 1568.0, start: 0.16, amplitude: 0.28, decay: 0.55),
             Note(frequency: 1975.5, start: 0.24, amplitude: 0.22, decay: 0.7)]
        case .farewell:
            // То же арпеджио вниз — «пока».
            [Note(frequency: 1568.0, start: 0, amplitude: 0.3, decay: 0.45),
             Note(frequency: 1318.5, start: 0.09, amplitude: 0.3, decay: 0.45),
             Note(frequency: 1046.5, start: 0.18, amplitude: 0.3, decay: 0.5),
             Note(frequency: 784.0, start: 0.27, amplitude: 0.3, decay: 0.7)]
        case .attention:
            // Два одинаковых «дин-дин»: Руни ждёт ответа.
            [Note(frequency: 1760.0, start: 0, amplitude: 0.36, decay: 0.2),
             Note(frequency: 1760.0, start: 0.15, amplitude: 0.3, decay: 0.35)]
        case .error:
            // Низко и вниз на полтона — без тревожной сирены.
            [Note(frequency: 523.25, start: 0, amplitude: 0.36, decay: 0.2),
             Note(frequency: 493.9, start: 0.13, amplitude: 0.34, decay: 0.32)]
        }
    }

    /// Служебные звуки тише событийных: закрытие и отправка — фон, не новость.
    private static func level(for cue: Cue) -> Float {
        switch cue {
        case .close: 0.6
        case .send: 0.55
        case .open: 0.75
        case .error: 0.8
        default: 1
        }
    }

    /// Обертоны стекла: кратные с лёгкой неровностью, верхние гаснут быстрее.
    private static let partials: [(ratio: Double, amplitude: Double)] = [
        (1, 1), (2.01, 0.28), (3.0, 0.1), (4.23, 0.05)
    ]

    private static func render(_ cue: Cue, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let notes = notes(for: cue)
        let rate = format.sampleRate
        let length = (notes.map { $0.start + $0.decay * 5 }.max() ?? 0.5) + 0.05
        let frames = AVAudioFrameCount(length * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) { samples[index] = 0 }

        let attack = 0.004
        for note in notes {
            let first = Int(note.start * rate)
            for index in first..<Int(frames) {
                let t = Double(index - first) / rate
                let rise = min(t / attack, 1)
                var value = 0.0
                for (number, partial) in partials.enumerated() {
                    let decay = note.decay / (1 + Double(number) * 0.9)
                    value += partial.amplitude * exp(-t / decay) * sin(2 * .pi * note.frequency * partial.ratio * t)
                }
                samples[index] += Float(value * rise * note.amplitude)
            }
        }

        // Ровная громкость всех звуков: пик на одном уровне, ниже порога искажений.
        var peak: Float = 0
        for index in 0..<Int(frames) { peak = max(peak, abs(samples[index])) }
        if peak > 0 {
            let gain = 0.45 * level(for: cue) / peak
            for index in 0..<Int(frames) { samples[index] *= gain }
        }
        // Мягкий хвост: последние 20 мс в ноль, без щелчка.
        let fade = Int(0.02 * rate)
        for index in 0..<fade {
            samples[Int(frames) - 1 - index] *= Float(index) / Float(fade)
        }
        // Второй канал — копия первого.
        memcpy(buffer.floatChannelData![1], samples, Int(frames) * MemoryLayout<Float>.size)
        return buffer
    }
}
