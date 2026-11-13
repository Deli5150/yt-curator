import AppKit
import SwiftUI

// MARK: - Remote images

/// Memory + URLCache-backed image loader so thumbnails and avatars don't re-download on scroll.
actor ImageLoader {
    static let shared = ImageLoader()

    private nonisolated(unsafe) let memory = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20,
                                   directory: AppPaths.cacheDir.appending(path: "images"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    init() { memory.countLimit = 600 }

    nonisolated func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> NSImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let task = inflight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, let u = URL(string: url) else { image = nil; return }
            if let hit = ImageLoader.shared.cached(u) { image = hit; return }
            image = nil
            image = await ImageLoader.shared.image(u)
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: String?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) { Color.secondary.opacity(0.15) }
    }
}

struct ChannelAvatar: View {
    let url: String?
    let title: String
    var size: CGFloat = 28

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.25))
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Logo

struct AppLogo: View {
    var height: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            if let mark = Bundle.main.image(forResource: "curator-logo-mark") {
                Image(nsImage: mark).resizable().scaledToFit().frame(height: height)
            } else {
                Image(systemName: "play.rectangle.fill").font(.system(size: height * 0.8)).foregroundStyle(.red)
            }
            Text("Curator").font(.system(size: height * 0.8, weight: .bold, design: .rounded))
        }
    }
}

// MARK: - Badges

struct ThumbBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Video tile

struct VideoTile: View {
    @Environment(AppModel.self) private var app
    let video: ChannelVideo
    let channel: SavedChannel?
    var showChannel = false

    @State private var hovering = false

    private var playlist: PlaylistModel { app.playlist }
    private var isSaved: Bool { playlist.savedIds.contains(video.videoId) }
    private var isCompleted: Bool { playlist.completedIds.contains(video.videoId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            HStack(alignment: .top, spacing: 8) {
                if showChannel, let channel {
                    ChannelAvatar(url: channel.avatarUrl, title: channel.title, size: 28)
                        .onTapGesture { app.openChannel(channel.channelId) }
                        .help("Open \(channel.title)")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .help(video.title)
                    if showChannel, let channel {
                        Button(channel.title) { app.openChannel(channel.channelId) }
                            .buttonStyle(.link)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Text([video.viewCountText, video.publishedText].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggable(video.dragPayload(author: channel?.title).encoded) {
            RemoteImage(url: video.thumbnailUrl)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onTapGesture(count: 2) { app.open(YouTubeURL.video(video.videoId)) }
        .contextMenu { menu }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: video.thumbnailUrl) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let d = video.durationText { ThumbBadge(text: d).padding(6) }
            }
            .overlay(alignment: .bottomLeading) {
                if video.isMembersOnly { ThumbBadge(text: "Members only").padding(6) }
            }
            .overlay(alignment: .topTrailing) { statusBadge.padding(6) }
            .overlay(alignment: .topLeading) {
                // Hover "+" (suppressed while saved; a completed-but-unsaved tile can be re-added).
                if hovering, !isSaved, playlist.hasPlaylist {
                    Button {
                        playlist.add(video.dragPayload(author: channel?.title))
                    } label: {
                        Image(systemName: "plus").font(.body.weight(.bold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Add to playlist")
                    .padding(6)
                }
            }
    }

    @ViewBuilder private var statusBadge: some View {
        if isSaved {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
                .help("In playlist")
        } else if isCompleted {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.title3)
                .help("Completed")
        }
    }

    @ViewBuilder private var menu: some View {
        if isSaved {
            Button("Remove from Playlist", systemImage: "minus.circle") { playlist.remove(videoId: video.videoId) }
                .disabled(!playlist.hasPlaylist)
        } else {
            Button("Add to Playlist", systemImage: "plus.circle") { playlist.add(video.dragPayload(author: channel?.title)) }
                .disabled(!playlist.hasPlaylist)
        }
        Divider()
        Button(isCompleted ? "Mark as Not Completed" : "Mark as Completed",
               systemImage: isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle") {
            playlist.toggleCompleted(video.videoId)
        }
        .disabled(isSaved || !playlist.hasPlaylist)
        Divider()
        Button("Open on YouTube", systemImage: "arrow.up.right.square") { app.open(YouTubeURL.video(video.videoId)) }
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(YouTubeURL.video(video.videoId).absoluteString, forType: .string)
        }
        if showChannel, let channel {
            Button("Go to \(channel.title)", systemImage: "person.crop.circle") { app.openChannel(channel.channelId) }
        }
    }
}

/// Adaptive grid of video tiles that reports when the end scrolls into view.
struct VideoGrid<Header: View>: View {
    let items: [(video: ChannelVideo, channel: SavedChannel?)]
    var showChannel = false
    var onEndReached: (() -> Void)?
    @ViewBuilder var header: () -> Header

    var body: some View {
        ScrollView {
            header()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18, alignment: .top)], spacing: 22) {
                ForEach(Array(items.enumerated()), id: \.element.video.videoId) { index, item in
                    VideoTile(video: item.video, channel: item.channel, showChannel: showChannel)
                        .onAppear { if index == items.count - 1 { onEndReached?() } }
                }
            }
            .padding(20)
        }
    }
}

extension VideoGrid where Header == EmptyView {
    init(items: [(video: ChannelVideo, channel: SavedChannel?)], showChannel: Bool = false, onEndReached: (() -> Void)? = nil) {
        self.init(items: items, showChannel: showChannel, onEndReached: onEndReached) { EmptyView() }
    }
}

struct SortMenu: View {
    @Binding var mode: SortMode
    var body: some View {
        Menu {
            Picker("Sort", selection: $mode) {
                ForEach(SortMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(mode.label, systemImage: "arrow.up.arrow.down")
        }
        .help("Sort: \(mode.label)")
    }
}
