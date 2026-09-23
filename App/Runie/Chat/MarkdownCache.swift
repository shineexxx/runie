import AppKit
import Foundation
import RunieKit

/// Разобранная разметка ответов под рукой.
///
/// Разбор идёт в теле вида, а SwiftUI пересчитывает тело на каждое движение:
/// прокрутил ленту — и десяток ответов разбирается заново по нескольку раз в
/// секунду. Текст ответа при этом не меняется, поэтому разобранное достаточно
/// сложить один раз и брать готовым; растёт только то, что человек видел, а
/// самые старые записи уходят.
@MainActor
enum MarkdownCache {

    static func blocks(of text: String) -> [MarkdownBlock] {
        blocksCache.value(for: text) { MarkdownBlock.parse(text) }
    }

    static func inline(_ text: String) -> AttributedString {
        inlineCache.value(for: text) { MarkdownText.inline(text) }
    }

    static func segments(of text: String) -> [MessageSegment] {
        segmentsCache.value(for: text) { MessageSegment.parse(text) }
    }

    /// Картинка из ответа: читать файл с диска на каждый пересчёт вида — верный
    /// способ уронить плавность прокрутки.
    static func image(atPath path: String) -> NSImage? {
        imageCache.value(for: path) { NSImage(contentsOfFile: path) }
    }

    private static let blocksCache = Store<[MarkdownBlock]>()
    private static let inlineCache = Store<AttributedString>()
    private static let segmentsCache = Store<[MessageSegment]>()
    private static let imageCache = Store<NSImage?>(limit: 40)

    /// Простое хранилище с пределом: дольше всех не спрашиваемое уходит первым.
    private final class Store<Value> {
        private var values: [String: Value] = [:]
        private var order: [String] = []
        private let limit: Int

        init(limit: Int = 200) { self.limit = limit }

        func value(for key: String, make: () -> Value) -> Value {
            if let ready = values[key] {
                touch(key)
                return ready
            }
            let made = make()
            values[key] = made
            order.append(key)
            if order.count > limit {
                let oldest = order.removeFirst()
                values[oldest] = nil
            }
            return made
        }

        private func touch(_ key: String) {
            guard let at = order.firstIndex(of: key), at != order.count - 1 else { return }
            order.remove(at: at)
            order.append(key)
        }
    }
}
