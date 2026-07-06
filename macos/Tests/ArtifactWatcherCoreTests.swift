import XCTest

@testable import Ghostty

/// Unit tests for the pure logic of the artifact watcher (docs/05 §2 UT,
/// built with the whitelist method of docs/05 §5).
///
/// ホワイトリスト（通るべき正常分岐の一覧）:
///
/// [Kind 判定]
///   W-K1 md/markdown → .markdown
///   W-K2 html/htm → .html
///   W-K3 txt/log/json/yaml/yml/csv → .text
///   W-K4 png/jpg/jpeg/gif/svg → .image
///   W-K5 未知の拡張子・拡張子なし → .other
///   W-K6 大文字拡張子も同様に判定（case-insensitive）
///
/// [パスフィルタ]
///   W-F1 root直下のファイル（深さ1）→ 採用
///   W-F2 サブディレクトリ1段のファイル（深さ2 = 既定maxDepth）→ 採用
///   W-F3 深さ3（maxDepth超過）→ 除外
///   W-F4 既定除外ディレクトリ（.git / node_modules / zig-out 等）配下 → 除外
///   W-F5 カスタム除外セットが有効
///   W-F6 隠しファイル・隠しディレクトリ配下 → 除外
///   W-F7 includeHiddenFiles=true なら隠しファイルも採用
///   W-F8 root外・root自身 → 除外
///   W-F9 除外名と同名の「ファイル」は除外しない（除外はディレクトリ名に対して）
///
/// [作成/更新の分類]
///   W-C1 creationDate >= watchStart → .created
///   W-C2 creationDate < watchStart → .updated
///   W-C3 creationDate 不明(nil) → .updated
///
/// [リスト整列・上限（リデューサ）]
///   W-R1 upsert で新規追加され新しい順に整列
///   W-R2 同一URLの upsert は置換（重複しない）
///   W-R3 remove で該当項目が消える
///   W-R4 ディレクトリURLの remove は配下の項目も消す
///   W-R5 maxItems 超過は古い順に切り捨て
///   W-R6 同時刻はパス昇順で安定整列
///
/// [デバウンス]
///   W-D1 静穏期間内の連続イベントは1回のフラッシュに合流（順序保持）
///   W-D2 静穏期間を挟んだイベントは別々のフラッシュ
///   W-D3 flushNow は即時配信
///   W-D4 cancel は保留イベントを破棄
///
/// 境界値・異常系は各セクション末尾（maxDepth境界・maxItems境界・空イベント・
/// 空リスト remove・maxItems 0 など）。ファイルシステム異常系（存在しない
/// ディレクトリ・権限なし・監視中の削除）は ArtifactWatcherIntegrationTests。
final class ArtifactWatcherCoreTests: XCTestCase {
    // MARK: - Helpers

    private let root = "/watch/root"

    private func makeConfiguration(
        maxDepth: Int = 2,
        excluded: Set<String> = ArtifactWatcherConfiguration.defaultExcludedDirectoryNames,
        includeHidden: Bool = false,
        maxItems: Int = 500
    ) -> ArtifactWatcherConfiguration {
        ArtifactWatcherConfiguration(
            maxDepth: maxDepth,
            excludedDirectoryNames: excluded,
            includeHiddenFiles: includeHidden,
            debounceInterval: 0.5,
            maxItems: maxItems
        )
    }

    private func included(_ path: String, _ configuration: ArtifactWatcherConfiguration? = nil) -> Bool {
        ArtifactPathFilter.isIncluded(
            path: path,
            under: root,
            configuration: configuration ?? makeConfiguration()
        )
    }

    private func makeItem(
        _ path: String,
        modifiedAt: Date,
        change: ArtifactItem.Change = .created
    ) -> ArtifactItem {
        ArtifactItem(url: URL(fileURLWithPath: path), modifiedAt: modifiedAt, change: change)
    }

    // MARK: - Kind (W-K1..W-K6)

    func testKindMarkdown() {
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "md"), .markdown)
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "markdown"), .markdown)
    }

    func testKindHTML() {
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "html"), .html)
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "htm"), .html)
    }

    func testKindText() {
        for ext in ["txt", "log", "json", "yaml", "yml", "csv"] {
            XCTAssertEqual(ArtifactItem.Kind(fileExtension: ext), .text, "extension: \(ext)")
        }
    }

    func testKindImage() {
        for ext in ["png", "jpg", "jpeg", "gif", "svg"] {
            XCTAssertEqual(ArtifactItem.Kind(fileExtension: ext), .image, "extension: \(ext)")
        }
    }

    func testKindOther() {
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "swift"), .other)
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: ""), .other)
    }

    func testKindIsCaseInsensitive() {
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "MD"), .markdown)
        XCTAssertEqual(ArtifactItem.Kind(fileExtension: "PNG"), .image)
    }

    func testKindFromURL() {
        XCTAssertEqual(ArtifactItem.Kind(url: URL(fileURLWithPath: "/a/report.md")), .markdown)
        XCTAssertEqual(ArtifactItem.Kind(url: URL(fileURLWithPath: "/a/noext")), .other)
    }

    // MARK: - Path filter (W-F1..W-F9)

    func testFilterAcceptsFileAtDepthOne() {
        XCTAssertTrue(included("/watch/root/report.md"))
    }

    func testFilterAcceptsFileAtDefaultMaxDepth() {
        XCTAssertTrue(included("/watch/root/sub/report.md"))
    }

    func testFilterRejectsFileBeyondMaxDepth() {
        XCTAssertFalse(included("/watch/root/sub/deeper/report.md"))
    }

    func testFilterRejectsDefaultExcludedDirectories() {
        XCTAssertFalse(included("/watch/root/node_modules/pkg.json"))
        XCTAssertFalse(included("/watch/root/zig-out/main.txt"))
        // Hidden and excluded at once (.git): rejected either way.
        XCTAssertFalse(included("/watch/root/.git/HEAD"))
    }

    func testFilterHonorsCustomExclusions() {
        let configuration = makeConfiguration(excluded: ["build"])
        XCTAssertFalse(included("/watch/root/build/out.txt", configuration))
        // node_modules is no longer excluded with the custom set.
        XCTAssertTrue(included("/watch/root/node_modules/pkg.json", configuration))
    }

    func testFilterRejectsHiddenFilesAndDirectories() {
        XCTAssertFalse(included("/watch/root/.hidden.md"))
        XCTAssertFalse(included("/watch/root/.hidden/report.md"))
    }

    func testFilterAcceptsHiddenFilesWhenConfigured() {
        let configuration = makeConfiguration(includeHidden: true)
        XCTAssertTrue(included("/watch/root/.hidden.md", configuration))
    }

    func testFilterRejectsPathsOutsideRootAndRootItself() {
        XCTAssertFalse(included("/watch/other/report.md"))
        XCTAssertFalse(included("/watch/root"))
        XCTAssertFalse(included("/watch"))
        // Sibling whose name shares the root as a string prefix.
        XCTAssertFalse(included("/watch/rootish/report.md"))
    }

    func testFilterExclusionAppliesToDirectoriesNotFileNames() {
        // A *file* named like an excluded directory is still a valid artifact.
        XCTAssertTrue(included("/watch/root/node_modules"))
    }

    // Boundary: maxDepth exactly at the component count; maxDepth 1.
    func testFilterMaxDepthBoundary() {
        let depthOne = makeConfiguration(maxDepth: 1)
        XCTAssertTrue(included("/watch/root/a.txt", depthOne))
        XCTAssertFalse(included("/watch/root/sub/a.txt", depthOne))

        let depthThree = makeConfiguration(maxDepth: 3)
        XCTAssertTrue(included("/watch/root/sub/deeper/a.txt", depthThree))
    }

    func testRelativeComponents() {
        XCTAssertEqual(
            ArtifactPathFilter.relativeComponents(of: "/watch/root/a/b.txt", under: root),
            ["a", "b.txt"]
        )
        XCTAssertNil(ArtifactPathFilter.relativeComponents(of: "/watch/root", under: root))
        XCTAssertNil(ArtifactPathFilter.relativeComponents(of: "/elsewhere/b.txt", under: root))
    }

    // MARK: - Change classification (W-C1..W-C3)

    func testClassifyCreatedWhenCreationInsideSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ArtifactPathFilter.change(creationDate: start.addingTimeInterval(1), watchStart: start),
            .created
        )
        // Boundary: creation exactly at watch start counts as created.
        XCTAssertEqual(ArtifactPathFilter.change(creationDate: start, watchStart: start), .created)
    }

    func testClassifyUpdatedWhenCreationBeforeSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ArtifactPathFilter.change(creationDate: start.addingTimeInterval(-1), watchStart: start),
            .updated
        )
    }

    func testClassifyUpdatedWhenCreationUnknown() {
        XCTAssertEqual(ArtifactPathFilter.change(creationDate: nil, watchStart: Date()), .updated)
    }

    // MARK: - Reducer (W-R1..W-R6)

    func testReducerInsertsNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        let older = makeItem("/watch/root/old.md", modifiedAt: base)
        let newer = makeItem("/watch/root/new.md", modifiedAt: base.addingTimeInterval(10))
        let result = ArtifactListReducer.apply(
            [.upsert(older), .upsert(newer)],
            to: [],
            maxItems: 500
        )
        XCTAssertEqual(result.map(\.fileName), ["new.md", "old.md"])
    }

    func testReducerReplacesSameURLWithoutDuplicating() {
        let base = Date(timeIntervalSince1970: 1_000)
        let first = makeItem("/watch/root/a.md", modifiedAt: base, change: .created)
        let other = makeItem("/watch/root/b.md", modifiedAt: base.addingTimeInterval(5))
        let updated = makeItem("/watch/root/a.md", modifiedAt: base.addingTimeInterval(10), change: .created)

        var items = ArtifactListReducer.apply([.upsert(first), .upsert(other)], to: [], maxItems: 500)
        items = ArtifactListReducer.apply([.upsert(updated)], to: items, maxItems: 500)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.fileName, "a.md")
        XCTAssertEqual(items.first?.modifiedAt, base.addingTimeInterval(10))
    }

    func testReducerRemovesDeletedItem() {
        let base = Date(timeIntervalSince1970: 1_000)
        let item = makeItem("/watch/root/a.md", modifiedAt: base)
        let items = ArtifactListReducer.apply([.upsert(item)], to: [], maxItems: 500)
        let result = ArtifactListReducer.apply(
            [.remove(URL(fileURLWithPath: "/watch/root/a.md"))],
            to: items,
            maxItems: 500
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testReducerRemovesChildrenOfRemovedDirectory() {
        let base = Date(timeIntervalSince1970: 1_000)
        let inside = makeItem("/watch/root/sub/a.md", modifiedAt: base)
        let outside = makeItem("/watch/root/subsequent.md", modifiedAt: base.addingTimeInterval(1))
        let items = ArtifactListReducer.apply(
            [.upsert(inside), .upsert(outside)],
            to: [],
            maxItems: 500
        )
        // Removing the directory "sub" removes a.md but must not remove
        // "subsequent.md" (string-prefix trap).
        let result = ArtifactListReducer.apply(
            [.remove(URL(fileURLWithPath: "/watch/root/sub"))],
            to: items,
            maxItems: 500
        )
        XCTAssertEqual(result.map(\.fileName), ["subsequent.md"])
    }

    func testReducerCapsAtMaxItemsDroppingOldest() {
        let base = Date(timeIntervalSince1970: 1_000)
        let events: [ArtifactListReducer.Event] = (0..<7).map { index in
            .upsert(makeItem("/watch/root/f\(index).txt", modifiedAt: base.addingTimeInterval(Double(index))))
        }
        let result = ArtifactListReducer.apply(events, to: [], maxItems: 5)
        XCTAssertEqual(result.count, 5)
        // Newest five survive: f6...f2. The oldest (f0, f1) are dropped.
        XCTAssertEqual(result.first?.fileName, "f6.txt")
        XCTAssertEqual(result.last?.fileName, "f2.txt")
    }

    func testReducerSortsTiesByPathForStability() {
        let base = Date(timeIntervalSince1970: 1_000)
        let bravo = makeItem("/watch/root/b.md", modifiedAt: base)
        let alpha = makeItem("/watch/root/a.md", modifiedAt: base)
        let result = ArtifactListReducer.apply(
            [.upsert(bravo), .upsert(alpha)],
            to: [],
            maxItems: 500
        )
        XCTAssertEqual(result.map(\.fileName), ["a.md", "b.md"])
    }

    // Boundary: exactly maxItems; empty event list; remove on empty list;
    // maxItems zero.
    func testReducerBoundaries() {
        let base = Date(timeIntervalSince1970: 1_000)
        let events: [ArtifactListReducer.Event] = (0..<5).map { index in
            .upsert(makeItem("/watch/root/f\(index).txt", modifiedAt: base.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(ArtifactListReducer.apply(events, to: [], maxItems: 5).count, 5)
        XCTAssertEqual(ArtifactListReducer.apply([], to: [], maxItems: 5), [])
        XCTAssertEqual(
            ArtifactListReducer.apply(
                [.remove(URL(fileURLWithPath: "/watch/root/none.txt"))],
                to: [],
                maxItems: 5
            ),
            []
        )
        XCTAssertEqual(ArtifactListReducer.apply(events, to: [], maxItems: 0), [])
    }

    // MARK: - Debouncer (W-D1..W-D4)

    func testDebouncerCoalescesBurstIntoSingleFlush() {
        let flushed = expectation(description: "single flush")
        var batches: [[Int]] = []
        let debouncer = EventDebouncer<Int>(interval: 0.15) { events in
            batches.append(events)
            flushed.fulfill()
        }
        debouncer.add([1])
        debouncer.add([2, 3])
        debouncer.add([4])
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(batches, [[1, 2, 3, 4]], "burst must arrive as one ordered batch")
    }

    func testDebouncerFlushesSeparateBurstsSeparately() {
        let first = expectation(description: "first flush")
        let second = expectation(description: "second flush")
        var batches: [[Int]] = []
        let debouncer = EventDebouncer<Int>(interval: 0.1) { events in
            batches.append(events)
            if batches.count == 1 { first.fulfill() }
            if batches.count == 2 { second.fulfill() }
        }
        debouncer.add([1])
        wait(for: [first], timeout: 2)
        debouncer.add([2])
        wait(for: [second], timeout: 2)
        XCTAssertEqual(batches, [[1], [2]])
    }

    func testDebouncerFlushNowDeliversImmediately() {
        let flushed = expectation(description: "immediate flush")
        var batches: [[Int]] = []
        // Long interval: only flushNow can deliver within the timeout.
        let debouncer = EventDebouncer<Int>(interval: 60) { events in
            batches.append(events)
            flushed.fulfill()
        }
        debouncer.add([1, 2])
        debouncer.flushNow()
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(batches, [[1, 2]])
    }

    func testDebouncerCancelDropsPendingEvents() {
        let quiet = expectation(description: "no flush after cancel")
        quiet.isInverted = true
        let debouncer = EventDebouncer<Int>(interval: 0.1) { _ in
            quiet.fulfill()
        }
        debouncer.add([1])
        debouncer.cancel()
        wait(for: [quiet], timeout: 0.5)
    }

    func testDebouncerFlushNowWithoutPendingIsNoOp() {
        let quiet = expectation(description: "no flush when empty")
        quiet.isInverted = true
        let debouncer = EventDebouncer<Int>(interval: 0.1) { _ in
            quiet.fulfill()
        }
        debouncer.flushNow()
        wait(for: [quiet], timeout: 0.3)
    }

    // MARK: - Configuration defaults (FR-2 spec table)

    func testConfigurationDefaultsMatchSpec() {
        let configuration = ArtifactWatcherConfiguration.default
        XCTAssertEqual(configuration.maxDepth, 2)
        XCTAssertEqual(configuration.debounceInterval, 0.5)
        XCTAssertEqual(configuration.maxItems, 500)
        XCTAssertFalse(configuration.includeHiddenFiles)
        for name in [".git", "node_modules", ".cache", "zig-cache", "zig-out"] {
            XCTAssertTrue(
                configuration.excludedDirectoryNames.contains(name),
                "missing default exclusion: \(name)"
            )
        }
    }

    // MARK: - ArtifactItem

    func testArtifactItemIdentityAndEquality() {
        let date = Date(timeIntervalSince1970: 1_000)
        let one = makeItem("/watch/root/a.md", modifiedAt: date)
        let two = makeItem("/watch/root/a.md", modifiedAt: date)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.id, one.url)
        XCTAssertEqual(one.fileName, "a.md")
        XCTAssertEqual(one.kind, .markdown)
    }
}
