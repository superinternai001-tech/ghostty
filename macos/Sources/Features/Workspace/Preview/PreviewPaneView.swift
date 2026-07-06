import SwiftUI

/// The right-hand preview pane (FR-1, WP-3 proof of concept).
///
/// For WP-3 this renders a fixed sample of "rendered Markdown" HTML to prove
/// that WKWebView works inside the SwiftUI-wrapped terminal layout under the
/// app sandbox. File selection and live rendering arrive in later WPs. Since
/// WP-4 the width is driven by `WorkspaceState` (resizable + persisted).
struct PreviewPaneView: View {
    @ObservedObject var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PreviewWebView(html: Self.sampleHTML)
        }
        .frame(width: workspace.previewWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preview — WP-3 PoC")
                .font(.headline)
            Text("sample.md")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A fixed, fully self-contained HTML document that looks like rendered
    /// Markdown. All CSS is inline and there are no external references, so
    /// nothing ever touches the network (NFR-5).
    static let sampleHTML = """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root {
        color-scheme: light dark;
        --fg: #1f2328;
        --bg: #ffffff;
        --muted: #59636e;
        --border: #d1d9e0;
        --code-bg: #f6f8fa;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --fg: #e6edf3;
          --bg: #1e1e1e;
          --muted: #9198a1;
          --border: #3d444d;
          --code-bg: #2b2b2b;
        }
      }
      body {
        margin: 0;
        padding: 16px;
        color: var(--fg);
        background: var(--bg);
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        font-size: 14px;
        line-height: 1.6;
      }
      h1 {
        font-size: 1.5em;
        margin: 0 0 0.5em;
        padding-bottom: 0.3em;
        border-bottom: 1px solid var(--border);
      }
      p { margin: 0 0 1em; }
      ul { margin: 0 0 1em; padding-left: 1.5em; }
      li { margin: 0.2em 0; }
      code {
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.9em;
        background: var(--code-bg);
        border-radius: 4px;
        padding: 0.15em 0.35em;
      }
      pre {
        margin: 0 0 1em;
        padding: 12px;
        background: var(--code-bg);
        border: 1px solid var(--border);
        border-radius: 6px;
        overflow-x: auto;
      }
      pre code { background: none; padding: 0; }
      .muted { color: var(--muted); font-size: 0.85em; }
    </style>
    </head>
    <body>
      <h1>sample.md</h1>
      <p>これは <strong>WP-3</strong> の実証表示です。右ペインの WKWebView が
      ローカル HTML をレンダリングできることを確認します。</p>
      <ul>
        <li>外部ネットワークへのアクセスなし</li>
        <li>JavaScript 無効・非永続データストア</li>
        <li>ライト／ダーク両テーマ対応</li>
      </ul>
      <p>コード例：</p>
      <pre><code>$ ghostty --version
    Ghostty 1.3.1</code></pre>
      <p>インラインコードは <code>loadHTMLString(_:baseURL:)</code> で読み込まれます。</p>
      <p class="muted">workspace preview proof of concept</p>
    </body>
    </html>
    """
}
