import SwiftUI

/// The left artifact sidebar pane (FR-2, WP-4 skeleton).
///
/// WP-4 only provides the pane frame: header, empty-state placeholder
/// (docs/06 §2.3), and a width driven by `WorkspaceState`. The actual
/// artifact list (`ArtifactListView`) and file watching arrive in WP-5+.
struct SidebarPaneView: View {
    @ObservedObject var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            emptyState
        }
        .frame(width: workspace.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Pane header (docs/06 §2.1). The watched-directory name and pin button
    /// arrive with the watcher in WP-5.
    private var header: some View {
        HStack {
            Text("成果物") // W-200
                .font(.system(size: 11))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    /// Empty-state placeholder (docs/06 §2.3, W-201/W-202).
    private var emptyState: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Image(systemName: "arrow.right")
                Image(systemName: "list.bullet.rectangle")
            }
            .font(.system(size: 16))

            Text("AI が作ったファイルがここに並びます") // W-201
                .font(.system(size: 13))

            Text("ターミナルで AI に指示すると、作成・更新されたファイルが新しい順に表示されます") // W-202
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
