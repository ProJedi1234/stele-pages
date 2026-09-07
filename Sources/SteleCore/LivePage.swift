import Foundation

/// Adds the small browser client that keeps an open page on its current revision.
public enum LivePage {
    public static func inject(html: String, slug: Slug, id: UUID, revision: Int64) -> String {
        let scan = HTMLScan(html)
        guard scan.canInject, !scan.optsOutOfLiveUpdates else { return html }

        let script = clientScript(slug: slug, id: id, revision: revision)
        let insertion = scan.bodyClosingTag ?? scan.htmlClosingTag ?? html.endIndex
        var result = html
        result.insert(contentsOf: script, at: insertion)
        return result
    }

    private static func clientScript(slug: Slug, id: UUID, revision: Int64) -> String {
        // Slugs have a deliberately narrow alphabet, and UUID strings cannot terminate a
        // script element. Keeping the generated values out of quoted JavaScript source also
        // makes this safe if either type's validation changes later.
        let configuration = try! String(
            decoding: JSONSerialization.data(withJSONObject: [
                "id": id.uuidString.lowercased(),
                "revision": String(revision),
                "events": "/pages/\(slug.value)/events?id=\(id.uuidString.lowercased())",
            ], options: [.sortedKeys, .withoutEscapingSlashes]),
            as: UTF8.self
        )

        return """
        <script data-stele-live>(function(c){
        "use strict";
        var source=null,reloading=false,reloadTimer=null,terminal=false,scrollKey="stele-live-scroll:"+c.id,guardKey="__stele_page";
        try{var cleanURL=new URL(location.href);if(cleanURL.searchParams.has(guardKey)){cleanURL.searchParams.delete(guardKey);history.replaceState(history.state,"",cleanURL);}}catch(_){}
        try{var saved=sessionStorage.getItem(scrollKey);if(saved!==null){sessionStorage.removeItem(scrollKey);requestAnimationFrame(function(){requestAnimationFrame(function(){scrollTo(0,Number(saved)||0);});});}}catch(_){}
        function unavailable(){
          terminal=true;
          if(reloadTimer!==null){clearTimeout(reloadTimer);reloadTimer=null;}
          if(source){source.close();source=null;}
          document.title="Page unavailable";
          var root=document.documentElement;
          root.replaceChildren();
          var head=document.createElement("head"),meta=document.createElement("meta"),title=document.createElement("title"),style=document.createElement("style"),body=document.createElement("body"),message=document.createElement("main");
          meta.name="viewport";meta.content="width=device-width, initial-scale=1";title.textContent="Page unavailable";style.textContent="html{color-scheme:light dark}body{min-height:100vh;margin:0;display:grid;place-items:center;font:16px system-ui,sans-serif}main{padding:2rem;text-align:center}";message.textContent="This page is unavailable.";
          head.append(meta,title,style);body.append(message);root.append(head,body);
        }
        function reload(){
          if(reloading)return;
          reloading=true;
          try{sessionStorage.setItem(scrollKey,String(scrollY));}catch(_){}
          try{var guardedURL=new URL(location.href);guardedURL.searchParams.set(guardKey,c.id);history.replaceState(history.state,"",guardedURL);}catch(_){}
          reloadTimer=setTimeout(function(){if(!terminal)location.reload();},30);
        }
        function connect(){
          if(terminal||document.visibilityState==="hidden")return;
          if(source)source.close();
          source=new EventSource(c.events);
          source.addEventListener("state",function(event){
            try{var state=JSON.parse(event.data);if(String(state.id).toLowerCase()!==c.id){unavailable();return;}if(String(state.revision)!==c.revision)reload();}catch(_){}
          });
          source.addEventListener("unavailable",unavailable);
        }
        document.addEventListener("visibilitychange",function(){if(document.visibilityState==="hidden"){if(source){source.close();source=null;}}else connect();});
        addEventListener("pagehide",function(){if(source){source.close();source=null;}});
        addEventListener("pageshow",function(){if(!source)connect();});
        connect();
        })(\(configuration));</script>
        """
    }
}

private struct HTMLScan {
    var bodyClosingTag: String.Index?
    var htmlClosingTag: String.Index?
    var optsOutOfLiveUpdates = false
    var canInject = true

    init(_ html: String) {
        var cursor = html.startIndex
        var rawTextElement: String?
        var templateDepth = 0

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                cursor = html.index(after: cursor)
                continue
            }

            if let rawTextElement {
                guard let closing = Self.findClosingTag(rawTextElement, in: html, from: cursor) else {
                    // Appending here would put the client inside an unterminated raw-text
                    // element, where the browser would treat it as text rather than code.
                    canInject = false
                    return
                }
                cursor = closing
            }

            if html[cursor...].hasPrefix("<!--") {
                guard let end = html[cursor...].range(of: "-->")?.upperBound else {
                    canInject = false
                    return
                }
                cursor = end
                continue
            }

            guard let tagEnd = Self.tagEnd(in: html, from: cursor) else {
                canInject = false
                return
            }
            let tagText = String(html[html.index(after: cursor)..<tagEnd])
            let tag = ParsedTag(tagText)

            if tag.isClosing {
                if tag.name == "template" { templateDepth = max(0, templateDepth - 1) }
                if templateDepth == 0, tag.name == "body", bodyClosingTag == nil { bodyClosingTag = cursor }
                if templateDepth == 0, tag.name == "html", htmlClosingTag == nil { htmlClosingTag = cursor }
                if tag.name == rawTextElement { rawTextElement = nil }
            } else {
                if tag.name == "meta",
                   tag.attributes["name"]?.caseInsensitiveCompare("stele-live") == .orderedSame,
                   tag.attributes["content"].map(Self.decodeCharacterReferences)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("off") == .orderedSame {
                    optsOutOfLiveUpdates = true
                }
                if tag.name == "template" { templateDepth += 1 }
                if ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]
                    .contains(tag.name) {
                    rawTextElement = tag.name
                }
                // HTML has no closing tag for plaintext. Everything after it is text.
                if tag.name == "plaintext" {
                    canInject = false
                    return
                }
            }
            cursor = html.index(after: tagEnd)
        }
        if rawTextElement != nil { canInject = false }
    }

    private static func decodeCharacterReferences(_ value: String) -> String {
        var result = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            guard value[cursor] == "&",
                  let semicolon = value[cursor...].firstIndex(of: ";") else {
                result.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }
            let entityStart = value.index(after: cursor)
            let entity = String(value[entityStart..<semicolon])
            let scalar: UnicodeScalar?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
            } else if entity.hasPrefix("#") {
                scalar = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init)
            } else {
                scalar = ["Tab": "\t", "NewLine": "\n", "amp": "&", "AMP": "&"] [entity]?
                    .unicodeScalars.first
            }
            if let scalar {
                result.unicodeScalars.append(scalar)
                cursor = value.index(after: semicolon)
            } else {
                result.append("&")
                cursor = entityStart
            }
        }
        return result
    }

    private static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
        var cursor = html.index(after: start)
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func findClosingTag(
        _ name: String, in html: String, from start: String.Index
    ) -> String.Index? {
        var search = start
        while let candidate = html.range(
            of: "</\(name)", options: [.caseInsensitive], range: search..<html.endIndex
        ) {
            let afterName = candidate.upperBound
            if afterName == html.endIndex
                || html[afterName].isWhitespace
                || html[afterName] == ">" {
                return candidate.lowerBound
            }
            search = afterName
        }
        return nil
    }
}

private struct ParsedTag {
    let name: String
    let isClosing: Bool
    let attributes: [String: String]

    init(_ source: String) {
        let characters = Array(source)
        var index = 0
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        isClosing = index < characters.count && characters[index] == "/"
        if isClosing { index += 1 }
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        let nameStart = index
        while index < characters.count, characters[index].isLetter { index += 1 }
        name = String(characters[nameStart..<index]).lowercased()

        var parsed: [String: String] = [:]
        while index < characters.count {
            while index < characters.count,
                  characters[index].isWhitespace || characters[index] == "/" { index += 1 }
            let keyStart = index
            while index < characters.count,
                  !characters[index].isWhitespace,
                  characters[index] != "=",
                  characters[index] != "/" { index += 1 }
            guard keyStart < index else { break }
            let key = String(characters[keyStart..<index]).lowercased()
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            var value = ""
            if index < characters.count, characters[index] == "=" {
                index += 1
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                    let quote = characters[index]
                    index += 1
                    let valueStart = index
                    while index < characters.count, characters[index] != quote { index += 1 }
                    value = String(characters[valueStart..<index])
                    if index < characters.count { index += 1 }
                } else {
                    let valueStart = index
                    while index < characters.count,
                          !characters[index].isWhitespace,
                          characters[index] != "/" { index += 1 }
                    value = String(characters[valueStart..<index])
                }
            }
            parsed[key] = value
        }
        attributes = parsed
    }
}
