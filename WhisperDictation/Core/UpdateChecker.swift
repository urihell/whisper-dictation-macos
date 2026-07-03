import AppKit

/// Manual update check against the GitHub releases API. Strictly
/// user-initiated (menu → "Check for Updates…") — the app never phones home
/// on its own, keeping the privacy posture intact. Proper auto-updates
/// (Sparkle) stay blocked on a Developer ID; see tasks/todo.md.
@MainActor
enum UpdateChecker {
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/urihell/whisper-dictation-macos/releases/latest")!

    static func checkNow() {
        Task {
            do {
                var request = URLRequest(url: latestReleaseAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                struct Release: Decodable {
                    let tag_name: String
                    let html_url: String
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
                if VersionCompare.isNewer(release.tag_name, than: current) {
                    OverlayController.shared.toast(
                        "⬆️ \(release.tag_name) is available — opening the download page"
                    )
                    if let page = URL(string: release.html_url) {
                        NSWorkspace.shared.open(page)
                    }
                } else {
                    OverlayController.shared.toast("✓ You're up to date (v\(current))")
                }
            } catch {
                Log.error("Update check failed: \(error.localizedDescription)")
                OverlayController.shared.toast("⚠️ Couldn't check for updates — try again later")
            }
        }
    }
}
