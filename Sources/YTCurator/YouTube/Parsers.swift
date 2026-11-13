import Foundation

/// Raw InnerTube JSON → app DTOs. This (with YouTubeClient) is the only code that knows
/// YouTube's response shapes. Every mapper handles both the legacy renderer shapes
/// (`videoRenderer`, `playlistVideoRenderer`, `gridPlaylistRenderer`, …) and the newer
/// `lockupViewModel` shape; extend the same dual-shape pattern if responses drift again.
enum Parsers {
    // MARK: - Shared helpers

    static let durationPattern = /^\d{1,2}(:\d{2}){1,2}$/
    static let membersOnlyPattern = /(?i)members[\s-]*only/

    struct Thumb { var url: String; var width: Int }

    static func normalizeImageURL(_ url: String?) -> String? {
        guard let trimmed = url?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
    }

    /// `{thumbnails:[…]}` or `{sources:[…]}` or a bare array of `{url,width}`.
    static func thumbs(_ node: J) -> [Thumb] {
        var list = node.array
        if list.isEmpty { list = node["thumbnails"].array }
        if list.isEmpty { list = node["sources"].array }
        return list.compactMap { t in
            guard let url = t["url"].string else { return nil }
            return Thumb(url: url, width: t["width"].int ?? 0)
        }
    }

    static func pickThumbnail(_ thumbs: [Thumb]) -> String? {
        normalizeImageURL(thumbs.max { $0.width < $1.width }?.url)
    }

    /// Prefer a crisp sidebar-sized avatar without grabbing a multi-MB original.
    static func pickAvatar(_ thumbs: [Thumb]) -> String? {
        let preferred = thumbs.filter { $0.width >= 88 && $0.width <= 320 }.max { $0.width < $1.width }
        return normalizeImageURL((preferred ?? thumbs.max { $0.width < $1.width })?.url)
    }

    static func normalizeHandle(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacing(/^(?i)https?:\/\/(www\.)?youtube\.com\//, with: "")
        if h.hasPrefix("@") { h.removeFirst() }
        if let cut = h.firstIndex(where: { "/?#".contains($0) }) { h = String(h[..<cut]) }
        return h
    }

    static func isDuration(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).wholeMatch(of: durationPattern) != nil
    }

    // MARK: - Item / continuation collection

    /// Keys whose values are list items; collection stops descending at these.
    static let itemKeys: Set<String> = [
        "lockupViewModel", "videoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "gridPlaylistRenderer", "playlistRenderer", "channelRenderer", "gridChannelRenderer",
    ]

    struct ItemList {
        var items: [(kind: String, node: J)] = []
        var continuation: String?
    }

    /// Walk `root` in document order collecting list items and the list's continuation token.
    /// A page can hold several continuations (e.g. a playlist plus a suggestions section below
    /// it); the one that sits in the same array as the items wins.
    static func collectItems(_ root: J) -> ItemList {
        var out = ItemList()
        var primary: String?
        var fallback: String?
        walkItems(root, &out, &primary, &fallback)
        out.continuation = primary ?? fallback
        return out
    }

    private static func walkItems(_ node: J, _ out: inout ItemList, _ primary: inout String?, _ fallback: inout String?) {
        if let a = node.raw as? [Any] {
            let itemsBefore = out.items.count
            var arrayToken: String?
            for v in a {
                let element = J(v)
                if element["continuationItemRenderer"].exists {
                    arrayToken = continuationToken(element["continuationItemRenderer"]) ?? arrayToken
                } else {
                    walkItems(element, &out, &primary, &fallback)
                }
            }
            if let arrayToken {
                if out.items.count > itemsBefore, primary == nil { primary = arrayToken } else { fallback = arrayToken }
            }
            return
        }
        guard let d = node.dict else { return }
        for (key, value) in d.sorted(by: { $0.key < $1.key }) {
            let v = J(value)
            if itemKeys.contains(key) {
                out.items.append((key, v))
            } else if key == "continuationItemRenderer" {
                if let token = continuationToken(v) { fallback = token }
            } else {
                walkItems(v, &out, &primary, &fallback)
            }
        }
    }

    static func continuationToken(_ renderer: J) -> String? {
        let endpoint = renderer["continuationEndpoint"]
        if let t = endpoint["continuationCommand"]["token"].string { return t }
        for cmd in endpoint["commandExecutorCommand"]["commands"].array {
            if let t = cmd["continuationCommand"]["token"].string { return t }
        }
        return renderer.first("token")?.string
    }

    /// Items from a `browse {continuation}` response.
    static func continuationItems(_ response: J) -> ItemList {
        var actions = response["onResponseReceivedActions"].array
        actions += response["onResponseReceivedEndpoints"].array
        var out = ItemList()
        for action in actions {
            for key in ["appendContinuationItemsAction", "reloadContinuationItemsCommand"] {
                let list = collectItems(action[key]["continuationItems"])
                out.items += list.items
                if list.continuation != nil { out.continuation = list.continuation }
            }
        }
        // Legacy continuationContents shape.
        if out.items.isEmpty, response["continuationContents"].exists {
            out = collectItems(response["continuationContents"])
        }
        return out
    }

    // MARK: - Lockup helpers

    static func lockupTitle(_ lockup: J) -> String? {
        lockup["metadata"]["lockupMetadataViewModel"]["title"].text
    }

    static func lockupRows(_ lockup: J) -> [J] {
        lockup["metadata"]["lockupMetadataViewModel"]["metadata"]["contentMetadataViewModel"]["metadataRows"].array
    }

    static func lockupRowTexts(_ lockup: J) -> [String] {
        lockupRows(lockup).flatMap { row in row["metadataParts"].array.compactMap { $0["text"].text } }
    }

    static func lockupRowBadges(_ lockup: J) -> [(text: String?, style: String?)] {
        lockupRows(lockup).flatMap { row in
            row["badges"].array.map { b in
                let vm = b["badgeViewModel"]
                return (vm["badgeText"].text ?? b["text"].text, vm["badgeStyle"].string ?? b["style"].string)
            }
        }
    }

    static func lockupThumbs(_ lockup: J) -> [Thumb] {
        let ci = lockup["contentImage"]
        for node in [ci["thumbnailViewModel"]["image"],
                     ci["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]["image"]] {
            let t = thumbs(node)
            if !t.isEmpty { return t }
        }
        if let img = ci.first("image") { return thumbs(img) }
        return []
    }

    /// Thumbnail overlay badge texts (duration, "N videos", …).
    static func lockupOverlayTexts(_ lockup: J) -> [String] {
        lockup["contentImage"].all("thumbnailBadgeViewModel").compactMap { $0["text"].text }
    }

    // MARK: - Videos

    static func channelVideo(kind: String, node: J) -> ChannelVideo? {
        switch kind {
        case "lockupViewModel":
            guard let id = node["contentId"].string else { return nil }
            if let type = node["contentType"].string, type != "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }
            let rows = lockupRowTexts(node)
            let badges = lockupRowBadges(node)
            return ChannelVideo(
                videoId: id,
                title: lockupTitle(node) ?? "Untitled",
                thumbnailUrl: pickThumbnail(lockupThumbs(node)),
                durationText: lockupOverlayTexts(node).first(where: isDuration),
                // Loose "ago" match — a row can carry other text alongside the relative date.
                publishedText: rows.first { $0.contains(/(?i)\bago\b/) },
                viewCountText: rows.first { $0.localizedCaseInsensitiveContains("view") },
                isMembersOnly: badges.contains { $0.style == "BADGE_MEMBERS_ONLY" || ($0.text ?? "").contains(membersOnlyPattern) }
            )
        case "videoRenderer", "gridVideoRenderer":
            guard let id = node["videoId"].string else { return nil }
            let overlayDuration = node["thumbnailOverlays"].all("thumbnailOverlayTimeStatusRenderer").compactMap { $0["text"].text }.first
            let badges = node["badges"].array.map { $0["metadataBadgeRenderer"] }
            return ChannelVideo(
                videoId: id,
                title: node["title"].text ?? "Untitled",
                thumbnailUrl: pickThumbnail(thumbs(node["thumbnail"])),
                durationText: node["lengthText"].text ?? overlayDuration,
                publishedText: node["publishedTimeText"].text,
                viewCountText: node["viewCountText"].text ?? node["shortViewCountText"].text,
                isMembersOnly: badges.contains {
                    ($0["style"].string ?? "").contains("MEMBERS_ONLY") || ($0["label"].text ?? "").contains(membersOnlyPattern)
                }
            )
        default:
            return nil
        }
    }

    static func playlistVideo(kind: String, node: J) -> PlaylistVideo? {
        switch kind {
        case "playlistVideoRenderer":
            guard let id = node["videoId"].string else { return nil }
            let byline = node["shortBylineText"]
            return PlaylistVideo(
                videoId: id,
                setVideoId: node["setVideoId"].string,
                title: node["title"].text ?? "Untitled",
                author: byline.text,
                channelId: byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                thumbnailUrl: pickThumbnail(thumbs(node["thumbnail"])),
                durationText: node["lengthText"].text
                    ?? node["thumbnailOverlays"].all("thumbnailOverlayTimeStatusRenderer").compactMap { $0["text"].text }.first
            )
        case "lockupViewModel":
            guard let id = node["contentId"].string else { return nil }
            if let type = node["contentType"].string, type != "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }
            let authorPart = lockupRows(node).first?["metadataParts"][0]["text"]
            return PlaylistVideo(
                videoId: id,
                setVideoId: node.first("setVideoId")?.string,
                title: lockupTitle(node) ?? "Untitled",
                author: authorPart?.text,
                channelId: authorPart?.first("browseEndpoint")?["browseId"].string,
                thumbnailUrl: pickThumbnail(lockupThumbs(node)),
                durationText: lockupOverlayTexts(node).first(where: isDuration)
            )
        case "videoRenderer":
            guard let v = channelVideo(kind: kind, node: node) else { return nil }
            let owner = node["ownerText"]
            return PlaylistVideo(
                videoId: v.videoId, setVideoId: node.first("setVideoId")?.string, title: v.title,
                author: owner.text, channelId: owner.first("browseId")?.string,
                thumbnailUrl: v.thumbnailUrl, durationText: v.durationText
            )
        default:
            return nil
        }
    }

    // MARK: - Playlists

    static func playlistSummary(kind: String, node: J) -> PlaylistSummary? {
        switch kind {
        case "lockupViewModel":
            guard let id = node["contentId"].string else { return nil }
            if let type = node["contentType"].string, type == "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }
            let countText = lockupOverlayTexts(node).first { $0.localizedCaseInsensitiveContains("video") }
            return PlaylistSummary(
                id: id,
                title: lockupTitle(node) ?? "Untitled playlist",
                videoCount: parseCount(countText),
                thumbnailUrl: pickThumbnail(lockupThumbs(node))
            )
        case "gridPlaylistRenderer", "playlistRenderer":
            guard let id = node["playlistId"].string else { return nil }
            var t = thumbs(node["thumbnail"])
            if t.isEmpty { t = thumbs(node["thumbnailRenderer"]["playlistVideoThumbnailRenderer"]["thumbnail"]) }
            if t.isEmpty, let first = node["thumbnails"].array.first { t = thumbs(first) }
            let countText = node["videoCountText"].text ?? node["videoCountShortText"].text ?? node["videoCount"].string
            return PlaylistSummary(
                id: id,
                title: node["title"].text ?? "Untitled playlist",
                videoCount: parseCount(countText),
                thumbnailUrl: pickThumbnail(t)
            )
        default:
            return nil
        }
    }

    static func parseCount(_ text: String?) -> Int {
        Int((text ?? "").filter(\.isNumber)) ?? 0
    }

    /// Header/metadata of a `browse VL<id>` response (items are collected separately).
    static func playlistHeader(_ response: J) -> (title: String?, description: String?, thumbnailUrl: String?) {
        let meta = response["metadata"]["playlistMetadataRenderer"]
        let header = response["header"]
        let title = meta["title"].text
            ?? header["pageHeaderRenderer"]["pageTitle"].text
            ?? header["playlistHeaderRenderer"]["title"].text
        let description = meta["description"].text ?? header["playlistHeaderRenderer"]["descriptionText"].text
        var t: [Thumb] = []
        if let primary = response["sidebar"].first("playlistSidebarPrimaryInfoRenderer") {
            t = thumbs(primary["thumbnailRenderer"].first("thumbnail") ?? J(nil))
        }
        if t.isEmpty, let hero = header.first("heroImage") ?? header.first("contentPreviewImageViewModel") {
            t = thumbs(hero.first("image") ?? hero)
        }
        return (title, description, pickThumbnail(t))
    }

    // MARK: - Channels

    static func channelDetail(channelId: String, response: J) -> ChannelDetail {
        let meta = response["metadata"]["channelMetadataRenderer"]
        let header = response["header"]
        let legacy = header["c4TabbedHeaderRenderer"]
        let page = header["pageHeaderRenderer"]["content"]["pageHeaderViewModel"]

        let rowTexts = page["metadata"]["contentMetadataViewModel"]["metadataRows"].array
            .flatMap { $0["metadataParts"].array.compactMap { $0["text"].text } }

        let title = meta["title"].text
            ?? legacy["title"].text
            ?? header["pageHeaderRenderer"]["pageTitle"].text
            ?? page["title"].first("content")?.string
            ?? "Channel"

        let rawHandle = meta["vanityChannelUrl"].string
            ?? legacy["channelHandleText"].text
            ?? rowTexts.first { $0.hasPrefix("@") }
        var handle: String?
        if let rawHandle {
            let normalized = normalizeHandle(rawHandle)
            // vanityChannelUrl can be /channel/UC…, which is not a handle.
            if !normalized.isEmpty, !normalized.hasPrefix("channel/") { handle = "@" + normalized }
        }

        var avatar = thumbs(meta["avatar"])
        if avatar.isEmpty { avatar = thumbs(legacy["avatar"]) }
        if avatar.isEmpty { avatar = thumbs(page["image"]["decoratedAvatarViewModel"]["avatar"]["avatarViewModel"]["image"]) }
        if avatar.isEmpty, let img = page["image"].first("image") { avatar = thumbs(img) }

        var banner = thumbs(legacy["banner"])
        if banner.isEmpty { banner = thumbs(page["banner"]["imageBannerViewModel"]["image"]) }
        if banner.isEmpty { banner = thumbs(legacy["tvBanner"]) }

        let subscribers = legacy["subscriberCountText"].text
            ?? rowTexts.first { $0.localizedCaseInsensitiveContains("subscriber") }

        let description = meta["description"].text ?? page["description"].first("content")?.string

        return ChannelDetail(
            channelId: channelId,
            title: title,
            handle: handle,
            description: description,
            avatarUrl: pickAvatar(avatar),
            bannerUrl: pickThumbnail(banner),
            subscriberText: subscribers
        )
    }

    /// Tabs on a channel browse response: url suffix → (browseEndpoint, selected).
    static func channelTabs(_ response: J) -> [(segment: String, endpoint: J, selected: Bool, content: J)] {
        response["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array.compactMap { tab in
            let tr = tab["tabRenderer"].exists ? tab["tabRenderer"] : tab["expandableTabRenderer"]
            guard let url = tr["endpoint"]["commandMetadata"]["webCommandMetadata"]["url"].string else { return nil }
            let segment = url.split(separator: "/").last.map(String.init) ?? ""
            return (segment, tr["endpoint"]["browseEndpoint"], tr["selected"].bool ?? false, tr["content"])
        }
    }

    /// "Latest" sort chip on a channel tab, when present and not already selected.
    static func latestChipToken(_ tabContent: J) -> String? {
        for chip in tabContent.all("chipViewModel") where chip["text"].text == "Latest" {
            if chip["selected"].bool == true { return nil }
            return chip.first("continuationCommand")?["token"].string
        }
        for item in tabContent.all("sortFilterSubMenuRenderer").flatMap({ $0["subMenuItems"].array }) where item["title"].text == "Latest" {
            if item["selected"].bool == true { return nil }
            return item.first("continuationCommand")?["token"].string
        }
        return nil
    }

    static func subscribedChannel(kind: String, node: J) -> SavedChannel? {
        guard kind == "channelRenderer" || kind == "gridChannelRenderer" else { return nil }
        guard let channelId = node["channelId"].string else { return nil }
        let title = node["title"].text ?? channelId
        var handle = channelId
        let base = node["navigationEndpoint"]["browseEndpoint"]["canonicalBaseUrl"].string.map(normalizeHandle) ?? ""
        if !base.isEmpty, !base.hasPrefix("channel/") {
            handle = base
        } else if let text = node["subscriberCountText"].text ?? node["videoCountText"].text, text.hasPrefix("@") {
            // Search/subscription cards show the @handle in place of the subscriber count.
            handle = normalizeHandle(text)
        }
        return SavedChannel(
            handle: handle.isEmpty ? channelId : handle,
            channelId: channelId,
            title: title,
            avatarUrl: pickAvatar(thumbs(node["thumbnail"]))
        )
    }

    /// YouTube error alerts embedded in a 200 response (e.g. "The playlist does not exist.").
    static func alertError(_ response: J) -> String? {
        for alert in response["alerts"].array {
            for key in ["alertRenderer", "alertWithButtonRenderer"] {
                let a = alert[key]
                if a["type"].string == "ERROR", let text = a["text"].text { return text }
            }
        }
        return nil
    }
}
