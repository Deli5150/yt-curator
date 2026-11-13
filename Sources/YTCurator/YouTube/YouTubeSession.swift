import AppKit
import Foundation
import WebKit

/// YouTube sign-in via the real Google login page in a WKWebView, persisted in a dedicated
/// website data store. The resulting cookies are reused for InnerTube requests.
@MainActor
final class YouTubeSession: NSObject {
    static let shared = YouTubeSession()

    /// Fixed identifier so the persistent store (and the sign-in) survives relaunches.
    private static let storeID = UUID(uuidString: "6C1B7E52-3F0A-4C55-9D7B-2B7C0F1A9E11")!

    /// Safari-like UA reduces Google's "browser may not be secure" blocks in WKWebView.
    nonisolated static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private static let authCookieNames: Set<String> = [
        "SAPISID", "__Secure-1PSID", "__Secure-3PSID", "SID", "SSID", "HSID", "APISID", "LOGIN_INFO",
    ]

    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2F&hl=en")!

    let dataStore = WKWebsiteDataStore(forIdentifier: YouTubeSession.storeID)

    private var loginWindow: NSWindow?
    private var loginContinuations: [CheckedContinuation<Bool, Never>] = []
    private var pollTimer: Timer?
    private var finishing = false

    // MARK: - Cookies

    private func youtubeCookies() async -> [HTTPCookie] {
        let all = await dataStore.httpCookieStore.allCookies()
        return all.filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com") }
    }

    /// Signed in for InnerTube purposes: auth cookies on youtube.com itself. Google's cookies
    /// alone aren't enough — they only reach youtube.com after the SetSID redirect.
    private func hasAuthCookies() async -> Bool {
        await youtubeCookies().contains {
            $0.domain.hasSuffix("youtube.com") && Self.authCookieNames.contains($0.name) && !$0.value.isEmpty
        }
    }

    private func hasGoogleAuthCookies() async -> Bool {
        await youtubeCookies().contains {
            $0.domain.hasSuffix("google.com") && Self.authCookieNames.contains($0.name) && !$0.value.isEmpty
        }
    }

    private var repairWebView: WKWebView?

    /// With a Google session but no youtube.com cookies (sign-in window closed before the
    /// redirect back to YouTube), replay the passive sign-in in a hidden web view. A signed-in
    /// Google account passes straight through SetSID to youtube.com without any UI.
    private func repairYouTubeCookies() async -> Bool {
        guard await hasGoogleAuthCookies() else { return false }
        Diagnostics.write("session: google cookies without youtube.com — replaying passive sign-in")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        repairWebView = webView
        defer { repairWebView = nil }
        webView.load(URLRequest(url: Self.loginURL))
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if await hasAuthCookies() {
                // Let the rest of the youtube.com cookie jar settle.
                try? await Task.sleep(for: .milliseconds(800))
                Diagnostics.write("session: youtube.com cookies restored")
                return true
            }
        }
        Diagnostics.write("session: passive sign-in did not produce youtube.com cookies")
        return false
    }

    /// Cookie header for InnerTube; `.youtube.com` wins over `.google.com` on name collisions.
    func cookieHeader() async -> String {
        let cookies = await youtubeCookies()
        var byName: [String: String] = [:]
        var order: [String] = []
        let google = cookies.filter { !$0.domain.hasSuffix("youtube.com") }
        let youtube = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        for c in google + youtube where !c.value.isEmpty {
            if byName[c.name] == nil { order.append(c.name) }
            byName[c.name] = c.value
        }
        return order.map { "\($0)=\(byName[$0]!)" }.joined(separator: "; ")
    }

    func isLoggedIn() async -> Bool {
        if await hasAuthCookies() { return true }
        return await repairYouTubeCookies()
    }

    /// Cookie names grouped by domain (never values), for the diagnostics log.
    func cookieSummary() async -> String {
        let grouped = Dictionary(grouping: await youtubeCookies(), by: \.domain)
        return grouped.keys.sorted().map { "\($0): \(grouped[$0]!.map(\.name).sorted().joined(separator: ","))" }
            .joined(separator: "\n")
    }

    func logout() async {
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    // MARK: - Login window

    /// Opens the Google sign-in window. Resolves true once auth cookies appear,
    /// false if the user closes the window without signing in.
    func openLogin() async -> Bool {
        if let window = loginWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return await withCheckedContinuation { loginContinuations.append($0) }
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 780), configuration: config)
        webView.customUserAgent = Self.safariUserAgent

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to YouTube"
        window.contentMinSize = NSSize(width: 420, height: 560)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        loginWindow = window
        finishing = false

        dataStore.httpCookieStore.add(self)
        // Cookie change events can lag — poll as well.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkCookies() }
        }

        webView.load(URLRequest(url: Self.loginURL))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        return await withCheckedContinuation { loginContinuations.append($0) }
    }

    private func checkCookies() async {
        guard loginWindow != nil, !finishing, await hasAuthCookies() else { return }
        finishing = true
        // Small delay so YouTube can finish setting the full cookie jar.
        try? await Task.sleep(for: .milliseconds(800))
        finish(true)
    }

    private func finish(_ loggedIn: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        dataStore.httpCookieStore.remove(self)
        let window = loginWindow
        loginWindow = nil
        window?.delegate = nil
        window?.close()
        let waiting = loginContinuations
        loginContinuations = []
        waiting.forEach { $0.resume(returning: loggedIn) }
    }
}

extension YouTubeSession: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.checkCookies() }
    }
}

extension YouTubeSession: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            guard self.loginWindow != nil else { return }
            // Dismissed without completing login — check cookies one last time.
            let ok = await self.isLoggedIn()
            self.finish(ok)
        }
    }
}
