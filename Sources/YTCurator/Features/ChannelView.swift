import SwiftUI

/// A single channel's banner + Videos/Live grid (port of channel-view.tsx).
struct ChannelView: View {
    @Environment(AppModel.self) private var app
    let channelId: String

    static let initialPages = 3
    static let pagesPerLoadMore = 3

    @AppStorage("channelTab") private var tab: ChannelTab = .videos
    @AppStorage("channelSort") private var sortMode: SortMode = .latest
    @State private var detail: ChannelDetail?
    @State private var page: ChannelVideosPage?
    @State private var pageBudget = ChannelView.initialPages
    @State private var loading = false
    @State private var error: String?

    private var saved: SavedChannel? { app.store.channel(channelId) }
    private var title: String { detail?.title ?? saved?.title ?? "Channel" }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationSubtitle([detail?.handle, detail?.subscriberText].compactMap { $0 }.joined(separator: " · "))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Tab", selection: $tab) {
                        ForEach(ChannelTab.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItemGroup {
                    Button { Task { await load(force: true) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)
                    SortMenu(mode: $sortMode)
                    Button { app.open(YouTubeURL.channel(channelId)) } label: {
                        Label("Open on YouTube", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .task(id: channelId) {
                detail = nil
                page = nil
                pageBudget = Self.initialPages
                async let d: Void = loadDetail()
                await load()
                await d
            }
            .onChange(of: tab) {
                page = nil
                pageBudget = Self.initialPages
                Task { await load() }
            }
    }

    private func loadDetail() async {
        detail = try? await YouTubeClient.shared.getChannel(channelId, priority: true)
    }

    private func load(force: Bool = false) async {
        let requested = (channelId, tab, pageBudget)
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await YouTubeClient.shared.getChannelVideos(channelId, tab: tab, maxPages: pageBudget, force: force, priority: true)
            // Never show a stale previous channel's/tab's videos.
            guard requested == (channelId, tab, pageBudget) else { return }
            page = result
        } catch {
            guard requested == (channelId, tab, pageBudget) else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() {
        guard let page, page.hasMore, !loading else { return }
        pageBudget += Self.pagesPerLoadMore
        Task { await load() }
    }

    @ViewBuilder private var content: some View {
        let videos = VideoSort.apply(page?.videos ?? [], sortMode)
        VideoGrid(items: videos.map { ($0, saved) }, onEndReached: loadMore) {
            banner
            if videos.isEmpty {
                Group {
                    if page == nil, loading {
                        ProgressView()
                    } else if let error {
                        ContentUnavailableView {
                            Label("Couldn't load \(tab.label.lowercased())", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { Task { await load(force: true) } }
                        }
                    } else if page != nil {
                        ContentUnavailableView(VideoSort.emptyMessage(tab: tab, mode: sortMode, total: page?.videos.count ?? 0),
                                               systemImage: "play.rectangle")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .overlay(alignment: .bottom) {
            if loading, page != nil {
                ProgressView().controlSize(.small).padding(10).glassEffect().padding(.bottom, 16)
            }
        }
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: 160)
                .overlay {
                    RemoteImage(url: detail?.bannerUrl, maxPixel: 2400) {
                        LinearGradient(colors: [.red.opacity(0.35), .accentColor.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            HStack(alignment: .bottom, spacing: 14) {
                ChannelAvatar(url: detail?.avatarUrl ?? saved?.avatarUrl, title: title, size: 76)
                    .overlay(Circle().stroke(.background, lineWidth: 3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                    if let meta = [detail?.handle, detail?.subscriberText].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                        Text(meta).font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.bottom, 6)
                Spacer()
                if saved == nil, detail != nil {
                    Button("Follow") {
                        Task { await app.follow(channelId: channelId) }
                    }
                    .buttonStyle(.glassProminent)
                    .padding(.bottom, 8)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .padding([.horizontal, .top], 20)
        .help(detail?.description ?? "")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
