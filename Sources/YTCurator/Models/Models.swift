import Foundation

/// App-level DTOs, ported from the Glaze app's `main/services/types.ts` + `renderer/lib/types.ts`.
/// Field names match the Glaze JSON so `app-data.json` decodes unchanged.

enum ChannelTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case videos
    case live

    var id: String { rawValue }
    var label: String { self == .videos ? "Videos" : "Live" }
    /// Path segment of the channel tab on youtube.com.
    var urlSegment: String { self == .videos ? "videos" : "streams" }
}

struct SavedChannel: Codable, Hashable, Identifiable, Sendable {
    var handle: String
    var channelId: String
    var title: String
    var avatarUrl: String?

    var id: String { channelId }
}

struct PlaylistSummary: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var videoCount: Int
    var thumbnailUrl: String?
}

struct PlaylistVideo: Codable, Hashable, Identifiable, Sendable {
    /// Public YouTube video id
    var videoId: String
    /// Playlist-item id required by InnerTube for move/remove
    var setVideoId: String?
    var title: String
    var author: String?
    /// Author's channel id when YouTube exposes it; nil for pending adds / unresolved rows.
    var channelId: String?
    var thumbnailUrl: String?
    var durationText: String?
    /// True for items staged locally that are not yet on YouTube
    var pendingAdd: Bool?

    /// Stable row key: setVideoId for real members, `pending:<videoId>` for staged adds.
    var key: String { setVideoId ?? "pending:\(videoId)" }
    var id: String { key }
}

struct PlaylistDetail: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String?
    var videoCount: Int
    var thumbnailUrl: String?
    var videos: [PlaylistVideo]
}

struct ChannelDetail: Codable, Hashable, Sendable {
    var channelId: String
    var title: String
    var handle: String?
    var description: String?
    var avatarUrl: String?
    var bannerUrl: String?
    var subscriberText: String?
}

struct ChannelVideo: Codable, Hashable, Identifiable, Sendable {
    var videoId: String
    var title: String
    var thumbnailUrl: String?
    var durationText: String?
    var publishedText: String?
    var viewCountText: String?
    var isMembersOnly: Bool

    var id: String { videoId }
}

/// Page of channel videos plus whether deeper history is still available.
struct ChannelVideosPage: Codable, Hashable, Sendable {
    var videos: [ChannelVideo]
    var hasMore: Bool
}

struct PlaylistSyncInput: Sendable {
    var playlistId: String
    /// Desired final order of all playlist videos (by public videoId).
    var orderedVideoIds: [String]
    /// setVideoIds to remove from the live playlist.
    var removedSetVideoIds: [String]
    /// Public video ids to append.
    var addedVideoIds: [String]
}

/// Locally staged playlist edits (persisted on disk until Sync).
struct StagedEdits: Codable, Hashable, Sendable {
    var playlistId: String
    /// Final ordered list of playlist videos after local edits.
    var videos: [PlaylistVideo]
    var removedSetVideoIds: [String]
    var addedVideoIds: [String]
    /// Baseline videoIds from last server fetch — used to compute dirty state.
    var baselineVideoIds: [String]
}

struct Loadout: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var channelIds: [String]
}

struct AppData: Codable, Sendable {
    var channels: [SavedChannel] = []
    var selectedPlaylistId: String?
    var selectedChannelId: String?
    var loadouts: [Loadout] = []
    /// nil = All channels
    var activeLoadoutId: String?
}

/// A video dragged from a grid tile onto the playlist panel.
struct VideoDragPayload: Codable, Hashable, Sendable {
    var videoId: String
    var title: String
    var thumbnailUrl: String?
    var durationText: String?
    var author: String?

    static let prefix = "ytcurator-video:"

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + (String(data: data, encoding: .utf8) ?? "")
    }

    static func decode(_ string: String) -> VideoDragPayload? {
        guard string.hasPrefix(prefix) else { return nil }
        let json = Data(string.dropFirst(prefix.count).utf8)
        return try? JSONDecoder().decode(VideoDragPayload.self, from: json)
    }
}

extension ChannelVideo {
    func dragPayload(author: String?) -> VideoDragPayload {
        VideoDragPayload(videoId: videoId, title: title, thumbnailUrl: thumbnailUrl, durationText: durationText, author: author)
    }
}

enum YouTubeURL {
    static func video(_ id: String) -> URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    static func playlist(_ id: String) -> URL { URL(string: "https://www.youtube.com/playlist?list=\(id)")! }
    static func channel(_ id: String) -> URL { URL(string: "https://www.youtube.com/channel/\(id)")! }
}
