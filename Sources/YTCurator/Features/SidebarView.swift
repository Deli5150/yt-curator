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
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
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

/// Avatar-only rail shown in place of the collapsed sidebar (Discord-style, like the Glaze rail).
struct MiniSidebarRail: View {
    @Environment(AppModel.self) private var app

    static let width: CGFloat = 64

    var body: some View {
        VStack(spacing: 10) {
            railButton(systemImage: "house.fill", selected: app.route == .home, help: "Home") { app.route = .home }

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
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassEffect(in: Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Loadout: \(app.store.activeLoadout?.name ?? "All channels")")

            Divider().padding(.horizontal, 14)

            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(app.store.activeChannels) { channel in
                        let selected = app.route == .channel(channel.channelId)
                        Button { app.openChannel(channel.channelId) } label: {
                            ChannelAvatar(url: channel.avatarUrl, title: channel.title, size: 40)
                                .padding(3)
                                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                        .help(channel.title)
                        .contextMenu { ChannelMenu(channel: channel) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)

            railButton(systemImage: "plus", selected: false, help: "Add channel") { app.sheet = .addChannel }
                .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func railButton(systemImage: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 40, height: 40)
                .background(selected ? Color.accentColor : .clear, in: Circle())
                .glassEffect(in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
