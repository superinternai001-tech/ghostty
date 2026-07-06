import Combine
import CoreServices
import Foundation

/// Watches a directory tree with FSEvents and maintains the newest-first list
/// of files created or updated during the watch session (FR-2 成果物リスト).
///
/// This class is the thin FSEvents shell; all filtering, ordering, capping and
/// debouncing decisions live in `ArtifactWatcherCore.swift` as pure logic.
///
/// Threading: file system events are processed on a private serial queue.
/// Published output (`items`, `watchedDirectory`) and the callbacks are always
/// delivered on the main thread so they can drive UI directly.
final class ArtifactWatcher: ObservableObject {
    enum WatcherError: Error, Equatable {
        /// The directory does not exist.
        case directoryNotFound(URL)

        /// The URL exists but is not a directory.
        case notADirectory(URL)

        /// The directory exists but is not readable (permissions).
        case notReadable(URL)

        /// FSEvents refused to create a stream for the directory.
        case streamCreationFailed(URL)
    }

    // MARK: - Output

    /// Artifacts of the current session, newest first, capped per configuration.
    /// Updated on the main thread.
    @Published private(set) var items: [ArtifactItem] = []

    /// The directory currently being watched (nil when stopped).
    @Published private(set) var watchedDirectory: URL?

    var isWatching: Bool { watchedDirectory != nil }

    /// Combine alternative to observing `items` directly.
    var itemsPublisher: AnyPublisher<[ArtifactItem], Never> { $items.eraseToAnyPublisher() }

    /// Called on the main thread whenever the item list changes.
    var onItemsChange: (([ArtifactItem]) -> Void)?

    /// Called on the main thread when the watched directory itself disappears
    /// (deleted or moved away). The watcher stops itself before this fires.
    var onWatchRootDisappeared: ((URL) -> Void)?

    let configuration: ArtifactWatcherConfiguration

    // MARK: - Private state (confined to eventQueue)

    private let eventQueue = DispatchQueue(label: "com.mitchellh.ghostty.workspace.artifactWatcher")
    private var stream: FSEventStreamRef?
    private var streamBox: Unmanaged<WeakBox>?
    private var debouncer: EventDebouncer<ArtifactListReducer.Event>?
    private var currentItems: [ArtifactItem] = []
    private var rootURL: URL?
    private var rootPath: String = ""
    private var watchStart = Date.distantFuture

    init(configuration: ArtifactWatcherConfiguration = .default) {
        self.configuration = configuration
    }

    deinit {
        // No other strong references exist at this point, so touching state
        // without the queue is safe; in-flight callbacks hold only a weak box.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streamBox?.release()
    }

    // MARK: - Public API

    /// Starts watching `directory`. When already watching, the previous stream
    /// is torn down first and the session (item list, start time) resets.
    func start(directory: URL) throws {
        let url = directory.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WatcherError.directoryNotFound(url)
        }
        guard isDirectory.boolValue else {
            throw WatcherError.notADirectory(url)
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw WatcherError.notReadable(url)
        }

        // FSEvents reports fully symlink-resolved paths (e.g. /private/var/…
        // for /var/…), so resolve the root the same way once and compare
        // lexically after that. POSIX realpath(3) is used on purpose:
        // Foundation's resolvingSymlinksInPath()/standardizedFileURL strip
        // the /private prefix and would disagree with FSEvents.
        let resolvedPath = url.path.withCString { cString -> String? in
            guard let real = realpath(cString, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        } ?? url.path
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)

        try eventQueue.sync {
            stopStreamLocked()
            currentItems = []
            watchStart = Date()
            rootURL = resolved
            rootPath = resolved.path
            try startStreamLocked(resolved: resolved)
            publishLocked()
        }
        setOnMain { self.watchedDirectory = url }
    }

    /// Switches the watch target (cwd change follow-up). Clears the item list
    /// and restarts the session against the new directory.
    func retarget(to directory: URL) throws {
        try start(directory: directory)
    }

    /// Stops watching and clears the session state.
    func stop() {
        eventQueue.sync {
            stopStreamLocked()
            currentItems = []
            rootURL = nil
            rootPath = ""
            publishLocked()
        }
        setOnMain { self.watchedDirectory = nil }
    }

    // MARK: - FSEvents plumbing

    fileprivate final class WeakBox {
        weak var watcher: ArtifactWatcher?

        init(_ watcher: ArtifactWatcher) {
            self.watcher = watcher
        }
    }

    private func startStreamLocked(resolved: URL) throws {
        let box = WeakBox(self)
        let unmanaged = Unmanaged.passRetained(box)
        var context = FSEventStreamContext()
        context.info = unmanaged.toOpaque()

        let createFlags = kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            artifactWatcherEventCallback,
            &context,
            [resolved.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(createFlags)
        ) else {
            unmanaged.release()
            throw WatcherError.streamCreationFailed(resolved)
        }

        self.stream = stream
        self.streamBox = unmanaged
        self.debouncer = EventDebouncer(
            interval: configuration.debounceInterval,
            queue: eventQueue
        ) { [weak self] events in
            self?.applyLocked(events)
        }

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            stopStreamLocked()
            throw WatcherError.streamCreationFailed(resolved)
        }
    }

    private func stopStreamLocked() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamBox?.release()
        streamBox = nil
        debouncer?.cancel()
        debouncer = nil
    }

    // MARK: - Event processing (on eventQueue)

    /// Entry point from the FSEvents C callback (runs on eventQueue).
    fileprivate func handleRawEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        var reducerEvents: [ArtifactListReducer.Event] = []
        var needsRescan = false
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                handleRootChangedLocked()
                return
            }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                needsRescan = true
                continue
            }
            reducerEvents.append(contentsOf: events(forChangedPath: path))
        }
        if needsRescan {
            reducerEvents.append(contentsOf: rescanEventsLocked())
        }
        if !reducerEvents.isEmpty {
            debouncer?.add(reducerEvents)
        }
    }

    /// Converts one changed path into reducer events by consulting the pure
    /// filter and the file's current on-disk state.
    private func events(forChangedPath path: String) -> [ArtifactListReducer.Event] {
        guard ArtifactPathFilter.isIncluded(
            path: path,
            under: rootPath,
            configuration: configuration
        ) else { return [] }

        let url = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            // The path no longer exists: remove it (and any children, in case
            // a whole directory was deleted in one event).
            return [.remove(url)]
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return [] }

        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        let change = ArtifactPathFilter.change(
            creationDate: attributes[.creationDate] as? Date,
            watchStart: watchStart
        )
        return [.upsert(ArtifactItem(url: url, modifiedAt: modifiedAt, change: change))]
    }

    /// The watched root itself changed (kFSEventStreamCreateFlagWatchRoot).
    private func handleRootChangedLocked() {
        guard let rootURL else { return }
        if FileManager.default.fileExists(atPath: rootPath) {
            // Root still exists (e.g. replaced): resynchronize by scanning.
            let events = rescanEventsLocked()
            if !events.isEmpty { debouncer?.add(events) }
            return
        }

        // The watched directory is gone. Tear down outside of this callback
        // frame (invalidating a stream from inside its own callback is unsafe).
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.stopStreamLocked()
            self.currentItems = []
            self.rootURL = nil
            self.rootPath = ""
            self.publishLocked()
            self.setOnMain {
                self.watchedDirectory = nil
                self.onWatchRootDisappeared?(rootURL)
            }
        }
    }

    /// Fallback when FSEvents coalesced events (MustScanSubDirs): walk the
    /// tree up to the configured depth and resynchronize the session list.
    private func rescanEventsLocked() -> [ArtifactListReducer.Event] {
        guard let rootURL else { return [] }
        let fileManager = FileManager.default
        var events: [ArtifactListReducer.Event] = []

        // Breadth-first walk; directory depth counted in components below root.
        var pending: [(url: URL, depth: Int)] = [(rootURL, 0)]
        while !pending.isEmpty {
            let (directory, depth) = pending.removeFirst()
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey,
                                             .contentModificationDateKey, .creationDateKey],
                options: configuration.includeHiddenFiles ? [] : [.skipsHiddenFiles]
            )) ?? []
            for child in contents {
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey,
                    .contentModificationDateKey, .creationDateKey,
                ])
                let name = child.lastPathComponent
                if values?.isDirectory == true {
                    let childDepth = depth + 1
                    // Files inside must stay within maxDepth components.
                    if childDepth < configuration.maxDepth &&
                        !configuration.excludedDirectoryNames.contains(name) {
                        pending.append((child, childDepth))
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                guard let modifiedAt = values?.contentModificationDate,
                      modifiedAt >= watchStart else { continue }
                let change = ArtifactPathFilter.change(
                    creationDate: values?.creationDate,
                    watchStart: watchStart
                )
                events.append(.upsert(ArtifactItem(url: child, modifiedAt: modifiedAt, change: change)))
            }
        }

        // Drop session items that no longer exist on disk.
        for item in currentItems where !fileManager.fileExists(atPath: item.url.path) {
            events.append(.remove(item.url))
        }
        return events
    }

    /// Debouncer flush: reduce into the canonical list and publish.
    private func applyLocked(_ events: [ArtifactListReducer.Event]) {
        currentItems = ArtifactListReducer.apply(
            events,
            to: currentItems,
            maxItems: configuration.maxItems
        )
        publishLocked()
    }

    private func publishLocked() {
        let snapshot = currentItems
        setOnMain {
            self.items = snapshot
            self.onItemsChange?(snapshot)
        }
    }

    /// UI-facing state is always mutated on the main thread.
    private func setOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

/// C callback for FSEvents. Kept as a file-scope constant because FSEvents
/// requires a C function pointer (no instance context beyond `info`).
private let artifactWatcherEventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let box = Unmanaged<ArtifactWatcher.WeakBox>.fromOpaque(info).takeUnretainedValue()
    guard let watcher = box.watcher else { return }
    // Created with kFSEventStreamCreateFlagUseCFTypes: paths arrive as CFArray.
    guard let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else {
        return
    }
    var flags: [FSEventStreamEventFlags] = []
    flags.reserveCapacity(numEvents)
    for index in 0..<numEvents {
        flags.append(eventFlags[index])
    }
    watcher.handleRawEvents(paths: paths, flags: flags)
}
