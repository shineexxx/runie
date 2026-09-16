import Foundation

/// Что именно человек разрешил «всегда».
///
/// Команда оболочки разрешается дословно: `sw_vers` не значит `rm`. Страница — по
/// сайту. Остальные инструменты — целиком: «Всегда создавать файлы» человек и имеет
/// в виду, нажимая кнопку.
enum PermissionGrant {
    static func key(for request: PermissionRequest) -> String {
        switch request.toolName {
        case "Bash":
            return "Bash:" + (request.input["command"]?.stringValue ?? "")
        case "WebFetch":
            let host = request.input["url"]?.stringValue.flatMap { URL(string: $0)?.host() }
            return "WebFetch:" + (host ?? "")
        default:
            return request.toolName
        }
    }
}
