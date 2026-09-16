import Foundation
import Testing
@testable import RunieKit

/// Загрузка фикстур, снятых с настоящего CLI и очищенных scripts/sanitize-fixture.py.
enum FixtureLoader {

    static let names = ["tool-use", "permission", "resume-missing", "bash-readonly", "thinking", "partial"]

    static func rawEvents(_ name: String) throws -> [RawAgentEvent] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "нет фикстуры \(name).jsonl"
        )
        var splitter = NDJSONLineSplitter()
        var lines = try splitter.append(try Data(contentsOf: url))
        if let tail = splitter.flush() { lines.append(tail) }
        return try lines.map { RawAgentEvent(payload: try JSONValue.decode($0)) }
    }

    static func events(_ name: String) throws -> [AgentEvent] {
        let normalizer = AgentEventNormalizer()
        return try rawEvents(name).flatMap(normalizer.normalize)
    }
}
