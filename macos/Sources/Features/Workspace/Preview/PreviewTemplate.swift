import Foundation

/// WP-7: プレビュー用 HTML 全体テンプレート。
///
/// - 外部リソース参照ゼロ: CSS はすべてインライン。さらに CSP
///   （default-src 'none'）で外部読み込みをブラウザレベルでも遮断する。
///   画像はローカル（file: / data:）のみ許可。
/// - ライト/ダーク両対応: `prefers-color-scheme` で OS 設定に自動追随。
/// - フォント: システムフォントスタック（本文）＋等幅スタック（コード）。
enum PreviewTemplate {
    /// HTML 文書全体を組み立てる。
    /// - Parameters:
    ///   - title: `<title>` に入れる文字列（エスケープされる）。
    ///   - bodyHTML: MarkdownRenderer が生成した HTML 断片。
    ///   - wasTruncated: true ならサイズ上限超過の警告バナーを先頭に表示。
    static func page(title: String, bodyHTML: String, wasTruncated: Bool = false) -> String {
        let banner = wasTruncated
            ? "<div class=\"truncation-warning\">注意: ファイルがサイズ上限（5MB）を超えているため、先頭部分のみ表示しています。</div>\n"
            : ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownRenderer.escapeHTML(title))</title>
        <style>
        \(styleSheet)
        </style>
        </head>
        <body>
        \(banner)<article class="markdown-body">
        \(bodyHTML)
        </article>
        </body>
        </html>
        """
    }

    /// MarkdownRenderer.RenderResult から直接ページを組み立てる補助 API。
    static func page(title: String, result: MarkdownRenderer.RenderResult) -> String {
        page(title: title, bodyHTML: result.html, wasTruncated: result.wasTruncated)
    }

    /// インライン CSS（外部参照なし）。
    private static let styleSheet = """
        :root {
          color-scheme: light dark;
          --bg: #ffffff;
          --fg: #1d1d1f;
          --muted: #6e6e73;
          --border: #d2d2d7;
          --code-bg: #f5f5f7;
          --quote-border: #d2d2d7;
          --link: #0066cc;
          --warn-bg: #fff3cd;
          --warn-fg: #664d03;
          --warn-border: #ffe69c;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1e1e1e;
            --fg: #e8e8ed;
            --muted: #98989d;
            --border: #3a3a3c;
            --code-bg: #2c2c2e;
            --quote-border: #48484a;
            --link: #409cff;
            --warn-bg: #3a3000;
            --warn-fg: #ffd60a;
            --warn-border: #5c4d00;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 1.5rem 2rem 3rem;
          background: var(--bg);
          color: var(--fg);
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue",
            "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic", sans-serif;
          font-size: 15px;
          line-height: 1.7;
          word-wrap: break-word;
        }
        .markdown-body { max-width: 52rem; margin: 0 auto; }
        h1, h2, h3, h4, h5, h6 {
          margin: 1.6em 0 0.6em;
          line-height: 1.3;
          font-weight: 600;
        }
        h1 { font-size: 1.7em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h3 { font-size: 1.2em; }
        h4 { font-size: 1.05em; }
        h5, h6 { font-size: 1em; color: var(--muted); }
        p { margin: 0.7em 0; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code, pre {
          font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Monaco,
            "Osaka-Mono", monospace;
          font-size: 0.9em;
        }
        code {
          background: var(--code-bg);
          border-radius: 4px;
          padding: 0.15em 0.4em;
        }
        pre {
          background: var(--code-bg);
          border: 1px solid var(--border);
          border-radius: 8px;
          padding: 0.9em 1.1em;
          overflow-x: auto;
          line-height: 1.55;
        }
        pre code { background: none; padding: 0; border-radius: 0; }
        table {
          border-collapse: collapse;
          margin: 1em 0;
          display: block;
          max-width: 100%;
          overflow-x: auto;
        }
        th, td {
          border: 1px solid var(--border);
          padding: 0.4em 0.9em;
          text-align: left;
        }
        th { background: var(--code-bg); font-weight: 600; }
        blockquote {
          margin: 1em 0;
          padding: 0.1em 1.2em;
          border-left: 4px solid var(--quote-border);
          color: var(--muted);
        }
        ul, ol { padding-left: 1.8em; margin: 0.7em 0; }
        li { margin: 0.25em 0; }
        hr {
          border: none;
          border-top: 1px solid var(--border);
          margin: 2em 0;
        }
        img { max-width: 100%; }
        .blocked-external-image {
          display: inline-block;
          padding: 0.1em 0.6em;
          border: 1px dashed var(--border);
          border-radius: 4px;
          color: var(--muted);
          font-size: 0.9em;
        }
        .blocked-external-image::before { content: "外部画像ブロック: "; }
        .truncation-warning {
          max-width: 52rem;
          margin: 0 auto 1.2rem;
          padding: 0.7em 1.1em;
          background: var(--warn-bg);
          color: var(--warn-fg);
          border: 1px solid var(--warn-border);
          border-radius: 8px;
          font-size: 0.95em;
        }
        """
}
