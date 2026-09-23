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
            return "WebFetch:" + (PermissionClassifier.site(of: request) ?? "")
        case "mcp__runie__web_open":
            // «Всегда» здесь — про один сайт, а не про все. Разрешив зайти в
            // дневник своей учётной записью, человек не разрешает то же самое
            // для почты и банка.
            let signingIn = request.input["sign_in"]?.boolValue == true
            return "web_open:\(PermissionClassifier.site(of: request) ?? ""):\(signingIn ? "вход" : "просмотр")"
        default:
            return request.toolName
        }
    }

}
