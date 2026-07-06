import SwiftUI

/// Lays out the workspace panes around the terminal content (WP-4).
///
/// This is the single place that decides the horizontal arrangement
/// (docs/06 §1.1): sidebar / terminal / preview inside an `HStack`. Hidden
/// panes are removed from the view hierarchy via `if` (not zero-width) so
/// the all-closed state keeps the WP-3 structure of a bare `HStack` around
/// the unmodified terminal content (acceptance 12-6).
///
/// Keeping this wrapper in Workspace/ (instead of inlining in
/// TerminalView.body) minimizes the diff against upstream and gives SwiftUI
/// a view that directly observes `WorkspaceState`, which a nested
/// `ObservableObject` on the view model would not republish.
struct WorkspaceLayoutView<Terminal: View>: View {
    @ObservedObject var workspace: WorkspaceState
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        HStack(spacing: 0) {
            if workspace.sidebarVisible {
                SidebarPaneView(workspace: workspace)
                WorkspacePaneDivider(
                    width: $workspace.sidebarWidth,
                    range: WorkspaceState.Metrics.sidebarWidthRange,
                    paneSide: .leading)
            }

            terminal()

            if workspace.previewVisible {
                WorkspacePaneDivider(
                    width: $workspace.previewWidth,
                    range: WorkspaceState.Metrics.previewWidthRange,
                    paneSide: .trailing)
                PreviewPaneView(workspace: workspace)
            }
        }
    }
}

/// A draggable vertical divider between a fixed-width workspace pane and the
/// terminal (docs/06 §1.2: 1pt visible, 9pt hit area; §1.3: dragging past
/// the pane's min/max stops at the limit, it never snaps closed).
///
/// The existing `SplitView.Divider` resizes a *fractional* split, while the
/// workspace panes keep a fixed point width when the window resizes
/// (docs/06 §1.3), so this uses a plain `DragGesture` on the pane width.
struct WorkspacePaneDivider: View {
    /// Which side of this divider the resizable pane is on.
    enum PaneSide {
        case leading
        case trailing

        /// Multiplier converting a rightward drag into a width change.
        var dragFactor: CGFloat {
            switch self {
            case .leading: return 1
            case .trailing: return -1
            }
        }
    }

    /// The pane width this divider adjusts (e.g. `$workspace.sidebarWidth`).
    @Binding var width: CGFloat

    /// Allowed width range for the pane.
    let range: ClosedRange<CGFloat>

    /// Where the pane sits relative to this divider.
    let paneSide: PaneSide

    /// The pane width at the start of the current drag, if dragging.
    @State private var dragStartWidth: CGFloat?

    /// Visible line and invisible hit-area sizes (docs/06 §1.2).
    private let visibleWidth: CGFloat = 1
    private let hitAreaWidth: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: visibleWidth)
            .frame(maxHeight: .infinity)
            .overlay(hitArea)
    }

    /// A transparent, wider hit area centered on the visible line so the
    /// divider stays easy to grab (same idea as `SplitView.Divider`).
    private var hitArea: some View {
        Color.clear
            .frame(width: hitAreaWidth)
            .contentShape(Rectangle())
            .backport.pointerStyle(.resizeLeftRight)
            .onHover { isHovered in
                // macOS 15+ uses the pointerStyle helper above; earlier
                // versions fall back to manual NSCursor push/pop.
                if #available(macOS 15, *) { return }
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(dragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workspace pane divider")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityHint("Drag to resize the pane")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = 10
                switch direction {
                case .increment:
                    width = min(width + adjustment, range.upperBound)
                case .decrement:
                    width = max(width - adjustment, range.lowerBound)
                @unknown default:
                    break
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { gesture in
                let start = dragStartWidth ?? width
                if dragStartWidth == nil { dragStartWidth = start }
                let proposed = start + paneSide.dragFactor * gesture.translation.width
                width = min(max(proposed, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                dragStartWidth = nil
            }
    }
}
