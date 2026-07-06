import Foundation

/// A single artifact: a file that was created or updated inside the watched
/// directory during the current watch session. Rendered by the workspace
/// artifact list (FR-2) and preview pane (FR-1).
struct ArtifactItem: Identifiable, Equatable {
    /// The rendering category of an artifact, derived from its file extension.
    /// The categories mirror the preview pane's supported types (FR-1).
    enum Kind: String, CaseIterable {
        case markdown
        case html
        case text
        case image
        case other

        /// Maps a file extension (without the leading dot, any case) to a kind.
        init(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "md", "markdown":
                self = .markdown
            case "html", "htm":
                self = .html
            case "txt", "log", "json", "yaml", "yml", "csv":
                self = .text
            case "png", "jpg", "jpeg", "gif", "svg":
                self = .image
            default:
                self = .other
            }
        }

        /// Derives the kind from a file URL's path extension.
        init(url: URL) {
            self.init(fileExtension: url.pathExtension)
        }
    }

    /// Distinguishes files that first appeared during the watch session from
    /// files that already existed and were modified (FR-2 "作成/更新の区別").
    enum Change: Equatable {
        /// The file was created after the watch session started.
        case created

        /// The file existed before the watch session started and was modified.
        case updated
    }

    /// Absolute file URL of the artifact. Taken as given (no standardization:
    /// `standardizedFileURL` behaves differently for deleted paths, which
    /// would break upsert/remove matching). The watcher always passes
    /// symlink-resolved FSEvents paths here.
    let url: URL

    /// Rendering category, derived from the file extension unless overridden.
    let kind: Kind

    /// Content modification date used for newest-first ordering.
    let modifiedAt: Date

    /// Whether this artifact was created or updated during the session.
    let change: Change

    var id: URL { url }

    /// Display name (last path component).
    var fileName: String { url.lastPathComponent }

    init(url: URL, kind: Kind? = nil, modifiedAt: Date, change: Change) {
        self.url = url
        self.kind = kind ?? Kind(url: url)
        self.modifiedAt = modifiedAt
        self.change = change
    }
}
