import XCTest
@testable import YTCurator

final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> J {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try J(data: Data(contentsOf: url))
    }

    func testChannelVideosTab() throws {
        let response = try fixture("videos")
        let tabs = Parsers.channelTabs(response)
        let selected = try XCTUnwrap(tabs.first { $0.selected })
        XCTAssertEqual(selected.segment, "videos")

        let list = Parsers.collectItems(selected.content)
        XCTAssertNotNil(list.continuation)
        let videos = list.items.compactMap { Parsers.channelVideo(kind: $0.kind, node: $0.node) }
        XCTAssertEqual(videos.count, 30)
        let first = try XCTUnwrap(videos.first)
        XCTAssertEqual(first.videoId.count, 11)
        XCTAssertNotEqual(first.title, "Untitled")
        XCTAssertNotNil(first.thumbnailUrl)
        XCTAssertNotNil(first.durationText)
        XCTAssertTrue(first.publishedText?.contains("ago") ?? false)
        XCTAssertTrue(first.viewCountText?.contains("view") ?? false)
        XCTAssertNil(Parsers.latestChipToken(selected.content), "Latest is already selected")

        let detail = Parsers.channelDetail(channelId: "UCBJycsmduvYEL83R_U4JriQ", response: response)
        XCTAssertEqual(detail.title, "Marques Brownlee")
        XCTAssertEqual(detail.handle, "@mkbhd")
        XCTAssertNotNil(detail.avatarUrl)
        XCTAssertNotNil(detail.bannerUrl)
        XCTAssertTrue(detail.subscriberText?.contains("subscribers") ?? false)
    }

    func testContinuation() throws {
        let list = Parsers.continuationItems(try fixture("videos_cont"))
        let videos = list.items.compactMap { Parsers.channelVideo(kind: $0.kind, node: $0.node) }
        XCTAssertEqual(videos.count, 30)
        XCTAssertNotNil(list.continuation)
    }

    func testStreamsTab() throws {
        let response = try fixture("streams")
        let selected = try XCTUnwrap(Parsers.channelTabs(response).first { $0.selected })
        XCTAssertEqual(selected.segment, ChannelTab.live.urlSegment)
        let videos = Parsers.collectItems(selected.content).items.compactMap { Parsers.channelVideo(kind: $0.kind, node: $0.node) }
        XCTAssertFalse(videos.isEmpty)
    }

    func testLockupPlaylist() throws {
        let response = try fixture("playlist")
        let header = Parsers.playlistHeader(response)
        XCTAssertEqual(header.title, "Retro Tech S2")
        XCTAssertNotNil(header.thumbnailUrl)
        let videos = Parsers.collectItems(response["contents"]).items.compactMap { Parsers.playlistVideo(kind: $0.kind, node: $0.node) }
        XCTAssertEqual(videos.count, 5)
        XCTAssertEqual(videos.first?.author, "Marques Brownlee")
        XCTAssertEqual(videos.first?.channelId, "UCBJycsmduvYEL83R_U4JriQ")
        XCTAssertEqual(videos.first?.durationText, "19:23")
    }

    func testLegacyPlaylist() throws {
        let response = try fixture("legacy_playlist")
        let header = Parsers.playlistHeader(response)
        XCTAssertEqual(header.title, "Watch Queue")
        XCTAssertEqual(header.thumbnailUrl, "https://i.ytimg.com/pl.jpg")
        let list = Parsers.collectItems(response["contents"])
        XCTAssertEqual(list.continuation, "NEXTPAGE")
        let videos = list.items.compactMap { Parsers.playlistVideo(kind: $0.kind, node: $0.node) }
        XCTAssertEqual(videos.map(\.setVideoId), ["SETA", "SETB"])
        XCTAssertEqual(videos[0].channelId, "UCaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(videos[0].thumbnailUrl, "https://i.ytimg.com/vi/aaaaaaaaaaa/hqdefault.jpg")
        XCTAssertEqual(videos[1].thumbnailUrl, "https://i.ytimg.com/vi/bbbbbbbbbbb/hqdefault.jpg")
        XCTAssertEqual(videos[1].durationText, "1:02:03")
    }

    func testPlaylistSummariesFromLockups() throws {
        let response = try fixture("channel_playlists")
        let summaries = Parsers.collectItems(response["contents"]).items.compactMap { Parsers.playlistSummary(kind: $0.kind, node: $0.node) }
        XCTAssertFalse(summaries.isEmpty)
        XCTAssertTrue(summaries.allSatisfy { !$0.id.isEmpty && $0.thumbnailUrl != nil })
    }

    func testSearchAndResolve() throws {
        let search = try fixture("search")
        let channel = try XCTUnwrap(search["contents"].all("channelRenderer").first.flatMap { Parsers.subscribedChannel(kind: "channelRenderer", node: $0) })
        XCTAssertEqual(channel.channelId, "UCBJycsmduvYEL83R_U4JriQ")
        XCTAssertEqual(channel.handle, "mkbhd")
        XCTAssertTrue(channel.avatarUrl?.hasPrefix("https:") ?? false)
        XCTAssertEqual(try fixture("resolve")["endpoint"]["browseEndpoint"]["browseId"].string, "UCBJycsmduvYEL83R_U4JriQ")
    }

    func testNormalizeHandle() {
        XCTAssertEqual(Parsers.normalizeHandle("@mkbhd"), "mkbhd")
        XCTAssertEqual(Parsers.normalizeHandle("https://www.youtube.com/@mkbhd/videos"), "mkbhd")
        XCTAssertEqual(Parsers.normalizeHandle("http://www.youtube.com/@Some.Name?x=1"), "Some.Name")
    }

    func testSapisidHash() {
        XCTAssertEqual(InnerTube.sapisidHash("abc", timestamp: 1_700_000_000),
                       "SAPISIDHASH 1700000000_" + sha1Hex("1700000000 abc https://www.youtube.com"))
    }

    private func sha1Hex(_ s: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try? p.run()
        input.fileHandleForWriting.write(Data(s.utf8))
        input.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    }
}
