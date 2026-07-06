import Foundation

// Pure logic for the artifact watcher (FR-2), kept free of FSEvents so it can
// be unit tested in isolation. `ArtifactWatcher` is the FSEvents-facing shell
// that feeds this logic.

// MARK: - Configuration

/// Tunable behavior of `ArtifactWatcher`. Defaults follow the FR-2 spec table.
struct ArtifactWatcherConfiguration: Equatable {
    /// Maximum directory depth relative to the watch root. A file directly in
    /// the root has depth 1. Default: 2 (root plus one subdirectory level).
    var maxDepth: Int

    /// Directory names excluded from watching. A path is excluded when any of
    /// its ancestor directories (relative to the root) matches one of these.
    var excludedDirectoryNames: Set<String>

    /// When false (default), any path component starting with "." is excluded.
    var includeHiddenFiles: Bool

    /// Quiet period used to coalesce bursts of file system events.
    var debounceInterval: TimeInterval

    /// Maximum number of items kept in the list; the oldest overflow is dropped.
    var maxItems: Int

    /// Default exclusions from the FR-2 spec table ("等" left open: build and
    /// cache directories commonly churned by toolchains).
    static let defaultExcludedDirectoryNames: Set<String> = [
        ".git",
        "node_modules",
        ".cache",
        "zig-cache",
        "zig-out",
        ".zig-cache",
        ".build",
        ".venv",
        "__pycache__",
        "DerivedData",
    ]

    static let `default` = ArtifactWatcherConfiguration()

    init(
        maxDepth: Int = 2,
        excludedDirectoryNames: Set<String> = Self.defaultExcludedDirectoryNames,
        includeHiddenFiles: Bool = false,
        debounceInterval: TimeInterval = 0.5,
        maxItems: Int = 500
    ) {
        self.maxDepth = maxDepth
        self.excludedDirectoryNames = excludedDirectoryNames
        self.includeHiddenFiles = includeHiddenFiles
        self.debounceInterval = debounceInterval
        self.maxItems = maxItems
    }
}

// MARK: - Path filtering

/// Pure path filtering: depth limit, exclusion list, hidden files (FR-2).
enum ArtifactPathFilter {
    /// Returns the path components of `path` relative to `rootPath`, or nil
    /// when `path` is not strictly inside `rootPath`. Purely lexical; does not
    /// touch the file system (callers must pass symlink-resolved paths —
    /// deliberately no `standardizedFileURL`, whose /private-stripping depends
    /// on whether the path still exists).
    static func relativeComponents(of path: String, under rootPath: String) -> [String]? {
        let root = URL(fileURLWithPath: rootPath).pathComponents
        let target = URL(fileURLWithPath: path).pathComponents
        guard target.count > root.count, Array(target.prefix(root.count)) == root else { return nil }
        return Array(target.dropFirst(root.count))
    }

    /// Whether a changed path should be considered an artifact candidate.
    static func isIncluded(
        path: String,
        under rootPath: String,
        configuration: ArtifactWatcherConfiguration
    ) -> Bool {
        guard let components = relativeComponents(of: path, under: rootPath) else { return false }
        return isIncluded(relativeComponents: components, configuration: configuration)
    }

    /// Core filter on components relative to the watch root:
    /// depth within `maxDepth`, no excluded ancestor directory, no hidden
    /// component (unless `includeHiddenFiles`).
    static func isIncluded(
        relativeComponents components: [String],
        configuration: ArtifactWatcherConfiguration
    ) -> Bool {
        guard !components.isEmpty else { return false }
        guard components.count <= configuration.maxDepth else { return false }
        if !configuration.includeHiddenFiles && components.contains(where: { $0.hasPrefix(".") }) {
            return false
        }
        if components.dropLast().contains(where: { configuration.excludedDirectoryNames.contains($0) }) {
            return false
        }
        return true
    }

    /// Classifies a change: files whose creation date falls inside the watch
    /// session are "created", everything else (including unknown creation
    /// dates) is "updated".
    static func change(creationDate: Date?, watchStart: Date) -> ArtifactItem.Change {
        guard let creationDate, creationDate >= watchStart else { return .updated }
        return .created
    }
}

// MARK: - List reduction

/// Pure list state machine: applies upsert/remove events to the item list,
/// keeps it sorted newest-first, and caps it at `maxItems` (FR-2).
enum ArtifactListReducer {
    enum Event: Equatable {
        /// Insert the item, replacing any previous entry with the same URL.
        case upsert(ArtifactItem)

        /// Remove the item at this URL and any items beneath it (covers
        /// deletion of a whole directory that FSEvents reports as one event).
        case remove(URL)
    }

    /// Applies `events` in order, then returns the sorted, capped list.
    static func apply(
        _ events: [Event],
        to items: [ArtifactItem],
        maxItems: Int
    ) -> [ArtifactItem] {
        var result = items
        for event in events {
            switch event {
            case .upsert(let item):
                result.removeAll { $0.url == item.url }
                result.append(item)
            case .remove(let url):
                let removedPath = url.path
                let prefix = removedPath.hasSuffix("/") ? removedPath : removedPath + "/"
                result.removeAll { $0.url.path == removedPath || $0.url.path.hasPrefix(prefix) }
            }
        }
        return sortedAndCapped(result, maxItems: maxItems)
    }

    /// Newest first by modification date; ties broken by path for stable order.
    static func sortedAndCapped(_ items: [ArtifactItem], maxItems: Int) -> [ArtifactItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.path < rhs.url.path
        }
        return Array(sorted.prefix(max(0, maxItems)))
    }
}

// MARK: - Debouncing

/// Trailing-edge debouncer: accumulates events and delivers them as one batch
/// once no new event has arrived for `interval` (FR-2: debounce 500ms).
///
/// All state is confined to `queue`; `add`/`flushNow`/`cancel` are safe to
/// call from any thread. The handler is invoked on `queue`.
final class EventDebouncer<Event> {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let handler: ([Event]) -> Void
    private var pending: [Event] = []
    private var scheduled: DispatchWorkItem?

    init(
        interval: TimeInterval,
        queue: DispatchQueue = DispatchQueue(label: "com.mitchellh.ghostty.workspace.debouncer"),
        handler: @escaping ([Event]) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.handler = handler
    }

    /// Adds events to the pending batch and (re)starts the quiet-period timer.
    func add(_ events: [Event]) {
        queue.async { self.append(events) }
    }

    /// Delivers the pending batch immediately (no-op when empty).
    func flushNow() {
        queue.async {
            self.scheduled?.cancel()
            self.scheduled = nil
            self.deliver()
        }
    }

    /// Drops all pending events without delivering them.
    func cancel() {
        queue.async {
            self.scheduled?.cancel()
            self.scheduled = nil
            self.pending = []
        }
    }

    private func append(_ events: [Event]) {
        pending.append(contentsOf: events)
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.deliver()
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func deliver() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        handler(batch)
    }
}
