import XCTest
@testable import YTCurator

final class StagingTests: XCTestCase {
    private func video(_ id: String, set: String? = nil) -> PlaylistVideo {
        PlaylistVideo(videoId: id, setVideoId: set ?? "S\(id)", title: id, author: nil, channelId: nil, thumbnailUrl: nil, durationText: nil)
    }

    private func playlist(_ videos: [PlaylistVideo]) -> PlaylistDetail {
        PlaylistDetail(id: "PL", title: "t", description: nil, videoCount: videos.count, thumbnailUrl: nil, videos: videos)
    }

    private func payload(_ id: String) -> VideoDragPayload {
        VideoDragPayload(videoId: id, title: id, thumbnailUrl: nil, durationText: nil, author: nil)
    }

    func testAddRemoveReorderAndPayload() {
        var e = Staging.baseline(playlist([video("a"), video("b"), video("c")]))
        XCTAssertEqual(Staging.pendingChanges(e), 0)

        e = Staging.add(e, payload("d"))
        e = Staging.add(e, payload("d")) // dedupe
        XCTAssertEqual(e.videos.map(\.videoId), ["a", "b", "c", "d"])
        XCTAssertEqual(e.addedVideoIds, ["d"])

        e = Staging.remove(e, key: "Sb")
        XCTAssertEqual(e.removedSetVideoIds, ["Sb"])
        e = Staging.move(e, from: IndexSet(integer: 2), to: 0) // d to top
        XCTAssertEqual(e.videos.map(\.videoId), ["d", "a", "c"])
        XCTAssertEqual(Staging.pendingChanges(e), 2) // remove + add, shared order a,c unchanged

        e = Staging.move(e, from: IndexSet(integer: 2), to: 1) // c before a
        XCTAssertEqual(Staging.pendingChanges(e), 3)

        // Canceling a pending add drops it from addedVideoIds instead of staging a removal.
        let canceled = Staging.remove(e, key: "pending:d")
        XCTAssertEqual(canceled.addedVideoIds, [])
        XCTAssertEqual(canceled.removedSetVideoIds, ["Sb"])

        let sync = Staging.syncPayload(e)
        XCTAssertEqual(sync.orderedVideoIds, ["d", "c", "a"])
        XCTAssertEqual(sync.removedSetVideoIds, ["Sb"])
        XCTAssertEqual(sync.addedVideoIds, ["d"])
    }

    func testMergeKeepsStagedOrderAndAppendsNewServerVideos() {
        var staged = Staging.baseline(playlist([video("a"), video("b"), video("c")]))
        staged = Staging.move(staged, from: IndexSet(integer: 2), to: 0)
        staged = Staging.remove(staged, key: "Sa")
        staged = Staging.add(staged, payload("x"))

        // Server: b's metadata changed, a still present (removal pending), new video n appeared.
        var b = video("b"); b.title = "B renamed"
        let merged = Staging.merge(playlist([video("a"), b, video("c"), video("n")]), existing: staged)
        XCTAssertEqual(merged.videos.map(\.videoId), ["c", "b", "x", "n"])
        XCTAssertEqual(merged.videos[1].title, "B renamed")
        XCTAssertEqual(merged.removedSetVideoIds, ["Sa"])
        XCTAssertEqual(merged.addedVideoIds, ["x"])

        // Server caught up with the add and the removal.
        let caughtUp = Staging.merge(playlist([b, video("c"), video("n"), video("x")]), existing: merged)
        XCTAssertEqual(caughtUp.addedVideoIds, [])
        XCTAssertEqual(caughtUp.removedSetVideoIds, [])
        XCTAssertEqual(caughtUp.videos.first { $0.videoId == "x" }?.pendingAdd, nil)
    }

    func testCompletedReconcile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let state = LocalState(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        // First sighting only seeds the baseline.
        XCTAssertEqual(Completed.reconcileExternalRemovals("PL", current: ["a", "b"], in: state), [])
        // b removed externally → completed.
        XCTAssertEqual(Completed.reconcileExternalRemovals("PL", current: ["a", "c"], in: state), ["b"])
        XCTAssertEqual(Completed.load("PL", in: state), ["b"])
    }

    func testDragPayloadRoundTrip() {
        let p = VideoDragPayload(videoId: "abc", title: "T \"quoted\"", thumbnailUrl: "u", durationText: "1:00", author: "A")
        XCTAssertEqual(VideoDragPayload.decode(p.encoded), p)
        XCTAssertNil(VideoDragPayload.decode("https://example.com"))
    }
}

final class SortTests: XCTestCase {
    func testRelativeAge() {
        XCTAssertEqual(VideoSort.relativeAge("3 days ago"), 3 * 86400)
        XCTAssertEqual(VideoSort.relativeAge("Streamed 2 weeks ago"), 14 * 86400)
        XCTAssertEqual(VideoSort.relativeAge("4h ago"), 4 * 3600)
        XCTAssertEqual(VideoSort.relativeAge("1 month ago"), 30 * 86400)
        XCTAssertEqual(VideoSort.relativeAge("12K views • 5 minutes ago"), 300)
        XCTAssertNil(VideoSort.relativeAge("Premieres tomorrow"))
        XCTAssertNil(VideoSort.relativeAge(nil))
    }

    func testSortAndFilter() {
        func v(_ id: String, _ p: String?) -> ChannelVideo {
            ChannelVideo(videoId: id, title: id, thumbnailUrl: nil, durationText: nil, publishedText: p, viewCountText: nil, isMembersOnly: false)
        }
        let items = [v("old", "2 months ago"), v("none", nil), v("new", "1h ago"), v("mid", "5 days ago")]
        XCTAssertEqual(VideoSort.newestFirst(items).map(\.videoId), ["new", "mid", "old", "none"])
        let sorted = VideoSort.newestFirst(items)
        XCTAssertEqual(VideoSort.apply(sorted, .week).map(\.videoId), ["new", "mid"])
        XCTAssertEqual(VideoSort.apply(sorted, .month).map(\.videoId), ["new", "mid"])
        XCTAssertEqual(VideoSort.apply(sorted, .oldest).map(\.videoId), ["none", "old", "mid", "new"])
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func channel(_ id: String, _ handle: String) -> SavedChannel {
        SavedChannel(handle: handle, channelId: id, title: handle, avatarUrl: nil)
    }

    func testMigratesGlazeData() throws {
        let glaze = AppPaths.glazeAppData
        try XCTSkipUnless(FileManager.default.fileExists(atPath: glaze.path), "No Glaze data on this machine")
        let store = AppStore(directory: dir, glazeImport: glaze)
        XCTAssertGreaterThan(store.channels.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "app-data.json").path))
        // Reopening reads our own file, not Glaze's.
        let reopened = AppStore(directory: dir, glazeImport: nil)
        XCTAssertEqual(reopened.channels.count, store.channels.count)
        XCTAssertEqual(reopened.loadouts.count, store.loadouts.count)
        XCTAssertEqual(reopened.activeLoadoutId, store.activeLoadoutId)
    }

    func testChannelsAndLoadouts() throws {
        let store = AppStore(directory: dir, glazeImport: nil)
        store.addChannel(channel("UC1", "one"))
        store.addChannel(channel("UC2", "two"))
        XCTAssertEqual(store.addChannels([channel("UC2", "two"), channel("UC3", "ONE"), channel("UC4", "four")]), 1)
        XCTAssertEqual(store.channels.map(\.channelId), ["UC1", "UC2", "UC4"])

        let loadout = try store.createLoadout(name: "  Mix ", channelIds: ["UC4", "UC1", "UC1", "UCX"])
        XCTAssertEqual(loadout.name, "Mix")
        XCTAssertEqual(loadout.channelIds, ["UC4", "UC1"])
        XCTAssertThrowsError(try store.createLoadout(name: " ", channelIds: []))

        store.setActiveLoadout(loadout.id)
        XCTAssertEqual(store.activeChannels.map(\.channelId), ["UC1", "UC4"]) // saved order

        store.removeChannel("UC1")
        XCTAssertEqual(store.loadouts[0].channelIds, ["UC4"])
        store.deleteLoadout(id: loadout.id)
        XCTAssertNil(store.activeLoadoutId)

        let reopened = AppStore(directory: dir, glazeImport: nil)
        XCTAssertEqual(reopened.channels.map(\.channelId), ["UC2", "UC4"])
    }
}

@MainActor
final class CompletedAddTests: XCTestCase {
    func testCompletedVideoAsksBeforeAdding() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(directory: dir, glazeImport: nil)
        store.selectedPlaylistId = "PL"
        let model = PlaylistModel(store: store, state: LocalState(directory: dir))
        model.edits = StagedEdits(playlistId: "PL", videos: [], removedSetVideoIds: [], addedVideoIds: [], baselineVideoIds: [])
        model.completedIds = ["done"]
        func payload(_ id: String) -> VideoDragPayload {
            VideoDragPayload(videoId: id, title: id, thumbnailUrl: nil, durationText: nil, author: nil)
        }

        model.requestAdd(payload("fresh"))
        XCTAssertEqual(model.videos.map(\.videoId), ["fresh"])
        XCTAssertNil(model.pendingCompletedAdd)

        model.requestAdd(payload("done"), at: 0)
        XCTAssertEqual(model.videos.map(\.videoId), ["fresh"], "completed video must wait for confirmation")
        let pending = try XCTUnwrap(model.pendingCompletedAdd)

        // Binding cleared first (as SwiftUI may do), then "Yes" still adds at the dropped position.
        model.pendingCompletedAdd = nil
        model.confirmAdd(pending)
        XCTAssertEqual(model.videos.map(\.videoId), ["done", "fresh"])
        XCTAssertFalse(model.completedIds.contains("done"), "re-adding clears the completed mark")
    }
}

final class UpdaterTests: XCTestCase {
    func testCompareVersions() {
        XCTAssertGreaterThan(Updater.compare("1.0.10", "1.0.9"), 0)
        XCTAssertGreaterThan(Updater.compare("v1.1", "1.0.9"), 0)
        XCTAssertEqual(Updater.compare("1.0", "1.0.0"), 0)
        XCTAssertLessThan(Updater.compare("0.9.0", "1.0.0"), 0)
        XCTAssertEqual(Updater.compare("1.2.0-beta", "1.2.0"), 0)
    }

    @MainActor
    func testParseRelease() throws {
        let json = """
        {"tag_name":"v1.2.0","html_url":"https://github.com/Deli5150/yt-curator/releases/tag/v1.2.0","body":"Notes",
         "draft":false,"prerelease":false,
         "assets":[{"name":"YT-Curator-1.2.0-mac.zip","browser_download_url":"https://example.com/a.zip","size":123,
                    "digest":"sha256:abc123"}]}
        """
        let release = try XCTUnwrap(Updater.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.sha256, "abc123")
        XCTAssertEqual(release.assetSize, 123)
        XCTAssertNil(Updater.parse(Data(json.replacingOccurrences(of: "-mac.zip", with: ".dmg").utf8)))
    }
}
