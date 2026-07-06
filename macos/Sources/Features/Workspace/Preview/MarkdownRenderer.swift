import Foundation

/// WP-7: 純 Swift 実装の Markdown → HTML 変換器。
///
/// 外部ライブラリ・外部通信を一切使わず、FR-1（docs/00_requirements.md §5）の
/// 対応要素だけをホワイトリスト方式で HTML に変換する:
/// 見出し / 段落 / 箇条書き・番号リスト（ネスト対応）/ 表 /
/// フェンス付きコードブロック / インラインコード / 強調 / リンク /
/// ローカル画像 / 引用 / 水平線 / バックスラッシュエスケープ。
///
/// CommonMark 完全準拠は目的としない（非対応: setext 見出し・インデント式
/// コードブロック・生 HTML パススルー・自動リンク・脚注・打ち消し線）。
///
/// セキュリティ（XSS 対策）:
/// - 入力中の生 HTML はブロック・インラインを問わず必ずエスケープし
///   「文字として」表示する（タグとして解釈させない）。
/// - リンク URL は http / https / mailto / file と相対パスのみ許可
///   （javascript: / data: 等のスキームは無効化しテキストだけ残す）。
/// - 画像はローカル（相対パス・絶対パス・file:）のみ許可。外部 URL や
///   プロトコル相対（//）の画像はブロックして代替テキスト表示にする。
enum MarkdownRenderer {
    /// FR-1: プレビュー対象の上限サイズ（5MB）。
    static let maxInputBytes = 5 * 1024 * 1024

    /// サイズ上限付き変換の結果。
    struct RenderResult: Equatable {
        /// 変換済みの HTML 断片（`<body>` の中身）。完全な HTML 文書は
        /// PreviewTemplate.page(...) が組み立てる。
        let html: String

        /// 入力が上限を超えたため先頭のみ変換した場合 true。
        /// 呼び出し側はこのフラグで警告バナーを表示する。
        let wasTruncated: Bool
    }

    // MARK: - 公開 API

    /// Markdown 文字列を HTML 断片（`<body>` の中身）へ変換する。
    /// サイズ上限は適用しない。上限が必要な場合は
    /// `renderWithSizeLimit(markdown:byteLimit:)` を使うこと。
    static func render(markdown: String) -> String {
        let lines = sanitize(markdown).components(separatedBy: "\n")
        return renderBlocks(lines)
    }

    /// サイズ上限（既定 5MB）付きで変換する。上限を超えた場合は
    /// UTF-8 の文字境界を壊さないよう先頭部分だけを変換し、
    /// `wasTruncated = true` を返す。
    static func renderWithSizeLimit(markdown: String, byteLimit: Int = maxInputBytes) -> RenderResult {
        guard markdown.utf8.count > byteLimit else {
            return RenderResult(html: render(markdown: markdown), wasTruncated: false)
        }
        return renderWithSizeLimit(data: Data(markdown.utf8), byteLimit: byteLimit)
    }

    /// バイト列（ファイル読み込み結果など）をサイズ上限付きで変換する。
    /// 不正な UTF-8 シーケンスは U+FFFD（置換文字）として安全に取り込む。
    static func renderWithSizeLimit(data: Data, byteLimit: Int = maxInputBytes) -> RenderResult {
        let truncated = data.count > byteLimit
        let capped = truncated ? data.prefix(byteLimit) : data[...]
        var text = decodeUTF8Lossy(capped)
        // 切断位置がマルチバイト文字の途中だった場合、末尾に置換文字が
        // 生まれるので取り除く（文字境界を保証する）。
        while truncated, text.hasSuffix("\u{FFFD}") {
            text.removeLast()
        }
        return RenderResult(html: render(markdown: text), wasTruncated: truncated)
    }

    /// 不正な UTF-8 バイトを U+FFFD に置き換えながらデコードする
    /// （壊れたファイルでもクラッシュ・欠落なしで表示するため）。
    private static func decodeUTF8Lossy(_ data: Data.SubSequence) -> String {
        if let strict = String(bytes: data, encoding: .utf8) { return strict }
        var result = ""
        result.reserveCapacity(data.count)
        var decoder = UTF8()
        var iterator = data.makeIterator()
        var finished = false
        while !finished {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                result.unicodeScalars.append(scalar)
            case .emptyInput:
                finished = true
            case .error:
                result.unicodeScalars.append("\u{FFFD}")
            }
        }
        return result
    }

    /// HTML 特殊文字（& < > " '）を実体参照へエスケープする。
    static func escapeHTML(_ text: String) -> String {
        let needsEscape = text.utf8.contains { byte in
            byte == 0x26 || byte == 0x3C || byte == 0x3E || byte == 0x22 || byte == 0x27
        }
        guard needsEscape else { return text }
        var out = ""
        out.reserveCapacity(text.count + 16)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 前処理

    /// 改行コードの正規化と、内部トークンに使う私用領域スカラー
    /// （U+E000/U+E001）・NUL の除去。悪意ある入力が内部トークンを
    /// 偽造できないようにするための防御。
    private static func sanitize(_ markdown: String) -> String {
        var text = markdown
        if text.contains("\r") {
            text = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if text.unicodeScalars.contains(where: isForbiddenScalar) {
            let scalars = text.unicodeScalars.filter { !isForbiddenScalar($0) }
            text = String(String.UnicodeScalarView(scalars))
        }
        return text
    }

    private static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0 || scalar.value == 0xE000 || scalar.value == 0xE001
    }

    // MARK: - 正規表現（コンパイル済みキャッシュ）

    private static func makeRegex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("invalid regex pattern: \(pattern)")
        }
        return regex
    }

    private static let headingRegex = makeRegex(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$"#)
    private static let trailingHashRegex = makeRegex(#"[ \t]+#+$"#)
    private static let thematicBreakRegex = makeRegex(#"^ {0,3}([-_*])[ \t]*(?:\1[ \t]*){2,}$"#)
    private static let fenceOpenRegex = makeRegex(#"^ {0,3}(`{3,}|~{3,})[ \t]*(.*)$"#)
    private static let fenceCloseRegex = makeRegex(#"^ {0,3}(`{3,}|~{3,})[ \t]*$"#)
    private static let quoteMarkerRegex = makeRegex(#"^ {0,3}> ?"#)
    private static let bulletItemRegex = makeRegex(#"^( {0,3})([-*+])(?:( +)(.*))?$"#)
    private static let orderedItemRegex = makeRegex(#"^( {0,3})(\d{1,9})([.)])(?:( +)(.*))?$"#)
    private static let codeSpanRegex = makeRegex(#"(`+)(.+?)\1"#, [.dotMatchesLineSeparators])
    private static let backslashEscapeRegex = makeRegex(#"\\([\\`*_{}\[\]()#+\-.!|~<>"'&])"#)
    private static let imageRegex = makeRegex(#"!\[([^\[\]]*)\]\(([^()\s]*)\)"#)
    private static let linkRegex = makeRegex(#"\[([^\[\]]+)\]\(([^()\s]*)\)"#)
    private static let strongEmRegex = makeRegex(#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, [.dotMatchesLineSeparators])
    private static let strongAsteriskRegex = makeRegex(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, [.dotMatchesLineSeparators])
    private static let strongUnderscoreRegex = makeRegex(
        #"(?<![A-Za-z0-9_])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9_])"#, [.dotMatchesLineSeparators])
    private static let emphasisAsteriskRegex = makeRegex(#"(?<!\*)\*(?!\*)(?=\S)([^*]+?)(?<=\S)\*(?!\*)"#)
    private static let emphasisUnderscoreRegex = makeRegex(#"(?<![A-Za-z0-9_])_(?!_)(?=\S)([^_]+?)(?<=\S)_(?![A-Za-z0-9_])"#)
    private static let hardBreakRegex = makeRegex(#" {2,}\n"#)
    private static let tokenRegex = makeRegex("\u{E000}(\\d+)\u{E001}")

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    /// マッチ箇所をコールバックの戻り値で置き換える汎用ヘルパー。
    private static func replaceMatches(
        of regex: NSRegularExpression,
        in text: String,
        _ transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, nsText)
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    // MARK: - ブロックレベル変換

    private static func renderBlocks(_ lines: [String]) -> String {
        var html = ""
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                index += 1
                continue
            }
            if let fence = fenceOpening(line) {
                html += consumeFence(lines, &index, fence)
                continue
            }
            if let heading = headingHTML(line) {
                html += heading
                index += 1
                continue
            }
            if isThematicBreak(line) {
                html += "<hr>\n"
                index += 1
                continue
            }
            if isBlockquoteLine(line) {
                html += consumeBlockquote(lines, &index)
                continue
            }
            if let marker = listMarker(line) {
                html += consumeList(lines, &index, first: marker)
                continue
            }
            if isTableStart(lines, index) {
                html += consumeTable(lines, &index)
                continue
            }
            html += consumeParagraph(lines, &index)
        }
        return html
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 段落の途中で別ブロックが始まるか（段落の打ち切り判定）。
    private static func startsBlock(_ lines: [String], _ index: Int) -> Bool {
        let line = lines[index]
        if fenceOpening(line) != nil { return true }
        if headingHTML(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if isBlockquoteLine(line) { return true }
        if listMarker(line) != nil { return true }
        if isTableStart(lines, index) { return true }
        return false
    }

    // MARK: 見出し

    private static func headingHTML(_ line: String) -> String? {
        guard line.contains("#") else { return nil }
        let nsLine = line as NSString
        guard let match = headingRegex.firstMatch(in: line, range: fullRange(line)) else { return nil }
        let level = match.range(at: 1).length
        var content = ""
        if match.range(at: 2).location != NSNotFound {
            content = nsLine.substring(with: match.range(at: 2))
        }
        // 閉じハッシュ（`# 見出し #` の末尾 #）を取り除く
        content = trailingHashRegex.stringByReplacingMatches(
            in: content, range: fullRange(content), withTemplate: "")
        return "<h\(level)>" + renderInline(content) + "</h\(level)>\n"
    }

    // MARK: 水平線

    private static func isThematicBreak(_ line: String) -> Bool {
        guard let first = line.drop(while: { $0 == " " }).first,
              first == "-" || first == "_" || first == "*" else { return false }
        return thematicBreakRegex.firstMatch(in: line, range: fullRange(line)) != nil
    }

    // MARK: コードブロック（フェンス）

    private struct FenceOpening {
        let char: Character
        let length: Int
        let info: String
    }

    private static func fenceOpening(_ line: String) -> FenceOpening? {
        guard line.contains("```") || line.contains("~~~") else { return nil }
        let nsLine = line as NSString
        guard let match = fenceOpenRegex.firstMatch(in: line, range: fullRange(line)) else { return nil }
        let fence = nsLine.substring(with: match.range(at: 1))
        let info = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        // CommonMark: バッククォートフェンスの info 文字列に ` は使えない
        if fence.hasPrefix("`"), info.contains("`") { return nil }
        return FenceOpening(char: fence.first ?? "`", length: fence.count, info: info)
    }

    private static func consumeFence(_ lines: [String], _ index: inout Int, _ fence: FenceOpening) -> String {
        index += 1
        var content: [String] = []
        while index < lines.count {
            let line = lines[index]
            if let match = fenceCloseRegex.firstMatch(in: line, range: fullRange(line)) {
                let closing = (line as NSString).substring(with: match.range(at: 1))
                if closing.first == fence.char, closing.count >= fence.length {
                    index += 1
                    break
                }
            }
            content.append(line)
            index += 1
        }
        let language = fence.info.split(separator: " ").first.map(String.init) ?? ""
        let classAttr = language.isEmpty ? "" : " class=\"language-\(escapeHTML(language))\""
        var body = escapeHTML(content.joined(separator: "\n"))
        if !body.isEmpty { body += "\n" }
        return "<pre><code\(classAttr)>\(body)</code></pre>\n"
    }

    // MARK: 引用

    private static func isBlockquoteLine(_ line: String) -> Bool {
        guard line.contains(">") else { return false }
        return quoteMarkerRegex.firstMatch(in: line, range: fullRange(line)) != nil
    }

    private static func consumeBlockquote(_ lines: [String], _ index: inout Int) -> String {
        var inner: [String] = []
        while index < lines.count, isBlockquoteLine(lines[index]) {
            let line = lines[index]
            inner.append(quoteMarkerRegex.stringByReplacingMatches(
                in: line, range: fullRange(line), withTemplate: ""))
            index += 1
        }
        return "<blockquote>\n" + renderBlocks(inner) + "</blockquote>\n"
    }

    // MARK: リスト

    private struct ListItemMarker {
        let indent: Int
        let ordered: Bool
        let number: Int
        /// アイテム本文の開始カラム。以降の行はこのカラム分の
        /// インデントを剥がしてアイテム内容として再帰処理する。
        let contentIndent: Int
        let content: String
    }

    private static func listMarker(_ line: String) -> ListItemMarker? {
        guard let first = line.drop(while: { $0 == " " }).first,
              first == "-" || first == "*" || first == "+" || first.isNumber else { return nil }
        let nsLine = line as NSString
        if let match = bulletItemRegex.firstMatch(in: line, range: fullRange(line)) {
            let indent = match.range(at: 1).length
            let spaces = match.range(at: 3).location == NSNotFound ? 1 : match.range(at: 3).length
            let content = match.range(at: 4).location == NSNotFound
                ? "" : nsLine.substring(with: match.range(at: 4))
            return ListItemMarker(
                indent: indent,
                ordered: false,
                number: 1,
                contentIndent: indent + 1 + min(spaces, 4),
                content: content)
        }
        if let match = orderedItemRegex.firstMatch(in: line, range: fullRange(line)) {
            let indent = match.range(at: 1).length
            let digits = match.range(at: 2).length
            let number = Int(nsLine.substring(with: match.range(at: 2))) ?? 1
            let spaces = match.range(at: 4).location == NSNotFound ? 1 : match.range(at: 4).length
            let content = match.range(at: 5).location == NSNotFound
                ? "" : nsLine.substring(with: match.range(at: 5))
            return ListItemMarker(
                indent: indent,
                ordered: true,
                number: number,
                contentIndent: indent + digits + 1 + min(spaces, 4),
                content: content)
        }
        return nil
    }

    private static func consumeList(_ lines: [String], _ index: inout Int, first: ListItemMarker) -> String {
        let ordered = first.ordered
        var itemsHTML = ""
        while index < lines.count,
              let marker = listMarker(lines[index]),
              marker.ordered == ordered,
              marker.indent < first.contentIndent {
            index += 1
            var itemLines: [String] = [marker.content]
            while index < lines.count {
                let line = lines[index]
                if isBlank(line) {
                    itemLines.append("")
                    index += 1
                    continue
                }
                if indentWidth(line) >= marker.contentIndent {
                    itemLines.append(stripIndent(line, marker.contentIndent))
                    index += 1
                    continue
                }
                break
            }
            while let last = itemLines.last, isBlank(last) {
                itemLines.removeLast()
            }
            itemsHTML += "<li>" + listItemBody(itemLines) + "</li>\n"
        }
        let tag = ordered ? "ol" : "ul"
        let startAttr = (ordered && first.number != 1) ? " start=\"\(first.number)\"" : ""
        return "<\(tag)\(startAttr)>\n" + itemsHTML + "</\(tag)>\n"
    }

    /// アイテム内容をブロックとして再帰変換し、段落が 1 つだけなら
    /// `<p>` を外す（タイトルリスト表示）。複数段落（ルーズリスト）は
    /// `<p>` を維持する。
    private static func listItemBody(_ lines: [String]) -> String {
        let html = renderBlocks(lines).trimmingCharacters(in: .whitespacesAndNewlines)
        guard html.hasPrefix("<p>"), let close = html.range(of: "</p>") else { return html }
        let rest = html[close.upperBound...]
        guard !rest.contains("<p>") else { return html }
        let inner = html[html.index(html.startIndex, offsetBy: 3)..<close.lowerBound]
        let restTrimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return restTrimmed.isEmpty ? String(inner) : inner + "\n" + restTrimmed
    }

    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " {
                width += 1
            } else if ch == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    private static func stripIndent(_ line: String, _ columns: Int) -> String {
        var remaining = columns
        var idx = line.startIndex
        while idx < line.endIndex, remaining > 0 {
            let ch = line[idx]
            if ch == " " {
                remaining -= 1
            } else if ch == "\t" {
                remaining -= 4
            } else {
                break
            }
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }

    // MARK: 表

    private enum ColumnAlignment: String {
        case left
        case center
        case right
    }

    private static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard lines[index].contains("|"), index + 1 < lines.count else { return false }
        guard isTableDelimiterRow(lines[index + 1]) else { return false }
        let headers = splitTableRow(lines[index])
        let delimiters = splitTableRow(lines[index + 1])
        return !headers.isEmpty && headers.count == delimiters.count
    }

    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        guard trimmed.allSatisfy({ $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }) else {
            return false
        }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// エスケープ済みパイプ（\|）を保持したままセル分割する。
    private static func splitTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var cells: [String] = []
        var current = ""
        var afterBackslash = false
        for ch in trimmed {
            if afterBackslash {
                current.append(ch)
                afterBackslash = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                afterBackslash = true
                continue
            }
            if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current)
        if trimmed.hasPrefix("|"), !cells.isEmpty {
            cells.removeFirst()
        }
        if trimmed.hasSuffix("\\|") == false, trimmed.hasSuffix("|"),
           let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func columnAlignment(_ delimiterCell: String) -> ColumnAlignment? {
        let leading = delimiterCell.hasPrefix(":")
        let trailing = delimiterCell.hasSuffix(":")
        switch (leading, trailing) {
        case (true, true): return .center
        case (false, true): return .right
        case (true, false): return .left
        case (false, false): return nil
        }
    }

    private static func alignAttr(_ alignment: ColumnAlignment?) -> String {
        guard let alignment else { return "" }
        return " style=\"text-align:\(alignment.rawValue)\""
    }

    private static func consumeTable(_ lines: [String], _ index: inout Int) -> String {
        let headers = splitTableRow(lines[index])
        let alignments = splitTableRow(lines[index + 1]).map(columnAlignment)
        index += 2
        var html = "<table>\n<thead>\n<tr>"
        for (column, cell) in headers.enumerated() {
            html += "<th\(alignAttr(alignments[column]))>" + renderInline(cell) + "</th>"
        }
        html += "</tr>\n</thead>\n"
        var rows: [[String]] = []
        while index < lines.count, !isBlank(lines[index]), lines[index].contains("|") {
            rows.append(splitTableRow(lines[index]))
            index += 1
        }
        if !rows.isEmpty {
            html += "<tbody>\n"
            for row in rows {
                html += "<tr>"
                for column in 0..<headers.count {
                    let cell = column < row.count ? row[column] : ""
                    html += "<td\(alignAttr(alignments[column]))>" + renderInline(cell) + "</td>"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        html += "</table>\n"
        return html
    }

    // MARK: 段落

    private static func consumeParagraph(_ lines: [String], _ index: inout Int) -> String {
        var collected: [String] = [lines[index]]
        index += 1
        while index < lines.count, !isBlank(lines[index]), !startsBlock(lines, index) {
            collected.append(lines[index])
            index += 1
        }
        let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return "<p>" + renderInline(text) + "</p>\n"
    }

    // MARK: - インライン変換

    /// インライン要素を変換する。処理順序が安全性の要:
    /// 1. インラインコードを退避（中身は装飾処理から保護）
    /// 2. バックスラッシュエスケープを退避
    /// 3. テキスト全体を HTML エスケープ（ここで生 HTML が無害化される）
    /// 4. 以降は「エスケープ済みテキスト」に対してタグを差し込む
    private static func renderInline(_ raw: String) -> String {
        var stash: [String] = []
        func stashToken(_ html: String) -> String {
            stash.append(html)
            return "\u{E000}\(stash.count - 1)\u{E001}"
        }

        var text = raw

        // 1. インラインコード
        if text.contains("`") {
            text = replaceMatches(of: codeSpanRegex, in: text) { match, nsText in
                var content = nsText.substring(with: match.range(at: 2))
                if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                   !content.trimmingCharacters(in: .whitespaces).isEmpty {
                    content = String(content.dropFirst().dropLast())
                }
                return stashToken("<code>" + escapeHTML(content) + "</code>")
            }
        }

        // 2. バックスラッシュエスケープ（\* など → 文字そのもの）
        if text.contains("\\") {
            text = replaceMatches(of: backslashEscapeRegex, in: text) { match, nsText in
                stashToken(escapeHTML(nsText.substring(with: match.range(at: 1))))
            }
        }

        // 3. HTML エスケープ（XSS 対策の中核）
        text = escapeHTML(text)

        // 4. 画像（ローカルのみ許可）
        if text.contains("![") {
            text = replaceMatches(of: imageRegex, in: text) { match, nsText in
                let alt = nsText.substring(with: match.range(at: 1))
                let src = nsText.substring(with: match.range(at: 2))
                guard isLocalImageSource(src) else {
                    let label = alt.isEmpty ? src : alt
                    return stashToken("<span class=\"blocked-external-image\">") + label + stashToken("</span>")
                }
                return stashToken("<img src=\"\(src)\" alt=\"\(alt)\">")
            }
        }

        // 5. リンク（危険スキームは無効化してテキストだけ残す）
        if text.contains("[") {
            text = replaceMatches(of: linkRegex, in: text) { match, nsText in
                let label = nsText.substring(with: match.range(at: 1))
                let url = nsText.substring(with: match.range(at: 2))
                guard isAllowedLinkURL(url) else { return label }
                return stashToken("<a href=\"\(url)\">") + label + stashToken("</a>")
            }
        }

        // 6. 強調（*** → ** → * の順で処理）
        if text.contains("*") {
            text = strongEmRegex.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "<strong><em>$1</em></strong>")
            text = strongAsteriskRegex.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "<strong>$1</strong>")
            text = emphasisAsteriskRegex.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "<em>$1</em>")
        }
        if text.contains("_") {
            text = strongUnderscoreRegex.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "<strong>$1</strong>")
            text = emphasisUnderscoreRegex.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "<em>$1</em>")
        }

        // 7. ハードブレーク（行末スペース 2 つ → <br>）
        if text.contains("\n") {
            text = hardBreakRegex.stringByReplacingMatches(
                in: text, range: fullRange(text), withTemplate: "<br>\n")
        }

        // 8. 退避したトークンを復元（入れ子があるので複数回）
        var iterations = 0
        while text.contains("\u{E000}"), iterations < 10 {
            text = replaceMatches(of: tokenRegex, in: text) { match, nsText in
                let tokenIndex = Int(nsText.substring(with: match.range(at: 1))) ?? -1
                return stash.indices.contains(tokenIndex) ? stash[tokenIndex] : ""
            }
            iterations += 1
        }
        return text
    }

    // MARK: URL 検査（XSS・外部通信対策）

    /// URL 先頭のスキーム部分を返す。スキームが無い（相対パス等）なら nil。
    private static func urlScheme(_ url: String) -> String? {
        guard let colonIndex = url.firstIndex(of: ":") else { return nil }
        let scheme = url[url.startIndex..<colonIndex]
        guard let first = scheme.first, first.isLetter else { return nil }
        let isSchemeChars = scheme.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }
        guard isSchemeChars else { return nil }
        return scheme.lowercased()
    }

    /// リンクとして許可する URL か。javascript: / data: 等は拒否する。
    private static func isAllowedLinkURL(_ url: String) -> Bool {
        guard let scheme = urlScheme(url) else { return true }
        return scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "file"
    }

    /// 画像ソースとして許可するか（FR-1: ローカル画像のみ・外部通信ゼロ）。
    private static func isLocalImageSource(_ src: String) -> Bool {
        if src.hasPrefix("//") { return false }
        guard let scheme = urlScheme(src) else { return true }
        return scheme == "file"
    }
}
