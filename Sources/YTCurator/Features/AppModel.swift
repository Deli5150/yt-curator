import AppKit
import Foundation
import Observation
import SwiftUI

enum LoginState { case checking, signedOut, signedIn }

enum Route: Hashable {
    case home
    case channel(String)
}

enum ActiveSheet: String, Identifiable {
    case addChannel, importSubscriptions, loadouts, playlistPicker
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    let store = AppStore()
    let playlist: PlaylistModel
    let feed = FeedModel()
    let drag = DragController()
    let updater = Updater()

    var loginState: LoginState = .checking
    var route: Route = .home
    var sheet: ActiveSheet?
    var showInspector = true
    var errorMessage: String?

    @ObservationIgnored private var avatarRefreshTask: Task<Void, Never>?

    init() {
        playlist = PlaylistModel(store: store)
        if let selected = store.selectedChannelId, store.channel(selected) != nil {
            // Land on Home like the Glaze build; the last channel stays highlighted for later.
            route = .home
        }
    }

    func bootstrap() async {
        updater.start()
        let loggedIn = await YouTubeSession.shared.isLoggedIn()
        loginState = loggedIn ? .signedIn : .signedOut
        if loggedIn { didSignIn() }
    }

    private func didSignIn() {
        Task { await playlist.load() }
        // Cosmetic avatar refresh: one heavy channel-page request per saved channel, so at most
        // once a day, and deferred so it doesn't compete with the feed's boot burst.
        let key = "lastAvatarRefresh"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        avatarRefreshTask?.cancel()
        avatarRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            let refreshed = await YouTubeClient.shared.refreshSavedChannels(self.store.channels)
            guard !Task.isCancelled else { return }
            self.store.replaceChannels(refreshed)
            UserDefaults.standard.set(Date(), forKey: key)
        }
    }

    func signIn() async {
        let ok = await YouTubeSession.shared.openLogin()
        guard ok else { return }
        await YouTubeClient.shared.reset()
        loginState = .signedIn
        didSignIn()
    }

    func signOut() async {
        avatarRefreshTask?.cancel()
        await YouTubeSession.shared.logout()
        await YouTubeClient.shared.reset()
        playlist.reset()
        feed.reset()
        loginState = .signedOut
    }

    // MARK: - Navigation

    func openChannel(_ channelId: String) {
        route = .channel(channelId)
        store.selectedChannelId = channelId
    }

    // MARK: - Channels

    func addChannel(handle: String) async throws {
        let channel = try await YouTubeClient.shared.resolveChannelByHandle(handle)
        store.addChannel(channel)
        openChannel(channel.channelId)
    }

    /// Follow a channel from a playlist row (does not change the selected channel).
    func follow(channelId: String) async {
        do {
            let channel = try await YouTubeClient.shared.resolveChannelById(channelId)
            store.addChannel(channel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeChannel(_ channelId: String) {
        store.removeChannel(channelId)
        if route == .channel(channelId) { route = .home }
    }

    func isFollowed(_ channelId: String?) -> Bool {
        guard let channelId else { return false }
        return store.channel(channelId) != nil
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: - Playlist panel state (port of playlist-panel.tsx logic)

@MainActor
@Observable
final class PlaylistModel {
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let state: LocalState

    var playlists: [PlaylistSummary] = []
    var playlistsLoading = false
    var playlistsError: String?

    var detail: PlaylistDetail?
    var edits: StagedEdits? {
        didSet {
            // Stored (not computed) and only reassigned on real change: every video tile reads
            // these, so recomputing or re-publishing them on a reorder re-rendered the whole grid.
            let saved = Set(edits?.videos.map(\.videoId) ?? [])
            if saved != savedIds { savedIds = saved }
            let pending = Staging.pendingChanges(edits)
            if pending != pendingChanges { pendingChanges = pending }
        }
    }
    private(set) var savedIds: Set<String> = []
    private(set) var pendingChanges = 0
    var completedIds: Set<String> = []
    /// Row the playlist list should scroll to (set after a quick-drop zone add).
    var scrollTarget: ScrollRequest?
    struct ScrollRequest: Equatable { var key: String; var atTop: Bool }
    var loading = false
    var syncing = false
    var error: String?

    init(store: AppStore, state: LocalState = LocalState()) {
        self.store = store
        self.state = state
        playlistId = store.selectedPlaylistId
    }

    /// Mirrors the store's selection so tiles don't observe the whole app-data object.
    private(set) var playlistId: String?
    var hasPlaylist: Bool { playlistId != nil }
    var videos: [PlaylistVideo] { edits?.videos ?? [] }

    func reset() {
        playlists = []
        detail = nil
        edits = nil
        completedIds = []
        error = nil
    }

    func loadPlaylists() async {
        playlistsLoading = true
        playlistsError = nil
        defer { playlistsLoading = false }
        do {
            playlists = try await YouTubeClient.shared.listPlaylists()
        } catch {
            playlistsError = error.localizedDescription
        }
    }

    func select(_ id: String) async {
        guard id != playlistId else { return }
        store.selectedPlaylistId = id
        playlistId = id
        detail = nil
        edits = nil
        completedIds = Completed.load(id, in: state)
        await load()
    }

    func load() async {
        guard let id = playlistId else { return }
        if edits == nil {
            // Paint staged state immediately while the live playlist loads.
            edits = Staging.load(id, in: state)
            completedIds = Completed.load(id, in: state)
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let fresh = try await YouTubeClient.shared.getPlaylist(id)
            guard id == playlistId else { return }
            apply(fresh)
        } catch {
            guard id == playlistId else { return }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ fresh: PlaylistDetail) {
        detail = fresh
        let merged = Staging.merge(fresh, existing: Staging.load(fresh.id, in: state))
        setEdits(merged)
        let members = fresh.videos.filter { $0.setVideoId != nil }.map(\.videoId)
        let completed = Completed.reconcileExternalRemovals(fresh.id, current: members, in: state)
        if completed != completedIds { completedIds = completed }
    }

    private func setEdits(_ next: StagedEdits) {
        edits = next
        if Staging.pendingChanges(next) == 0 {
            Staging.clear(next.playlistId, in: state)
        } else {
            Staging.save(next, in: state)
        }
    }

    private func setCompleted(_ videoId: String, _ completed: Bool) {
        guard let id = playlistId else { return }
        if completed { completedIds.insert(videoId) } else { completedIds.remove(videoId) }
        Completed.save(completedIds, id, in: state)
    }

    // MARK: - Staged edits

    /// An add of an already-completed video, waiting for the user's yes/no.
    struct PendingAdd: Identifiable {
        let id = UUID()
        var video: VideoDragPayload
        var index: Int?
        var scroll: ScrollRequest?
    }
    var pendingCompletedAdd: PendingAdd?

    /// Every UI add goes through here: adds right away, or asks first when the video was
    /// already completed (the answer comes back through `resolvePendingAdd`).
    func requestAdd(_ video: VideoDragPayload, at index: Int? = nil, scroll: ScrollRequest? = nil) {
        guard edits != nil, !savedIds.contains(video.videoId) else { return }
        if completedIds.contains(video.videoId) {
            pendingCompletedAdd = PendingAdd(video: video, index: index, scroll: scroll)
            return
        }
        add(video, at: index)
        if let scroll { scrollTarget = scroll }
    }

    /// "Yes" on the completed-video prompt. Takes the presented item itself, so it works no
    /// matter whether SwiftUI clears the alert binding before or after running the button.
    func confirmAdd(_ pending: PendingAdd) {
        pendingCompletedAdd = nil
        guard !savedIds.contains(pending.video.videoId) else { return }
        withAnimation(.snappy(duration: 0.25)) { add(pending.video, at: pending.index) }
        if let scroll = pending.scroll { scrollTarget = scroll }
    }

    func add(_ video: VideoDragPayload, at index: Int? = nil) {
        guard let edits else { return }
        setEdits(Staging.add(edits, video, at: index))
        setCompleted(video.videoId, false)
    }

    func remove(key: String) {
        guard let edits, let video = edits.videos.first(where: { $0.key == key }) else { return }
        setEdits(Staging.remove(edits, key: key))
        // Removing a real synced member counts as completing it; canceling a pending add doesn't.
        if video.setVideoId != nil, video.pendingAdd != true { setCompleted(video.videoId, true) }
    }

    func remove(videoId: String) {
        if let video = videos.first(where: { $0.videoId == videoId }) { remove(key: video.key) }
    }

    func toggleCompleted(_ videoId: String) {
        guard !savedIds.contains(videoId) else { return }
        setCompleted(videoId, !completedIds.contains(videoId))
    }

    func move(from source: IndexSet, to destination: Int) {
        guard let edits else { return }
        setEdits(Staging.move(edits, from: source, to: destination))
    }

    func move(key: String, to target: MoveTarget) {
        guard let index = videos.firstIndex(where: { $0.key == key }) else { return }
        let destination: Int = switch target {
        case .top: 0
        case .up: max(0, index - 1)
        case .down: min(videos.count, index + 2)
        case .bottom: videos.count
        }
        move(from: IndexSet(integer: index), to: destination)
    }

    enum MoveTarget { case top, up, down, bottom }

    func sync() async {
        guard let edits, !syncing else { return }
        syncing = true
        error = nil
        defer { syncing = false }
        do {
            let fresh = try await YouTubeClient.shared.syncPlaylist(Staging.syncPayload(edits))
            Staging.clear(edits.playlistId, in: state)
            apply(fresh)
        } catch {
            self.error = error.localizedDescription
            // Reload so the panel reflects whatever partially applied.
            await load()
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Home feed loader (port of home-feed.tsx's per-channel queries)

/// One aggregated feed entry with its publish age parsed once (the regex is too slow to rerun
/// inside sort comparators on every render).
struct FeedItem: Identifiable {
    var video: ChannelVideo
    var channel: SavedChannel
    var age: TimeInterval?
    var id: String { video.videoId }
}

@MainActor
@Observable
final class FeedModel {
    /// One page (the 30 newest, since the client forces the "Latest" sort) per channel: the
    /// aggregated feed only needs recent uploads, and a second page doubled the request count.
    static let maxPages = 1
    /// Like React Query's staleTime: refetch in the background when older than this.
    static let staleAfter: TimeInterval = 5 * 60
    /// Fetch completions are applied in batches so the grid re-renders a few times a second
    /// instead of once per channel.
    static let flushInterval: Duration = .milliseconds(250)

    struct Key: Hashable, Sendable { var channelId: String; var tab: ChannelTab }

    private(set) var pages: [Key: ChannelVideosPage] = [:]
    private(set) var failures: [Key: String] = [:]
    private(set) var inFlight: Set<Key> = []
    /// Progress of the current fetch run (reset when a run starts from idle), for the loading bar.
    private(set) var batchTotal = 0
    private(set) var batchDone = 0
    @ObservationIgnored private var batchStarted = Date()
    /// Held while a fetch run is active so App Nap doesn't throttle the request gate's timers
    /// when the window is in the background (a background refresh took 5x longer without it).
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// Bumped on every applied batch; derived feeds are memoized against it.
    private(set) var version = 0

    @ObservationIgnored private var fetchedAt: [Key: Date] = [:]
    @ObservationIgnored private var diskChecked: Set<Key> = []
    @ObservationIgnored private var pendingPages: [Key: ChannelVideosPage] = [:]
    @ObservationIgnored private var pendingFailures: [Key: String] = [:]
    @ObservationIgnored private var pendingDone: Set<Key> = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var memo: (key: MemoKey, items: [FeedItem])?

    private struct MemoKey: Equatable { var tab: ChannelTab; var channels: [SavedChannel]; var version: Int }

    func reset() {
        pages = [:]
        failures = [:]
        inFlight = []
        fetchedAt = [:]
        diskChecked = []
        memo = nil
        version += 1
    }

    func isLoading(_ channels: [SavedChannel], _ tab: ChannelTab) -> Bool {
        !inFlight.isEmpty && channels.contains { inFlight.contains(Key(channelId: $0.channelId, tab: tab)) }
    }

    func loadedCount(_ channels: [SavedChannel], _ tab: ChannelTab) -> Int {
        channels.filter { pages[Key(channelId: $0.channelId, tab: tab)] != nil }.count
    }

    func failed(_ channels: [SavedChannel], _ tab: ChannelTab) -> [Key] {
        guard !failures.isEmpty else { return [] }
        return channels.map { Key(channelId: $0.channelId, tab: tab) }.filter { failures[$0] != nil }
    }

    /// Aggregated, de-duplicated, newest-first feed for the given channels (memoized).
    func sortedFeed(_ channels: [SavedChannel], _ tab: ChannelTab) -> [FeedItem] {
        let key = MemoKey(tab: tab, channels: channels, version: version)
        if let memo, memo.key == key { return memo.items }
        var seen = Set<String>()
        var items: [FeedItem] = []
        for channel in channels {
            for video in pages[Key(channelId: channel.channelId, tab: tab)]?.videos ?? [] where seen.insert(video.videoId).inserted {
                items.append(FeedItem(video: video, channel: channel, age: VideoSort.relativeAge(video.publishedText)))
            }
        }
        // Stable newest-first; unparseable dates sink to the bottom.
        let sorted = items.enumerated().sorted { a, b in
            switch (a.element.age, b.element.age) {
            case let (x?, y?): x == y ? a.offset < b.offset : x < y
            case (nil, nil): a.offset < b.offset
            case (nil, _): false
            case (_, nil): true
            }
        }.map(\.element)
        memo = (key, sorted)
        return sorted
    }

    func load(_ channels: [SavedChannel], _ tab: ChannelTab, force: Bool = false) {
        let keys = channels.map { Key(channelId: $0.channelId, tab: tab) }
        let unchecked = keys.filter { pages[$0] == nil && !diskChecked.contains($0) }
        diskChecked.formUnion(unchecked)
        guard !unchecked.isEmpty else {
            startFetches(keys, force: force)
            return
        }
        // Warm start: read last-fetched pages off the main thread, paint them, then refresh.
        Task {
            let cached = await Task.detached(priority: .userInitiated) {
                unchecked.compactMap { key in FeedCache.read(key.channelId, key.tab).map { (key, $0) } }
            }.value
            for (key, entry) in cached where pages[key] == nil {
                pages[key] = entry.page
                fetchedAt[key] = entry.savedAt
            }
            if !cached.isEmpty { version += 1 }
            startFetches(keys, force: force)
        }
    }

    func retry(_ keys: [Key]) {
        startFetches(keys, force: true)
    }

    private func startFetches(_ keys: [Key], force: Bool) {
        let due = keys.filter { key in
            if inFlight.contains(key) { return false }
            if force || failures[key] != nil { return true }
            guard let at = fetchedAt[key] else { return true }
            return Date().timeIntervalSince(at) >= Self.staleAfter
        }
        guard !due.isEmpty else { return }
        if inFlight.isEmpty {
            batchTotal = 0
            batchDone = 0
            batchStarted = Date()
            activity = activity ?? ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Loading channel feeds")
        }
        batchTotal += due.count
        inFlight.formUnion(due)
        for key in due {
            Task {
                do {
                    let page = try await YouTubeClient.shared.getChannelVideos(key.channelId, tab: key.tab, maxPages: Self.maxPages, force: force)
                    pendingPages[key] = page
                    fetchedAt[key] = Date()
                    Task.detached(priority: .background) { FeedCache.write(key.channelId, key.tab, page) }
                } catch {
                    pendingFailures[key] = error.localizedDescription
                }
                pendingDone.insert(key)
                scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: Self.flushInterval)
            // Don't reflow the grid under a drag in progress.
            while DragController.isDragging { try? await Task.sleep(for: Self.flushInterval) }
            flushScheduled = false
            var nextPages = pages, nextFailures = failures
            for (key, page) in pendingPages {
                nextPages[key] = page
                nextFailures[key] = nil
            }
            for (key, message) in pendingFailures { nextFailures[key] = message }
            pages = nextPages
            if nextFailures != failures { failures = nextFailures }
            inFlight.subtract(pendingDone)
            batchDone += pendingDone.count
            if inFlight.isEmpty, batchTotal > 0 {
                Diagnostics.write(String(format: "feed: %d channel fetches in %.1fs", batchTotal, Date().timeIntervalSince(batchStarted)))
                if let activity { ProcessInfo.processInfo.endActivity(activity) }
                activity = nil
            }
            pendingPages = [:]
            pendingFailures = [:]
            pendingDone = []
            version += 1
        }
    }
}
