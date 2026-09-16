import AppKit
import ImageIO
import RunieKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Хранилище

/// Откуда берутся вложения: снимок области экрана, выбор файлов, перетаскивание.
@MainActor
enum AttachmentStore {

    /// `~/Library/Application Support/Runie/Attachments` — здесь лежат снимки и
    /// уменьшенные копии картинок, чтобы история разговоров их не теряла.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Runie/Attachments", directoryHint: .isDirectory)
    }()

    /// Картинки больше этого по длинной стороне уменьшаются: модели крупнее не нужно,
    /// а сообщение с огромным снимком Retina идёт долго.
    private static let maxImageSide = 2000

    /// Снимок области: системное выделение, как по ⌘⇧4. `nil` — выделение отменили.
    static func captureArea() async -> Attachment? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = FileManager.default.temporaryDirectory.appending(path: "runie-shot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i выделение (пробел — снимок окна), -x без звука, -o без тени окна.
        process.arguments = ["-i", "-x", "-o", raw.path]
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
        guard FileManager.default.fileExists(atPath: raw.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: raw) }
        let name = "Снимок \(Date().formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(.runie)))"
        return importImage(raw, name: name)
    }

    /// Файлы, выбранные или перетащенные. Картинки копируются уменьшенными,
    /// остальное остаётся на месте — агенту уходит путь.
    static func importFiles(_ urls: [URL]) -> [Attachment] {
        urls.compactMap { url in
            if MessageImage.mediaType(forExtension: url.pathExtension) != nil {
                return importImage(url, name: url.lastPathComponent)
            }
            return Attachment(path: url.path)
        }
    }

    /// Что лежит в буфере обмена — для подписи в списке.
    static func clipboardSummary() -> String {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.count == 1 ? urls[0].lastPathComponent : "Файлов: \(urls.count)"
        }
        if NSImage(pasteboard: board) != nil { return "Картинка" }
        if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return "«\(line.count > 28 ? String(line.prefix(28)) + "…" : line)»"
        }
        return "Пусто"
    }

    /// Содержимое буфера: файлы и картинка — вложениями, текст — в поле ввода.
    static func readClipboard() -> (attachments: [Attachment], text: String?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return (importFiles(urls), nil)
        }
        if let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let raw = FileManager.default.temporaryDirectory.appending(path: "runie-clip-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: raw) }
            if (try? png.write(to: raw)) != nil, let attachment = importImage(raw, name: "Из буфера обмена") {
                return ([attachment], nil)
            }
        }
        let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([], text?.isEmpty == false ? text : nil)
    }

    static func pickFiles() -> [Attachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Выберите файлы для Руни"
        panel.prompt = "Прикрепить"
        NSApp.activate()
        guard panel.runModal() == .OK else { return [] }
        return importFiles(panel.urls)
    }

    private static func importImage(_ url: URL, name: String) -> Attachment? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let isPNG = url.pathExtension.lowercased() == "png"
        let target = directory.appending(path: "\(UUID().uuidString).\(isPNG ? "png" : "jpg")")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxImageSide
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(
                target as CFURL, (isPNG ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
        else { return Attachment(path: url.path, name: name) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return Attachment(path: url.path, name: name) }
        return Attachment(path: target.path, name: name)
    }
}

// MARK: - Кнопки и полоска вложений

/// «+» у поля ввода. Нажатие открывает список: снимок области, буфер обмена, файлы.
struct AttachmentButtons: View {
    let onPickFiles: () -> Void
    let onCapture: () -> Void
    let onPaste: () -> Void

    @State private var anchor = WindowAnchor()
    @State private var isOpen = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .rotationEffect(.degrees(isOpen ? 45 : 0))
                .foregroundStyle(isOpen ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(.primary.opacity(isOpen ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOpen)
        }
        .buttonStyle(.plain)
        .background(WindowAnchorReader(anchor: anchor))
        .help("Прикрепить")
        .accessibilityLabel("Прикрепить")
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .runieDebugOpenAttachMenu)) { _ in toggle() }
        #endif
    }

    private func toggle() {
        let dropdown = GlassDropdown.shared
        if isOpen || dropdown.justClosed {
            dropdown.close()
            return
        }
        guard let rect = anchor.screenRect() else { return }
        isOpen = true
        dropdown.show(
            below: rect,
            items: [
                DropdownItem(id: "capture", title: "Снимок области экрана",
                             detail: "Выделите, что показать Руни", symbol: "viewfinder", action: onCapture),
                DropdownItem(id: "clipboard", title: "Буфер обмена",
                             detail: AttachmentStore.clipboardSummary(), symbol: "doc.on.clipboard", action: onPaste),
                DropdownItem(id: "files", title: "Файлы…",
                             detail: "Документы, картинки, архивы", symbol: "doc", action: onPickFiles)
            ],
            onClose: { isOpen = false }
        )
    }
}

/// Приложенное к ещё не отправленному сообщению: миниатюры с крестиком.
struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, size: 52)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(.black.opacity(0.7)))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .help("Убрать")
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }
}

/// Миниатюра картинки или значок файла с именем.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    let size: CGFloat

    var body: some View {
        Group {
            if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 2) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.path))
                        .resizable()
                        .frame(width: size * 0.5, height: size * 0.5)
                    Text(attachment.name)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 3)
                }
                .frame(width: size, height: size)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
        .help(attachment.name)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(attachment.url) }
    }
}

// MARK: - Сообщения с картинками и файлами

/// Текст ответа с картинками и файлами, которые вставил агент.
struct RichMessageText: View {
    let text: String
    var imageWidth: CGFloat = 300

    var body: some View {
        let segments = MessageSegment.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    Text(MarkdownText.inline(value))
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let source, let alt):
                    MessageImageView(source: source, alt: alt, maxWidth: imageWidth)
                case .file(let path, let name):
                    FileChip(path: path, name: name)
                }
            }
        }
    }
}

/// Картинка в ответе: локальный файл или ссылка. По нажатию открывается целиком.
struct MessageImageView: View {
    let source: String
    let alt: String
    let maxWidth: CGFloat

    private var isRemote: Bool { source.hasPrefix("http://") || source.hasPrefix("https://") }

    var body: some View {
        Group {
            if isRemote, let url = URL(string: source) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): styled(image)
                    case .failure: missing
                    default:
                        ProgressView().controlSize(.small).frame(width: 120, height: 80)
                    }
                }
            } else if let image = NSImage(contentsOfFile: source) {
                styled(Image(nsImage: image))
            } else {
                missing
            }
        }
        .onTapGesture {
            if isRemote, let url = URL(string: source) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: source))
            }
        }
        .help(alt.isEmpty ? "Открыть картинку" : alt)
        .accessibilityLabel(alt.isEmpty ? "Картинка" : alt)
    }

    private func styled(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: maxWidth, maxHeight: 240, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
    }

    private var missing: some View {
        Label(alt.isEmpty ? "Картинка не найдена" : alt, systemImage: "photo.badge.exclamationmark")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// Файл в ответе: значок и имя. Нажатие открывает, правый клик — показать в Finder.
struct FileChip: View {
    let path: String
    let name: String

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !exists {
                    Text("не найден")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(OrbPalette.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        .help(path)
    }
}

// MARK: - Перетаскивание

extension View {
    /// Принимает перетащенные файлы и отдаёт их вложениями.
    func acceptsDroppedFiles(_ onDrop: @escaping ([Attachment]) -> Void) -> some View {
        self.dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            onDrop(AttachmentStore.importFiles(files))
            return true
        }
    }
}
