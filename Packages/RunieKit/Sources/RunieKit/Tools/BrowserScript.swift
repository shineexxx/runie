import Foundation

/// AppleScript для управления Safari и Chrome.
///
/// Только сборка текста скриптов — выполняет их приложение. Всё, что приходит от
/// модели (адреса, селекторы, надписи), попадает в скрипт через экранирование:
/// строки JavaScript — как JSON, строка AppleScript — с экранированными `\` и `"`.
public enum BrowserScript {

    public enum Browser: String, CaseIterable, Sendable {
        case safari
        case chrome

        public var appName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Google Chrome"
            }
        }

        public var title: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Chrome"
            }
        }
    }

    /// Строка AppleScript в кавычках.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Литерал JavaScript для строки — через JSON, так безопаснее ручного экранирования.
    public static func jsString(_ text: String?) -> String {
        guard let text else { return "null" }
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Все вкладки: строки «окно<TAB>вкладка<TAB>активная<TAB>заголовок<TAB>адрес».
    ///
    /// Разделители задаются до `tell`: внутри `tell application "Safari"` слово `tab`
    /// означает вкладку, а не символ табуляции.
    public static func listTabs(_ browser: Browser) -> String {
        let titleKey = browser == .safari ? "name" : "title"
        let currentIndex = browser == .safari ? "index of current tab of w" : "active tab index of w"
        return """
        set sep to ASCII character 9
        set nl to ASCII character 10
        set output to ""
        tell application \(quoted(browser.appName))
            set windowIndex to 0
            repeat with w in windows
                set windowIndex to windowIndex + 1
                set tabIndex to 0
                set currentIndex to 0
                try
                    set currentIndex to \(currentIndex)
                end try
                try
                    repeat with t in tabs of w
                        set tabIndex to tabIndex + 1
                        set activeFlag to "0"
                        if tabIndex is equal to currentIndex then set activeFlag to "1"
                        set tabTitle to ""
                        set tabURL to ""
                        try
                            set tabTitle to (\(titleKey) of t) as text
                        end try
                        try
                            set tabURL to (URL of t) as text
                        end try
                        set output to output & windowIndex & sep & tabIndex & sep & activeFlag & sep & tabTitle & sep & tabURL & nl
                    end repeat
                end try
            end repeat
        end tell
        return output
        """
    }

    public static func open(_ browser: Browser, url: String, newTab: Bool) -> String {
        let target = quoted(url)
        switch browser {
        case .safari:
            return newTab
                ? """
                tell application "Safari"
                    activate
                    if (count of windows) is 0 then make new document
                    tell front window to set current tab to (make new tab with properties {URL:\(target)})
                end tell
                """
                : """
                tell application "Safari"
                    activate
                    if (count of windows) is 0 then make new document
                    set URL of current tab of front window to \(target)
                end tell
                """
        case .chrome:
            return newTab
                ? """
                tell application "Google Chrome"
                    activate
                    if (count of windows) is 0 then make new window
                    tell front window to make new tab with properties {URL:\(target)}
                end tell
                """
                : """
                tell application "Google Chrome"
                    activate
                    if (count of windows) is 0 then make new window
                    set URL of active tab of front window to \(target)
                end tell
                """
        }
    }

    public static func activate(_ browser: Browser, window: Int, tab: Int) -> String {
        switch browser {
        case .safari:
            """
            tell application "Safari"
                activate
                set current tab of window \(window) to tab \(tab) of window \(window)
                set index of window \(window) to 1
            end tell
            """
        case .chrome:
            """
            tell application "Google Chrome"
                activate
                set active tab index of window \(window) to \(tab)
                set index of window \(window) to 1
            end tell
            """
        }
    }

    /// Выполнить JavaScript во вкладке. Без окна и вкладки — в активной вкладке переднего окна.
    public static func runJavaScript(_ browser: Browser, _ javaScript: String, window: Int?, tab: Int?) -> String {
        let code = quoted(javaScript)
        switch browser {
        case .safari:
            let target = (window != nil && tab != nil) ? "tab \(tab!) of window \(window!)" : "current tab of front window"
            return "tell application \"Safari\" to do JavaScript \(code) in \(target)"
        case .chrome:
            let target = (window != nil && tab != nil) ? "tab \(tab!) of window \(window!)" : "active tab of front window"
            return "tell application \"Google Chrome\" to execute \(target) javascript \(code)"
        }
    }

    // MARK: JavaScript

    public static let pageTextJS = """
    (function(){var t=document.body?document.body.innerText:'';\
    return document.title+'\\n'+location.href+'\\n\\n'+t.slice(0,15000);})()
    """

    /// Нажать элемент: по CSS-селектору или по видимой надписи.
    public static func clickJS(selector: String?, text: String?) -> String {
        """
        (function(sel,txt){var el=null;if(sel){try{el=document.querySelector(sel);}catch(e){return 'bad selector';}}\
        if(!el&&txt){var q=txt.trim().toLowerCase();\
        var c=Array.from(document.querySelectorAll('a,button,input[type=submit],input[type=button],[role=button],[role=link],[role=tab],[role=menuitem],summary,label'));\
        var name=function(e){return (e.innerText||e.value||e.getAttribute('aria-label')||e.title||'').trim().toLowerCase();};\
        el=c.find(function(e){return name(e)===q;})||c.find(function(e){return name(e).indexOf(q)>=0;});}\
        if(!el)return 'not found';el.scrollIntoView({block:'center'});el.click();\
        return 'clicked: '+((el.innerText||el.value||el.getAttribute('aria-label')||el.tagName)+'').trim().slice(0,80);})\
        (\(jsString(selector)),\(jsString(text)))
        """
    }

    /// Заполнить поле: по CSS-селектору или по подписи, placeholder, name, aria-label.
    /// Значение ставится через нативный сеттер и событиями input/change — так его
    /// видят и страницы на React.
    public static func fillJS(selector: String?, field: String?, value: String) -> String {
        """
        (function(sel,label,val){var el=null;if(sel){try{el=document.querySelector(sel);}catch(e){return 'bad selector';}}\
        if(!el&&label){var q=label.trim().toLowerCase();\
        var fields=Array.from(document.querySelectorAll('input:not([type=hidden]),textarea,[contenteditable=true]'));\
        var labelOf=function(e){var l=e.labels&&e.labels[0]?e.labels[0].innerText:'';\
        return [l,e.placeholder,e.name,e.getAttribute('aria-label'),e.id].filter(Boolean).join(' ').toLowerCase();};\
        el=fields.find(function(e){return labelOf(e).indexOf(q)>=0;});}\
        if(!el)return 'not found';el.focus();\
        if(el.isContentEditable){el.innerText=val;}else{var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;\
        Object.getOwnPropertyDescriptor(proto,'value').set.call(el,val);}\
        el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));\
        return 'filled: '+(el.name||el.id||el.placeholder||el.tagName);})\
        (\(jsString(selector)),\(jsString(field)),\(jsString(value)))
        """
    }
}

// MARK: - Свой JavaScript

extension BrowserScript {

    /// Что свой код трогать не может: cookie, хранилища сайта, поля паролей и отправку
    /// данных в сеть. Проверка по тексту — от случайностей, а не от злого умысла; главная
    /// защита — человек видит код в запросе разрешения.
    public static func forbiddenReason(inScript code: String) -> String? {
        let compact = code.lowercased().filter { !$0.isWhitespace }
        let rules: [(needles: [String], reason: String)] = [
            (["cookie"], "cookie сайта"),
            (["localstorage", "sessionstorage", "indexeddb", "caches."], "хранилище сайта"),
            (["password", "пароль"], "поля паролей"),
            (["fetch(", "xmlhttprequest", "sendbeacon", "websocket", "eventsource", ".submit("], "отправку данных в сеть"),
        ]
        guard let hit = rules.first(where: { $0.needles.contains(where: compact.contains) }) else { return nil }
        return "Такой код Руни не выполняет: он затрагивает \(hit.reason)."
    }

    /// Обёртка вокруг тела функции: результат всегда строка, ошибка — тоже строка.
    public static func wrapUserScript(_ body: String, limit: Int = 20_000) -> String {
        """
        (function(){try{var __r=(function(){
        \(body)
        })();if(__r===undefined)return 'undefined';\
        var __s=typeof __r==='string'?__r:JSON.stringify(__r,null,1);\
        return String(__s).slice(0,\(limit));}catch(e){return 'JS error: '+e;}})()
        """
    }
}
