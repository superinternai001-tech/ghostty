import XCTest
@testable import Ghostty

/// WP-7 MarkdownRenderer の単体テスト。
/// docs/05_test-plan.md §2（UT 観点）・§5（ホワイトリスト方式）に基づき、
/// FR-1 の対応要素ごとに 正常系 → 境界値 → 異常系 の順で検査する。
final class MarkdownRendererTests: XCTestCase {
    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - 見出し

    func testHeadingLevels1To6() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "# H1"), "<h1>H1</h1>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "## H2"), "<h2>H2</h2>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "###### H6"), "<h6>H6</h6>\n")
    }

    func testHeadingWithInlineFormatting() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "# **強調** 見出し"),
            "<h1><strong>強調</strong> 見出し</h1>\n")
    }

    func testHeadingClosingHashesAreStripped() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "## Hi ##"), "<h2>Hi</h2>\n")
    }

    func testHeadingEmptyContent() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "##"), "<h2></h2>\n")
    }

    func testSevenHashesIsNotHeading() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "####### x"), "<p>####### x</p>\n")
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "#tag"), "<p>#tag</p>\n")
    }

    // MARK: - 段落・改行

    func testParagraphsSeparatedByBlankLine() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "a\n\nb"), "<p>a</p>\n<p>b</p>\n")
    }

    func testSoftWrapKeptInsideParagraph() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "a\nb"), "<p>a\nb</p>\n")
    }

    func testHardBreakWithTwoTrailingSpaces() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "a  \nb"), "<p>a<br>\nb</p>\n")
    }

    // MARK: - 強調

    func testStrongWithAsterisksAndUnderscores() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "**b**"), "<p><strong>b</strong></p>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "__b__"), "<p><strong>b</strong></p>\n")
    }

    func testEmphasisWithAsteriskAndUnderscore() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "*i*"), "<p><em>i</em></p>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "_i_"), "<p><em>i</em></p>\n")
    }

    func testStrongEmphasisCombined() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "***x***"),
            "<p><strong><em>x</em></strong></p>\n")
    }

    func testNestedEmphasisInsideStrong() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "**a *b* c**"),
            "<p><strong>a <em>b</em> c</strong></p>\n")
    }

    func testIntrawordUnderscoreIsNotEmphasis() {
        let html = MarkdownRenderer.render(markdown: "snake_case_name")
        XCTAssertFalse(html.contains("<em>"))
        XCTAssertTrue(html.contains("snake_case_name"))
    }

    func testUnclosedAsteriskStaysLiteral() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "*unclosed"), "<p>*unclosed</p>\n")
    }

    func testBackslashEscapePreventsEmphasis() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: #"\*not\*"#), "<p>*not*</p>\n")
    }

    // MARK: - インラインコード

    func testInlineCode() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "`x`"), "<p><code>x</code></p>\n")
    }

    func testInlineCodeEscapesHTML() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "`<b>&`"),
            "<p><code>&lt;b&gt;&amp;</code></p>\n")
    }

    func testDoubleBacktickAllowsEmbeddedBacktick() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "`` a`b ``"),
            "<p><code>a`b</code></p>\n")
    }

    func testNoEmphasisInsideInlineCode() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "`*x*`"),
            "<p><code>*x*</code></p>\n")
    }

    // MARK: - コードブロック（フェンス）

    func testFencedCodeBlockWithLanguage() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "```swift\nlet a = 1\n```"),
            "<pre><code class=\"language-swift\">let a = 1\n</code></pre>\n")
    }

    func testFencedCodeBlockEscapesScriptTag() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "```\n<script>alert(1)</script>\n```"),
            "<pre><code>&lt;script&gt;alert(1)&lt;/script&gt;\n</code></pre>\n")
    }

    func testTildeFence() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "~~~\nx\n~~~"),
            "<pre><code>x\n</code></pre>\n")
    }

    func testUnclosedFenceRunsToEndOfInput() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "```\nabc"),
            "<pre><code>abc\n</code></pre>\n")
    }

    func testMarkdownSyntaxInsideFenceStaysLiteral() {
        let html = MarkdownRenderer.render(markdown: "```\n# not a heading\n- not a list\n```")
        XCTAssertTrue(html.contains("# not a heading"))
        XCTAssertTrue(html.contains("- not a list"))
        XCTAssertFalse(html.contains("<h1>"))
        XCTAssertFalse(html.contains("<ul>"))
    }

    func testFenceInfoStringIsEscaped() {
        let html = MarkdownRenderer.render(markdown: "```a\"b\ncode\n```")
        XCTAssertTrue(html.contains("class=\"language-a&quot;b\""))
    }

    // MARK: - リスト

    func testUnorderedList() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "- a\n- b"),
            "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
    }

    func testOrderedList() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "1. a\n2. b"),
            "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n")
    }

    func testOrderedListStartNumber() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "3. a"),
            "<ol start=\"3\">\n<li>a</li>\n</ol>\n")
    }

    func testNestedUnorderedList() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "- a\n  - b"),
            "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul></li>\n</ul>\n")
    }

    func testOrderedListNestedInUnordered() {
        let html = MarkdownRenderer.render(markdown: "- a\n  1. b")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>b</li>"))
    }

    func testDeeplyNestedListTenLevels() {
        var lines: [String] = []
        for level in 0..<10 {
            lines.append(String(repeating: "  ", count: level) + "- L\(level)")
        }
        let html = MarkdownRenderer.render(markdown: lines.joined(separator: "\n"))
        XCTAssertEqual(occurrences(of: "<ul>", in: html), 10)
        XCTAssertTrue(html.contains("L9"))
    }

    func testLooseListItemKeepsParagraphs() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "- a\n\n  b"),
            "<ul>\n<li><p>a</p>\n<p>b</p></li>\n</ul>\n")
    }

    func testBulletWithoutSpaceIsNotList() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "-nospace"), "<p>-nospace</p>\n")
    }

    func testMarkerTypeSwitchStartsNewList() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "- a\n1. b"),
            "<ul>\n<li>a</li>\n</ul>\n<ol>\n<li>b</li>\n</ol>\n")
    }

    // MARK: - 表

    func testBasicTable() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"),
            "<table>\n<thead>\n<tr><th>A</th><th>B</th></tr>\n</thead>\n"
                + "<tbody>\n<tr><td>1</td><td>2</td></tr>\n</tbody>\n</table>\n")
    }

    func testTableAlignment() {
        let html = MarkdownRenderer.render(
            markdown: "| L | C | R |\n| :-- | :-: | --: |\n| a | b | c |")
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">L</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">C</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">R</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">c</td>"))
    }

    func testTableRowCellCountMismatchIsNormalized() {
        let html = MarkdownRenderer.render(
            markdown: "| A | B |\n| --- | --- |\n| 1 |\n| 1 | 2 | 3 |")
        // 不足セルは空で補完、過剰セルは切り捨て（ヘッダ列数に正規化）
        XCTAssertTrue(html.contains("<tr><td>1</td><td></td></tr>"))
        XCTAssertTrue(html.contains("<tr><td>1</td><td>2</td></tr>"))
        XCTAssertFalse(html.contains("<td>3</td>"))
    }

    func testTableEscapedPipeInCell() {
        let html = MarkdownRenderer.render(markdown: "| a \\| b |\n| --- |\n| \\| |")
        XCTAssertTrue(html.contains("<th>a | b</th>"))
        XCTAssertTrue(html.contains("<td>|</td>"))
    }

    func testPipeLineWithoutDelimiterRowIsParagraph() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "| a | b |"),
            "<p>| a | b |</p>\n")
    }

    func testInlineFormattingInsideTableCells() {
        let html = MarkdownRenderer.render(markdown: "| **b** |\n| --- |\n| `c` |")
        XCTAssertTrue(html.contains("<th><strong>b</strong></th>"))
        XCTAssertTrue(html.contains("<td><code>c</code></td>"))
    }

    // MARK: - リンク

    func testBasicLink() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "[t](https://example.com/a)"),
            "<p><a href=\"https://example.com/a\">t</a></p>\n")
    }

    func testRelativeLinkIsAllowed() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "[doc](./notes/doc.md)"),
            "<p><a href=\"./notes/doc.md\">doc</a></p>\n")
    }

    func testLinkURLAmpersandIsEscaped() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "[t](a&b.md)"),
            "<p><a href=\"a&amp;b.md\">t</a></p>\n")
    }

    func testEmphasisInsideLinkText() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "[*i*](x.md)"),
            "<p><a href=\"x.md\"><em>i</em></a></p>\n")
    }

    func testJavascriptSchemeLinkIsDisabled() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "[t](javascript:alert)"),
            "<p>t</p>\n")
    }

    func testDataSchemeLinkIsDisabled() {
        let html = MarkdownRenderer.render(markdown: "[t](data:text/html;base64,PHNjcmlwdD4)")
        XCTAssertFalse(html.contains("<a "))
        XCTAssertTrue(html.contains("t"))
    }

    func testJavascriptLinkWithParenthesesDoesNotBecomeLink() {
        let html = MarkdownRenderer.render(markdown: "[t](javascript:alert(1))")
        XCTAssertFalse(html.contains("<a "))
    }

    // MARK: - 画像（ローカルのみ）

    func testLocalRelativeImage() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "![alt](img.png)"),
            "<p><img src=\"img.png\" alt=\"alt\"></p>\n")
    }

    func testAbsolutePathImage() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "![a](/Users/x/i.png)"),
            "<p><img src=\"/Users/x/i.png\" alt=\"a\"></p>\n")
    }

    func testFileSchemeImageIsAllowed() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "![a](file:///Users/x/i.png)"),
            "<p><img src=\"file:///Users/x/i.png\" alt=\"a\"></p>\n")
    }

    func testEmptyAltImage() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "![](x.png)"),
            "<p><img src=\"x.png\" alt=\"\"></p>\n")
    }

    func testExternalHTTPImageIsBlocked() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "![a](https://evil.example/x.png)"),
            "<p><span class=\"blocked-external-image\">a</span></p>\n")
    }

    func testProtocolRelativeImageIsBlocked() {
        let html = MarkdownRenderer.render(markdown: "![a](//evil.example/x.png)")
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("blocked-external-image"))
    }

    func testImageAltWithScriptTagIsEscaped() {
        let html = MarkdownRenderer.render(markdown: "![<script>](x.png)")
        XCTAssertTrue(html.contains("alt=\"&lt;script&gt;\""))
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - 引用

    func testBlockquote() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "> hi"),
            "<blockquote>\n<p>hi</p>\n</blockquote>\n")
    }

    func testMultiLineBlockquote() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "> a\n> b"),
            "<blockquote>\n<p>a\nb</p>\n</blockquote>\n")
    }

    func testNestedBlockquote() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "> > deep"),
            "<blockquote>\n<blockquote>\n<p>deep</p>\n</blockquote>\n</blockquote>\n")
    }

    func testBlockquoteContainingList() {
        let html = MarkdownRenderer.render(markdown: "> - a")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<li>a</li>"))
    }

    func testTwentyLevelNestedBlockquoteDoesNotCrash() {
        let markdown = String(repeating: "> ", count: 20) + "x"
        let html = MarkdownRenderer.render(markdown: markdown)
        XCTAssertEqual(occurrences(of: "<blockquote>", in: html), 20)
        XCTAssertTrue(html.contains("<p>x</p>"))
    }

    // MARK: - 水平線

    func testThematicBreakVariants() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "---"), "<hr>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "***"), "<hr>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "___"), "<hr>\n")
        XCTAssertEqual(MarkdownRenderer.render(markdown: "- - -"), "<hr>\n")
    }

    func testTwoDashesIsNotThematicBreak() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "--"), "<p>--</p>\n")
    }

    // MARK: - XSS 対策（生 HTML は必ずエスケープ）

    func testScriptTagIsEscaped() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "<script>alert('x')</script>"),
            "<p>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</p>\n")
    }

    func testImgTagWithOnErrorIsEscaped() {
        let html = MarkdownRenderer.render(markdown: "<img src=x onerror=alert(1)>")
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertFalse(html.contains("<img "))
    }

    func testInlineHTMLTagIsEscaped() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "a <b>bold</b> c"),
            "<p>a &lt;b&gt;bold&lt;/b&gt; c</p>\n")
    }

    func testRawHTMLBlockIsEscaped() {
        let html = MarkdownRenderer.render(markdown: "<div>\n<p>hi</p>\n</div>")
        XCTAssertTrue(html.contains("&lt;div&gt;"))
        XCTAssertTrue(html.contains("&lt;p&gt;hi&lt;/p&gt;"))
        XCTAssertFalse(html.contains("<div>"))
    }

    func testQuoteInjectionInImageAltIsEscaped() {
        let html = MarkdownRenderer.render(markdown: "![\" onmouseover=\"alert(1)](x.png)")
        XCTAssertTrue(html.contains("alt=\"&quot; onmouseover=&quot;alert(1)\""))
    }

    func testInternalTokenScalarsInInputAreRemoved() {
        // 私用領域スカラーで内部トークンを偽造できないこと
        let html = MarkdownRenderer.render(markdown: "a\u{E000}0\u{E001}b")
        XCTAssertEqual(html, "<p>a0b</p>\n")
    }

    // MARK: - 境界値（空・巨大・サイズ上限・不正入力）

    func testEmptyInput() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: ""), "")
    }

    func testWhitespaceOnlyInput() {
        XCTAssertEqual(MarkdownRenderer.render(markdown: "   \n  \n\t\n"), "")
    }

    func testSizeLimitNotExceeded() {
        let result = MarkdownRenderer.renderWithSizeLimit(markdown: "abc", byteLimit: 10)
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(result.html, "<p>abc</p>\n")
    }

    func testSizeLimitExactBoundaryIsNotTruncated() {
        let result = MarkdownRenderer.renderWithSizeLimit(markdown: "aaaa", byteLimit: 4)
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(result.html, "<p>aaaa</p>\n")
    }

    func testSizeLimitExceededIsTruncated() {
        let result = MarkdownRenderer.renderWithSizeLimit(markdown: "aaaa", byteLimit: 3)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.html, "<p>aaa</p>\n")
    }

    func testTruncationRespectsUTF8CharacterBoundary() {
        // "あ" = 3 bytes。4 バイトで切ると "い" の途中になるが、
        // 文字境界を守って "あ" だけが残ること
        let result = MarkdownRenderer.renderWithSizeLimit(markdown: "あいう", byteLimit: 4)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.html, "<p>あ</p>\n")
    }

    func testDefaultFiveMegabyteLimit() {
        XCTAssertEqual(MarkdownRenderer.maxInputBytes, 5 * 1024 * 1024)
        let big = "# Title\n\n" + String(repeating: "a", count: 6 * 1024 * 1024)
        let result = MarkdownRenderer.renderWithSizeLimit(markdown: big)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertTrue(result.html.hasPrefix("<h1>Title</h1>\n<p>aaa"))
    }

    func testInvalidUTF8BytesAreReplacedNotCrashing() {
        let data = Data([0x61, 0xFF, 0xFE, 0x62]) // "a" + 不正バイト + "b"
        let result = MarkdownRenderer.renderWithSizeLimit(data: data)
        XCTAssertFalse(result.wasTruncated)
        XCTAssertTrue(result.html.contains("a"))
        XCTAssertTrue(result.html.contains("b"))
        XCTAssertTrue(result.html.contains("\u{FFFD}"))
    }

    func testCRLFNewlinesAreNormalized() {
        XCTAssertEqual(
            MarkdownRenderer.render(markdown: "# a\r\n\r\nb\r\n"),
            "<h1>a</h1>\n<p>b</p>\n")
    }

    func testBrokenSyntaxMixDoesNotCrash() {
        let markdown = "[broken](  \n> *\n| | |\n``` \n**\n![]("
        let html = MarkdownRenderer.render(markdown: markdown)
        XCTAssertFalse(html.isEmpty)
        XCTAssertFalse(html.contains("<script"))
    }

    func testLargeDocumentRendersAllBlocks() {
        // 1000 ブロックの複合文書が欠落なく変換されること
        var parts: [String] = []
        for index in 0..<1000 {
            parts.append("## 見出し\(index)\n\n本文 **強調** `code` 段落。\n")
        }
        let html = MarkdownRenderer.render(markdown: parts.joined(separator: "\n"))
        XCTAssertEqual(occurrences(of: "<h2>", in: html), 1000)
        XCTAssertEqual(occurrences(of: "<strong>強調</strong>", in: html), 1000)
    }

    // MARK: - 複合ドキュメント

    func testMixedDocument() {
        let markdown = """
        # タイトル

        導入の段落です。[リンク](https://example.com) と `code` を含む。

        ## 表

        | 項目 | 値 |
        | --- | ---: |
        | A | 1 |

        - リスト1
          - ネスト
        - リスト2

        > 引用です

        ```sh
        echo "hello"
        ```

        ---
        """
        let html = MarkdownRenderer.render(markdown: markdown)
        XCTAssertTrue(html.contains("<h1>タイトル</h1>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">リンク</a>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">1</td>"))
        XCTAssertTrue(html.contains("<li>ネスト</li>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("class=\"language-sh\""))
        XCTAssertTrue(html.contains("echo &quot;hello&quot;"))
        XCTAssertTrue(html.contains("<hr>"))
    }
}

/// PreviewTemplate の単体テスト（外部参照ゼロ・テーマ対応・エスケープ）。
final class PreviewTemplateTests: XCTestCase {
    func testPageContainsInlineStyleAndThemeSupport() {
        let page = PreviewTemplate.page(title: "t", bodyHTML: "<p>x</p>")
        XCTAssertTrue(page.contains("<style>"))
        XCTAssertTrue(page.contains("prefers-color-scheme"))
        XCTAssertTrue(page.contains("-apple-system"))
        XCTAssertTrue(page.contains("monospace"))
    }

    func testPageHasNoExternalResourceReferences() {
        let page = PreviewTemplate.page(title: "t", bodyHTML: "")
        XCTAssertFalse(page.contains("http://"))
        XCTAssertFalse(page.contains("https://"))
        XCTAssertTrue(page.contains("default-src 'none'"))
    }

    func testTitleIsEscaped() {
        let page = PreviewTemplate.page(title: "<t>&\"", bodyHTML: "")
        XCTAssertTrue(page.contains("<title>&lt;t&gt;&amp;&quot;</title>"))
    }

    func testBodyIsEmbedded() {
        let page = PreviewTemplate.page(title: "t", bodyHTML: "<h1>Hi</h1>")
        XCTAssertTrue(page.contains("<h1>Hi</h1>"))
    }

    func testTruncationBannerToggle() {
        let with = PreviewTemplate.page(title: "t", bodyHTML: "", wasTruncated: true)
        let without = PreviewTemplate.page(title: "t", bodyHTML: "", wasTruncated: false)
        XCTAssertTrue(with.contains("<div class=\"truncation-warning\">"))
        XCTAssertFalse(without.contains("<div class=\"truncation-warning\">"))
    }

    func testPageFromRenderResult() {
        let result = MarkdownRenderer.renderWithSizeLimit(markdown: "# a", byteLimit: 100)
        let page = PreviewTemplate.page(title: "t", result: result)
        XCTAssertTrue(page.contains("<h1>a</h1>"))
        XCTAssertFalse(page.contains("<div class=\"truncation-warning\">"))
    }
}
