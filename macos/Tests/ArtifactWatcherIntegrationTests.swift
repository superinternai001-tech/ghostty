import XCTest

@testable import Ghostty

/// FSEvents-level tests for `ArtifactWatcher` against a real temporary
/// directory: detection (create/update/delete), retargeting, and the abnormal
/// cases required by docs/05 §5 (存在しないディレクトリ・権限なし・監視中の削除).
final class ArtifactWatcherIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var watchers: [ArtifactWatcher] = []

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArtifactWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for watcher in watchers { watcher.stop() }
        watchers = []
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            // Restore permissions in case a permissions test failed mid-way.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempDir.path
            )
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func makeWatcher(
        configuration: ArtifactWatcherConfiguration = ArtifactWatcherConfiguration(debounceInterval: 0.1)
    ) -> ArtifactWatcher {
        let watcher = ArtifactWatcher(configuration: configuration)
        watchers.append(watcher)
        return watcher
    }

    private func write(_ name: String, in directory: URL? = nil, contents: String = "hello") throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Waits until the watcher publishes an item list satisfying `predicate`.
    private func waitForItems(
        of watcher: ArtifactWatcher,
        timeout: TimeInterval = 5,
        description: String = "items",
        until predicate: @escaping ([ArtifactItem]) -> Bool
    ) {
        let satisfied = expectation(description: description)
        satisfied.assertForOverFulfill = false
        watcher.onItemsChange = { items in
            if predicate(items) { satisfied.fulfill() }
        }
        if predicate(watcher.items) { satisfied.fulfill() }
        wait(for: [satisfied], timeout: timeout)
        watcher.onItemsChange = nil
    }

    // MARK: - Detection (正常系)

    func testDetectsCreatedFileAsCreated() throws {
        let watcher = makeWatcher()
        try watcher.start(directory: tempDir)
        XCTAssertTrue(watcher.isWatching)

        let url = try write("report.md")
        waitForItems(of: watcher, description: "created file listed") { items in
            items.contains { $0.url.lastPathComponent == "report.md" }
        }
        let item = watcher.items.first { $0.url.lastPathComponent == "report.md" }
        XCTAssertEqual(item?.change, .created)
        XCTAssertEqual(item?.kind, .markdown)
        XCTAssertEqual(item?.url.lastPathComponent, url.lastPathComponent)
    }

    func testDetectsPreexistingFileModificationAsUpdated() throws {
        let url = try write("existing.txt", contents: "before")
        // Ensure the file's creation date clearly precedes the watch start.
        Thread.sleep(forTimeInterval: 0.3)

        let watcher = makeWatcher()
        try watcher.start(directory: tempDir)
        try "after".write(to: url, atomically: false, encoding: .utf8)

        waitForItems(of: watcher, description: "updated file listed") { items in
            items.contains { $0.url.lastPathComponent == "existing.txt" }
        }
        let item = watcher.items.first { $0.url.lastPathComponent == "existing.txt" }
        XCTAssertEqual(item?.change, .updated)
        XCTAssertEqual(item?.kind, .text)
    }

    func testRemovesDeletedFileFromList() throws {
        let watcher = makeWatcher()
        try watcher.start(directory: tempDir)

        let url = try write("victim.log")
        waitForItems(of: watcher, description: "file listed before deletion") { items in
            items.contains { $0.url.lastPathComponent == "victim.log" }
        }

        try FileManager.default.removeItem(at: url)
        waitForItems(of: watcher, description: "file removed from list") { items in
            !items.contains { $0.url.lastPathComponent == "victim.log" }
        }
    }

    func testIgnoresExcludedDirectoriesAndDepthOverflow() throws {
        let excluded = tempDir.appendingPathComponent("node_modules")
        let deep = tempDir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let watcher = makeWatcher()
        try watcher.start(directory: tempDir)

        _ = try write("inside-excluded.txt", in: excluded)
        _ = try write("too-deep.txt", in: deep) // depth 3 > default maxDepth 2
        _ = try write("visible.txt")

        waitForItems(of: watcher, description: "only the visible file is listed") { items in
            items.contains { $0.url.lastPathComponent == "visible.txt" }
        }
        // Give the debouncer one extra window to surface any wrong extras.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(watcher.items.map(\.fileName), ["visible.txt"])
    }

    func testRetargetSwitchesDirectoryAndClearsList() throws {
        let second = tempDir.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let watcher = makeWatcher()
        try watcher.start(directory: tempDir)
        _ = try write("first-dir.md")
        waitForItems(of: watcher, description: "first directory file listed") { items in
            items.contains { $0.url.lastPathComponent == "first-dir.md" }
        }

        try watcher.retarget(to: second)
        XCTAssertEqual(watcher.items, [], "retarget must clear the session list")

        _ = try write("second-dir.md", in: second)
        waitForItems(of: watcher, description: "second directory file listed") { items in
            items.map(\.fileName) == ["second-dir.md"]
        }
    }

    func testStopClearsStateAndStopsDelivery() throws {
        let watcher = makeWatcher()
        try watcher.start(directory: tempDir)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(watcher.items, [])

        let quiet = expectation(description: "no delivery after stop")
        quiet.isInverted = true
        watcher.onItemsChange = { items in
            if !items.isEmpty { quiet.fulfill() }
        }
        _ = try write("after-stop.txt")
        wait(for: [quiet], timeout: 0.6)
    }

    // MARK: - 異常系

    func testStartOnNonexistentDirectoryThrows() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let watcher = makeWatcher()
        XCTAssertThrowsError(try watcher.start(directory: missing)) { error in
            XCTAssertEqual(
                error as? ArtifactWatcher.WatcherError,
                .directoryNotFound(missing)
            )
        }
        XCTAssertFalse(watcher.isWatching)
    }

    func testStartOnFileThrowsNotADirectory() throws {
        let file = try write("plain.txt")
        let watcher = makeWatcher()
        XCTAssertThrowsError(try watcher.start(directory: file)) { error in
            XCTAssertEqual(error as? ArtifactWatcher.WatcherError, .notADirectory(file))
        }
    }

    func testStartOnUnreadableDirectoryThrows() throws {
        let locked = tempDir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: locked.path
            )
        }

        let watcher = makeWatcher()
        XCTAssertThrowsError(try watcher.start(directory: locked)) { error in
            XCTAssertEqual(error as? ArtifactWatcher.WatcherError, .notReadable(locked))
        }
    }

    func testWatchedDirectoryDeletionStopsWatcherAndNotifies() throws {
        let target = tempDir.appendingPathComponent("volatile")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let watcher = makeWatcher()
        let notified = expectation(description: "root disappearance reported")
        watcher.onWatchRootDisappeared = { _ in notified.fulfill() }
        try watcher.start(directory: target)

        try FileManager.default.removeItem(at: target)
        wait(for: [notified], timeout: 5)
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(watcher.items, [])
    }
}
