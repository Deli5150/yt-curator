import SwiftUI

/// Home, active loadout picker and the loadout's channels (port of channel-rail.tsx).
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: selection) {
            Label("Home", systemImage: "house").tag(Route.home)

            Section {
                ForEach(app.store.activeChannels) { channel in
                    HStack(spacing: 8) {
                        ChannelAvatar(url: channel.avatarUrl, title: channel.title, size: 24)
                        Text(channel.title).lineLimit(1)
                    }
                    .tag(Route.channel(channel.channelId))
                    .contextMenu { ChannelMenu(channel: channel) }
                }
            } header: {
                loadoutMenu
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { app.sheet = .addChannel } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .help("Add a channel by handle")
                Spacer()
                Button { app.sheet = .loadouts } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Manage loadouts")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private var selection: Binding<Route?> {
        Binding(
            get: { app.route },
            set: { route in
                guard let route else { return }
                if case .channel(let id) = route { app.openChannel(id) } else { app.route = route }
            }
        )
    }

    private var loadoutMenu: some View {
        Menu {
            Picker("Loadout", selection: Binding(
                get: { app.store.activeLoadoutId },
                set: { app.store.setActiveLoadout($0) }
            )) {
                Text("All channels").tag(String?.none)
                ForEach(app.store.loadouts) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Manage Loadouts…") { app.sheet = .loadouts }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(app.store.activeLoadout?.name ?? "All channels")
                Text("\(app.store.activeChannels.count)").foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Switch loadout")
    }
}
