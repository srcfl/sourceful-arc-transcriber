import Foundation
import AppKit
import Combine

/// Polls the project's GitHub Releases feed and — on user confirmation —
/// swaps the running `.app` bundle with the latest release, then
/// relaunches. Modelled on the pattern in `srcful-nova-app/cmd/nova/
/// updater.go` (custom GH API poll, zip asset, in-place replace).
@MainActor
final class AutoUpdater: ObservableObject {

    // Match this to the actual GitHub repo the releases live on.
    private let owner = "srcfl"
    private let repo  = "sourceful-arc-transcriber"

    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseNotes: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var assetURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckError: String?

    /// Auto-check timer. Separate from `check()` so callers can run a
    /// one-off check on-demand (menu item) without restarting the loop.
    private var checkTask: Task<Void, Never>?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.semverGreater(latest, than: currentVersion)
    }

    /// Start the periodic check loop: fires immediately, then every
    /// 6 hours while the app is running.
    func startPeriodicChecks() {
        checkTask?.cancel()
        checkTask = Task { @MainActor [weak self] in
            // Small delay on launch so the UI settles first.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func stopPeriodicChecks() {
        checkTask?.cancel()
        checkTask = nil
    }

    func check() async {
        isChecking = true
        lastCheckError = nil
        defer { isChecking = false }

        let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // 404 is expected when the repo has no releases yet.
                if http.statusCode != 404 {
                    lastCheckError = "GitHub returned \(http.statusCode)"
                }
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let tag = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            latestVersion = tag
            releaseNotes = release.body
            releaseURL = URL(string: release.html_url)
            assetURL = release.assets
                .first(where: { $0.name.hasSuffix(".zip") })
                .flatMap { URL(string: $0.browser_download_url) }
        } catch {
            lastCheckError = (error as NSError).localizedDescription
        }
    }

    /// Download the latest release zip, extract, swap the current
    /// `.app` in place, and relaunch. Returns when the install script
    /// is spawned — the app then terminates.
    func downloadAndInstall() async throws {
        guard let asset = assetURL else { throw Failure.noAsset }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sat-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 1. Download
        let (tmpZip, _) = try await URLSession.shared.download(from: asset)
        let zipPath = tempDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmpZip, to: zipPath)

        // 2. Extract
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try Self.runProcess("/usr/bin/unzip", args: ["-q", zipPath.path, "-d", extractDir.path])

        // 3. Locate the .app inside the extracted tree
        let newApp = try Self.findAppBundle(in: extractDir)
        let currentApp = Bundle.main.bundleURL

        // 4. Write a bash helper that waits for us to quit, swaps the
        //    bundles, and relaunches. Spawned detached; we exit below.
        let script = """
        #!/bin/bash
        set -e
        CURRENT='\(currentApp.path)'
        NEW='\(newApp.path)'

        # Wait for the current binary to exit
        for i in {1..40}; do
          if ! pgrep -f "$CURRENT/Contents/MacOS/" > /dev/null; then break; fi
          sleep 0.25
        done
        sleep 0.5

        BACKUP="${CURRENT}.old-$(date +%s)"
        /bin/mv "$CURRENT" "$BACKUP"
        /bin/mv "$NEW" "$CURRENT" || { /bin/mv "$BACKUP" "$CURRENT"; exit 1; }
        /bin/rm -rf "$BACKUP"

        /usr/bin/open "$CURRENT"
        """
        let scriptURL = tempDir.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )

        // 5. Spawn detached and quit. The helper handles the rest.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        try proc.run()

        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    enum Failure: Error, LocalizedError {
        case noAsset
        case noBundleFound

        var errorDescription: String? {
            switch self {
            case .noAsset:        return "Release has no .zip asset to install."
            case .noBundleFound:  return "Could not find a .app bundle in the downloaded update."
            }
        }
    }

    private static func runProcess(_ path: String, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "AutoUpdater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(path) exited with \(p.terminationStatus)"])
        }
    }

    private static func findAppBundle(in dir: URL) throws -> URL {
        // Depth-1 search — zips from our CI put the bundle at the root.
        let items = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        if let direct = items.first(where: { $0.pathExtension == "app" }) {
            return direct
        }
        for nested in items where (try? nested.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let app = try? findAppBundle(in: nested) { return app }
        }
        throw Failure.noBundleFound
    }

    /// `a > b` comparing dotted semver (major.minor.patch, ignoring
    /// anything after). "0.1.0" > "0.0.9", "1.0.0" > "0.9.9".
    private static func semverGreater(_ a: String, than b: String) -> Bool {
        let parse: (String) -> [Int] = { s in
            let stripped = s.split(separator: "-").first.map(String.init) ?? s   // drop pre-release
            return stripped.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        }
        let pa = parse(a) + [0, 0, 0]
        let pb = parse(b) + [0, 0, 0]
        for i in 0..<3 {
            if pa[i] != pb[i] { return pa[i] > pb[i] }
        }
        return false
    }

    // MARK: - GH decode

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }
}
