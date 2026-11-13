import Foundation

/// Small JSON-file key/value store for per-playlist local state (staged edits, completed
/// marks, known-member baselines). Replaces the Glaze build's `localStorage`, without its quota.
struct LocalState {
    let directory: URL

    init(directory: URL = AppPaths.supportDir.appending(path: "state", directoryHint: .isDirectory)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL {
        let safe = key.replacing(/[^A-Za-z0-9_.-]/, with: "_")
        return directory.appending(path: safe + ".json")
    }

    func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, _ key: String) {
        do {
            try JSONEncoder().encode(value).write(to: url(key), options: .atomic)
        } catch {
            log.error("Could not persist \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(key))
    }
}

// MARK: - Staged edits (port of renderer/lib/staged-edits.ts)

enum Staging {
    static func key(_ playlistId: String) -> String { "staged-\(playlistId)" }

    static func load(_ playlistId: String, in state: LocalState) -> StagedEdits? {
        guard let e = state.read(StagedEdits.self, key(playlistId)), e.playlistId == playlistId else { return nil }
        return e
    }

    static func save(_ edits: StagedEdits, in state: LocalState) { state.write(edits, key(edits.playlistId)) }
    static func clear(_ playlistId: String, in state: LocalState) { state.remove(key(playlistId)) }

    static func baseline(_ playlist: PlaylistDetail) -> StagedEdits {
        StagedEdits(playlistId: playlist.id, videos: playlist.videos, removedSetVideoIds: [],
                    addedVideoIds: [], baselineVideoIds: playlist.videos.map(\.videoId))
    }

    /// Merge a server playlist with previously staged local edits.
    static func merge(_ playlist: PlaylistDetail, existing: StagedEdits?) -> StagedEdits {
        guard let existing else { return baseline(playlist) }
        var serverBySetId: [String: PlaylistVideo] = [:]
        var serverByVideoId: [String: PlaylistVideo] = [:]
        for v in playlist.videos {
            if let s = v.setVideoId { serverBySetId[s] = v }
            serverByVideoId[v.videoId] = v
        }
        let removed = Set(existing.removedSetVideoIds)

        var merged: [PlaylistVideo] = []
        for v in existing.videos {
            if v.pendingAdd == true {
                // Server caught up — use the server copy; otherwise keep the pending add.
                merged.append(serverByVideoId[v.videoId] ?? v)
                continue
            }
            if let s = v.setVideoId, removed.contains(s) { continue }
            // Prefer live metadata but keep the staged position.
            if let s = v.setVideoId, let server = serverBySetId[s] {
                merged.append(server)
            } else if let server = serverByVideoId[v.videoId] {
                merged.append(server)
            }
        }

        // Append brand-new server videos not represented in the staged list.
        var seen = Set(merged.map { $0.setVideoId ?? $0.videoId })
        for v in playlist.videos {
            let k = v.setVideoId ?? v.videoId
            if !seen.contains(k), !(v.setVideoId.map(removed.contains) ?? false) {
                merged.append(v)
                seen.insert(k)
            }
        }

        return StagedEdits(
            playlistId: playlist.id,
            videos: merged,
            removedSetVideoIds: existing.removedSetVideoIds.filter { id in playlist.videos.contains { $0.setVideoId == id } },
            addedVideoIds: existing.addedVideoIds.filter { serverByVideoId[$0] == nil },
            baselineVideoIds: playlist.videos.map(\.videoId)
        )
    }

    static func pendingChanges(_ edits: StagedEdits?) -> Int {
        guard let edits else { return 0 }
        let current = edits.videos.map(\.videoId)
        var changes = edits.removedSetVideoIds.count + edits.addedVideoIds.count
        let currentSet = Set(current), baselineSet = Set(edits.baselineVideoIds)
        // Count a reorder if the order of shared ids differs.
        if edits.baselineVideoIds.filter(currentSet.contains) != current.filter(baselineSet.contains) {
            changes += 1
        }
        return changes
    }

    static func move(_ edits: StagedEdits, from source: IndexSet, to destination: Int) -> StagedEdits {
        var next = edits
        next.videos.move(fromOffsets: source, toOffset: destination)
        return next
    }

    static func remove(_ edits: StagedEdits, key: String) -> StagedEdits {
        guard let video = edits.videos.first(where: { $0.key == key }) else { return edits }
        var next = edits
        next.videos.removeAll { $0.key == key }
        if video.pendingAdd == true || video.setVideoId == nil {
            next.addedVideoIds.removeAll { $0 == video.videoId }
        } else if let s = video.setVideoId, !next.removedSetVideoIds.contains(s) {
            next.removedSetVideoIds.append(s)
        }
        return next
    }

    static func add(_ edits: StagedEdits, _ video: VideoDragPayload, at index: Int? = nil) -> StagedEdits {
        guard !edits.videos.contains(where: { $0.videoId == video.videoId }) else { return edits }
        var next = edits
        let item = PlaylistVideo(
            videoId: video.videoId, setVideoId: nil, title: video.title, author: video.author,
            // Drag payload has no channel id — Follow becomes available after a server reload.
            channelId: nil, thumbnailUrl: video.thumbnailUrl, durationText: video.durationText, pendingAdd: true
        )
        next.videos.insert(item, at: min(index ?? next.videos.count, next.videos.count))
        if !next.addedVideoIds.contains(video.videoId) { next.addedVideoIds.append(video.videoId) }
        return next
    }

    static func syncPayload(_ edits: StagedEdits) -> PlaylistSyncInput {
        PlaylistSyncInput(
            playlistId: edits.playlistId,
            // Full staged order by public id — the client resolves setVideoIds after adding.
            orderedVideoIds: edits.videos.map(\.videoId),
            removedSetVideoIds: edits.removedSetVideoIds,
            addedVideoIds: edits.addedVideoIds
        )
    }
}

// MARK: - Completed videos (port of renderer/lib/completed-videos.ts)

enum Completed {
    static func key(_ playlistId: String) -> String { "completed-\(playlistId)" }
    static func knownKey(_ playlistId: String) -> String { "known-\(playlistId)" }

    static func load(_ playlistId: String, in state: LocalState) -> Set<String> {
        Set(state.read([String].self, key(playlistId)) ?? [])
    }

    static func save(_ ids: Set<String>, _ playlistId: String, in state: LocalState) {
        state.write(ids.sorted(), key(playlistId))
    }

    /// Diff the fresh server member list against the last-seen baseline. Any previously known id
    /// now absent (including removals made directly on YouTube) is marked completed. The first
    /// sighting only establishes the baseline.
    static func reconcileExternalRemovals(_ playlistId: String, current: [String], in state: LocalState) -> Set<String> {
        let currentSet = Set(current)
        var completed = load(playlistId, in: state)
        if let known = state.read([String].self, knownKey(playlistId)) {
            let removed = Set(known).subtracting(currentSet).subtracting(completed)
            if !removed.isEmpty {
                completed.formUnion(removed)
                save(completed, playlistId, in: state)
            }
        }
        state.write(currentSet.sorted(), knownKey(playlistId))
        return completed
    }
}

// MARK: - Feed cache (port of renderer/lib/feed-cache.ts, on disk)

/// Last-fetched page per (channel, tab) so a warm launch paints the home feed instantly.
enum FeedCache {
    static let maxVideos = 40

    struct Entry: Codable { var page: ChannelVideosPage; var savedAt: Date }

    private static var dir: URL {
        let d = AppPaths.cacheDir.appending(path: "feed", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func url(_ channelId: String, _ tab: ChannelTab) -> URL {
        dir.appending(path: "\(channelId)-\(tab.rawValue).json")
    }

    static func read(_ channelId: String, _ tab: ChannelTab) -> Entry? {
        guard let data = try? Data(contentsOf: url(channelId, tab)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func write(_ channelId: String, _ tab: ChannelTab, _ page: ChannelVideosPage) {
        let trimmed = ChannelVideosPage(videos: Array(page.videos.prefix(maxVideos)), hasMore: page.hasMore)
        if let data = try? JSONEncoder().encode(Entry(page: trimmed, savedAt: Date())) {
            try? data.write(to: url(channelId, tab), options: .atomic)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}
