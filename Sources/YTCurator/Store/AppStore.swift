import Foundation
import Observation

enum AppPaths {
    static var supportDir: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "YT Curator", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cacheDir: URL {
        let dir = URL.cachesDirectory.appending(path: "com.delvison.ytcurator", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The Glaze build's data file, imported once on first launch.
    static let glazeAppData = URL.applicationSupportDirectory
        .appending(path: "app.glaze.macos.1hewbq6s-local/app-data.json")
}

enum StoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}

/// Atomic JSON store for channels, loadouts and selections (port of `app-store.ts`).
@MainActor
@Observable
final class AppStore {
    private(set) var data: AppData {
        didSet { refreshActiveChannels() }
    }
    /// Channels in the active loadout (all channels when none is active), in saved order.
    /// Stored because the sidebar, rail and feed all read it on every render.
    private(set) var activeChannels: [SavedChannel] = []
    @ObservationIgnored private let fileURL: URL

    init(directory: URL = AppPaths.supportDir, glazeImport: URL? = AppPaths.glazeAppData) {
        fileURL = directory.appending(path: "app-data.json")
        if let loaded = Self.read(fileURL) {
            data = loaded
        } else if let glazeImport, let imported = Self.read(glazeImport) {
            data = imported
            log.info("Imported \(imported.channels.count) channels and \(imported.loadouts.count) loadouts from Glaze")
            persist()
        } else {
            data = AppData()
        }
        refreshActiveChannels()
    }

    private static func read(_ url: URL) -> AppData? {
        guard let raw = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(AppData.self, from: raw) else { return nil }
        decoded.loadouts = decoded.loadouts.compactMap { l in
            let id = l.id.trimmingCharacters(in: .whitespaces)
            let name = l.name.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return Loadout(id: id, name: name, channelIds: normalizeChannelIds(l.channelIds))
        }
        if let active = decoded.activeLoadoutId, !decoded.loadouts.contains(where: { $0.id == active }) {
            decoded.activeLoadoutId = nil
        }
        return decoded
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Failed to save app-data.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func normalizeChannelIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id in
            let t = id.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && seen.insert(t).inserted ? t : nil
        }
    }

    // MARK: - Channels

    var channels: [SavedChannel] { data.channels }

    func channel(_ id: String) -> SavedChannel? { data.channels.first { $0.channelId == id } }

    func addChannel(_ channel: SavedChannel) {
        data.channels.removeAll {
            $0.channelId == channel.channelId || $0.handle.lowercased() == channel.handle.lowercased()
        }
        data.channels.append(channel)
        persist()
    }

    /// Bulk-add channels, skipping existing channelId/handle matches. One persist.
    @discardableResult
    func addChannels(_ channels: [SavedChannel]) -> Int {
        var ids = Set(data.channels.map(\.channelId))
        var handles = Set(data.channels.map { $0.handle.lowercased() })
        var added = 0
        for c in channels where !ids.contains(c.channelId) && !handles.contains(c.handle.lowercased()) {
            ids.insert(c.channelId)
            handles.insert(c.handle.lowercased())
            data.channels.append(c)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func removeChannel(_ channelId: String) {
        data.channels.removeAll { $0.channelId == channelId }
        if data.selectedChannelId == channelId { data.selectedChannelId = nil }
        // Drop deleted channels from every loadout so membership stays valid.
        for i in data.loadouts.indices { data.loadouts[i].channelIds.removeAll { $0 == channelId } }
        persist()
    }

    /// Replace saved rows in place by channelId (same order / membership).
    func replaceChannels(_ channels: [SavedChannel]) {
        let byId = Dictionary(channels.map { ($0.channelId, $0) }, uniquingKeysWith: { a, _ in a })
        let next = data.channels.map { byId[$0.channelId] ?? $0 }
        guard next != data.channels else { return }
        data.channels = next
        persist()
    }

    // MARK: - Selections

    var selectedPlaylistId: String? {
        get { data.selectedPlaylistId }
        set { data.selectedPlaylistId = newValue; persist() }
    }

    var selectedChannelId: String? {
        get { data.selectedChannelId }
        set { guard newValue != data.selectedChannelId else { return }; data.selectedChannelId = newValue; persist() }
    }

    // MARK: - Loadouts

    var loadouts: [Loadout] { data.loadouts }
    var activeLoadoutId: String? { data.activeLoadoutId }
    var activeLoadout: Loadout? { data.loadouts.first { $0.id == data.activeLoadoutId } }

    private func refreshActiveChannels() {
        let next: [SavedChannel]
        if let loadout = activeLoadout {
            let members = Set(loadout.channelIds)
            next = data.channels.filter { members.contains($0.channelId) }
        } else {
            next = data.channels
        }
        if next != activeChannels { activeChannels = next }
    }

    @discardableResult
    func createLoadout(name: String, channelIds: [String]) throws -> Loadout {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw StoreError.message("Loadout name is required") }
        let known = Set(data.channels.map(\.channelId))
        let loadout = Loadout(id: UUID().uuidString.lowercased(), name: trimmed,
                              channelIds: Self.normalizeChannelIds(channelIds).filter(known.contains))
        data.loadouts.append(loadout)
        persist()
        return loadout
    }

    func updateLoadout(id: String, name: String? = nil, channelIds: [String]? = nil) throws {
        guard let index = data.loadouts.firstIndex(where: { $0.id == id }) else { throw StoreError.message("Loadout not found") }
        let nextName = name?.trimmingCharacters(in: .whitespaces) ?? data.loadouts[index].name
        guard !nextName.isEmpty else { throw StoreError.message("Loadout name is required") }
        data.loadouts[index].name = nextName
        if let channelIds {
            let known = Set(data.channels.map(\.channelId))
            data.loadouts[index].channelIds = Self.normalizeChannelIds(channelIds).filter(known.contains)
        }
        persist()
    }

    func deleteLoadout(id: String) {
        data.loadouts.removeAll { $0.id == id }
        if data.activeLoadoutId == id { data.activeLoadoutId = nil }
        persist()
    }

    func setActiveLoadout(_ id: String?) {
        if let id, !data.loadouts.contains(where: { $0.id == id }) { return }
        data.activeLoadoutId = id
        persist()
    }
}
