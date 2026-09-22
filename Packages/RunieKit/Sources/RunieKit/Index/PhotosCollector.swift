import Foundation
#if canImport(Photos)
import Photos
import Vision
#endif

/// Собирает медиатеку в указатель.
///
/// У фотографий нет текста, по которому их искать, поэтому берём то, что есть:
/// когда снято, что это — снимок экрана, видео или фотография, в каких альбомах
/// лежит. А у снимков экрана распознаём надписи: «скриншот с ошибкой про
/// сертификат» — обычная просьба, и без распознавания на неё не ответить.
///
/// Распознавание идёт на самом Mac средствами системы, ничего никуда не
/// отправляется. Обычные фотографии через него не гоняем: это долго, а толку
/// мало — на них редко бывает текст.
public struct PhotosCollector: Sendable {

    /// Докуда дошли вглубь медиатеки.
    static let depthMark = "photos.oldest"

    /// Сколько снимков берём за проход.
    public var limit = 2_000
    /// Сколько снимков экрана распознаём за проход: это самая долгая часть.
    public var recognitionLimit = 150
    public var maxTextLength = 4_000

    public init() {}

    /// Что это за снимок — по этому слову человек его и ищет.
    public enum Kind: String, Sendable {
        case photo
        case screenshot
        case video

        var title: String {
            switch self {
            case .photo: t("Фотография")
            case .screenshot: t("Снимок экрана")
            case .video: t("Видео")
            }
        }
    }

    /// Снимок без подробностей библиотеки: так его удобно и собирать, и проверять.
    struct Shot {
        let id: String
        let kind: Kind
        let date: Date
        var albums: [String] = []
        /// Надписи, распознанные на снимке экрана.
        var recognized: String?
    }

    /// Запись указателя для снимка.
    func item(from shot: Shot) -> IndexStore.Item {
        let day = shot.date.formatted(.dateTime.day().month(.wide).year().locale(.runie))
        var details = ["kind": shot.kind.rawValue]
        if !shot.albums.isEmpty { details["albums"] = shot.albums.joined(separator: ", ") }

        var lines: [String] = []
        if !shot.albums.isEmpty {
            lines.append(t("Альбомы: \(shot.albums.joined(separator: ", "))"))
        }
        if let recognized = shot.recognized?.trimmingCharacters(in: .whitespacesAndNewlines), !recognized.isEmpty {
            lines.append(recognized)
        }
        return IndexStore.Item(
            source: .photos,
            externalID: shot.id,
            title: shot.kind.title + ", " + day,
            body: String(lines.joined(separator: "\n").prefix(maxTextLength)),
            date: shot.date,
            details: details
        )
    }

    #if canImport(Photos)

    /// Спрашивала ли система разрешение и чем дело кончилось.
    public static var authorization: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public static var isAllowed: Bool {
        [.authorized, .limited].contains(authorization)
    }

    /// Просит доступ к медиатеке. Окно показывает система, не Руни.
    @discardableResult
    public static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return [.authorized, .limited].contains(status)
    }

    /// Обходит медиатеку и складывает снимки в указатель.
    @discardableResult
    public func scan(
        into store: IndexStore,
        model: MemoryModel? = nil,
        since: Date? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        guard await Self.requestAccess() else {
            throw IndexStore.Failure.cannotOpen(t("Фото — не выдан доступ к медиатеке"))
        }
        let start = Date()
        let since = since ?? store.lastScan(of: .photos)
        let depth = store.mark(Self.depthMark)

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)

        // Альбомы спрашиваем один раз: иначе на каждый снимок был бы свой запрос.
        let albums = Self.albumsByAsset()

        var shots: [Shot] = []
        var oldest = depth
        assets.enumerateObjects { asset, _, stop in
            guard shots.count < limit else {
                stop.pointee = true
                return
            }
            let date = asset.creationDate ?? asset.modificationDate ?? Date()
            let isFresh = since.map { date > $0 } ?? true
            let isHistory = depth.map { date < $0 } ?? false
            guard isFresh || isHistory else { return }
            var shot = Shot(id: asset.localIdentifier, kind: Self.kind(of: asset), date: date)
            shot.albums = albums[asset.localIdentifier] ?? []
            shots.append(shot)
            if oldest == nil || date < oldest! { oldest = date }
        }

        // Распознаём надписи, но только у снимков экрана и только у части за раз.
        var recognized = 0
        for index in shots.indices where shots[index].kind == .screenshot && recognized < recognitionLimit {
            try Task.checkCancellation()
            if let text = await Self.recognizeText(assetID: shots[index].id) {
                shots[index].recognized = text
            }
            recognized += 1
        }

        var indexed = 0
        for shot in shots {
            try Task.checkCancellation()
            let item = item(from: shot)
            let vector = model?.embed(item.title + " " + String(item.body.prefix(1_000)))
            try store.put(item, vector: vector)
            indexed += 1
            if indexed % 50 == 0 {
                progress?(indexed)
                await Task.yield()
            }
        }
        if let oldest { try store.setMark(Self.depthMark, to: oldest) }
        try store.markScanned(.photos, at: start)
        progress?(indexed)
        return indexed
    }

    static func kind(of asset: PHAsset) -> Kind {
        if asset.mediaType == .video { return .video }
        return asset.mediaSubtypes.contains(.photoScreenshot) ? .screenshot : .photo
    }

    /// В каких альбомах лежит каждый снимок.
    static func albumsByAsset() -> [String: [String]] {
        var result: [String: [String]] = [:]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            guard let name = collection.localizedTitle else { return }
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                result[asset.localIdentifier, default: []].append(name)
            }
        }
        return result
    }

    /// Надписи на снимке — средствами системы, на самом Mac.
    static func recognizeText(assetID: String) async -> String? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.isSynchronous = false
        options.resizeMode = .fast

        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(data: data, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
    #endif
}
