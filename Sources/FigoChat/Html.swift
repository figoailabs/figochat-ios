import Foundation

/// A piece of message text with one style; a message is rendered as a list of these.
public struct FigoTextRun: Equatable, Hashable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    /// Url opened when the run is tapped.
    public var link: String?

    public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.link = link
    }

    fileprivate func sameStyle(_ other: FigoTextRun) -> Bool {
        bold == other.bold && italic == other.italic && underline == other.underline && link == other.link
    }

    fileprivate func with(text: String, link: String? = nil) -> FigoTextRun {
        FigoTextRun(text: text, bold: bold, italic: italic, underline: underline, link: link ?? self.link)
    }
}

/// Parses the HTML that assistant replies and live agent messages arrive in into styled runs, so the chat can
/// render it natively (no web view):
/// - `<b>`, `<strong>` and headings are bold, `<i>`/`<em>` italic, `<u>` underlined, `<a href>` a tappable link;
/// - paragraphs, divs, headings and `<br>` break lines; `<ul>` items get `• ` bullets and `<ol>` items `1. `, `2. `…;
/// - other tags (span, font…) keep their text and drop their styling; entities are decoded;
/// - bare urls in the text become tappable too.
/// Plain text (no tags) keeps its own line breaks. HTML that arrives entity-encoded (`&lt;p&gt;…`) is decoded first.
public func htmlToRuns(_ input: String) -> [FigoTextRun] {
    var s = input
    if !matches(s, tagPattern), matches(s, encodedTagPattern) { s = decodeEntities(s) }
    let runs = matches(s, tagPattern) ? parseHtml(s) : parsePlain(decodeEntities(s))
    return linkify(merge(runs))
}

/// The same message as plain text: no tags and no markdown, with line breaks, `• ` bullets and `1. ` numbers kept.
/// This is what `onMessageReceived` listeners get.
public func htmlToText(_ input: String) -> String {
    htmlToRuns(input).map(\.text).joined()
}

/// Runs for text the user typed: never parsed as HTML, only urls are made tappable.
public func plainToRuns(_ text: String) -> [FigoTextRun] {
    linkify([FigoTextRun(text: text)])
}

// MARK: - Parsing

private let tagPattern = #"</?[a-z][a-z0-9]*(\s[^<>]*)?/?>"#
private let encodedTagPattern = #"&lt;/?[a-z][a-z0-9]*(\s[\s\S]*?)?/?&gt;"#
private let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>)]*[^\s<>).,!?;:'"]"#)

private func parsePlain(_ text: String) -> [FigoTextRun] {
    // `**bold**` is drawn bold rather than shown with its asterisks
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let ns = t as NSString
    var runs: [FigoTextRun] = []
    var last = 0
    forEachMatch(t, #"\*\*([^*\n]+)\*\*"#) { range, groups in
        if range.location > last { runs.append(FigoTextRun(text: ns.substring(with: NSRange(location: last, length: range.location - last)))) }
        runs.append(FigoTextRun(text: groups[1] ?? "", bold: true))
        last = range.location + range.length
    }
    if last < ns.length { runs.append(FigoTextRun(text: ns.substring(from: last))) }
    return runs
}

private func parseHtml(_ html: String) -> [FigoTextRun] {
    var s = replace(html, #"<(script|style|head|title)\b[\s\S]*?</\1\s*>"#, with: "")
    s = replace(s, #"<!--[\s\S]*?-->"#, with: "")
    var out = RunBuilder()
    var bold = 0
    var italic = 0
    var underline = 0
    var links: [String] = []
    var lists: [(ordered: Bool, n: Int)] = []
    func style(_ text: String) -> FigoTextRun {
        let link = links.last.flatMap { $0.isEmpty ? nil : $0 }
        return FigoTextRun(text: text, bold: bold > 0, italic: italic > 0, underline: underline > 0, link: link)
    }

    forEachMatch(s, #"<(/?)([a-z][a-z0-9]*)\b([^>]*)>|([^<]+)|<"#) { _, m in
        guard let tag = m[2] else {
            out.text(style(decodeEntities(replace(m[4] ?? "<", #"\s+"#, with: " "))))
            return
        }
        let closing = m[1] == "/"
        let name = tag.lowercased()
        let delta = closing ? -1 : 1
        switch name {
        case "br":
            out.lineBreak()
        case "b", "strong":
            bold = max(0, bold + delta)
        case "i", "em":
            italic = max(0, italic + delta)
        case "u", "ins":
            underline = max(0, underline + delta)
        case "a":
            if closing { _ = links.popLast() } else { links.append(safeHref(attr(m[3] ?? "", "href"))) }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            out.block(2)
            bold = max(0, bold + delta)
        case "ul", "ol":
            out.block(lists.isEmpty ? 2 : 1)
            if closing { _ = lists.popLast() } else { lists.append((ordered: name == "ol", n: 0)) }
        case "li":
            if !closing {
                out.block(1)
                let indent = String(repeating: "    ", count: max(0, lists.count - 1))
                var marker = "• "
                if let index = lists.indices.last, lists[index].ordered {
                    lists[index].n += 1
                    marker = "\(lists[index].n). "
                }
                out.raw(indent + marker)
            }
        case "p", "blockquote", "table", "pre":
            out.block(2)
        case "div", "tr", "section", "article", "header", "footer":
            out.block(1)
        default:
            break // span, font, img… keep the text, drop the tag
        }
    }
    return out.finish()
}

/// Collects runs while collapsing whitespace the way a browser does.
private struct RunBuilder {
    private var runs: [FigoTextRun] = []
    private var pendingBreaks = 0

    mutating func block(_ lines: Int) {
        if !runs.isEmpty { pendingBreaks = max(pendingBreaks, lines) }
    }

    mutating func lineBreak() {
        if !runs.isEmpty { pendingBreaks = min(pendingBreaks + 1, 2) }
    }

    mutating func text(_ run: FigoTextRun) {
        var run = run
        let lastText = runs.last?.text ?? ""
        if pendingBreaks > 0 || runs.isEmpty || lastText.hasSuffix(" ") || lastText.hasSuffix("\n") {
            run.text = String(run.text.drop(while: { $0 == " " }))
        }
        if run.text.isEmpty { return }
        flush()
        runs.append(run)
    }

    /// Text that is written as is, such as a list bullet.
    mutating func raw(_ text: String) {
        flush()
        runs.append(FigoTextRun(text: text))
    }

    mutating func finish() -> [FigoTextRun] {
        trimTrailingSpaces()
        return runs
    }

    private mutating func flush() {
        if pendingBreaks > 0 && !runs.isEmpty {
            trimTrailingSpaces()
            runs.append(FigoTextRun(text: String(repeating: "\n", count: pendingBreaks)))
        }
        pendingBreaks = 0
    }

    private mutating func trimTrailingSpaces() {
        while let index = runs.indices.last {
            while runs[index].text.hasSuffix(" ") { runs[index].text.removeLast() }
            if !runs[index].text.isEmpty { return }
            runs.removeLast()
        }
    }
}

private func attr(_ attrs: String, _ name: String) -> String {
    var value = ""
    if let m = firstMatch(attrs, #"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) {
        value = m[1] ?? m[2] ?? m[3] ?? ""
    }
    return decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Only web, mail and phone links are tappable.
private func safeHref(_ href: String) -> String {
    matches(href, #"^(https?:|mailto:|tel:)"#) ? href : ""
}

private func merge(_ runs: [FigoTextRun]) -> [FigoTextRun] {
    var merged: [FigoTextRun] = []
    for run in runs {
        if let index = merged.indices.last, merged[index].sameStyle(run) {
            merged[index].text += run.text
        } else {
            merged.append(run)
        }
    }
    return merged
}

private func linkify(_ runs: [FigoTextRun]) -> [FigoTextRun] {
    var result: [FigoTextRun] = []
    for run in runs {
        guard run.link == nil, let urlRegex else {
            result.append(run)
            continue
        }
        let ns = run.text as NSString
        var last = 0
        for match in urlRegex.matches(in: run.text, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            if r.location > last { result.append(run.with(text: ns.substring(with: NSRange(location: last, length: r.location - last)))) }
            let url = ns.substring(with: r)
            result.append(run.with(text: url, link: url))
            last = r.location + r.length
        }
        if last < ns.length { result.append(last > 0 ? run.with(text: ns.substring(from: last)) : run) }
    }
    return result
}

// MARK: - Entities

private let namedEntities: [String: String] = [
    "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
    "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}",
    "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}", "bull": "\u{2022}",
    "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "naira": "\u{20A6}",
]

private func decodeEntities(_ input: String) -> String {
    var s = replace(input, #"&#x([0-9a-f]+);"#) { fromCode(UInt32($0[1], radix: 16), fallback: $0[0]) }
    s = replace(s, #"&#(\d+);"#) { fromCode(UInt32($0[1]), fallback: $0[0]) }
    s = replace(s, #"&([a-z]+);"#) { namedEntities[$0[1].lowercased()] ?? $0[0] }
    return replace(s, "&amp;", with: "&")
}

private func fromCode(_ code: UInt32?, fallback: String) -> String {
    guard let code, let scalar = Unicode.Scalar(code) else { return fallback }
    return String(Character(scalar))
}

// MARK: - Regex helpers (case-insensitive)

private func regex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private func matches(_ s: String, _ pattern: String) -> Bool {
    regex(pattern)?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// Calls `body` for each match with its range and groups (an unmatched group is nil), in UTF-16 offsets.
private func forEachMatch(_ s: String, _ pattern: String, _ body: (NSRange, [String?]) -> Void) {
    guard let re = regex(pattern) else { return }
    let ns = s as NSString
    for match in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        body(match.range, groups(of: match, in: ns))
    }
}

private func firstMatch(_ s: String, _ pattern: String) -> [String?]? {
    let ns = s as NSString
    guard let match = regex(pattern)?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return groups(of: match, in: ns)
}

private func groups(of match: NSTextCheckingResult, in ns: NSString) -> [String?] {
    (0..<match.numberOfRanges).map { i in
        let r = match.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

private func replace(_ s: String, _ pattern: String, with template: String) -> String {
    guard let re = regex(pattern) else { return s }
    return re.stringByReplacingMatches(
        in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: template)
    )
}

/// Replaces every match with the transform's result; the transform gets the whole match and its groups
/// (an unmatched group is "").
private func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
    let ns = s as NSString
    var result = ""
    var last = 0
    forEachMatch(s, pattern) { range, groups in
        result += ns.substring(with: NSRange(location: last, length: range.location - last))
        result += transform(groups.map { $0 ?? "" })
        last = range.location + range.length
    }
    result += ns.substring(from: last)
    return result
}
