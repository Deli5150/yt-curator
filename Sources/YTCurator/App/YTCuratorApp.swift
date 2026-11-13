import SwiftUI

@main
struct YTCuratorApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("YT Curator", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 560)
                .task { await app.bootstrap() }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await app.updater.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Channel…") { app.sheet = .addChannel }
                    .keyboardShortcut("n")
                    .disabled(app.loginState != .signedIn)
                Button("Import Subscriptions…") { app.sheet = .importSubscriptions }
                    .disabled(app.loginState != .signedIn)
            }
            CommandMenu("Playlist") {
                Button("Choose Playlist…") { app.sheet = .playlistPicker }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Refresh Playlist") { Task { await app.playlist.load() } }
                    .keyboardShortcut("r")
                Button("Sync") { Task { await app.playlist.sync() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(app.playlist.pendingChanges == 0 || app.playlist.syncing)
            }
            CommandGroup(after: .sidebar) {
                Button(app.showInspector ? "Hide Playlist" : "Show Playlist") { app.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Go Home") { app.route = .home }
                    .keyboardShortcut("1")
            }
        }

        Settings {
            SettingsView().environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.loginState {
            case .checking:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignedOutView()
            case .signedIn:
                MainView()
            }
        }
        .sheet(item: $app.sheet) { SheetHost(sheet: $0) }
        .sheet(isPresented: Binding(get: { app.updater.presentedRelease != nil },
                                    set: { if !$0 { app.updater.presentedRelease = nil } })) {
            if let release = app.updater.presentedRelease { UpdateSheet(release: release) }
        }
        .alert("Software Update", isPresented: Binding(get: { app.updater.checkMessage != nil },
                                                       set: { if !$0 { app.updater.checkMessage = nil } })) {
            Button("OK") { app.updater.checkMessage = nil }
        } message: {
            Text(app.updater.checkMessage ?? "")
        }
        .alert(
            "Already completed",
            isPresented: Binding(
                get: { app.playlist.pendingCompletedAdd != nil },
                // Any dismissal without "Yes" (No, Esc) just drops the pending add.
                set: { if !$0 { app.playlist.pendingCompletedAdd = nil } }
            ),
            presenting: app.playlist.pendingCompletedAdd
        ) { pending in
            Button("Yes") { app.playlist.confirmAdd(pending) }
                .keyboardShortcut(.defaultAction)
            Button("No", role: .cancel) { app.playlist.pendingCompletedAdd = nil }
        } message: { pending in
            Text("You already completed “\(pending.video.title)”. Do you still want to add it to the playlist?")
        }
        .alert("Something went wrong", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    /// Starts collapsed to the avatar rail; the full sidebar is a toggle away.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            HStack(spacing: 0) {
                // Collapsed sidebar → keep channel avatars reachable in a slim rail.
                if columnVisibility == .detailOnly {
                    MiniSidebarRail()
                    Divider()
                }
                Group {
                    switch app.route {
                    case .home: HomeView()
                    case .channel(let id): ChannelView(channelId: id).id(id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.snappy, value: columnVisibility)
            .inspector(isPresented: $app.showInspector) {
                PlaylistInspector()
                    .toolbar {
                        ToolbarItem {
                            Button { app.showInspector.toggle() } label: {
                                Label("Playlist", systemImage: "sidebar.trailing")
                            }
                            .help("Hide playlist")
                        }
                    }
            }
        }
        .overlay { DragOverlay() }
        .toolbar {
            if !app.showInspector {
                ToolbarItem(placement: .primaryAction) {
                    Button { app.showInspector = true } label: {
                        Label("Playlist", systemImage: "sidebar.trailing")
                    }
                    .help("Show playlist")
                }
            }
        }
    }
}

struct SignedOutView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: 18) {
            // The full logo's wordmark is white, so light mode uses the mark + system text.
            if colorScheme == .dark, let logo = Bundle.main.image(forResource: "curator-logo") {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 72)
            } else {
                AppLogo(height: 48)
            }
            Text("Curate your YouTube playlists")
                .font(.title2.weight(.semibold))
            Text("Browse the channels you follow, stage playlist edits, and sync them when you're ready.\nSign in with your Google account to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                signingIn = true
                Task {
                    await app.signIn()
                    signingIn = false
                }
            } label: {
                Label("Sign in to YouTube", systemImage: "person.crop.circle")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(signingIn)
            if !app.store.channels.isEmpty {
                Text("\(app.store.channels.count) channels and \(app.store.loadouts.count) loadouts ready.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [.red.opacity(0.12), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cleared = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("YouTube") {
                    Text(app.loginState == .signedIn ? "Signed in" : "Signed out")
                }
                if app.loginState == .signedIn {
                    Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                } else {
                    Button("Sign In…") { Task { await app.signIn() } }
                }
            }
            UpdateSettingsSection()
            Section("Data") {
                LabeledContent("Channels", value: "\(app.store.channels.count)")
                LabeledContent("Loadouts", value: "\(app.store.loadouts.count)")
                Button(cleared ? "Cache Cleared" : "Clear Feed Cache") {
                    FeedCache.clear()
                    app.feed.reset()
                    cleared = true
                }
                .disabled(cleared)
                Button("Show Data Folder in Finder") { NSWorkspace.shared.open(AppPaths.supportDir) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
