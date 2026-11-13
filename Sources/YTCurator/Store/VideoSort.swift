import Foundation

/// Client-side sort/filter modes (port of renderer/lib/video-sort.ts).
enum SortMode: String, CaseIterable, Identifiable {
    case latest, oldest, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .latest: "Latest to oldest"
        case .oldest: "Oldest to latest"
        case .week: "Last week"
        case .month: "Last month"
        }
    }
}

enum VideoSort {
    private static let second: TimeInterval = 1
    private static let minute = 60 * second
    private static let hour = 60 * minute
    private static let day = 24 * hour
    private static let week = 7 * day
    private static let month = 30 * day
    private static let year = 365 * day

    private static let unitSeconds: [String: TimeInterval] = [
        "second": second, "sec": second, "s": second,
        "minute": minute, "min": minute, "m": minute,
        "hour": hour, "hr": hour, "h": hour,
        "day": day, "d": day,
        "week": week, "wk": week, "w": week,
        "month": month, "mo": month,
        "year": year, "yr": year, "y": year,
    ]

    /// Parses "3 days ago", "Streamed 2 weeks ago" and the abbreviated "4h ago" form, anywhere in
    /// the string. Multi-letter units come before single letters so "month" isn't read as "m".
    static func relativeAge(_ text: String?) -> TimeInterval? {
        guard let text,
              let match = text.firstMatch(of: /(?i)(\d+)\s*(second|minute|month|hour|week|year|day|sec|min|mo|hr|wk|yr|s|m|h|d|w|y)s?\s*ago\b/),
              let amount = Double(match.1),
              let unit = unitSeconds[match.2.lowercased()] else { return nil }
        return amount * unit
    }

    /// Newest-first by relative age; unparseable timestamps sink to the bottom (stable).
    static func newestFirst(_ videos: [ChannelVideo]) -> [ChannelVideo] {
        videos.enumerated().sorted { a, b in
            switch (relativeAge(a.element.publishedText), relativeAge(b.element.publishedText)) {
            case let (x?, y?): x == y ? a.offset < b.offset : x < y
            case (nil, nil): a.offset < b.offset
            case (nil, _): false
            case (_, nil): true
            }
        }.map(\.element)
    }

    static func apply(_ videos: [ChannelVideo], _ mode: SortMode) -> [ChannelVideo] {
        switch mode {
        case .latest: return videos
        case .oldest: return videos.reversed()
        case .week, .month:
            let maxAge = mode == .week ? week : month
            return videos.filter { (relativeAge($0.publishedText) ?? .infinity) <= maxAge }
        }
    }

    static func emptyMessage(tab: ChannelTab, mode: SortMode, total: Int) -> String {
        let noun = tab == .videos ? "videos" : "live streams"
        if total == 0 { return "No \(noun) on this channel." }
        switch mode {
        case .week: return "No \(noun) in the last week."
        case .month: return "No \(noun) in the last month."
        default: return "No \(noun) on this channel."
        }
    }
}
