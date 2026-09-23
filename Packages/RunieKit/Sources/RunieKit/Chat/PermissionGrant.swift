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
            return "WebFetch:" + (host(of: request) ?? "")
        case "mcp__runie__web_open":
            // «Всегда» здесь — про один сайт, а не про все. Разрешив зайти в
            // дневник своей учётной записью, человек не разрешает то же самое
            // для почты и банка.
            let signingIn = request.input["sign_in"]?.boolValue == true
            return "web_open:\(host(of: request) ?? ""):\(signingIn ? "вход" : "просмотр")"
        default:
            return request.toolName
        }
    }

    /// Узел из адреса. Человек мог написать его без «https://».
    private static func host(of request: PermissionRequest) -> String? {
        guard let address = request.input["url"]?.stringValue else { return nil }
        let text = address.contains("://") ? address : "https://" + address
        return URL(string: text)?.host()?.lowercased()
    }
}
