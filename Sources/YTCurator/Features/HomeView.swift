import SwiftUI

enum HomeTab: String, CaseIterable, Identifiable {
    case videos, live, channels
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var channelTab: ChannelTab? { self == .videos ? .videos : self == .live ? .live : nil }
}

/// Aggregated feed of the active loadout's channels (port of home-feed.tsx).
struct HomeView: View {
    @Environment(AppModel.self) private var app

    static let pageSize = 50

    @AppStorage("homeTab") private var tab: HomeTab = .videos
    @AppStorage("homeSort") private var sortMode: SortMode = .latest
    @AppStorage("hideWatched") private var hideWatched = false
    @State private var visibleCount = HomeView.pageSize

    private var channels: [SavedChannel] { app.store.activeChannels }

    var body: some View {
        content
            .navigationTitle("Home")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .task(id: LoadKey(tab: tab, ids: channels.map(\.channelId))) {
                if let t = tab.channelTab { app.feed.load(channels, t) }
            }
            .onChange(of: tab) { visibleCount = Self.pageSize }
            .onChange(of: sortMode) { visibleCount = Self.pageSize }
            .onChange(of: hideWatched) { visibleCount = Self.pageSize }
            .onChange(of: app.store.activeLoadoutId) { visibleCount = Self.pageSize }
    }

    private struct LoadKey: Hashable { var tab: HomeTab; var ids: [String] }

    private var subtitle: String {
        let loadout = app.store.activeLoadout?.name ?? "All channels"
        if tab == .channels { return "\(app.store.channels.count) channels" }
        guard let t = tab.channelTab else { return loadout }
        let loaded = app.feed.loadedCount(channels, t)
        if app.feed.isLoading(channels, t), loaded < channels.count {
            return "\(loadout) · loading \(loaded)/\(channels.count) channels"
        }
        return "\(loadout) · \(channels.count) channels"
    }

    @ViewBuilder private var content: some View {
        if app.store.channels.isEmpty {
            ContentUnavailableView {
                Label("No channels yet", systemImage: "person.2.badge.plus")
            } description: {
                Text("Add a channel by its handle, or import the channels you subscribe to.")
            } actions: {
                Button("Import Subscriptions") { app.sheet = .importSubscriptions }.buttonStyle(.borderedProminent)
                Button("Add Channel…") { app.sheet = .addChannel }
            }
        } else if tab == .channels {
            ChannelsGrid()
        } else if let t = tab.channelTab {
            feed(t)
        }
    }

    @ViewBuilder private func feed(_ t: ChannelTab) -> some View {
        if channels.isEmpty {
            ContentUnavailableView("No channels in this loadout", systemImage: "square.stack.3d.up.slash",
                                   description: Text("Edit the loadout or switch to All channels."))
        } else {
            let all = displayed(t)
            let failed = app.feed.failed(channels, t)
            Group {
                if all.isEmpty {
                    if app.feed.isLoading(channels, t) {
                        ProgressView("Loading \(t == .videos ? "videos" : "live streams")…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !failed.isEmpty, failed.count == channels.count {
                        ContentUnavailableView {
                            Label("Couldn't load the feed", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(app.feed.failures[failed[0]] ?? "")
                        } actions: {
                            Button("Retry") { app.feed.retry(failed) }
                        }
                    } else {
                        ContentUnavailableView(emptyMessage(t), systemImage: "play.rectangle")
                    }
                } else {
                    VideoGrid(items: Array(all.prefix(visibleCount)).map { ($0.video, $0.channel) }, showChannel: true) {
                        if visibleCount < all.count { visibleCount += Self.pageSize }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !failed.isEmpty, !all.isEmpty {
                    Button {
                        app.feed.retry(failed)
                    } label: {
                        Label("\(failed.count) channel\(failed.count == 1 ? "" : "s") failed to load — Retry",
                              systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func emptyMessage(_ t: ChannelTab) -> String {
        let noun = t == .videos ? "videos" : "live streams"
        switch sortMode {
        case .week: return "No \(noun) in the last week."
        case .month: return "No \(noun) in the last month."
        default: return hideWatched ? "Everything here is watched." : "No \(noun) yet."
        }
    }

    private func displayed(_ t: ChannelTab) -> [(video: ChannelVideo, channel: SavedChannel)] {
        let items = app.feed.items(channels, t)
        let channelFor = Dictionary(items.map { ($0.video.videoId, $0.channel) }, uniquingKeysWith: { a, _ in a })
        var videos = VideoSort.apply(VideoSort.newestFirst(items.map(\.video)), sortMode)
        if hideWatched {
            let saved = app.playlist.savedIds, completed = app.playlist.completedIds
            videos.removeAll { saved.contains($0.videoId) || completed.contains($0.videoId) }
        }
        return videos.compactMap { v in channelFor[v.videoId].map { (v, $0) } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(HomeTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if let t = tab.channelTab {
            ToolbarItemGroup {
                Button {
                    app.feed.load(channels, t, force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(app.feed.isLoading(channels, t))
                .help("Refresh feed")
                Toggle(isOn: $hideWatched) {
                    Label("Hide Watched", systemImage: hideWatched ? "eye.slash" : "eye")
                }
                .help(hideWatched ? "Show watched videos" : "Hide videos in the playlist or completed")
                SortMenu(mode: $sortMode)
            }
        } else {
            ToolbarItemGroup {
                Button { app.sheet = .importSubscriptions } label: {
                    Label("Import Subscriptions", systemImage: "square.and.arrow.down")
                }
                .help("Import subscriptions")
                Button { app.sheet = .loadouts } label: {
                    Label("Loadouts", systemImage: "square.stack.3d.up")
                }
                .help("Manage loadouts")
            }
        }
    }
}

/// Grid of every saved channel (never loadout-filtered).
struct ChannelsGrid: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(app.store.channels) { channel in
                    Button {
                        app.openChannel(channel.channelId)
                    } label: {
                        VStack(spacing: 8) {
                            RemoteImage(url: channel.avatarUrl)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(Circle())
                            Text(channel.title)
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ChannelMenu(channel: channel) }
                }
            }
            .padding(20)
        }
    }
}

struct ChannelMenu: View {
    @Environment(AppModel.self) private var app
    let channel: SavedChannel

    var body: some View {
        Button("Open on YouTube", systemImage: "arrow.up.right.square") { app.open(YouTubeURL.channel(channel.channelId)) }
        Divider()
        Button("Remove Channel", systemImage: "trash", role: .destructive) { app.removeChannel(channel.channelId) }
    }
}
