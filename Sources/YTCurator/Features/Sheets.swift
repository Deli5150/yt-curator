import SwiftUI

struct SheetHost: View {
    @Environment(AppModel.self) private var app
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .addChannel: AddChannelSheet()
        case .importSubscriptions: ImportSubscriptionsSheet()
        case .loadouts: LoadoutManagerSheet()
        case .playlistPicker: PlaylistPickerSheet()
        }
    }
}

// MARK: - Add channel

struct AddChannelSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Channel").font(.title2.bold())
            Text("Enter a channel handle or URL, like @mkbhd.").foregroundStyle(.secondary)
            TextField("@handle", text: $handle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .disabled(working)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: add) {
                    if working { ProgressView().controlSize(.small) } else { Text("Add") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func add() {
        guard !working, !handle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                try await app.addChannel(handle: handle)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Import subscriptions

struct ImportSubscriptionsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var subscriptions: [SavedChannel]?
    @State private var selected: Set<String> = []
    @State private var error: String?
    @State private var search = ""

    private var existing: Set<String> { Set(app.store.channels.map(\.channelId)) }
    private var candidates: [SavedChannel] { (subscriptions ?? []).filter { !existing.contains($0.channelId) } }
    private var filtered: [SavedChannel] {
        search.isEmpty ? candidates : candidates.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.handle.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Subscriptions").font(.title2.bold())
            if let subscriptions {
                Text("\(subscriptions.count) subscriptions · \(candidates.count) not yet added")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Filter", text: $search).textFieldStyle(.roundedBorder)
                    Button("Select All") { selected.formUnion(filtered.map(\.channelId)) }
                    Button("Select None") { selected.subtract(filtered.map(\.channelId)) }
                }
                List(filtered) { channel in
                    Toggle(isOn: Binding(
                        get: { selected.contains(channel.channelId) },
                        set: { if $0 { selected.insert(channel.channelId) } else { selected.remove(channel.channelId) } }
                    )) {
                        HStack(spacing: 8) {
                            ChannelAvatar(url: channel.avatarUrl, title: channel.title, size: 28)
                            VStack(alignment: .leading) {
                                Text(channel.title)
                                Text("@" + channel.handle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.bordered)
                .frame(minHeight: 320)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't load subscriptions", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ProgressView("Loading subscriptions…").frame(maxWidth: .infinity, minHeight: 320)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(selected.count) Channel\(selected.count == 1 ? "" : "s")") {
                    app.store.addChannels(candidates.filter { selected.contains($0.channelId) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do {
            let subs = try await YouTubeClient.shared.fetchSubscribedChannels()
            subscriptions = subs
            selected = Set(subs.map(\.channelId)).subtracting(existing)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Loadouts

struct LoadoutManagerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var editing: LoadoutDraft?

    struct LoadoutDraft: Identifiable {
        var id: String?
        var name: String
        var channelIds: Set<String>
    }

    var body: some View {
        VStack(spacing: 0) {
            if let draft = Binding($editing) {
                LoadoutEditor(draft: draft) { editing = nil }
            } else {
                manager
            }
        }
        .frame(width: 640, height: 560)
    }

    private var manager: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Loadouts").font(.title2.bold())
                Spacer()
                Button("New Loadout", systemImage: "plus") {
                    editing = LoadoutDraft(id: nil, name: "", channelIds: [])
                }
            }
            if app.store.loadouts.isEmpty {
                ContentUnavailableView {
                    Label("No loadouts", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Loadouts are named groups of channels. The home feed and sidebar show the active loadout.")
                } actions: {
                    Button("Create Loadout") { editing = LoadoutDraft(id: nil, name: "", channelIds: []) }
                }
            } else {
                HSplitView {
                    List(app.store.loadouts, selection: $selection) { loadout in
                        HStack {
                            Text(loadout.name)
                            Spacer()
                            Text("\(loadout.channelIds.count)").foregroundStyle(.secondary)
                            if loadout.id == app.store.activeLoadoutId {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("Active")
                            }
                        }
                        .tag(loadout.id)
                    }
                    .frame(minWidth: 180, maxWidth: 220)
                    detailPane.frame(minWidth: 300)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { selection = selection ?? app.store.activeLoadoutId ?? app.store.loadouts.first?.id }
    }

    @ViewBuilder private var detailPane: some View {
        if let loadout = app.store.loadouts.first(where: { $0.id == selection }) {
            let members = app.store.channels.filter { loadout.channelIds.contains($0.channelId) }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(loadout.name).font(.headline)
                    Spacer()
                    Button("Edit") {
                        editing = LoadoutDraft(id: loadout.id, name: loadout.name, channelIds: Set(loadout.channelIds))
                    }
                    Button("Delete", role: .destructive) {
                        app.store.deleteLoadout(id: loadout.id)
                        selection = app.store.loadouts.first?.id
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 12) {
                        ForEach(members) { channel in
                            VStack(spacing: 4) {
                                ChannelAvatar(url: channel.avatarUrl, title: channel.title, size: 44)
                                Text(channel.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 12)
        } else {
            Text("Select a loadout").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LoadoutEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: LoadoutManagerSheet.LoadoutDraft
    let close: () -> Void
    @State private var search = ""
    @State private var error: String?

    private var channels: [SavedChannel] {
        search.isEmpty ? app.store.channels : app.store.channels.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == nil ? "New Loadout" : "Edit Loadout").font(.title2.bold())
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Filter channels", text: $search).textFieldStyle(.roundedBorder)
                Text("\(draft.channelIds.count) selected").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 12) {
                    ForEach(channels) { channel in
                        let on = draft.channelIds.contains(channel.channelId)
                        Button {
                            if on { draft.channelIds.remove(channel.channelId) } else { draft.channelIds.insert(channel.channelId) }
                        } label: {
                            VStack(spacing: 4) {
                                ChannelAvatar(url: channel.avatarUrl, title: channel.title, size: 48)
                                    .overlay(alignment: .bottomTrailing) {
                                        if on {
                                            Image(systemName: "checkmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color.accentColor)
                                        }
                                    }
                                    .opacity(on ? 1 : 0.55)
                                Text(channel.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .padding(6)
                            .background(on ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        // Keep membership in saved-channel order.
                        let ids = app.store.channels.map(\.channelId).filter(draft.channelIds.contains)
                        if let id = draft.id {
                            try app.store.updateLoadout(id: id, name: draft.name, channelIds: ids)
                        } else {
                            try app.store.createLoadout(name: draft.name, channelIds: ids)
                        }
                        close()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Playlist picker

struct PlaylistPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    private var playlist: PlaylistModel { app.playlist }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose Playlist").font(.title2.bold())
                Spacer()
                Button { Task { await playlist.loadPlaylists() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(playlist.playlistsLoading)
            }
            Group {
                if playlist.playlists.isEmpty, playlist.playlistsLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlist.playlists.isEmpty, let error = playlist.playlistsError {
                    ContentUnavailableView {
                        Label("Couldn't load playlists", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await playlist.loadPlaylists() } }
                    }
                } else if playlist.playlists.isEmpty {
                    ContentUnavailableView("No playlists", systemImage: "music.note.list")
                } else {
                    List(playlist.playlists, selection: $selection) { item in
                        HStack(spacing: 10) {
                            Color.clear
                                .frame(width: 80, height: 45)
                                .overlay { RemoteImage(url: item.thumbnailUrl) }
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(1)
                                if item.videoCount > 0 {
                                    Text("\(item.videoCount) videos").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tag(item.id)
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(minHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm") {
                    if let selection { Task { await playlist.select(selection) } }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 540)
        .task {
            selection = playlist.playlistId
            await playlist.loadPlaylists()
        }
    }
}
