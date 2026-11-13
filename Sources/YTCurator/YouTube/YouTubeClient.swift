import Foundation

/// The isolated unofficial YouTube adapter (port of the Glaze app's `youtube-client.ts`).
/// Exposes only app DTOs; all InnerTube endpoint knowledge lives here and in `Parsers`.
actor YouTubeClient {
    static let shared = YouTubeClient()

    private let innerTube = InnerTube.shared

    /// Tab params for direct channel-tab browses (what youtubei.js resolves from the tab list).
    /// Browsing a tab directly skips a separate channel-home request per channel.
    private static let tabParams: [ChannelTab: String] = [
        .videos: "EgZ2aWRlb3PyBgQKAjoA",
        .live: "EgdzdHJlYW1z8gYECgJ6AA==",
    ]

    private static let cacheTTL: TimeInterval = 3 * 60
    private static let cacheMax = 64

    private struct Cached<T> { var value: T; var expiresAt: Date }
    private var channelDetailCache: [String: Cached<ChannelDetail>] = [:]
    private var channelVideosCache: [String: Cached<ChannelVideosPage>] = [:]
    /// In-flight channel browses, so concurrent callers (feed + avatar refresh) share one fetch.
    private var channelInflight: [String: Task<ChannelDetail, Error>] = [:]

    func reset() async {
        channelDetailCache = [:]
        channelVideosCache = [:]
        channelInflight = [:]
        await innerTube.reset()
    }

    private func cacheGet<T>(_ map: [String: Cached<T>], _ key: String) -> T? {
        guard let entry = map[key], entry.expiresAt > Date() else { return nil }
        return entry.value
    }

    private func cachePut<T>(_ map: inout [String: Cached<T>], _ key: String, _ value: T) {
        map[key] = Cached(value: value, expiresAt: Date().addingTimeInterval(Self.cacheTTL))
        if map.count > Self.cacheMax {
            let expired = map.filter { $0.value.expiresAt <= Date() }.map(\.key)
            expired.forEach { map.removeValue(forKey: $0) }
            if map.count > Self.cacheMax, let oldest = map.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                map.removeValue(forKey: oldest)
            }
        }
    }

    // MARK: - Playlists

    func listPlaylists() async throws -> [PlaylistSummary] {
        var items: [(kind: String, node: J)] = []
        var lastError: Error?

        for browseId in ["FEplaylist_aggregation", "FElibrary"] where items.isEmpty {
            do {
                var page = Parsers.collectItems(try await innerTube.call("browse", ["browseId": browseId], priority: true)["contents"])
                items = page.items
                var pages = 1
                while let token = page.continuation, pages < 10 {
                    page = Parsers.continuationItems(try await innerTube.call("browse", ["continuation": token]))
                    items += page.items
                    pages += 1
                }
            } catch {
                lastError = error
                log.warning("\(browseId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if items.isEmpty, let lastError {
            throw YouTubeError.other("Failed to load playlists: \(lastError.localizedDescription)")
        }

        var seen = Set<String>()
        return items.compactMap { item in
            guard let summary = Parsers.playlistSummary(kind: item.kind, node: item.node),
                  seen.insert(summary.id).inserted else { return nil }
            return summary
        }
    }

    func getPlaylist(_ playlistId: String) async throws -> PlaylistDetail {
        let response: J
        do {
            response = try await innerTube.call("browse", ["browseId": "VL" + playlistId], label: "getPlaylist(\(playlistId))", priority: true)
        } catch {
            throw YouTubeError.other("Failed to load playlist: \(Self.describePlaylistError(error))")
        }
        let header = Parsers.playlistHeader(response)
        var page = Parsers.collectItems(response["contents"])
        var rawItems = page.items
        var pages = 0
        while let token = page.continuation, pages < 20 {
            // Gate continuations too — an ungated pagination loop is what floods YouTube into a 429.
            let next: J
            do {
                next = try await innerTube.call("browse", ["continuation": token], priority: true)
            } catch {
                Diagnostics.write("getPlaylist continuation failed: \(error.localizedDescription)")
                break
            }
            page = Parsers.continuationItems(next)
            rawItems += page.items
            pages += 1
        }
        let videos = rawItems.compactMap { Parsers.playlistVideo(kind: $0.kind, node: $0.node) }
        return PlaylistDetail(
            id: playlistId,
            title: header.title ?? "Playlist",
            description: header.description,
            videoCount: videos.count,
            thumbnailUrl: header.thumbnailUrl ?? videos.first?.thumbnailUrl,
            videos: videos
        )
    }

    private static func describePlaylistError(_ error: Error) -> String {
        let message = error.localizedDescription
        if (error as? YouTubeError)?.kind == .rateLimited {
            return "YouTube is temporarily rate-limiting requests. Wait a moment and try again."
        }
        if message.lowercased().contains("does not exist") {
            return "Couldn't load this playlist. It may have been deleted, or YouTube is throttling requests — try again in a moment."
        }
        return message
    }

    // MARK: - Channels

    /// `priority` = user-initiated (jumps ahead of background feed/avatar requests in the gate).
    func getChannel(_ channelId: String, priority: Bool = false) async throws -> ChannelDetail {
        if let cached = cacheGet(channelDetailCache, channelId) { return cached }
        if let inflight = channelInflight[channelId] { return try await inflight.value }
        let task = Task<ChannelDetail, Error> {
            do {
                let response = try await innerTube.call("browse", ["browseId": channelId], label: "getChannel(\(channelId))", priority: priority)
                return Parsers.channelDetail(channelId: channelId, response: response)
            } catch {
                throw YouTubeError.other("Failed to load channel: \(error.localizedDescription)")
            }
        }
        channelInflight[channelId] = task
        defer { channelInflight[channelId] = nil }
        let detail = try await task.value
        cachePut(&channelDetailCache, channelId, detail)
        return detail
    }

    func resolveChannelById(_ rawId: String) async throws -> SavedChannel {
        let id = rawId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw YouTubeError.other("Channel id is required.") }
        let detail = try await getChannel(id, priority: true)
        // Fall back to the id so handle-based dedupe can't collapse two handle-less channels.
        let handle = detail.handle.map { String($0.drop(while: { $0 == "@" })) }
        return SavedChannel(handle: handle?.isEmpty == false ? handle! : id, channelId: id,
                            title: detail.title.isEmpty ? id : detail.title, avatarUrl: detail.avatarUrl)
    }

    func resolveChannelByHandle(_ rawHandle: String) async throws -> SavedChannel {
        let handle = Parsers.normalizeHandle(rawHandle)
        guard !handle.isEmpty else { throw YouTubeError.other("Enter a YouTube channel handle (e.g. @mkbhd).") }

        var channelId: String?
        var title = handle
        var avatarUrl: String?

        if handle.hasPrefix("UC"), handle.count == 24 {
            channelId = handle
        }
        if channelId == nil {
            do {
                let resolved = try await innerTube.call("navigation/resolve_url", ["url": "https://www.youtube.com/@\(handle)"], priority: true)
                channelId = resolved["endpoint"]["browseEndpoint"]["browseId"].string
                    ?? resolved.first("browseId")?.string
            } catch {
                log.warning("resolve_url failed for @\(handle, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if channelId == nil {
            if let results = try? await innerTube.call("search", ["query": "@\(handle)", "params": "EgIQAg=="], priority: true),
               let first = results["contents"].all("channelRenderer").first,
               let mapped = Parsers.subscribedChannel(kind: "channelRenderer", node: first) {
                channelId = mapped.channelId
                title = mapped.title
                avatarUrl = mapped.avatarUrl
            }
        }
        guard let channelId else { throw YouTubeError.other("Could not find a channel for @\(handle).") }

        guard let detail = try? await getChannel(channelId, priority: true) else {
            return SavedChannel(handle: handle, channelId: channelId, title: title, avatarUrl: avatarUrl)
        }
        return SavedChannel(
            handle: detail.handle.map { String($0.dropFirst()) } ?? handle,
            channelId: channelId,
            title: detail.title.isEmpty ? title : detail.title,
            avatarUrl: detail.avatarUrl ?? avatarUrl
        )
    }

    /// Re-fetch title/avatar for each saved channel so sidebar pictures stay current.
    /// Sequential on purpose — one request per channel at once is exactly what triggers 429.
    func refreshSavedChannels(_ channels: [SavedChannel]) async -> [SavedChannel] {
        var refreshed: [SavedChannel] = []
        for channel in channels {
            if Task.isCancelled { refreshed.append(channel); continue }
            if let detail = try? await getChannel(channel.channelId) {
                let handle = detail.handle.map { String($0.dropFirst()) }
                refreshed.append(SavedChannel(
                    handle: handle?.isEmpty == false ? handle! : channel.handle,
                    channelId: channel.channelId,
                    title: detail.title.isEmpty ? channel.title : detail.title,
                    avatarUrl: detail.avatarUrl ?? channel.avatarUrl
                ))
            } else {
                refreshed.append(channel)
            }
        }
        return refreshed
    }

    func getChannelVideos(_ channelId: String, tab: ChannelTab, maxPages: Int = 100, force: Bool = false, priority: Bool = false) async throws -> ChannelVideosPage {
        let budget = max(1, min(maxPages, 100))
        // Depth is part of the key so a shallow feed result never satisfies a deep channel request.
        let cacheKey = "\(channelId):\(tab.rawValue):\(budget)"
        // A manual refresh must bypass the cache, or Refresh within 3 minutes returns the same page.
        if !force, let cached = cacheGet(channelVideosCache, cacheKey) { return cached }

        let response: J
        do {
            response = try await innerTube.call("browse", ["browseId": channelId, "params": Self.tabParams[tab]!],
                                                label: "\(channelId) \(tab.rawValue)", priority: priority)
        } catch {
            throw YouTubeError.other("Failed to load \(tab.rawValue): \(error.localizedDescription)")
        }

        // The tab browse also carries the channel header — keep it for detail/avatar callers.
        if response["metadata"]["channelMetadataRenderer"].exists {
            cachePut(&channelDetailCache, channelId, Parsers.channelDetail(channelId: channelId, response: response))
        }

        // A channel without this tab (e.g. never gone live) gets its Home tab back instead.
        // That's genuinely zero items, not a failure.
        let tabs = Parsers.channelTabs(response)
        guard let selected = tabs.first(where: { $0.selected }), selected.segment == tab.urlSegment else {
            let empty = ChannelVideosPage(videos: [], hasMore: false)
            cachePut(&channelVideosCache, cacheKey, empty)
            return empty
        }

        var page = Parsers.collectItems(selected.content)
        // A tab can default to "Popular" instead of "Latest" (owner setting). Force newest-first
        // so recent uploads aren't pushed past the shallow page budget.
        if let latest = Parsers.latestChipToken(selected.content),
           let resorted = try? await innerTube.call("browse", ["continuation": latest], priority: priority) {
            let list = Parsers.continuationItems(resorted)
            if !list.items.isEmpty {
                log.info("channel \(channelId, privacy: .public) \(tab.rawValue, privacy: .public) defaulted to a non-Latest sort — forced Latest")
                page = list
            }
        }

        var rawItems = page.items
        var pages = 1
        var exhausted = page.continuation == nil
        while pages < budget, let token = page.continuation {
            guard let next = try? await innerTube.call("browse", ["continuation": token], label: "\(channelId) \(tab.rawValue) page \(pages + 1)", priority: priority) else { break }
            page = Parsers.continuationItems(next)
            rawItems += page.items
            pages += 1
            exhausted = page.continuation == nil
        }

        let videos = rawItems.compactMap { Parsers.channelVideo(kind: $0.kind, node: $0.node) }
        let result = ChannelVideosPage(videos: videos, hasMore: !exhausted)
        cachePut(&channelVideosCache, cacheKey, result)
        return result
    }

    /// Every channel the signed-in user is subscribed to (FEchannels feed).
    func fetchSubscribedChannels() async throws -> [SavedChannel] {
        var page: Parsers.ItemList
        do {
            page = Parsers.collectItems(try await innerTube.call("browse", ["browseId": "FEchannels"], priority: true)["contents"])
        } catch {
            throw YouTubeError.other("Failed to load subscriptions: \(error.localizedDescription)")
        }
        var items = page.items
        var pages = 1
        while let token = page.continuation, pages < 20 {
            guard let next = try? await innerTube.call("browse", ["continuation": token]) else { break }
            page = Parsers.continuationItems(next)
            items += page.items
            pages += 1
        }
        var seen = Set<String>()
        return items.compactMap { item in
            guard let channel = Parsers.subscribedChannel(kind: item.kind, node: item.node),
                  seen.insert(channel.channelId).inserted else { return nil }
            return channel
        }
    }

    // MARK: - Sync

    private func editPlaylist(_ playlistId: String, actions: [[String: Any]]) async throws {
        let result = try await innerTube.call("browse/edit_playlist", ["playlistId": playlistId, "actions": actions], priority: true)
        if let status = result["status"].string, status != "STATUS_SUCCEEDED" {
            throw YouTubeError.other("edit_playlist failed with status \(status)")
        }
    }

    /// Resolve desired public video ids to live setVideoIds, waiting briefly when
    /// just-added items have not yet appeared (eventual consistency).
    private func resolveDesiredSetVideoIds(_ playlistId: String, ordered: [String], expect: [String]) async throws -> (live: PlaylistDetail, desired: [String]) {
        let maxAttempts = 4
        var live = try await getPlaylist(playlistId)
        for attempt in 1...maxAttempts {
            var byVideoId: [String: String] = [:]
            for v in live.videos { if let s = v.setVideoId { byVideoId[v.videoId] = s } }
            let missing = expect.filter { byVideoId[$0] == nil }
            let desired = ordered.compactMap { byVideoId[$0] }
            if missing.isEmpty || attempt == maxAttempts {
                if !missing.isEmpty {
                    log.warning("reorder: \(missing.count) video(s) still missing after add (attempt \(attempt)/\(maxAttempts))")
                }
                return (live, desired)
            }
            try? await Task.sleep(for: .milliseconds(400 * attempt))
            live = try await getPlaylist(playlistId)
        }
        return (live, [])
    }

    /// Apply the desired order with sequential single-action MOVE_AFTER calls. Batching is
    /// intentionally avoided: YouTube evaluates each action against the initial snapshot, so
    /// multi-action requests only partially reorder. A local model skips already-adjacent pairs.
    private func applyPlaylistOrder(_ playlistId: String, desired: [String], current live: [String]) async throws {
        guard desired.count > 1 else { return }
        let desiredSet = Set(desired)
        var current = live.filter { desiredSet.contains($0) }
        for id in desired where !current.contains(id) { current.append(id) }

        var moves = 0
        for i in 1..<desired.count {
            let want = desired[i], pred = desired[i - 1]
            guard let wantIdx = current.firstIndex(of: want), let predIdx = current.firstIndex(of: pred) else { continue }
            if wantIdx == predIdx + 1 { continue }
            try await editPlaylist(playlistId, actions: [[
                "action": "ACTION_MOVE_VIDEO_AFTER",
                "setVideoId": want,
                "movedSetVideoIdPredecessor": pred,
            ]])
            moves += 1
            current.remove(at: wantIdx)
            let newPred = current.firstIndex(of: pred)!
            current.insert(want, at: newPred + 1)
        }
        if moves > 0 { log.info("reorder: applied \(moves) sequential move(s) for playlist \(playlistId, privacy: .public)") }
    }

    private static func liveSetOrder(_ live: PlaylistDetail, _ desired: [String]) -> [String] {
        let set = Set(desired)
        return live.videos.compactMap(\.setVideoId).filter { set.contains($0) }
    }

    func syncPlaylist(_ input: PlaylistSyncInput) async throws -> PlaylistDetail {
        if !input.removedSetVideoIds.isEmpty {
            do {
                try await editPlaylist(input.playlistId, actions: input.removedSetVideoIds.map {
                    ["action": "ACTION_REMOVE_VIDEO", "setVideoId": $0]
                })
            } catch {
                throw YouTubeError.other("Failed to remove videos: \(error.localizedDescription)")
            }
        }

        if !input.addedVideoIds.isEmpty {
            do {
                try await editPlaylist(input.playlistId, actions: input.addedVideoIds.map {
                    ["action": "ACTION_ADD_VIDEO", "addedVideoId": $0]
                })
            } catch {
                throw YouTubeError.other("Failed to add videos: \(error.localizedDescription)")
            }
        }

        if input.orderedVideoIds.count > 1 {
            do {
                // Include just-added ids so we wait for their setVideoIds to appear.
                let (initialLive, desired) = try await resolveDesiredSetVideoIds(
                    input.playlistId, ordered: input.orderedVideoIds, expect: input.addedVideoIds)
                if desired.count > 1 {
                    let maxPasses = 3
                    var live = initialLive
                    for pass in 1...maxPasses {
                        let current = Self.liveSetOrder(live, desired)
                        if current == desired { break }
                        log.info("reorder: pass \(pass)/\(maxPasses) for \(input.playlistId, privacy: .public) (\(desired.count) items)")
                        try await applyPlaylistOrder(input.playlistId, desired: desired, current: current)
                        if pass < maxPasses { try? await Task.sleep(for: .milliseconds(250 * pass)) }
                        live = try await getPlaylist(input.playlistId)
                        if Self.liveSetOrder(live, desired) == desired { break }
                        if pass == maxPasses {
                            log.warning("reorder: order still diverges after \(maxPasses) passes for \(input.playlistId, privacy: .public)")
                        }
                    }
                }
            } catch {
                throw YouTubeError.other("Failed to reorder playlist: \(error.localizedDescription)")
            }
        }

        // Always return a fresh fetch so the UI reflects YouTube's official order.
        return try await getPlaylist(input.playlistId)
    }
}
