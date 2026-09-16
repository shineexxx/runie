import Foundation
import Testing
@testable import RunieKit

@Suite("ClaudeCodeLocator")
struct ClaudeCodeLocatorTests {

    /// Готовит временный "домашний каталог" и возвращает локатор, который в него смотрит.
    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runie-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test("находит claude в известном месте установки")
    func findsWellKnownPath() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let installed = home.appendingPathComponent(".local/bin/claude")
        try writeExecutable(at: installed)

        let locator = ClaudeCodeLocator(homeDirectory: home, pathVariable: nil)
        #expect(try locator.locate().path == installed.path)
    }

    @Test("не наследует PATH из шелла, но использует его как дополнение")
    func fallsBackToPathVariable() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let elsewhere = home.appendingPathComponent("custom/bin/claude")
        try writeExecutable(at: elsewhere)

        let locator = ClaudeCodeLocator(
            homeDirectory: home,
            pathVariable: home.appendingPathComponent("custom/bin").path
        )
        #expect(try locator.locate().path == elsewhere.path)
    }

    @Test("каталог с именем claude не считается установкой")
    func ignoresDirectories() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".local/bin/claude"),
            withIntermediateDirectories: true
        )

        let locator = ClaudeCodeLocator(homeDirectory: home, pathVariable: nil)
        #expect(throws: ClaudeCodeLocator.Failure.self) { try locator.locate() }
    }

    @Test("неисполняемый файл не считается установкой")
    func ignoresNonExecutableFile() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let path = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not executable".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

        let locator = ClaudeCodeLocator(homeDirectory: home, pathVariable: nil)
        #expect(throws: ClaudeCodeLocator.Failure.self) { try locator.locate() }
    }

    @Test("ошибка перечисляет все проверенные пути")
    func failureListsSearchedPaths() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let locator = ClaudeCodeLocator(homeDirectory: home, pathVariable: nil)
        do {
            _ = try locator.locate()
            Issue.record("ожидалась ошибка notFound")
        } catch let ClaudeCodeLocator.Failure.notFound(searched) {
            #expect(searched.count == ClaudeCodeLocator.wellKnownPaths.count)
            #expect(searched.contains { $0.hasSuffix("/.local/bin/claude") })
        }
    }

    @Test("дубликаты путей не проверяются дважды")
    func deduplicatesCandidates() throws {
        let home = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: home) }

        let locator = ClaudeCodeLocator(
            homeDirectory: home,
            pathVariable: "/usr/local/bin:/usr/local/bin:/opt/homebrew/bin"
        )
        let paths = locator.candidates.map(\.path)
        #expect(paths.count == Set(paths).count)
    }
}
