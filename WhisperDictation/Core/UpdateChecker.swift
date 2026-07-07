import AppKit

/// Manual update check. Strictly user-initiated (menu → "Check for Updates…")
/// — the app never phones home on its own. Two probes:
///  1. GitHub's releases API — but unauthenticated API calls are rate-limited
///     PER IP (60/hr), so shared networks/VPNs commonly get 403s.
///  2. Fallback: github.com/…/releases/latest redirects to releases/tag/vX.Y.Z
///     — the final URL carries the version. No API, no JSON, effectively
///     unthrottled. Field failure on a second machine traced to probe 1's
///     fragility; probe 2 makes the check work anywhere github.com loads.
@MainActor
enum UpdateChecker {
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/urihell/whisper-dictation-macos/releases/latest")!
    private static let latestReleasePage =
        URL(string: "https://github.com/urihell/whisper-dictation-macos/releases/latest")!

    static func checkNow() {
        Task {
            let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
            var latest = await latestViaAPI()
            if latest == nil { latest = await latestViaRedirect() }
            guard let latest else {
                OverlayController.shared.toast("⚠️ Couldn't check for updates — try again later")
                return
            }
            if VersionCompare.isNewer(latest.tag, than: current) {
                OverlayController.shared.toast("⬆️ \(latest.tag) is available — opening the download page")
                NSWorkspace.shared.open(latest.page)
            } else {
                OverlayController.shared.toast("✓ You're up to date (v\(current))")
            }
        }
    }

    private static func latestViaAPI() async -> (tag: String, page: URL)? {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.error("Update check: API returned HTTP \(status)\(status == 403 ? " (rate limit — shared IP?)" : "") — trying redirect probe.")
                return nil
            }
            struct Release: Decodable {
                let tag_name: String
                let html_url: String
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let page = URL(string: release.html_url) else { return nil }
            return (release.tag_name, page)
        } catch {
            Log.error("Update check: API request failed (\(error.localizedDescription)) — trying redirect probe.")
            return nil
        }
    }

    /// Rate-limit-proof fallback: HEAD the public releases/latest page and
    /// read the version tag out of the redirect's final URL.
    private static func latestViaRedirect() async -> (tag: String, page: URL)? {
        var request = URLRequest(url: latestReleasePage)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let final = http.url else {
                Log.error("Update check: redirect probe returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1).")
                return nil
            }
            let tag = final.lastPathComponent
            // Sanity: we must have landed on releases/tag/<version>. Landing
            // back on "latest" (no releases) or elsewhere isn't a version.
            guard tag != "latest", tag.hasPrefix("v") || (tag.first?.isNumber ?? false) else {
                Log.error("Update check: redirect probe landed on \(final.absoluteString) — no version tag.")
                return nil
            }
            Log.info("Update check: redirect probe found \(tag).")
            return (tag, final)
        } catch {
            Log.error("Update check: redirect probe failed (\(error.localizedDescription)).")
            return nil
        }
    }
}
