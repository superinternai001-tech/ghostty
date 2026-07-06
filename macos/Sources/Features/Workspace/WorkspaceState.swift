import SwiftUI

/// Observable UI state for the workspace layer (WP-4).
///
/// Owns the visibility and width of the two workspace panes: the artifact
/// sidebar (left, FR-2) and the preview pane (right, FR-1). The state is
/// owned by `BaseTerminalController` (AppKit owns state, SwiftUI observes;
/// see the `TerminalViewModel` design note in TerminalView.swift).
///
/// Values persist to `UserDefaults.ghostty` under `workspace.*` keys
/// (docs/01 §4) so new windows open with the most recently saved layout and
/// the layout survives an app relaunch (docs/06 §1.4, acceptance 12-7).
final class WorkspaceState: ObservableObject {
    /// Pane layout metrics from docs/06_ui-design.md §1.2 (points).
    enum Metrics {
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarDefaultWidth: CGFloat = 240
        static let sidebarMaxWidth: CGFloat = 400
        static let sidebarWidthRange: ClosedRange<CGFloat> = sidebarMinWidth...sidebarMaxWidth

        static let previewMinWidth: CGFloat = 240
        static let previewDefaultWidth: CGFloat = 380
        static let previewMaxWidth: CGFloat = 600
        static let previewWidthRange: ClosedRange<CGFloat> = previewMinWidth...previewMaxWidth
    }

    /// UserDefaults keys (docs/01 §4: `workspace.` prefix).
    private enum Keys {
        static let sidebarVisible = "workspace.sidebarVisible"
        static let previewVisible = "workspace.previewVisible"
        static let sidebarWidth = "workspace.sidebarWidth"
        static let previewWidth = "workspace.previewWidth"
    }

    /// Whether workspace panes may be shown at all. The quick terminal
    /// doesn't get workspace UI (docs/01 §2), so its controller creates a
    /// disabled state: visibility is forced to false and nothing persists.
    let enabled: Bool

    /// Whether the left artifact sidebar pane is visible. When hidden the
    /// pane is removed from the view hierarchy entirely (not zero-width),
    /// per docs/06 §1.1 / acceptance 12-6.
    @Published var sidebarVisible: Bool {
        didSet {
            guard enabled else { return }
            defaults.set(sidebarVisible, forKey: Keys.sidebarVisible)
        }
    }

    /// Whether the right preview pane is visible. Same removal semantics
    /// as `sidebarVisible`.
    @Published var previewVisible: Bool {
        didSet {
            guard enabled else { return }
            defaults.set(previewVisible, forKey: Keys.previewVisible)
        }
    }

    /// Current sidebar width in points. Clamped to `Metrics.sidebarWidthRange`.
    @Published var sidebarWidth: CGFloat {
        didSet {
            let clamped = sidebarWidth.clamped(to: Metrics.sidebarWidthRange)
            if clamped != sidebarWidth { sidebarWidth = clamped }
            guard enabled else { return }
            defaults.set(Double(sidebarWidth), forKey: Keys.sidebarWidth)
        }
    }

    /// Current preview width in points. Clamped to `Metrics.previewWidthRange`.
    @Published var previewWidth: CGFloat {
        didSet {
            let clamped = previewWidth.clamped(to: Metrics.previewWidthRange)
            if clamped != previewWidth { previewWidth = clamped }
            guard enabled else { return }
            defaults.set(Double(previewWidth), forKey: Keys.previewWidth)
        }
    }

    private let defaults: UserDefaults

    init(enabled: Bool = true, defaults: UserDefaults = .ghostty) {
        self.enabled = enabled
        self.defaults = defaults

        guard enabled else {
            self.sidebarVisible = false
            self.previewVisible = false
            self.sidebarWidth = Metrics.sidebarDefaultWidth
            self.previewWidth = Metrics.previewDefaultWidth
            return
        }

        // `bool(forKey:)` returns false for missing keys, which matches the
        // WP-4 default (both panes hidden).
        self.sidebarVisible = defaults.bool(forKey: Keys.sidebarVisible)
        self.previewVisible = defaults.bool(forKey: Keys.previewVisible)
        self.sidebarWidth = Self.restoredWidth(
            from: defaults,
            key: Keys.sidebarWidth,
            fallback: Metrics.sidebarDefaultWidth,
            range: Metrics.sidebarWidthRange)
        self.previewWidth = Self.restoredWidth(
            from: defaults,
            key: Keys.previewWidth,
            fallback: Metrics.previewDefaultWidth,
            range: Metrics.previewWidthRange)
    }

    /// Reads a persisted width, falling back to the default when the key was
    /// never written and clamping stored values to the allowed range.
    private static func restoredWidth(
        from defaults: UserDefaults,
        key: String,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return CGFloat(defaults.double(forKey: key)).clamped(to: range)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
