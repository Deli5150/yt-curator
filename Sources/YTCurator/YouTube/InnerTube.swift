import CryptoKit
import Foundation
import OSLog

let log = Logger(subsystem: "com.delvison.ytcurator", category: "youtube")

/// Plain-text diagnostics in Application Support (unified logging drops info-level messages).
enum Diagnostics {
    private static let queue = DispatchQueue(label: "diagnostics")
    static var url: URL { AppPaths.supportDir.appending(path: "diagnostics.log") }

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

struct YouTubeError: LocalizedError, Sendable {
    enum Kind: Sendable { case notSignedIn, rateLimited, http, youtube, network, missingTab, other }
    var kind: Kind
    var message: String
    var errorDescription: String? { message }

    static func other(_ message: String) -> YouTubeError { YouTubeError(kind: .other, message: message) }

    /// Failures worth retrying: rate-limiting, throttled/empty responses, flaky network.
    var isTransient: Bool {
        switch kind {
        case .rateLimited, .network: return true
        case .http: return message.contains("status 5")
        case .youtube: return message.lowercased().contains("does not exist")
        default: return false
        }
    }
}

/// InnerTube request gate. YouTube's unofficial endpoints rate-limit (HTTP 429) when the app
/// fires a burst of calls at once, so every network call funnels through this limiter.
/// It's adaptive: it runs at a brisk pace by default and, on the first 429, pauses everything for
/// a cooldown and then drops to the conservative pace the Glaze app always used (2 at a time,
/// 300ms apart) for a while before trying the fast pace again. A throttled playlist fetch is
/// what surfaces as "The playlist does not exist.".
actor RequestGate {
    struct Pace { var concurrency: Int; var spacing: Duration }
    static let fast = Pace(concurrency: 6, spacing: .milliseconds(80))
    static let safe = Pace(concurrency: 2, spacing: .milliseconds(300))
    /// After a 429, pause ALL requests this long so we don't keep hammering a blocked session.
    static let rateLimitCooldown: Duration = .seconds(30)
    /// How long to stay at the safe pace after a 429.
    static let safeModeDuration: Duration = .seconds(600)

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Served before `waiters`: interactive work (playlist, sync) shouldn't queue behind the feed.
    private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextStart = ContinuousClock.now
    private var rateLimitedUntil = ContinuousClock.now
    private var safeUntil = ContinuousClock.now

    private var pace: Pace { ContinuousClock.now < safeUntil ? Self.safe : Self.fast }

    func acquire(priority: Bool = false) async {
        if active >= pace.concurrency {
            await withCheckedContinuation { c in
                if priority { priorityWaiters.append(c) } else { waiters.append(c) }
            }
        } else {
            active += 1
        }
        let now = ContinuousClock.now
        let start = max(now, nextStart, rateLimitedUntil)
        nextStart = start + pace.spacing
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    func release() {
        active = max(0, active - 1)
        wakeIfRoom()
    }

    /// Hand free slots to queued requests (priority first). Each woken waiter owns one slot, so
    /// a pace change takes effect as slots free up.
    private func wakeIfRoom() {
        while active < pace.concurrency, !(priorityWaiters.isEmpty && waiters.isEmpty) {
            active += 1
            (priorityWaiters.isEmpty ? waiters.removeFirst() : priorityWaiters.removeFirst()).resume()
        }
    }

    func noteRateLimited() {
        let now = ContinuousClock.now
        if now >= safeUntil { Diagnostics.write("gate: 429 — cooling down, then safe pace for 10 min") }
        rateLimitedUntil = now + Self.rateLimitCooldown
        safeUntil = now + Self.rateLimitCooldown + Self.safeModeDuration
    }
}

/// Raw InnerTube transport: WEB client context, cookie + SAPISIDHASH auth.
actor InnerTube {
    static let shared = InnerTube()

    private static let origin = "https://www.youtube.com"
    /// Fallback when the live client version can't be scraped (from youtubei.js 17.2).
    private static let fallbackClientVersion = "2.20260623.01.00"

    let gate = RequestGate()
    private let urlSession: URLSession
    private var clientVersion: String?
    private var visitorData: String?
    private var configCookie: String?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config)
    }

    func reset() {
        clientVersion = nil
        visitorData = nil
        configCookie = nil
    }

    private func cookie() async throws -> String {
        let cookie = await YouTubeSession.shared.cookieHeader()
        guard !cookie.isEmpty else {
            throw YouTubeError(kind: .notSignedIn, message: "Not signed in to YouTube. Sign in first.")
        }
        return cookie
    }

    private static func cookieValue(_ header: String, _ name: String) -> String? {
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix(name + "=") { return String(kv.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /// GFEEDBACK `logged_in` tracking param: whether YouTube treated the request as signed in.
    static func loggedInFlag(_ json: J) -> String? {
        for service in json["responseContext"]["serviceTrackingParams"].array {
            for param in service["params"].array where param["key"].string == "logged_in" {
                return param["value"].string
            }
        }
        return nil
    }

    static func sapisidHash(_ sapisid: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        let input = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }

    /// Scrape the live web client version + visitor data once per session (like youtubei.js
    /// fetching a real session), so authenticated browse isn't rejected for a stale version.
    private func ensureConfig(cookie: String) async {
        if clientVersion != nil, configCookie == cookie { return }
        configCookie = cookie
        var request = URLRequest(url: URL(string: "https://www.youtube.com/?hl=en")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(YouTubeSession.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await urlSession.data(for: request), let html = String(data: data, encoding: .utf8) {
            clientVersion = html.firstMatch(of: /"INNERTUBE_CLIENT_VERSION":"([^"]+)"/).map { String($0.1) }
            visitorData = html.firstMatch(of: /"VISITOR_DATA":"([^"]+)"/).map { String($0.1) }
        }
        if clientVersion == nil { clientVersion = Self.fallbackClientVersion }
        let hasSapisid = Self.cookieValue(cookie, "SAPISID") != nil
        Diagnostics.write("session: clientVersion=\(clientVersion ?? "?") visitorData=\(visitorData != nil) SAPISID=\(hasSapisid)\n\(await YouTubeSession.shared.cookieSummary())")
        log.info("InnerTube client version \(self.clientVersion ?? "?", privacy: .public)")
    }

    /// POST youtubei/v1/<endpoint> through the gate, retrying transient failures.
    func call(_ endpoint: String, _ body: [String: Any], label: String? = nil, priority: Bool = false) async throws -> J {
        let maxAttempts = 3
        var lastError: Error = YouTubeError.other("Request failed")
        for attempt in 1...maxAttempts {
            await gate.acquire(priority: priority)
            do {
                let result = try await perform(endpoint, body)
                await gate.release()
                return result
            } catch let error as YouTubeError {
                await gate.release()
                lastError = error
                if error.kind == .rateLimited { await gate.noteRateLimited() }
                if attempt >= maxAttempts || !error.isTransient { throw error }
                log.warning("\(label ?? endpoint, privacy: .public) transient failure (attempt \(attempt)): \(error.message, privacy: .public)")
                if error.kind != .rateLimited {
                    // The cooldown gate already enforces the wait after a 429.
                    let backoff = 500 * (1 << (attempt - 1)) + Int.random(in: 0..<250)
                    try? await Task.sleep(for: .milliseconds(backoff))
                }
            } catch {
                await gate.release()
                throw error
            }
        }
        throw lastError
    }

    private func perform(_ endpoint: String, _ body: [String: Any]) async throws -> J {
        let cookie = try await cookie()
        await ensureConfig(cookie: cookie)
        let version = clientVersion ?? Self.fallbackClientVersion

        var client: [String: Any] = ["clientName": "WEB", "clientVersion": version, "hl": "en", "gl": "US"]
        if let visitorData { client["visitorData"] = visitorData }
        var payload = body
        payload["context"] = ["client": client, "user": [String: Any]()]

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(YouTubeSession.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let sapisid = Self.cookieValue(cookie, "SAPISID") ?? Self.cookieValue(cookie, "__Secure-3PAPISID") {
            request.setValue(Self.sapisidHash(sapisid), forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw YouTubeError(kind: .network, message: "Network error: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            throw YouTubeError(kind: .rateLimited, message: "YouTube is temporarily rate-limiting requests (429).")
        }
        let json = (try? J(data: data)) ?? J(nil)
        if !(200..<300).contains(status) {
            let detail = json["error"]["message"].string ?? HTTPURLResponse.localizedString(forStatusCode: status)
            Diagnostics.write("\(endpoint) HTTP \(status): \(detail)")
            throw YouTubeError(kind: .http, message: "\(endpoint) failed with status \(status): \(detail)")
        }
        if let alert = Parsers.alertError(json) {
            Diagnostics.write("\(endpoint) \(body["browseId"] ?? "") alert: \(alert) logged_in=\(Self.loggedInFlag(json) ?? "?")")
            throw YouTubeError(kind: .youtube, message: alert)
        }
        return json
    }
}
