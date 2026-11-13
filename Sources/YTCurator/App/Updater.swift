import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// In-app updater. New versions are GitHub Releases on the public repo (published by
/// scripts/release.sh), each carrying `YT-Curator-<version>-mac.zip`. The app is ad-hoc signed,
/// so it installs updates itself: download, check the SHA-256 GitHub reports, unzip, swap the
/// running .app for the new one, and relaunch.
@MainActor
@Observable
final class Updater {
    static let repo = "Deli5150/yt-curator"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    private static let checkInterval: TimeInterval = 6 * 3600

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var assetURL: URL
        var assetSize: Int
        var sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Set when a check finds a newer version, to show the update sheet.
    var presentedRelease: Release?
    /// Result of a "Check for Updates…" that found nothing new (or failed), for an alert.
    var checkMessage: String?
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "skippedUpdateVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedUpdateVersion") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Only a real .app bundle can replace itself (not `swift run`).
    static var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static var workDir: URL { AppPaths.cacheDir.appending(path: "update", directoryHint: .isDirectory) }
    private static var oldBundle: URL { Bundle.main.bundleURL.deletingPathExtension().appendingPathExtension("app.old") }

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    /// Clean up after the last update and start periodic checks.
    func start() {
        try? FileManager.default.removeItem(at: Self.workDir)
        if Self.canInstall { try? FileManager.default.removeItem(at: Self.oldBundle) }
        guard Self.canInstall else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.autoCheck == true { await self?.check(userInitiated: false) } }
        }
        if autoCheck {
            Task {
                try? await Task.sleep(for: .seconds(5))
                await check(userInitiated: false)
            }
        }
    }

    // MARK: - Check

    /// Background checks stay quiet unless there's an update the user hasn't skipped;
    /// "Check for Updates…" always reports the result.
    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            var request = URLRequest(url: Self.latestAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("GitHub returned status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let release = Self.parse(data) else { throw UpdateError("The latest release has no Mac download.") }
            if Self.compare(release.version, Self.currentVersion) > 0 {
                state = .available(release)
                // Test hook for end-to-end update runs without UI input (see CLAUDE.md).
                if ProcessInfo.processInfo.environment["YTCURATOR_AUTO_INSTALL_UPDATE"] == "1" {
                    await downloadAndInstall(release)
                    return
                }
                if userInitiated || release.version != skippedVersion { presentedRelease = release }
            } else {
                state = .upToDate
                if userInitiated { checkMessage = "YT Curator \(Self.currentVersion) is the newest version." }
            }
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            if userInitiated { checkMessage = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? J(data: data), let tag = json["tag_name"].string,
              let page = json["html_url"].string.flatMap(URL.init(string:)) else { return nil }
        if json["draft"].bool == true || json["prerelease"].bool == true { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assetName = "YT-Curator-\(version)-mac.zip"
        guard let asset = json["assets"].array.first(where: { $0["name"].string == assetName }),
              let url = asset["browser_download_url"].string.flatMap(URL.init(string:)) else { return nil }
        let digest = asset["digest"].string.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, notes: json["body"].string ?? "", page: page,
                       assetURL: url, assetSize: asset["size"].int ?? 0, sha256: digest)
    }

    /// Negative when a < b. "v1.2.10" → [1, 2, 10]; anything after "-" is ignored.
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            let core = (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: "-").first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d }
        }
        return 0
    }

    func skip(_ release: Release) {
        skippedVersion = release.version
        presentedRelease = nil
    }

    // MARK: - Download & install

    func downloadAndInstall(_ release: Release) async {
        guard Self.canInstall else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading(release, progress: 0)
        do {
            let zip = try await download(release)
            state = .installing(release)
            try await install(zip: zip)
            relaunch()
        } catch {
            state = .failed("Couldn't install the update: \(error.localizedDescription). You can download it from the release page instead.")
        }
    }

    private func download(_ release: Release) async throws -> URL {
        try? FileManager.default.removeItem(at: Self.workDir)
        try FileManager.default.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        let destination = Self.workDir.appending(path: release.assetURL.lastPathComponent)

        let (bytes, response) = try await URLSession.shared.bytes(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("download failed") }
        let expected = max(release.assetSize, Int(response.expectedContentLength), 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
                let progress = Double(received) / Double(expected)
                if progress - lastReported > 0.01 {
                    lastReported = progress
                    state = .downloading(release, progress: min(progress, 1))
                }
            }
        }
        try handle.write(contentsOf: buffer)
        hasher.update(data: buffer)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let sha = release.sha256, sha.lowercased() != digest {
            throw UpdateError("the download didn't match its checksum")
        }
        return destination
    }

    private func install(zip: URL) async throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("\(target.deletingLastPathComponent().path) can't be changed by your account")
        }
        let unpacked = Self.workDir.appending(path: "unpacked")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let name = try FileManager.default.contentsOfDirectory(atPath: unpacked.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("the update has no app in it")
        }
        let next = unpacked.appending(path: name)
        try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", next.path])
        // Refuse anything that doesn't look like this app.
        guard Bundle(url: next)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("the update is a different app")
        }

        let old = Self.oldBundle
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: target, to: old)
        do {
            try FileManager.default.moveItem(at: next, to: target)
        } catch {
            // Different volume: copy instead; put the old app back if that fails too.
            do {
                try await Self.run("/usr/bin/ditto", [next.path, target.path])
            } catch {
                try? FileManager.default.moveItem(at: old, to: target)
                throw error
            }
        }
        Diagnostics.write("update: installed \(Bundle(url: target)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") over \(Self.currentVersion)")
    }

    /// Reopen the (now replaced) bundle once this process has exited, then quit.
    private func relaunch() {
        let target = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n '\(target)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() } else {
                    continuation.resume(throwing: UpdateError("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct UpdateSheet: View {
    @Environment(AppModel.self) private var app
    let release: Updater.Release

    private var updater: Updater { app.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YT Curator \(release.version) is available").font(.title3.bold())
                    Text("You have \(Updater.currentVersion).").foregroundStyle(.secondary)
                }
            }
            if !release.notes.isEmpty {
                ScrollView {
                    Text(LocalizedStringKey(release.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 180)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            status
            HStack {
                Button("Skip This Version") { updater.skip(release) }
                    .disabled(busy)
                Spacer()
                Button("Later") { updater.presentedRelease = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(Updater.canInstall ? "Install and Relaunch" : "Open Release Page") {
                    Task { await updater.downloadAndInstall(release) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(busy)
    }

    private var busy: Bool {
        switch updater.state {
        case .downloading, .installing: true
        default: false
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .downloading(_, let progress):
            ProgressView(value: progress) { Text("Downloading…").font(.caption) }
        case .installing:
            ProgressView { Text("Installing…").font(.caption) }
        case .failed(let message):
            HStack(alignment: .top) {
                Text(message).font(.caption).foregroundStyle(.red)
                Spacer()
                Link("Release page", destination: release.page).font(.caption)
            }
        default:
            EmptyView()
        }
    }
}

struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var updater = app.updater
        Section("Updates") {
            LabeledContent("Version", value: Updater.currentVersion)
            Toggle("Check for updates automatically", isOn: $updater.autoCheck)
            HStack {
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch app.updater.state {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let r): "Version \(r.version) available"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .failed: "Check failed"
        }
    }
}
