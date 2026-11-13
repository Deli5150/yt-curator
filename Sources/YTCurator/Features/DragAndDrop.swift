import AppKit
import SwiftUI

/// In-app drag of a video tile onto the playlist panel. The system drag (`.draggable`) gives no
/// control over the preview, so the grabbed thumbnail is drawn by `DragOverlay` instead: it lifts
/// out of the tile, springs down to a small card under the cursor, and flies back if dropped
/// outside the playlist. Everything here works in `.global` (window) coordinates.
@MainActor
@Observable
final class DragController {
    static let cardSize = CGSize(width: 176, height: 99)

    private(set) var payload: VideoDragPayload?
    private(set) var image: NSImage?
    private(set) var sourceFrame: CGRect = .zero
    /// Pointer position (window coordinates).
    private(set) var location: CGPoint = .zero
    /// Pointer offset from the source frame's center when the drag began.
    private(set) var grabOffset: CGSize = .zero
    /// Drives the lift/shrink animation.
    private(set) var lifted = false
    /// Set on a successful drop: the card slides into the list and fades.
    private(set) var dropping = false
    private(set) var overPlaylist = false
    private(set) var alreadyInPlaylist = false
    /// Quick-drop zones under the playlist while dragging: left adds to the top, right to the bottom.
    enum Zone { case top, bottom }
    /// The quick-drop zone under the cursor, if any.
    private(set) var hoveredZone: Zone?
    /// Where the insertion line is drawn (window y), when over the playlist rows.
    private(set) var indicatorY: CGFloat?
    @ObservationIgnored private var dropIndex: Int?
    @ObservationIgnored private var startLocation: CGPoint = .zero

    // Written continuously by geometry observers; never observed, so they don't cause renders.
    @ObservationIgnored var playlistFrame: CGRect = .zero
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored var zoneFrames: [Zone: CGRect] = [:]

    var activeVideoId: String? { payload?.videoId }

    /// True from grab until the drop animation finishes; the feed holds back updates meanwhile
    /// so tiles don't reflow under the cursor.
    static var isDragging = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var playlist: PlaylistModel?

    /// The tile's gesture only starts the drag. Movement and release come from an app-level
    /// event monitor: if the grid re-renders or reflows mid-drag, SwiftUI cancels the tile's
    /// gesture without calling onEnded, which left the card stuck on screen.
    func begin(_ payload: VideoDragPayload, sourceFrame: CGRect, start: CGPoint, playlist: PlaylistModel) {
        guard self.payload == nil else { return }
        Self.isDragging = true
        self.playlist = playlist
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let playlist = self.playlist, let point = Self.windowPoint(event) else { return event }
            if event.type == .leftMouseUp {
                self.move(to: point, playlist: playlist)
                self.end(playlist: playlist)
            } else {
                self.move(to: point, playlist: playlist)
            }
            return event
        }
        begin(payload, sourceFrame: sourceFrame, start: start)
    }

    /// NSEvent window location → SwiftUI `.global` (top-left origin of the content view).
    private static func windowPoint(_ event: NSEvent) -> CGPoint? {
        guard let content = event.window?.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
    }

    private func begin(_ payload: VideoDragPayload, sourceFrame: CGRect, start: CGPoint) {
        self.payload = payload
        self.sourceFrame = sourceFrame
        startLocation = start
        location = start
        grabOffset = CGSize(width: start.x - sourceFrame.midX, height: start.y - sourceFrame.midY)
        image = payload.thumbnailUrl.flatMap(URL.init(string:)).flatMap { ImageLoader.shared.cached($0, maxPixel: 640) }
        lifted = false
        dropping = false
        // Render one frame at the tile's size first so the shrink is visible.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) { self.lifted = true }
        }
    }

    func move(to point: CGPoint, playlist: PlaylistModel) {
        guard payload != nil else { return }
        location = point
        let over = playlist.edits != nil && playlistFrame.contains(point)
        let saved = over && playlist.savedIds.contains(payload!.videoId)
        let zone = over ? zoneFrames.first(where: { $0.value.contains(point) })?.key : nil
        var y: CGFloat?
        var index: Int?
        if let zone, !saved {
            index = zone == .top ? 0 : playlist.videos.count
        } else if over, !saved, zone == nil {
            (index, y) = insertionPoint(at: point, in: playlist.videos)
        }
        if over != overPlaylist || saved != alreadyInPlaylist || zone != hoveredZone {
            withAnimation(.snappy(duration: 0.18)) {
                overPlaylist = over
                alreadyInPlaylist = saved
                hoveredZone = zone
            }
        }
        if y != indicatorY {
            withAnimation(indicatorY == nil || y == nil ? nil : .snappy(duration: 0.12)) { indicatorY = y }
        }
        dropIndex = index
    }

    /// Index to insert at, and where to draw the line, from the visible rows' frames.
    private func insertionPoint(at point: CGPoint, in videos: [PlaylistVideo]) -> (Int, CGFloat?) {
        let visible = videos.enumerated().compactMap { offset, video -> (Int, CGRect)? in
            guard let frame = rowFrames[video.key], frame.intersects(playlistFrame) else { return nil }
            return (offset, frame)
        }.sorted { $0.1.minY < $1.1.minY }
        guard let last = visible.last else { return (videos.count, nil) }
        if let target = visible.first(where: { point.y < $0.1.midY }) {
            return (target.0, max(target.1.minY, playlistFrame.minY))
        }
        return (last.0 + 1, min(last.1.maxY, playlistFrame.maxY))
    }

    func end(playlist: PlaylistModel) {
        guard let payload, monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let scroll = hoveredZone.map { PlaylistModel.ScrollRequest(key: "pending:\(payload.videoId)", atTop: $0 == .top) }
        if overPlaylist, !alreadyInPlaylist, let index = dropIndex, playlist.completedIds.contains(payload.videoId) {
            // Already completed: return the card and ask before adding (PlaylistModel.pendingCompletedAdd).
            playlist.requestAdd(payload, at: index, scroll: scroll)
            flyBack()
        } else if overPlaylist, !alreadyInPlaylist, let index = dropIndex {
            let k = DragController.cardSize.width / max(sourceFrame.width, 1)
            let zoneFrame = hoveredZone.flatMap { zoneFrames[$0] }
            let anchor = zoneFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? CGPoint(x: playlistFrame.midX, y: indicatorY ?? location.y)
            let target = CGPoint(x: anchor.x + grabOffset.width * k, y: anchor.y + grabOffset.height * k)
            withAnimation(.snappy(duration: 0.25)) {
                // Show where it went: zone drops scroll the list to the new first/last row.
                playlist.requestAdd(payload, at: index, scroll: scroll)
            }
            // Slide into the insertion point, shrink and fade.
            withAnimation(.easeIn(duration: 0.2)) {
                location = target
                dropping = true
                indicatorY = nil
                overPlaylist = false
                hoveredZone = nil
            }
            finish(after: 0.2)
        } else {
            flyBack()
        }
    }

    /// Return the card to its tile.
    private func flyBack() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            location = startLocation
            lifted = false
            overPlaylist = false
            alreadyInPlaylist = false
            hoveredZone = nil
            indicatorY = nil
        }
        finish(after: 0.3)
    }

    private func finish(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeOut(duration: 0.12)) {
                self.payload = nil
                self.image = nil
            }
            self.dropIndex = nil
            Self.isDragging = false
        }
    }
}

/// Floating card + insertion line, drawn above the whole split view.
struct DragOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let drag = app.drag
            ZStack(alignment: .topLeading) {
                if drag.overPlaylist {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(drag.alreadyInPlaylist ? Color.secondary : Color.accentColor, lineWidth: 3)
                        .frame(width: drag.playlistFrame.width - 8, height: drag.playlistFrame.height - 8)
                        .position(x: drag.playlistFrame.midX - origin.x, y: drag.playlistFrame.midY - origin.y)
                        .transition(.opacity)
                }
                if let y = drag.indicatorY {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, drag.playlistFrame.width - 36), height: 3)
                        .shadow(color: .accentColor.opacity(0.6), radius: 4)
                        .position(x: drag.playlistFrame.midX - origin.x, y: y - origin.y)
                }
                if drag.payload != nil {
                    DragCard(drag: drag)
                        .position(x: drag.location.x - origin.x, y: drag.location.y - origin.y)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

private struct DragCard: View {
    let drag: DragController

    var body: some View {
        let source = drag.sourceFrame.size == .zero ? DragController.cardSize : drag.sourceFrame.size
        let size = drag.lifted ? DragController.cardSize : source
        // Keep the same point of the thumbnail under the cursor while it shrinks.
        let k = size.width / max(source.width, 1)
        ZStack {
            if let image = drag.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: drag.lifted ? 12 : 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let d = drag.payload?.durationText { ThumbBadge(text: d).padding(5) }
        }
        .overlay(alignment: .topTrailing) {
            if drag.overPlaylist {
                Image(systemName: drag.alreadyInPlaylist ? "checkmark.circle.fill" : "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, drag.alreadyInPlaylist ? Color.secondary : Color.accentColor)
                    .font(.title2)
                    .padding(5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(drag.lifted ? 0.35 : 0), radius: drag.lifted ? 16 : 0, y: drag.lifted ? 10 : 0)
        .rotationEffect(.degrees(drag.lifted ? -2.5 : 0))
        .scaleEffect(drag.dropping ? 0.45 : drag.overPlaylist ? 0.94 : 1)
        .opacity(drag.dropping ? 0 : drag.lifted ? 0.96 : 1)
        .offset(x: -drag.grabOffset.width * k, y: -drag.grabOffset.height * k)
    }
}

/// Reference box for geometry that must be readable at gesture time without re-rendering.
final class FrameBox {
    var frame: CGRect = .zero
}

/// Two compact quick-drop zones shown under the playlist while a video is dragged:
/// left adds it to the top of the playlist, right to the bottom.
struct PlaylistDropZones: View {
    var body: some View {
        HStack(spacing: 8) {
            DropZoneTile(zone: .top, symbol: "arrow.up.to.line", label: "Add to top")
            DropZoneTile(zone: .bottom, symbol: "arrow.down.to.line", label: "Add to bottom")
        }
    }
}

private struct DropZoneTile: View {
    @Environment(AppModel.self) private var app
    let zone: DragController.Zone
    let symbol: String
    let label: String

    var body: some View {
        let drag = app.drag
        let hovered = drag.hoveredZone == zone
        let hot = hovered && !drag.alreadyInPlaylist
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: hovered && drag.alreadyInPlaylist ? "checkmark.circle" : symbol)
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.bounce, value: hot)
            Text(hovered && drag.alreadyInPlaylist ? "In playlist" : label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(hot ? Color.white : Color.primary.opacity(0.75))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background {
            shape.fill(hot ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial))
        }
        .overlay {
            shape.strokeBorder(hot ? Color.accentColor : Color.primary.opacity(0.35),
                               style: StrokeStyle(lineWidth: 1.5, dash: hot ? [] : [6, 4]))
        }
        .scaleEffect(hot ? 1.04 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.drag.zoneFrames[zone] = $0 }
        .onDisappear { app.drag.zoneFrames[zone] = nil }
    }
}
