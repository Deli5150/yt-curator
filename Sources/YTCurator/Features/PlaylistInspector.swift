import SwiftUI

/// Right-hand playlist panel: staged reorder/remove/add, then Sync (port of playlist-panel.tsx).
struct PlaylistInspector: View {
    @Environment(AppModel.self) private var app

    private var playlist: PlaylistModel { app.playlist }

    var body: some View {
        VStack(spacing: 0) {
            if playlist.hasPlaylist {
                header
                Divider()
                list
                // While a video is dragged, quick-drop zones open under the list.
                if app.drag.payload != nil, playlist.edits != nil {
                    PlaylistDropZones()
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)),
                            removal: .opacity
                        ))
                }
                footer
            } else {
                ContentUnavailableView {
                    Label("No playlist selected", systemImage: "music.note.list")
                } description: {
                    Text("Choose the playlist you want to curate.")
                } actions: {
                    Button("Choose Playlist…") { app.sheet = .playlistPicker }.buttonStyle(.borderedProminent)
                }
            }
        }
        // Drop target for tiles dragged via DragController (drawn by DragOverlay).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.drag.playlistFrame = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: app.drag.payload != nil)
        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { app.sheet = .playlistPicker } label: {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { RemoteImage(url: playlist.detail?.thumbnailUrl ?? playlist.videos.first?.thumbnailUrl) }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Label("Change", systemImage: "arrow.left.arrow.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassEffect()
                            .padding(8)
                    }
            }
            .buttonStyle(.plain)
            .help("Change playlist")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.detail?.title ?? "Loading…").font(.headline).lineLimit(2)
                    Text(countText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await playlist.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: playlist.loading)
                }
                .disabled(playlist.loading || playlist.syncing)
                .help("Refresh playlist")
                Button {
                    if let id = playlist.playlistId { app.open(YouTubeURL.playlist(id)) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open on YouTube")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
    }

    private var countText: String {
        let n = playlist.videos.count
        let pending = playlist.pendingChanges
        return "\(n) video\(n == 1 ? "" : "s")" + (pending > 0 ? " · \(pending) pending" : "")
    }

    @ViewBuilder private var list: some View {
        if playlist.edits == nil {
            Group {
                if let error = playlist.error {
                    ContentUnavailableView {
                        Label("Couldn't load playlist", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await playlist.load() } }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxHeight: .infinity)
        } else if playlist.videos.isEmpty {
            ContentUnavailableView("Empty playlist", systemImage: "tray",
                                   description: Text("Drag videos here or use the + on a tile."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(playlist.videos.enumerated()), id: \.element.key) { index, video in
                        PlaylistRow(video: video, index: index, count: playlist.videos.count)
                    }
                    .onMove { playlist.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: playlist.scrollTarget) { _, request in
                    guard let request else { return }
                    playlist.scrollTarget = nil
                    // Wait for the inserted row to be laid out, or the scroll stops one row short.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.snappy) { proxy.scrollTo(request.key, anchor: request.atTop ? .top : .bottom) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let error = playlist.error, playlist.edits != nil {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).lineLimit(3)
            }
            Text(playlist.pendingChanges > 0 ? "\(playlist.pendingChanges) to sync" : "Up to date")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await playlist.sync() }
            } label: {
                HStack {
                    if playlist.syncing { ProgressView().controlSize(.small) }
                    Text(playlist.syncing ? "Syncing…" : "Sync")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(playlist.pendingChanges == 0 || playlist.syncing || playlist.loading)
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .padding(14)
    }
}

struct PlaylistRow: View {
    @Environment(AppModel.self) private var app
    let video: PlaylistVideo
    let index: Int
    let count: Int

    @State private var hovering = false
    @State private var following = false

    private var playlist: PlaylistModel { app.playlist }

    var body: some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 96, height: 54)
                .overlay { RemoteImage(url: video.thumbnailUrl, maxPixel: 200) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let d = video.durationText { ThumbBadge(text: d).scaleEffect(0.85).padding(2) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(.callout).lineLimit(2)
                HStack(spacing: 4) {
                    if video.pendingAdd == true {
                        Text("Pending").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    if let author = video.author {
                        Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .trailing) {
            if hovering { actions } else {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .glassEffect(in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { app.open(YouTubeURL.video(video.videoId)) }
        .contextMenu { menu }
        // Row frames let a dragged tile find its insertion point.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.drag.rowFrames[video.key] = $0 }
        .onDisappear { app.drag.rowFrames[video.key] = nil }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            action("chevron.up.2", "Move to top", disabled: index == 0) { playlist.move(key: video.key, to: .top) }
            action("chevron.up", "Move up", disabled: index == 0) { playlist.move(key: video.key, to: .up) }
            action("chevron.down", "Move down", disabled: index == count - 1) { playlist.move(key: video.key, to: .down) }
            action("chevron.down.2", "Move to bottom", disabled: index == count - 1) { playlist.move(key: video.key, to: .bottom) }
            action("trash", "Remove", disabled: false) { playlist.remove(key: video.key) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .glassEffect(in: Capsule())
    }

    private func action(_ symbol: String, _ help: String, disabled: Bool, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).frame(width: 24, height: 24)
        }
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder private var menu: some View {
        if let author = video.author {
            let followed = app.isFollowed(video.channelId)
            Button(followed ? "Following \(author)" : "Follow \(author)", systemImage: followed ? "checkmark" : "person.badge.plus") {
                guard let id = video.channelId else { return }
                following = true
                Task {
                    await app.follow(channelId: id)
                    following = false
                }
            }
            .disabled(followed || following || video.channelId == nil)
            if let id = video.channelId {
                Button("Go to \(author)", systemImage: "person.crop.circle") { app.openChannel(id) }
            }
            Divider()
        }
        Button("Move to Top", systemImage: "arrow.up.to.line") { playlist.move(key: video.key, to: .top) }.disabled(index == 0)
        Button("Move to Bottom", systemImage: "arrow.down.to.line") { playlist.move(key: video.key, to: .bottom) }.disabled(index == count - 1)
        Divider()
        Button("Open on YouTube", systemImage: "arrow.up.right.square") { app.open(YouTubeURL.video(video.videoId)) }
        Button("Remove from Playlist", systemImage: "trash", role: .destructive) { playlist.remove(key: video.key) }
    }
}
