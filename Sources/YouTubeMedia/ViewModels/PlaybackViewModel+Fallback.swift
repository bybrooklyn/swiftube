@preconcurrency import AVFoundation
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif
import YouTubeCore

private typealias VideoFormat = YouTubeCore.VideoFormat

private let playerLog = DiagnosticsLogger(category: "Player")

/// Client-specific HLS settings used for both initial playback and quality changes.
struct HLSPlaybackPolicy: Equatable, Sendable {
    let userAgent: String
    let maximumHeight: Int?
    let filtersMasterManifest: Bool
    let requiresH264: Bool

    static func resolve(label: String, isHLS: Bool) -> Self {
        guard isHLS else {
            // A progressive (muxed/DASH) URL is signed for the client that asked
            // for it, and the CDN checks the User-Agent against that signature.
            // This branch used to hand back the iOS UA for every non-HLS URL
            // whatever the client, so an `c=ANDROID_VR` muxed URL — the one
            // client here that returns a plain playable MP4 — was fetched with
            // the wrong UA and came back `HTTP 403: Forbidden`, while the same
            // URL probed with the matching UA returned 206. Match the label.
            let ua: String
            if label.localizedCaseInsensitiveContains("androidvr") {
                ua = InnerTubeClients.AndroidVR.userAgent
            } else if label.localizedCaseInsensitiveContains("visionos") {
                ua = InnerTubeClients.VisionOS.userAgent
            } else if label.contains("WebSafari") {
                ua = InnerTubeClients.WebSafari.userAgent
            } else {
                ua = "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)"
            }
            return Self(
                userAgent: ua,
                maximumHeight: nil,
                filtersMasterManifest: false,
                requiresH264: false
            )
        }
        if label.localizedCaseInsensitiveContains("visionos") {
            return Self(
                userAgent: InnerTubeClients.VisionOS.userAgent,
                maximumHeight: InnerTubeClients.VisionOS.maximumHLSHeight,
                filtersMasterManifest: true,
                requiresH264: true
            )
        }
        if label.contains("WebSafari") {
            return Self(
                userAgent: InnerTubeClients.WebSafari.userAgent,
                maximumHeight: nil,
                filtersMasterManifest: false,
                requiresH264: false
            )
        }
        return Self(
            userAgent: "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)",
            maximumHeight: nil,
            filtersMasterManifest: false,
            requiresH264: false
        )
    }

    func cappedHeight(requested: Int?) -> Int? {
        guard let maximumHeight else { return requested }
        return min(requested ?? maximumHeight, maximumHeight)
    }

    func allowsFormat(height: Int, mimeType: String) -> Bool {
        if let maximumHeight, height > maximumHeight { return false }
        if requiresH264, !mimeType.contains("avc1") { return false }
        return true
    }
}

// MARK: - Exhaustive Playback Retry

extension PlaybackViewModel {

    // MARK: - Entry Points

    /// Main retry entry point. Called whenever the primary iOS stream fails.
    ///
    /// Strategy:
    ///   Phase 0 — Authenticated TV client: when logged in, the TV client with
    ///             `html5Preference: HTML5_PREF_WANTS` returns `streamingData` including
    ///             an `hlsManifestUrl`. Authenticated HLS URLs bypass rqh=1 CDN enforcement
    ///             and enable quality switching via AVPlayer ABR. Skipped if not logged in.
    ///   Phase 1 — TV embedded (TVHTML5_SIMPLY_EMBEDDED_PLAYER): returns HLS for most
    ///             embeddable videos without pot/rqh=1 restriction.
    ///   Phase 2 — try HLS + adaptive from iOS and Android clients in order.
    ///   Phase 3 — Android VR (Oculus Quest client, nameID=28): per yt-dlp research, this
    ///             client is exempt from the PO-token / rqh=1 requirement on adaptive streams.
    ///             Correct VR headers (nameID=28, Oculus UA on googleapis.com) are required.
    ///   Phase 4 — if all adaptive attempts fail, fall back to the Android muxed 360p stream.
    ///   The entire cycle repeats up to 3 times to survive transient network errors.
    /// Wall-clock budget for one `exhaustiveRetry` run, across every rung.
    ///
    /// Generous enough that the rungs which actually work on macOS — VisionOS
    /// HLS first, then the TV client — get their full chance, and short enough
    /// that a video which is never going to play says so while the user is still
    /// watching the screen.
    static let retryLadderBudgetSeconds: Double = 45

    func exhaustiveRetry(video: Video, originalError: Error?, playerInfo: PlayerInfo? = nil, cached: CachedVideoData? = nil) async {
        // Release the task handle when the ladder finishes. Nothing else did:
        // only stop() and load() cleared `exhaustiveRetryTask`, so after the
        // first stall-driven escalation the `== nil` guard in setupRateObserver
        // stayed false for the rest of the video and every later stall loop was
        // silently ignored. A cancelled run leaves the handle alone — whoever
        // cancelled it has already replaced or cleared it.
        defer { if !Task.isCancelled { exhaustiveRetryTask = nil } }
        // Testing override: --uitesting-force-stream-method restricts the retry to a
        // single named client so UI tests can probe one path at a time.
        if let method = StreamMethodProbeSupport.forcedStreamMethod {
            await probeStreamMethod(method, video: video)
            return
        }
        // An overall budget for the whole ladder.
        //
        // Every rung has its own timeout but there was no cap across them, and no
        // backoff between the three attempt passes. Adding the documented
        // per-rung budgets up gives a worst case around nine minutes of spinner
        // before the give-up tail — dominated by two 40 s WebView extractions, a
        // BotGuard wait, and three passes over seven clients. Past the deadline
        // the remaining rungs are skipped and the user is told, which is a far
        // better outcome than a spinner nobody will wait out.
        //
        // Checked at the rungs that cost real time, not on every line: a rung
        // already in flight is allowed to finish, since it may be the one that
        // works.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.retryLadderBudgetSeconds))
        func ladderExpired(_ phase: String) -> Bool {
            guard ContinuousClock.now >= deadline else { return false }
            playerLog.notice("[ladder] budget of \(Self.retryLadderBudgetSeconds)s exhausted before \(phase) — giving up")
            return true
        }

        // VISIONOS is yt-dlp's primary JS-less Apple client: after seeding a
        // normal YouTube webpage session it returns **token-free HLS** with
        // H.264 through 1080p, which AVPlayer handles natively.
        //
        // This was `#if os(tvOS)`, added on the reasoning that tvOS cannot use
        // the WKWebView/BotGuard recovery that iOS and macOS can. That reasoning
        // held only while the macOS recovery worked. It does not: every path it
        // offers ends in `rqh=1`, and rqh is enforced by *position* — playback
        // dies at byte 3,276,800 whether the range is asked for by header or by
        // query, on a re-signed URL, or with a minted `pot=` token. Token-free
        // HLS has no such wall, and the one client that returns it was the one
        // client compiled out of this build.
        do {
            let visionInfo = try await api.fetchPlayerInfoVisionOS(videoId: video.id)
            if await tryAllStreams(
                video: video,
                info: visionInfo,
                label: "VisionOS",
                skipMuxed: true
            ) {
                playerLog.notice("[VisionOS] ✅ native HLS playback — exhaustiveRetry done")
                return
            }
            playerLog.notice("[VisionOS] HLS/adaptive playback failed — continuing legacy fallbacks")
        } catch {
            playerLog.notice("[VisionOS] player request failed: \(error) — continuing legacy fallbacks")
        }
        // Phase -2: authenticated TV client, first.
        //
        // For a signed-in user this is the path most likely to work — the TV
        // client returns an hlsManifestUrl whose CDN URLs bypass rqh=1
        // enforcement (see the phase notes below). It used to sit at priority 0
        // *inside the attempt loop*, which only runs after the WKWebView race
        // and the serial extraction have both given up. Measured on this
        // machine that is two 40 s timeouts: the client with the best chance of
        // playing was tried 80 s in, long after the user has concluded the app
        // is broken.
        //
        // Trying it up front costs one request when it fails, and skips the
        // whole recovery chain when it works.
        if hasAuthToken {
            do {
                let tvInfo = try await api.fetchPlayerInfoAuthenticated(videoId: video.id)
                if await tryAllStreams(video: video, info: tvInfo, label: "TVAuth", skipMuxed: true) {
                    playerLog.notice("[TVAuth] ✅ authenticated TV playback — exhaustiveRetry done")
                    return
                }
                playerLog.notice("[TVAuth] streams failed — continuing recovery chain")

                // Take the muxed stream now, not two minutes from now.
                //
                // There is already a muxed last resort, but it sits past three
                // rounds of the whole recovery chain — measured here, roughly
                // two minutes of black screen, which is indistinguishable from
                // a broken app. Meanwhile this very response already carries a
                // progressive itag-18 track with a plain URL that AVPlayer
                // plays natively, and no other path on this machine has ever
                // resolved a stream (rqh=1 stalls `loadTracks`, WEB comes back
                // cipher-protected).
                //
                // So the trade is not "360p or 1080p", it is "360p now or a
                // black screen": exactly the reasoning that moved TVAuth itself
                // up to Phase -2. `tvInfo` is reused, so this costs no request.
                // The chain below still runs when muxed is absent or fails.
                if await tryAllStreams(video: video, info: tvInfo,
                                       label: "TVAuth/muxed-early", skipMuxed: false) {
                    playerLog.notice("[TVAuth/muxed-early] ✅ playing muxed stream — exhaustiveRetry done")
                    return
                }
                playerLog.notice("[TVAuth/muxed-early] muxed unavailable — continuing recovery chain")

                // TVAuth's muxed URL turns out to be a SABR URL (c=TVHTML5),
                // which is not a playable MP4 — measured, not assumed. The
                // ANDROID_VR response is the one that carries a genuine
                // progressive itag-18 track with a plain URL, and it is already
                // treated as rqh-exempt further down the chain. So ask it
                // directly, still ahead of the long recovery race.
                if let vrInfo = try? await api.fetchPlayerInfoAndroidVR(videoId: video.id),
                   await tryAllStreams(video: video, info: vrInfo,
                                       label: "AndroidVR/muxed-early", skipMuxed: false) {
                    playerLog.notice("[AndroidVR/muxed-early] ✅ playing muxed stream — exhaustiveRetry done")
                    return
                }
                playerLog.notice("[AndroidVR/muxed-early] muxed unavailable — continuing recovery chain")
            } catch {
                playerLog.error("[TVAuth] player request failed: \(String(describing: error)) — continuing recovery chain")
            }
        }

        #if canImport(WebKit)
        if ladderExpired("the cached-HLS shortcut") { return giveUp(video: video) }
        // Phase -1a: Cached WKWebView HLS URL shortcut — skip 5–9 s extraction when the
        // master manifest URL for this video was stored by a prior session or neighbour
        // pre-extraction. Falls through to live WKWebView extraction if the URL has expired
        // or if tryWebViewHLS fails (e.g. 403 on an expired signed URL).
        //
        // Note: for preWarm origin + pot=nil videos (e.g. uN7uKLsGRWw), tryWebViewHLS will
        // fail (~1.32 s) because pfa/1 variant playlist segments need pot= or a warm CDN
        // session. However, this failure is USEFUL: it gives wkHLSEarlyTask (launched by
        // loadAsync concurrently) ~1.78 s of head start so Path B wins immediately after
        // Phase -1a fails. Do NOT skip Phase -1a for preWarm+pot=nil — doing so removes the
        // concurrent overlap and forces Path B to wait the full ~2.17 s alone, costing ~0.6 s.
        if let cachedHLSURL = await VideoPreloadCache.shared.cachedWKHLSURL(for: video.id) {
            playerLog.notice("[wkHLS] cached HLS URL found — probing validity")
            let nSolver = YouTubeWebViewHLSExtractor.shared.extractedNSolver
            // fix21: Read pot= from VideoPreloadCache instead of from the extractor's
            // volatile extractedPoToken field. The extractor resets that field to nil at the
            // START of every new extractHLSURL call; wkHLSEarlyTask triggers that reset
            // before this point, so extractedPoToken is always nil here. The cache entry is
            // written by preWarm() AFTER extraction completes and is only evicted together
            // with the HLS URL itself — so it reliably holds the preWarm-extracted token.
            // fix24: Fall back to InnerTubeAPI's BotGuard-minted token when VideoPreloadCache
            // has no pot=. For videos with no serviceIntegrityDimensions.poToken (e.g.
            // uN7uKLsGRWw), preWarm stores nil in wkHLSPoTokenCache but BotGuard may have
            // minted a valid CDN token during loadAsync's 2 s prefetchPoToken window. Using
            // this token allows the proxy's Step 4 to inject pot= into segment URLs so the
            // CDN accepts them without iOS UA rejection.
            var capturedPoToken = await VideoPreloadCache.shared.cachedPoToken(for: video.id)
            // NOTE: Do NOT fall back to InnerTubeAPI.currentPoToken (BotGuard token, ~107 chars).
            // The BotGuard pot= is for youtubei/v1/player API auth; it is NOT a valid CDN
            // segment token. Injecting it into segment URLs TRIGGERS pot= validation on CDN
            // servers that would otherwise not enforce rqh=1 (returning HTTP 206). The result
            // is that CDN rejects segments with the wrong pot= type (-12753/-12860) even though
            // it would have accepted them with pot=nil. Only WKWebView-player-minted tokens
            // (from serviceIntegrityDimensions.poToken) are valid CDN segment tokens.
            // fix24 fallback removed in fix26.
            // fix25: Skip the HEAD probe if the URL was stored within the last 10 s.
            // The double-prewarm in VideoCardView ensures the cached URL is from a fresh
            // WKWebView session (< 1s old when the heartbeat fires). A fresh URL's CDN
            // session is guaranteed active — probing wastes ~0.22s that the user perceives.
            // For older URLs (> 10s), keep the probe to detect expired manifest URLs early.
            let urlIsFresh = await VideoPreloadCache.shared.isWKHLSURLFresh(for: video.id, within: 10)
            if urlIsFresh {
                playerLog.notice("[wkHLS/fix25] fresh URL (< 10s) — skipping probe")
            }
            let probeValid: Bool
            if urlIsFresh {
                probeValid = true
            } else {
                probeValid = await isWKHLSURLValid(cachedHLSURL)
            }
            if probeValid {
                if await tryWebViewHLS(cachedHLSURL, nSolver: nSolver, poToken: capturedPoToken, skipIfPfa1: true, for: video) {
                    playerLog.notice("[wkHLS] cached URL played — exhaustiveRetry done")
                    if let playerInfo { launchPhase2(video: video, info: playerInfo, cached: cached) }
                    return
                }
                playerLog.notice("[wkHLS] cached URL failed (tryWebViewHLS) — invalidating and falling back to live WKWebView")
                await VideoPreloadCache.shared.invalidateWKHLSURL(for: video.id)
            } else {
                playerLog.notice("[wkHLS] cached URL expired (probe 403/timeout) — invalidating and using live extraction")
                await VideoPreloadCache.shared.invalidateWKHLSURL(for: video.id)
            }
        }
        if ladderExpired("the BotGuard/WebView race") { return giveUp(video: video) }
        startWebViewHLSExtractionIfNeeded(for: video.id)
        // Phase -2 + Phase -1b: race BotGuardWV adaptive path vs WKWebView HLS path.
        //
        // Both paths start simultaneously. They interleave cooperatively at every `await`
        // (suspension point) since both run on @MainActor. Whichever path reaches
        // `readyToPlay` first wins; the other task is cancelled immediately.
        //
        // Path A — BotGuardWV adaptive: waits for BotGuard mint (up to 6 s on cold start,
        //   <5 ms if already warm), probes CDN, tries WEB adaptive / proxy HLS / iOS+Android
        //   adaptive. Fast for videos where the CDN accepts the minted token (~1–2 s).
        //
        // Path B — WKWebView HLS: awaits `wkHLSEarlyTask` (started in loadAsync, already
        //   in-flight). Bypasses the 6 s BotGuard wait on cold starts. Fast for rqh=1 videos
        //   where the CDN probe returns 403 (~3–4 s from loadAsync start).
        //
        // Path C — AndroidVR adaptive: fetches playerInfo via the ANDROID_VR (Oculus Quest)
        //   client, which is CDN-exempt from rqh=1 / pot= token requirements. Runs concurrently
        //   with Path A and B. Expected ~2–3 s cold; beats serial WKWebView extraction (~3–5 s).
        //
        // fix30 (task #230): Pre-fetch TVEmbedded playerInfo in parallel with the race on iOS.
        // If all race paths fail, Phase 1 (TVEmbedded serial) can consume the already-resolved
        // result instead of waiting an additional ~0.5–1 s for a fresh network request.
        // tvOS already starts tvEmbeddedEarlyTask inside tryAllStreams (fix2); on iOS we fire
        // it here so the prefetch begins as soon as the race paths do.
        #if !os(tvOS)
        if tvEmbeddedEarlyTask == nil {
            let prefetchVideoId = video.id
            tvEmbeddedEarlyTask = Task { [weak self] in
                guard let self else { return nil }
                return try? await self.api.fetchPlayerInfoTVEmbedded(videoId: prefetchVideoId)
            }
            playerLog.notice("[TVEmbedded] fix30: started iOS TVEmbedded early pre-fetch alongside race paths")
        }
        #endif
        //
        // Key safety property: all paths are @MainActor, so `player.replaceCurrentItem` and
        // `itemObserverTask` mutations are always serialised. Losing paths' status streams
        // exit via task cancellation.
        var raceWon = false
        var raceWinningPath = 0  // 0=A (BotGuardWV), 1=B (WKWebView HLS), 2=C (AndroidVR)
        await withTaskGroup(of: (Bool, Int).self) { raceGroup in
            // Path A, B, C are @MainActor methods — calling them via `await self.`
            // from these nonisolated closures hops to the main actor for each path.
            // They interleave cooperatively at every `await` suspension point.
            raceGroup.addTask { (await self.racePathA(video: video), 0) }
            raceGroup.addTask { (await self.racePathB(video: video), 1) }
            #if os(tvOS)
            // fix2: Skip racePathC on tvOS. A fresh AndroidVR fetch hits the same rqh=1
            // timeout (2s) for the same video — wasting 2s just to fail again. The
            // TVEmbedded pre-fetch (tvEmbeddedEarlyTask) already runs concurrently from
            // tryAllStreams; Phase 1 will consume it instantly after the race.
            raceGroup.addTask { (false, 2) }
            #else
            raceGroup.addTask { (await self.racePathC(video: video), 2) }
            #endif
            for await (result, path) in raceGroup {
                if result {
                    raceWon = true
                    raceWinningPath = path
                    raceGroup.cancelAll()
                    return
                }
            }
        }
        if raceWon {
            switch raceWinningPath {
            case 1:
                playerLog.notice("✅ [webView] Path B won — WKWebView HLS playing via wkHLSEarlyTask — exhaustiveRetry done")
                // tryWebViewHLS does not call launchPhase2 internally — do it here so Phase 2
                // metadata (nextVideo, endCards, sponsorSegments) is fetched and cached data is used.
                if let playerInfo { launchPhase2(video: video, info: playerInfo, cached: cached) }
            case 2:
                playerLog.notice("[AndroidVR] ✅ Path C won — AndroidVR adaptive — exhaustiveRetry done")
                // attemptComposition already called launchPhase2(vrInfo) with the correct AndroidVR
                // playerInfo. Do NOT call it again — a second call would cancel the first phase2Task
                // and restart it with the stale iOS playerInfo, reverting availableFormats to
                // rqh=1-blocked streams and breaking quality switches.
                //
                // If AndroidVR composed at low quality (maxH < 480 and below user's preferred),
                // schedule a background HLS quality upgrade via TVEmbedded or MWEB while the
                // video is already playing at the lower quality. Does not affect readyToPlay timing.
                let vrMaxH = availableFormats.map(\.height).max() ?? 0
                let preferredH = settings.preferredQuality == .auto
                    ? Self.displayMaxVideoHeight()
                    : (settings.preferredQuality.maxHeight ?? 1080)
                if vrMaxH > 0 && vrMaxH < min(preferredH, 480) {
                    playerLog.notice("[AndroidVR] maxH=\(vrMaxH) < preferred \(min(preferredH, 480))p — scheduling background HLS quality upgrade")
                    let upgradeVideo = video
                    Task { [weak self] in await self?.backgroundQualityUpgrade(video: upgradeVideo) }
                }
            default:
                playerLog.notice("[BotGuardWV] ✅ adaptive streaming via minted BotGuard token — exhaustiveRetry done")
                // attemptComposition / attemptURL already called launchPhase2(webInfo). Same
                // reasoning as Path C: don't override with stale playerInfo.
            }
            return
        }

        // Both race paths failed — fall back to serial WKWebView extraction in case
        // the early task returned nil (e.g. network timeout, JS player error).
        // Skip serial extraction when Path B already hit a CDN permission error — a fresh
        // extraction produces the same CDN-signed URL which will get the same 403.
        // fix235: guard cancellation before expensive serial extraction — the exhaustiveRetry
        // task may have been cancelled by a subsequent load() or stop() call.
        guard !Task.isCancelled else {
            playerLog.notice("⚠️ [webView] race failed but task is cancelled — skipping serial extraction for \(video.id)")
            return
        }
        if wkHLSPermissionDenied {
            playerLog.notice("⚠️ [webView] race Path B hit CDN permission error — skipping serial extraction, going straight to client chain")
        } else {
            playerLog.notice("⚠️ [webView] race failed — attempting serial WKWebView extraction")
            isLoading = true
            retryStatusMessage = "Still loading\u{2026}"
            // Use serialExtract() instead of extractHLSURL() directly: serialExtract awaits any
            // in-flight extraction (for any video) before starting a new one, preventing the
            // cross-video cancellation chain where two concurrent serial callers (for video A and
            // video B) each call extractHLSURL and cancel each other via finish(url:nil).
            let serialURL = await YouTubeWebViewHLSExtractor.shared.serialExtract(videoId: video.id)
            let nSolverSerial = YouTubeWebViewHLSExtractor.shared.extractedNSolver
            if let pot = YouTubeWebViewHLSExtractor.shared.extractedPoToken {
                await api.storeExternalPoToken(pot, for: video.id)
            }
            if let serialURL {
                if await tryWebViewHLS(serialURL, nSolver: nSolverSerial, for: video) {
                    playerLog.notice("✅ [webView] serial WKWebView HLS playing — exhaustiveRetry done")
                    if let playerInfo { launchPhase2(video: video, info: playerInfo, cached: cached) }
                    return
                }
                playerLog.notice("⚠️ [webView] serial HLS load failed — falling through to client retry chain")
            } else {
                playerLog.notice("⚠️ [webView] serial WKWebView extraction returned nil — proceeding with client chain")
            }
        }
        #endif
        if ladderExpired("the client sweep") { return giveUp(video: video) }
        for attempt in 1...3 {
            if attempt > 1, ladderExpired("retry pass \(attempt)") { return giveUp(video: video) }
            guard !Task.isCancelled else { return }
            retryAttempts = attempt
            isLoading = true
            retryStatusMessage = attempt == 1 ? "Trying alternative sources\u{2026}" : "Retrying (\(attempt)/3)\u{2026}"
            playerLog.notice("Exhaustive retry \(attempt)/3 for \(video.id)")

            // Evict the stale cache entry so each attempt gets fresh signed URLs.
            await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)

            // --- Parallel fetch: fire all 7 API calls concurrently ---
            //
            // Each fetchPlayerInfo* is an independent network round-trip (~0.5–1 s).
            // Running them serially added 3.5–7 s of unnecessary latency on every load
            // for videos where the first few clients fail (rqh=1, embedding-disabled, etc.).
            // Running them in parallel collapses that to ~1 s (slowest single fetch).
            //
            // Play strategy:
            //  • HLS results are tried immediately as they arrive — first HLS success wins.
            //  • Non-HLS (adaptive-only) results are queued and tried in priority order
            //    after all fetches complete, so the fastest HLS client always gets priority
            //    regardless of which fetch finished first.
            //
            // Priority (lower = higher priority, mirrors proven probe data 2026-06-05):
            //   0 TVAuth  1 MWEB  2 TVEmbedded  3 WebSafari  4 iOS  5 Android  6 AndroidVR

            // Capture @MainActor state before entering the task group.
            let capturedEarlyTask = tvEmbeddedEarlyTask
            tvEmbeddedEarlyTask = nil
            let capturedHasAuth = hasAuthToken

            // Task group result carrier — @unchecked Sendable because PlayerInfo is accessed
            // only from @MainActor (the `for await` body runs on the calling actor).
            struct _FR: @unchecked Sendable {
                let priority: Int; let label: String; let info: PlayerInfo; let skipMuxed: Bool
            }
            enum _FO: @unchecked Sendable { case result(_FR); case ipBlocked(Error) }

            var pendingNonHLS: [_FR] = []     // adaptive-only results, tried after all fetches
            var androidInfoForMuxed: PlayerInfo? = nil
            var fetchIPBlockError: Error? = nil
            var parallelPlaySucceeded = false

            await withTaskGroup(of: Optional<_FO>.self) { fetchGroup in

                // 0 — TVAuth (authenticated TV client, HLS)
                if capturedHasAuth {
                    fetchGroup.addTask {
                        do {
                            let info = try await self.api.fetchPlayerInfoAuthenticated(videoId: video.id)
                            return .result(_FR(priority: 0, label: "TVAuth[\(attempt)]", info: info, skipMuxed: true))
                        } catch {
                            // Deliberately not `try?`. This is the phase that is
                            // supposed to carry playback for a signed-in user —
                            // authenticated TV HLS bypasses rqh=1 CDN
                            // enforcement — so when it fails the reason has to be
                            // visible. Swallowing it made TVAuth look like it had
                            // never run at all.
                            playerLog.error("[TVAuth] fetch failed: \(String(describing: error))")
                            return nil
                        }
                    }
                } else {
                    playerLog.notice("[TVAuth] skipped — no auth token on the player")
                }

                // 1 — MWEB (no embedding restriction, no pot= required for HLS)
                fetchGroup.addTask {
                    guard let info = try? await self.api.fetchPlayerInfoMWEB(videoId: video.id) else { return nil }
                    return .result(_FR(priority: 1, label: "MWEB[\(attempt)]", info: info, skipMuxed: true))
                }

                // 2 — TVEmbedded (consume fix2/fix30 pre-fetch if available)
                let earlyTask2 = capturedEarlyTask
                fetchGroup.addTask {
                    if let et = earlyTask2, let info = await et.value {
                        return .result(_FR(priority: 2, label: "TVEmbedded[\(attempt)]", info: info, skipMuxed: true))
                    }
                    guard let info = try? await self.api.fetchPlayerInfoTVEmbedded(videoId: video.id) else { return nil }
                    return .result(_FR(priority: 2, label: "TVEmbedded[\(attempt)]", info: info, skipMuxed: true))
                }

                // 3 — WebSafari (WEB + macOS Safari UA, HLS for embedding-disabled)
                fetchGroup.addTask {
                    guard let info = try? await self.api.fetchPlayerInfoWebSafari(videoId: video.id) else { return nil }
                    return .result(_FR(priority: 3, label: "WebSafari[\(attempt)]", info: info, skipMuxed: true))
                }

                // 4 — iOS (authenticated preferred; IP-block detection)
                let hasAuth4 = capturedHasAuth
                fetchGroup.addTask {
                    do {
                        let info: PlayerInfo
                        if hasAuth4, let auth = try? await self.api.fetchPlayerInfoiOSAuthenticated(videoId: video.id) {
                            info = auth
                        } else {
                            info = try await self.api.fetchPlayerInfo(videoId: video.id)
                        }
                        return .result(_FR(priority: 4, label: "iOS[\(attempt)]", info: info, skipMuxed: true))
                    } catch {
                        if case APIError.ipBlocked = error { return .ipBlocked(error) }
                        return nil
                    }
                }

                // 5 — Android (IP-block detection; saved for muxed fallback)
                fetchGroup.addTask {
                    do {
                        let info = try await self.api.fetchPlayerInfoAndroid(videoId: video.id)
                        return .result(_FR(priority: 5, label: "Android[\(attempt)]", info: info, skipMuxed: true))
                    } catch {
                        if case APIError.ipBlocked = error { return .ipBlocked(error) }
                        return nil
                    }
                }

                // 6 — AndroidVR (CDN-exempt rqh=1, 2s composition timeout)
                fetchGroup.addTask {
                    guard let info = try? await self.api.fetchPlayerInfoAndroidVR(videoId: video.id) else { return nil }
                    return .result(_FR(priority: 6, label: "AndroidVR[\(attempt)]", info: info, skipMuxed: true))
                }

                // Process results as they arrive
                for await maybeOutcome in fetchGroup {
                    guard let outcome = maybeOutcome else { continue }
                    switch outcome {
                    case .ipBlocked(let err):
                        fetchIPBlockError = err
                        fetchGroup.cancelAll()
                        return
                    case .result(let r):
                        // Side-effects that need the concrete label/info
                        if r.label.hasPrefix("iOS[") {
                            await VideoPreloadCache.shared.store(playerInfo: r.info, for: video.id)
                        }
                        if r.label.hasPrefix("Android[") && !r.label.contains("VR") {
                            androidInfoForMuxed = r.info
                        }
                        // HLS present → try immediately; first success wins and cancels rest
                        if r.info.hlsURL != nil {
                            if await tryAllStreams(video: video, info: r.info,
                                                  label: r.label, skipMuxed: r.skipMuxed) {
                                parallelPlaySucceeded = true
                                fetchGroup.cancelAll()
                                return
                            }
                        } else {
                            // No HLS (adaptive/muxed only) → defer until all fetches done
                            pendingNonHLS.append(r)
                        }
                    }
                }
            } // end withTaskGroup

            if parallelPlaySucceeded { return }

            if let ipErr = fetchIPBlockError {
                playerLog.error("❌ IP blocked during parallel fetch (attempt \(attempt)) — \(ipErr)")
                self.error = ipErr
                return
            }
            guard !Task.isCancelled else { return }

            // Try non-HLS results (adaptive-only) in priority order.
            //
            // AndroidVR (priority=6) is skipped when a muxed fallback is available:
            // its 2s loadTracks timeout would delay muxed play with no gain when all
            // other methods already failed. Instead, muxed plays immediately and
            // backgroundQualityUpgrade retries AndroidVR (+ TVEmbedded/MWEB) in the
            // background — upgrading to higher quality while the video is already playing.
            pendingNonHLS.sort { $0.priority < $1.priority }
            let hasMuxedFallback = androidInfoForMuxed?.bestMuxedDownloadURL != nil
            playerLog.notice("[parallel fetch] attempt \(attempt): \(pendingNonHLS.count) non-HLS candidate(s) — trying in priority order (hasMuxed=\(hasMuxedFallback))")
            for candidate in pendingNonHLS {
                guard !Task.isCancelled else { return }
                // Skip AndroidVR when muxed is available — see comment above.
                if hasMuxedFallback && candidate.label.hasPrefix("AndroidVR[") {
                    playerLog.notice("[parallel fetch] skipping \(candidate.label) (muxed available — background upgrade will retry)")
                    continue
                }
                if await tryAllStreams(video: video, info: candidate.info,
                                      label: candidate.label, skipMuxed: candidate.skipMuxed) {
                    return
                }
            }

            guard !Task.isCancelled else { return }

            // --- Muxed direct MP4 (360p last resort) ---
            // Only reached when ALL HLS + adaptive attempts above failed.
            // On success: schedule backgroundQualityUpgrade to try TVEmbedded/MWEB HLS
            // and AndroidVR adaptive in the background while the video is already playing.
            if let androidInfo = androidInfoForMuxed, androidInfo.bestMuxedDownloadURL != nil {
                isLoading = true
                retryStatusMessage = "Using fallback stream\u{2026}"
                playerLog.notice("[Android[\(attempt)]] All adaptive failed — trying muxed fallback")
                if await tryAllStreams(video: video, info: androidInfo,
                                      label: "Android[\(attempt)]/muxed") {
                    // Muxed playing — attempt quality upgrade in background while user watches.
                    let upgradeVideo = video
                    Task { [weak self] in await self?.backgroundQualityUpgrade(video: upgradeVideo) }
                    return
                }
                // Android muxed failed (possibly AVF -11828 "Cannot Open" on SABR/long-video URLs,
                // or URL expiry). Try the Web/iOS client muxed URL as a final rescue path.
                // fetchPlayerInfo() returns iOS-client playerInfo whose muxed URL is
                // CDN-signed with standard MP4 headers, avoiding the TVHTML5 SABR issue.
                playerLog.notice("[Android[\(attempt)]] Muxed failed — trying Web client muxed fallback")
                do {
                    let webInfo = try await api.fetchPlayerInfo(videoId: video.id)
                    if webInfo.bestMuxedDownloadURL != nil {
                        if await tryAllStreams(video: video, info: webInfo,
                                              label: "Web[\(attempt)]/muxed") {
                            return
                        }
                    }
                } catch {
                    playerLog.error("Web client muxed fallback fetch failed (attempt \(attempt)): \(error)")
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Last resort: the authenticated TV client's muxed stream.
        //
        // Phase -2 asks TVAuth for HLS or adaptive and refuses its muxed
        // formats, because muxed is a single low-resolution track with no
        // quality ladder. But when every other client has failed the real
        // choice is not "muxed or 1080p", it is "muxed or a black screen" —
        // and this response is the one thing in the whole chain we know
        // YouTube served us. Measured here: TVAuth returns
        // `HLS=false DASH=false adaptive=false muxed=true`, and it was being
        // thrown away.
        if hasAuthToken, let tvInfo = try? await api.fetchPlayerInfoAuthenticated(videoId: video.id) {
            playerLog.notice("[TVAuth/muxed] every client failed — retrying TVAuth allowing muxed")
            if await tryAllStreams(video: video, info: tvInfo, label: "TVAuth/muxed", skipMuxed: false) {
                playerLog.notice("[TVAuth/muxed] ✅ playing muxed stream — exhaustiveRetry done")
                return
            }
        }

        playerLog.error("❌ All 3 retry attempts exhausted for \(video.id)")
        giveUp(video: video)
    }

    /// The single place the ladder reports defeat, so an early exit on the budget
    /// leaves exactly the state the exhausted path does — and `TVPlayerView` has
    /// one thing to render.
    private func giveUp(video: Video) {
        playerLog.error("[ladder] giving up on \(video.id)")
        error = APIError.unavailable("Unable to play this video")
        retryStatusMessage = "Tried every stream this client can use and none of them played."
        isLoading = false
    }

    // MARK: - Race helpers (called from withTaskGroup in exhaustiveRetry)

    /// Path A of the exhaustiveRetry race: BotGuardWV adaptive / proxy HLS path.
    /// Waits up to 6 s for BotGuard to mint a token, then tries WEB/iOS/Android adaptive.
    /// Returns `true` if a stream reached `readyToPlay`.
    #if canImport(WebKit)
    func racePathA(video: Video) async -> Bool {
        if !BotGuardWebViewRunner.shared.isReady {
            playerLog.notice("[BotGuardWV] waiting up to 6 s for minted token (race Path A)…")
            // A real 6 s budget — `prepare` is bounded only by its own 45 s safety
            // timer and honours no cancellation, so the task-group form this
            // replaced could hold Path A open for the full 45.
            let videoId = video.id
            await withTimeout(seconds: 6) {
                await BotGuardWebViewRunner.shared.prepare(for: videoId)
            }
        }
        guard !Task.isCancelled else { return false }
        guard BotGuardWebViewRunner.shared.isReady else {
            playerLog.notice("[BotGuardWV] not ready after 6 s wait — Path A done")
            return false
        }
        // fix9: SAPISID recovery from WKWebView propagated cookies.
        // BotGuardWebViewRunner.prepare() calls propagateWebViewCookies() which copies
        // youtube.com cookies (including SAPISID) from the WKWebView session into
        // HTTPCookieStorage.shared. On real device, the WKWebView is signed into YouTube
        // (default WKWebsiteDataStore shares cookies with the signed-in browser session)
        // so SAPISID is now in HTTPCookieStorage.shared even when AuthService couldn't get
        // it via OAuthLogin/Multilogin (openid scope missing / old token).
        // Recovering SAPISID here lets postWebSafari use SAPISIDHASH auth → YouTube returns
        // rqh=0 adaptive URLs → CDN probe passes → Path A wins instead of waiting for Path B.
        if await !api.hasSAPISID,
           let webSAPISID = HTTPCookieStorage.shared
               .cookies(for: URL(string: "https://www.youtube.com")!)?.first(where: { $0.name == "SAPISID" })?.value {
            await api.setSAPISID(webSAPISID)
            playerLog.notice("[BotGuardWV] fix9: recovered SAPISID from WKWebView propagated cookies (len=\(webSAPISID.count))")
        }
        let webVD = BotGuardWebViewRunner.shared.webVisitorData
        // fix8: use webVD as the mintToken identifier so the minted pot= token is bound
        // to the WEB session visitorData — the same VD that will be sent in
        // fetchPlayerInfoWebWithPoToken's context.client.visitorData and X-Goog-Visitor-Id.
        // Previously, api.currentVisitorData() (iOS/TV session VD) was used as identifier,
        // causing apiVD ≠ webVD — the CDN tied the streaming URLs to the iOS session but
        // our pot= token was minted for the WEB session, causing HTTP 403 on every segment.
        // If webVD is empty (BotGuard warm-up hasn't fetched guide yet), fall back to apiVD.
        let apiVD = await api.currentVisitorData() ?? ""
        let identifier = webVD.isEmpty ? apiVD : webVD
        guard let mintedToken = await BotGuardWebViewRunner.shared.mintToken(identifier: identifier) else {
            playerLog.notice("[BotGuardWV] ⚠️ mintToken returned nil — Path A done")
            return false
        }
        await api.storeExternalPoToken(mintedToken, for: video.id)
        hasMintedPoToken = true
        playerLog.notice("[BotGuardWV] ✅ minted token (len=\(mintedToken.count) webVD.len=\(webVD.count) apiVD.len=\(apiVD.count) match=\(apiVD == webVD)) — Path A racing WKWebView HLS")
        guard !Task.isCancelled else { return false }
        do {
            let webInfo = try await api.fetchPlayerInfoWebWithPoToken(
                videoId: video.id, visitorData: webVD.isEmpty ? nil : webVD
            )
            let probeURL = webInfo.formats.first(where: {
                $0.mimeType.hasPrefix("video/mp4") && $0.url != nil
            })?.url
            var webProbeStatus: Int? = nil
            if let probeURL {
                let hasRqh = probeURL.absoluteString.contains("rqh=1")
                // Only run the CDN HEAD probe when the URL has rqh=1. The probe is only
                // used to skip tryAllStreams on 403. For non-rqh=1 URLs the CDN serves
                // the stream directly — skipping the probe removes one network round-trip
                // (~0.5–1s) from Path A, helping it win the race against Path B.
                if hasRqh {
                    var req = URLRequest(url: probeURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 1)
                    req.httpMethod = "HEAD"
                    let hasPot = probeURL.absoluteString.contains("pot=")
                    if let (_, resp) = try? await URLSession.shared.data(for: req),
                       let http = resp as? HTTPURLResponse {
                        webProbeStatus = http.statusCode
                        playerLog.notice("[BotGuardWV/WEB probe] CDN HEAD: HTTP \(http.statusCode) — pot=\(hasPot ? "YES" : "NO") rqh=1")
                    }
                } else {
                    playerLog.notice("[BotGuardWV/WEB probe] skipping CDN probe — no rqh=1, proceeding directly")
                }
            }
            guard !Task.isCancelled else { return false }
            if webProbeStatus != 403,
               await tryAllStreams(video: video, info: webInfo, label: "BotGuardWV", skipMuxed: true) {
                playerLog.notice("[BotGuardWV] ✅ Path A won — WEB adaptive")
                return true
            } else if webProbeStatus == 403 {
                playerLog.notice("[BotGuardWV] WEB probe 403 — skipping tryAllStreams + proxy HLS in Path A")
            }
            if webProbeStatus != 403, let hlsURL = webInfo.hlsURL, let proxyURL = hlsURL.proxyURL {
                guard !Task.isCancelled else { return false }
                playerLog.notice("[BotGuardWV] trying HLS via pot= proxy (Path A)")
                let safariUA = InnerTubeClients.WebSafari.userAgent
                let potProxyLoader = YTHLSProxyLoader(ua: safariUA, poToken: mintedToken)
                let asset = AVURLAsset(url: proxyURL)
                asset.resourceLoader.setDelegate(potProxyLoader, queue: DispatchQueue.global(qos: .userInitiated))
                webHLSProxyLoader = potProxyLoader
                let proxyItem = AVPlayerItem(asset: asset)
                proxyItem.audioTimePitchAlgorithm = .spectral
                proxyItem.preferredForwardBufferDuration = 0.5
                player.replaceCurrentItem(with: proxyItem)
                installEndAndStallObservers(for: proxyItem)
                itemObserverTask?.cancel()
                for await st in proxyItem.statusStream {
                    guard !Task.isCancelled else { return false }
                    switch st {
                    case .readyToPlay:
                        playerLog.notice("[benchmark] readyToPlay — BotGuardWV/proxy-HLS — videoId=\(video.id)")
                        timeToPlayMs = Int(Date().timeIntervalSince(videoLoadStartedAt) * 1000)
                        if timeToPlayMs > 4_000 {
                            DiagnosticsLogger.recordSlowVideoLoad(
                                videoId: video.id,
                                elapsedMs: timeToPlayMs,
                                streamType: "BotGuardWV/proxyHLS",
                                hasError: false
                            )
                        }
                        playerLog.notice("[BotGuardWV] ✅ Path A won — proxy HLS")
                        return true
                    case .failed:
                        playerLog.notice("[BotGuardWV] ⚠️ proxy HLS failed: \(proxyItem.error?.localizedDescription ?? "unknown")")
                        break
                    default:
                        continue
                    }
                    break
                }
            }
            guard !Task.isCancelled, webProbeStatus != 403 else { return false }
            playerLog.notice("[BotGuardWV] trying iOS adaptive with WAA minted token (Path A)")
            do {
                let iosInfo = try await api.fetchPlayerInfo(videoId: video.id)
                if await tryAllStreams(video: video, info: iosInfo, label: "BotGuardWV", skipMuxed: true) {
                    playerLog.notice("[BotGuardWV] ✅ Path A won — iOS adaptive")
                    return true
                }
            } catch {
                playerLog.notice("[BotGuardWV] ⚠️ iOS adaptive fetch failed: \(error)")
            }
            guard !Task.isCancelled else { return false }
            playerLog.notice("[BotGuardWV] trying Android adaptive with WAA minted token (Path A)")
            do {
                let androidInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
                if await tryAllStreams(video: video, info: androidInfo, label: "BotGuardWV", skipMuxed: true) {
                    playerLog.notice("[BotGuardWV] ✅ Path A won — Android adaptive")
                    return true
                }
            } catch {
                playerLog.notice("[BotGuardWV] ⚠️ Android adaptive fetch failed: \(error)")
            }
        } catch {
            playerLog.notice("[BotGuardWV] ⚠️ WEB client fetch failed: \(error)")
        }
        playerLog.notice("[BotGuardWV] Path A exhausted — all BotGuardWV attempts failed")
        return false
    }
    #endif // canImport(WebKit)

    /// Starts the WKWebView HLS extraction that Path B of the race awaits.
    ///
    /// This used to run from `loadAsync` on every load (and from `stop()` on
    /// every Back), so the WebView session was paid for even when VisionOS
    /// HLS — the path that actually plays on macOS — succeeded seconds earlier.
    /// It now starts here, only once the ladder has reached the race. Reuses an
    /// in-flight task for the same video when one exists.
    #if canImport(WebKit)
    func startWebViewHLSExtractionIfNeeded(for videoId: String) {
        guard wkHLSEarlyTask == nil else { return }
        wkHLSEarlyTaskVideoId = videoId
        wkHLSEarlyTask = Task { @MainActor in
            // priorityExtract bypasses pendingSerialTask chaining so wv.load()
            // starts immediately rather than behind a background card extraction.
            await YouTubeWebViewHLSExtractor.shared.priorityExtract(videoId: videoId)
        }
    }
    #endif

    /// Path B of the exhaustiveRetry race: early WKWebView HLS path.
    /// Awaits the `wkHLSEarlyTask` started by `startWebViewHLSExtractionIfNeeded`.
    /// Returns `true` if a stream reached `readyToPlay`.
    #if canImport(WebKit)
    func racePathB(video: Video) async -> Bool {
        guard let earlyTask = wkHLSEarlyTask else {
            playerLog.notice("⚠️ [webView] no earlyTask — Path B done")
            return false
        }
        playerLog.notice("⚠️ [webView] Path B awaiting early WKWebView HLS task…")
        guard let url = await earlyTask.value, !Task.isCancelled else {
            playerLog.notice("⚠️ [webView] earlyTask returned nil or cancelled — Path B done")
            return false
        }
        // fix20: Capture nSolver and poToken after earlyTask completes — the fresh
        // extraction has the up-to-date values (extractedPoToken is set at end of extractHLSURL).
        let nSolver = YouTubeWebViewHLSExtractor.shared.extractedNSolver
        let capturedPoToken = YouTubeWebViewHLSExtractor.shared.extractedPoToken
        if let pot = capturedPoToken {
            await api.storeExternalPoToken(pot, for: video.id)
            playerLog.notice("[webView] pot= token stored from WKWebView (\(pot.count) chars)")
        }
        let nInfo = nSolver.map { "\($0.unsolved)→\($0.solved)" } ?? "nil"
        playerLog.notice("⚠️ [webView] Path B got hlsManifestUrl — nSolver=\(nInfo as NSString)")
        let won = await tryWebViewHLS(url, nSolver: nSolver, poToken: capturedPoToken, for: video)
        if won { playerLog.notice("✅ [webView] Path B won — WKWebView HLS") }
        return won
    }
    #endif // canImport(WebKit)

    /// Path C of the exhaustiveRetry race: Android VR (Oculus Quest) adaptive path.
    /// CDN-exempt from rqh=1 / pot= token requirements. Runs concurrently with Path A and B.
    /// Returns `true` if adaptive composition reached `readyToPlay`.
    func racePathC(video: Video) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
            if await tryAllStreams(video: video, info: vrInfo, label: "AndroidVR/race", skipMuxed: true) {
                playerLog.notice("[AndroidVR] ✅ Path C won — AndroidVR adaptive composition")
                return true
            }
        } catch {
            playerLog.notice("[AndroidVR] ⚠️ Path C fetch failed: \(error)")
        }
        playerLog.notice("[AndroidVR] Path C done — AndroidVR adaptive failed")
        return false
    }

    /// Background quality upgrade after AndroidVR wins the race at low quality (maxH < 480).
    ///
    /// Called from the `raceWon / case 2` block when AndroidVR composes at e.g. 240p for
    /// rqh=1 worst-case videos. Fires after a 700 ms stabilisation delay so the initial
    /// `readyToPlay` playback is already running. Tries:
    ///   1. TVEmbedded HLS (WEB_EMBEDDED_PLAYER — HLS for most embeddable videos)
    ///   2. MWEB HLS (m.youtube.com — no pot= for HLS, wider coverage than TVEmbedded)
    ///
    /// On success, replaces the current AVPlayerItem at the current playback position so
    /// the user sees no gap (position is saved to `savedPositionToRestore` just before
    /// calling `attemptURL`, and consumed by `attemptURL`'s `.readyToPlay` handler).
    /// On failure, stays on the AndroidVR quality silently — no error shown to the user.
    func backgroundQualityUpgrade(video: Video) async {
        // Stabilisation delay — let readyToPlay fire and playback begin before replacing the item.
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }
        // Bail if the user navigated to a different video while we were waiting.
        guard currentVideo?.id == video.id else {
            playerLog.notice("[VR→HLS/upgrade] video changed — cancelling quality upgrade")
            return
        }

        // 1. Try TVEmbedded HLS (WEB_EMBEDDED_PLAYER, nameID=56).
        do {
            let tvEmbedInfo = try await api.fetchPlayerInfoTVEmbedded(videoId: video.id)
            guard !Task.isCancelled, currentVideo?.id == video.id else { return }
            if let hlsURL = tvEmbedInfo.hlsURL {
                playerLog.notice("[VR→HLS/upgrade] TVEmbedded HLS available — upgrading from AndroidVR quality")
                // Capture position right before replacement so the stale window is minimal.
                let pos = currentTime
                if pos > 0.5 { savedPositionToRestore = pos }
                if await attemptURL(hlsURL, for: video, info: tvEmbedInfo, label: "VR→HLS/upgrade/TVEmbed") {
                    playerLog.notice("[VR→HLS/upgrade] ✅ quality upgrade via TVEmbedded HLS complete")
                    return
                }
                // attemptURL returned false — clear the now-stale saved position.
                savedPositionToRestore = nil
            }
        } catch {
            playerLog.notice("[VR→HLS/upgrade] TVEmbedded fetch failed: \(error)")
        }

        guard !Task.isCancelled, currentVideo?.id == video.id else { return }

        // 2. Try MWEB HLS (m.youtube.com — no pot= required for HLS, wider coverage).
        do {
            let mwebInfo = try await api.fetchPlayerInfoMWEB(videoId: video.id)
            guard !Task.isCancelled, currentVideo?.id == video.id else { return }
            if let hlsURL = mwebInfo.hlsURL {
                playerLog.notice("[VR→HLS/upgrade] MWEB HLS available — upgrading from AndroidVR quality")
                let pos = currentTime
                if pos > 0.5 { savedPositionToRestore = pos }
                if await attemptURL(hlsURL, for: video, info: mwebInfo, label: "VR→HLS/upgrade/MWEB") {
                    playerLog.notice("[VR→HLS/upgrade] ✅ quality upgrade via MWEB HLS complete")
                    return
                }
                savedPositionToRestore = nil
            }
        } catch {
            playerLog.notice("[VR→HLS/upgrade] MWEB fetch failed: \(error)")
        }

        // 3. Try AndroidVR adaptive (CDN-exempt rqh=1, no HLS needed).
        // Useful when muxed (360p) is playing and AndroidVR can deliver 1080p+ via adaptive
        // composition. The 2s loadTracks timeout applies — if CDN stalls we bail quickly.
        // Position is saved so the upgraded stream resumes from current playback point.
        //
        // On failure: keep availableFormats = AndroidVR's format list (so the quality picker
        // shows e.g. 1080p/720p options). Also restore isMuxedFallback = true because
        // tryAllStreams() unconditionally sets it to false via the label check. Without this
        // restoration, tapping a quality routes through reloadDASHItem (silent rqh=1 failure)
        // instead of triggering retryWith403Recovery → exhaustiveRetry.
        guard !Task.isCancelled, currentVideo?.id == video.id else { return }
        do {
            let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
            guard !Task.isCancelled, currentVideo?.id == video.id else { return }
            let vrPos = currentTime
            if vrPos > 0.5 { savedPositionToRestore = vrPos }
            if await tryAllStreams(video: video, info: vrInfo,
                                  label: "muxed→upgrade/AndroidVR", skipMuxed: true) {
                playerLog.notice("[upgrade] ✅ quality upgrade via AndroidVR adaptive complete")
                return
            }
            savedPositionToRestore = nil
            // Upgrade failed: availableFormats now has AndroidVR's list (set by attemptComposition)
            // which is correct — user can see quality options and tap to trigger a retry.
            // Restore isMuxedFallback so quality taps route to retryWith403Recovery.
            qualityManager.isMuxedFallback = true
            playerLog.notice("[upgrade] AndroidVR adaptive failed — isMuxedFallback restored, \(availableFormats.count) formats visible in picker")
        } catch {
            playerLog.notice("[upgrade] AndroidVR fetch failed: \(error)")
        }

        playerLog.notice("[upgrade] no quality upgrade available — staying on muxed stream")
    }

    /// Kept for the `PlaybackQualityManagerDelegate` protocol.
    /// Quality-switch 403 errors start a fresh 3-attempt exhaustive cycle.
    func retryWith403Recovery(video: Video, originalError: Error?) async {
        playerLog.notice("403 recovery (quality switch) — exhaustive retry for \(video.id)")
        // Capture the current playback position so the new stream resumes from here.
        // Without this, attemptComposition / attemptURL have no seekTo target and the
        // new item starts from t=0 — causing the position-preservation assertion to fail.
        let pos = currentTime
        if pos > 0 {
            savedPositionToRestore = pos
        }
        retryAttempts = 0
        await exhaustiveRetry(video: video, originalError: originalError)
    }

}
