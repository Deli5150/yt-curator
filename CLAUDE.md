# YT Curator (native macOS)

SwiftUI port of the Glaze app at `~/Glaze/YT Curator/sources` (React + youtubei.js). Curates one
YouTube playlist: browse saved channels (grouped into loadouts), stage add/remove/reorder edits
locally, then Sync them to the real playlist. YouTube access is deliberately **unofficial**: no
Data API, no OAuth. Sign-in is the real Google page in a WKWebView; its cookies drive raw InnerTube
(`youtubei/v1/*`) calls with a SAPISIDHASH header.

## Build / run
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` / `swift test`
- `scripts/bundle.sh [--install]` → `build/YT Curator.app` (ad-hoc signed), optionally copied to `/Applications`.
- Swift 5 language mode + `BareSlashRegexLiterals`; macOS 26+ (Liquid Glass APIs).

## Layout
- `YouTube/InnerTube.swift` — transport, WEB client context (version scraped from youtube.com, fallback
  constant), adaptive `RequestGate`: fast pace (6 concurrent, 80ms) until the first 429, then a 30s
  cooldown and the Glaze-era safe pace (2 concurrent, 300ms) for 10 minutes. Priority lane for
  user-initiated requests. Measured 2026-11-12: 249-channel cold feed 176.6s → 30.3s, no 429s.
  Home feed fetches 1 page per channel (FeedModel.maxPages).
- `YouTube/YouTubeClient.swift` — every endpoint + the sync algorithm. `YouTube/Parsers.swift` — the
  only code that knows response shapes. If YouTube changes shapes, only these two files should change.
- `Store/` — `AppStore` (app-data.json, same JSON shape as Glaze; imported from Glaze on first launch),
  `LocalState` (staged edits / completed / known-member baselines as JSON files), `FeedCache`, `VideoSort`.
- `Features/` — `AppModel` (+ `PlaylistModel`, `FeedModel`), views and sheets.

Data: `~/Library/Application Support/YT Curator/` (app-data.json, state/). Cache: `~/Library/Caches/com.delvison.ytcurator/`.

## InnerTube notes (carried over from the Glaze app's history)
- Channel tabs are browsed directly with tab params (`EgZ2aWRlb3PyBgQKAjoA` videos,
  `EgdzdHJlYW1z8gYECgJ6AA==` streams). A channel without a Live tab returns its Home tab selected →
  treat as an empty page, not an error.
- Force the "Latest" chip when a tab defaults to Popular, or recent uploads fall past the page budget.
- Items come as legacy renderers or `lockupViewModel`; parsers handle both. Continuations arrive in
  `onResponseReceivedActions` or `onResponseReceivedEndpoints`.
- Sync = remove (ACTION_REMOVE_VIDEO by setVideoId) → add (ACTION_ADD_VIDEO) → re-fetch to map
  videoIds to setVideoIds → **one ACTION_MOVE_VIDEO_AFTER per request** (batched moves only partially
  apply because YouTube evaluates them against the initial snapshot) → up to 3 verify passes.
- "The playlist does not exist." alerts are usually throttling, so they count as transient and retry.
- Fixtures in `Tests/YTCuratorTests/Fixtures` are real unauthenticated responses (mkbhd); refresh them
  when parsers break.
