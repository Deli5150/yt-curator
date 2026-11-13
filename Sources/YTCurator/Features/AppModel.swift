import AppKit
import Foundation
import Observation

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
        let loggedIn = await YouTubeSession.shared.isLoggedIn()
        loginState = loggedIn ? .signedIn : .signedOut
        if loggedIn { didSignIn() }
    }

    private func didSignIn() {
        Task { await playlist.load() }
        // Cosmetic avatar refresh, deferred so it doesn't compete with the feed's boot burst.
        avatarRefreshTask?.cancel()
        avatarRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            let refreshed = await YouTubeClient.shared.refreshSavedChannels(self.store.channels)
            guard !Task.isCancelled else { return }
            self.store.replaceChannels(refreshed)
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
    @ObservationIgnored private let state = LocalState()

    var playlists: [PlaylistSummary] = []
    var playlistsLoading = false
    var playlistsError: String?

    var detail: PlaylistDetail?
    var edits: StagedEdits?
    var completedIds: Set<String> = []
    var loading = false
    var syncing = false
    var error: String?

    init(store: AppStore) { self.store = store }

    var playlistId: String? { store.selectedPlaylistId }
    var hasPlaylist: Bool { playlistId != nil }
    var videos: [PlaylistVideo] { edits?.videos ?? [] }
    var savedIds: Set<String> { Set(videos.map(\.videoId)) }
    var pendingChanges: Int { Staging.pendingChanges(edits) }

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
        completedIds = Completed.reconcileExternalRemovals(fresh.id, current: members, in: state)
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

@MainActor
@Observable
final class FeedModel {
    /// Shallow page budget per channel so aggregating many channels stays a handful of requests.
    static let maxPages = 2
    /// Like React Query's staleTime: refetch in the background when older than this.
    static let staleAfter: TimeInterval = 5 * 60

    struct Key: Hashable { var channelId: String; var tab: ChannelTab }

    private(set) var pages: [Key: ChannelVideosPage] = [:]
    private(set) var failures: [Key: String] = [:]
    private(set) var inFlight: Set<Key> = []
    @ObservationIgnored private var fetchedAt: [Key: Date] = [:]

    func reset() {
        pages = [:]
        failures = [:]
        inFlight = []
        fetchedAt = [:]
    }

    func isLoading(_ channels: [SavedChannel], _ tab: ChannelTab) -> Bool {
        channels.contains { inFlight.contains(Key(channelId: $0.channelId, tab: tab)) }
    }

    func loadedCount(_ channels: [SavedChannel], _ tab: ChannelTab) -> Int {
        channels.filter { pages[Key(channelId: $0.channelId, tab: tab)] != nil }.count
    }

    func failed(_ channels: [SavedChannel], _ tab: ChannelTab) -> [Key] {
        channels.map { Key(channelId: $0.channelId, tab: tab) }.filter { failures[$0] != nil }
    }

    /// Aggregate videos for the given channels, each tagged with its channel.
    func items(_ channels: [SavedChannel], _ tab: ChannelTab) -> [(video: ChannelVideo, channel: SavedChannel)] {
        var seen = Set<String>()
        var out: [(ChannelVideo, SavedChannel)] = []
        for channel in channels {
            for video in pages[Key(channelId: channel.channelId, tab: tab)]?.videos ?? [] where seen.insert(video.videoId).inserted {
                out.append((video, channel))
            }
        }
        return out
    }

    func load(_ channels: [SavedChannel], _ tab: ChannelTab, force: Bool = false) {
        for channel in channels {
            let key = Key(channelId: channel.channelId, tab: tab)
            if pages[key] == nil, let cached = FeedCache.read(channel.channelId, tab) {
                // Warm start: paint the last-fetched page instantly, refresh in the background.
                pages[key] = cached.page
                fetchedAt[key] = cached.savedAt
            }
            if inFlight.contains(key) { continue }
            if !force, failures[key] == nil, let at = fetchedAt[key], Date().timeIntervalSince(at) < Self.staleAfter { continue }
            fetch(key, force: force)
        }
    }

    func retry(_ keys: [Key]) {
        for key in keys where !inFlight.contains(key) { fetch(key, force: true) }
    }

    private func fetch(_ key: Key, force: Bool) {
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            do {
                let page = try await YouTubeClient.shared.getChannelVideos(key.channelId, tab: key.tab, maxPages: Self.maxPages, force: force)
                pages[key] = page
                failures[key] = nil
                fetchedAt[key] = Date()
                FeedCache.write(key.channelId, key.tab, page)
            } catch {
                failures[key] = error.localizedDescription
            }
        }
    }
}
