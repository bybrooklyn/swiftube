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

// MARK: - WKWebView HLS fast path (split out of +Fallback)
extension PlaybackViewModel {

    // MARK: - yt-dlp HLS simulator fast-path

    #if canImport(WebKit)
    /// Loads an HLS manifest URL extracted by `YouTubeWebViewHLSExtractor` directly into AVPlayer.
    ///
    /// The URL was obtained by intercepting the YouTube JS player's internal InnerTube call in a
    /// hidden WKWebView — the JS player computes the `spc=` token that bypasses `rqh=1` CDN
    /// restrictions. Segment URLs in the manifest are signed by YouTube and served without 403.
    ///
    /// Fetches the `hls_variant` master manifest, parses it for a per-quality `hls_playlist`
    /// URL at ≥720p, then loads that into AVPlayer via YTHLSProxyLoader so that ALL
    /// HLS requests (playlist + segments) are forwarded through URLSession with the
    /// correct desktop-Safari User-Agent that manifest.googlevideo.com requires.
    /// - Parameter poToken: When non-nil, the proxy rewrites variant playlist URIs to the
    ///   proxy scheme and injects ?pot=<token> into every segment URL so rqh=1-enforced
    ///   CDN requests are authenticated without needing googlevideo.com session cookies.
    /// - Parameter skipIfPfa1: When `true` (Phase -1a only), bail immediately if the selected
    ///   variant URL contains `pfa/1` and `poToken` is nil. The Phase -1a cached preWarm URL has
    ///   a STALE `xpc=` credential that CDN always rejects for pfa/1 videos. Racing paths and
    ///   serial-extraction paths pass `false` because those use a FRESH `xpc=` URL (earlyTask).
    func tryWebViewHLS(_ masterURL: URL, nSolver: (unsolved: String, solved: String)?, poToken: String? = nil, skipIfPfa1: Bool = false, for video: Video) async -> Bool {
        playerLog.notice("[webView/HLS] fetching master manifest: \(masterURL.absoluteString.prefix(120))")

        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        // 1. Download the master M3U8 via URLSession (spc= in URL = self-authenticating)
        var request = URLRequest(url: masterURL, timeoutInterval: 20)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let manifestText = String(data: data, encoding: .utf8) else {
            playerLog.error("❌ [webView/HLS] failed to fetch master manifest")
            return false
        }
        playerLog.notice("[webView/HLS] master manifest OK bytes=\(data.count)")

        // 2. Parse ALL variants for the quality picker and best ≥720p for initial playback.
        let allVariants = parseHLSAllVariants(from: manifestText, baseURL: masterURL)
        let bestURL = parseHLSBestVariant(from: manifestText, baseURL: masterURL, minHeight: 720)
                   ?? parseHLSBestVariant(from: manifestText, baseURL: masterURL, minHeight: 0)
        guard let bestURL else {
            playerLog.error("❌ [webView/HLS] no quality URL found in master manifest")
            return false
        }
        playerLog.notice("[webView/HLS] selected per-quality URL: \(bestURL.absoluteString.prefix(200))")

        // fix28: Fast-fail for pfa/1 urls in Phase -1a when no pot= is available.
        //
        // For pfa/1 variants the CDN rejects segment requests (-12660) unless the URL's
        // xpc= credential is FRESH (< ~5 s, minted by the YouTube player at wv.load() time).
        // When Phase -1a calls tryWebViewHLS with the CACHED preWarm URL (stored 90+ s ago),
        // that URL's xpc= is always stale → CDN rejects all segments → 1.1 s wasted.
        //
        // Returning false immediately lets the race start earlier. Race Path B awaits
        // wkHLSEarlyTask (priorityExtract), which has already extracted a FRESH xpc= URL.
        // Path B wins with that fresh URL, reducing c1 from ~2.87 s → ~1.0-1.4 s.
        //
        // IMPORTANT: this guard only fires when `skipIfPfa1 == true` (Phase -1a mode).
        // The race path (racePathB) and serial extraction after race-failed pass
        // `skipIfPfa1: false` so fresh liveRace URLs are never prematurely rejected.
        if skipIfPfa1, poToken == nil,
           (bestURL.absoluteString.contains("/pfa/1/") || bestURL.absoluteString.contains("pfa%2F1")) {
            playerLog.notice("[webView/HLS] Phase -1a pfa/1 + pot=nil — stale xpc= cannot auth CDN segments; bailing early (fix28)")
            return false
        }

        // Cache the master manifest URL so future loads of this video (or pre-extracted
        // neighbours) can skip the 5–9 s WKWebView extraction step entirely.
        await VideoPreloadCache.shared.store(wkHLSManifestURL: masterURL, for: video.id)

        // Extract WKWebView cookies for the proxy loader.
        // Note: segment URLs in variant playlists are served natively by AVPlayer (not proxied),
        // so the proxy does not need googlevideo.com cookies for rqh=1 content. The master
        // manifest URL is self-authenticated via spc=, and youtube.com session cookies
        // (VISITOR_INFO1_LIVE, YSC, etc.) are sufficient for CDN segment auth in practice.
        let webViewCookies = await extractWKWebViewCookies()
        let gvCount = webViewCookies.filter { $0.domain.contains("googlevideo") }.count
        playerLog.notice("[webView/HLS] extracted \(webViewCookies.count) cookies (\(gvCount) googlevideo) for proxy")

        // Populate the quality picker with the HLS variant heights from the master manifest.
        // These are the only formats guaranteed to work via the proxy — iOS adaptive rqh=1
        // streams are intentionally excluded from the picker.
        if !allVariants.isEmpty {
            hlsVariantURLs = allVariants
            wkHLSMasterURL = masterURL
            let syntheticFormats = allVariants.keys.sorted(by: >).map { h in
                VideoFormat(label: "\(h)p", width: 0, height: h, fps: 30,
                            mimeType: "video/mp4; codecs=\"avc1.640028\"",
                            url: allVariants[h], bitrate: nil)
            }
            availableFormats = syntheticFormats
            playerLog.notice("[webView/HLS] quality picker: \(syntheticFormats.map { $0.qualityLabel }.joined(separator: ", "))")
        }

        // 2b. Parse dubbed-audio language tracks from YT-EXT-AUDIO-CONTENT-ID attributes.
        //     YouTube encodes dubbed languages in #EXT-X-STREAM-INF lines (not #EXT-X-MEDIA
        //     TYPE=AUDIO), so loadMediaSelectionGroup returns nil. We parse them directly here
        //     and populate AudioTrackManager so the language selector appears immediately.
        let hlsLanguageTracks = parseHLSAudioLanguages(from: manifestText)
        playerLog.notice("[webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks: \(hlsLanguageTracks.count) — \(hlsLanguageTracks.map { $0.name }.joined(separator: ", "))")
        if !hlsLanguageTracks.isEmpty {
            audioManager.loadHLSVariantTracks(hlsLanguageTracks)
            // Wire language switching: when the user picks a track, reload the AVPlayerItem
            // with the proxy filtered for that language. The callback is cleared by reset()
            // when a new video loads.
            audioManager.onHLSLanguageChange = { [weak self] (track: AudioTrack?) in
                guard let self else { return }
                let savedPos = self.player.currentTime().seconds
                // Use contentID (the YT-EXT-AUDIO-CONTENT-ID value) for proxy filtering.
                // nil means original audio: for real originals that lack the attribute,
                // contentID is nil on the synthetic "Original" entry; for real originals
                // with the attribute (e.g. "en-US.4"), contentID equals the real value.
                // The "Auto" picker row passes track=nil → contentID=nil → original filter.
                let contentID = track?.contentID
                Task { [weak self] in
                    await self?.switchHLSLanguage(
                        to: contentID,
                        masterURL: masterURL,
                        manifestText: manifestText,
                        nSolver: nSolver,
                        webViewCookies: webViewCookies,
                        for: video,
                        seekTo: savedPos
                    )
                }
            }
        }

        // 3. Route through YTHLSProxyLoader using the MASTER manifest URL (not a per-quality
        //    variant URL). The proxy filters #EXT-X-STREAM-INF variants for the selected
        //    dubbed language (or original audio when none is selected). Without the proxy,
        //    AVPlayer would receive all N×M language+quality variant entries and could pick
        //    any language during ABR adaptation.
        guard let proxyURL = masterURL.proxyURL else {
            playerLog.error("❌ [webView/HLS] failed to build proxy URL for master")
            return false
        }
        // Determine the initial content ID: if the user has a saved language preference that
        // matches one of the HLS variant tracks, start with that language; otherwise nil (original).
        // Use contentID (not id) so the synthetic "Original" entry (id="yt-original-audio",
        // contentID=nil) correctly maps to nil → proxy keeps no-content-ID variants.
        let initialContentID: String?
        if let pref = settings.preferredAudioLanguage,
           let preferred = hlsLanguageTracks.first(where: { $0.languageCode == pref }) {
            initialContentID = preferred.contentID
        } else {
            initialContentID = nil
        }
        let langDisplay = initialContentID ?? "original"
        // fix20: Use the caller-supplied poToken (captured before wkHLSEarlyTask clears
        // extractedPoToken). With a non-nil poToken the proxy rewrites variant playlist URLs
        // to ytwebhls:// and injects ?pot=<token> into segment URLs, authenticating rqh=1
        // CDN requests without requiring googlevideo.com session cookies in the cookie jar.
        // Falls back to extractedPoToken in case the caller didn't supply one.
        let effectivePoToken = poToken ?? YouTubeWebViewHLSExtractor.shared.extractedPoToken
        let potDisplay = effectivePoToken.map { "\($0.count) chars" } ?? "nil"
        playerLog.notice("[webView/HLS] ✅ proxying master URL (lang=\(langDisplay), pot=\(potDisplay), YT-EXT-AUDIO-CONTENT-ID filter active)")
        let proxyLoader = YTHLSProxyLoader(ua: ua, nSolver: nSolver, webViewCookies: webViewCookies,
                                           selectedLanguageContentID: initialContentID,
                                           poToken: effectivePoToken)
        let asset = AVURLAsset(url: proxyURL)
        // Keep proxy loader alive for the lifetime of this asset
        asset.resourceLoader.setDelegate(proxyLoader, queue: DispatchQueue.global(qos: .userInitiated))
        // Store reference so ARC doesn't release the loader while AVPlayer uses the asset
        webHLSProxyLoader = proxyLoader

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        // Fast-start: require only 0.5 s of buffered content before readyToPlay fires
        // (matches the primary HLS path in loadAsync). Forward buffer is reset to system
        // default in the readyToPlay ramp task below.
        item.preferredForwardBufferDuration = 0.5
        // Fast-start ABR: cap initial variant at 360p so AVPlayer downloads the smallest
        // first segment, then ramp to preferred quality after readyToPlay.
        // Compute preferred height here so the ramp Task captures it.
        let preferredHeight: Int
        if settings.preferredQuality != .auto, let cap = settings.preferredQuality.maxHeight {
            preferredHeight = cap
        } else if let best = allVariants.keys.filter({ $0 >= 720 }).max()
                          ?? allVariants.keys.max() {
            preferredHeight = best
        } else {
            preferredHeight = 0
        }
        // Start at 360p (fast first-frame) regardless of preferred quality.
        item.preferredMaximumResolution = CGSize(width: 640, height: 360)
        playerLog.notice("[webView/HLS] fast-start ABR: initial cap 360p → ramp to \(preferredHeight > 0 ? "\(preferredHeight)p" : "Auto") after readyToPlay")
        // fix235: Final cancellation / video-identity check before touching the player.
        // A stale exhaustiveRetry task (cancelled by a subsequent load() or stop()) must not
        // call replaceCurrentItem — doing so would silently swap the visible video.
        guard !Task.isCancelled, currentVideo?.id == video.id else {
            playerLog.notice("⚠️ [webView/HLS] fix235: task cancelled or video changed (current=\(currentVideo?.id ?? "nil") expected=\(video.id)) — aborting replaceCurrentItem")
            return false
        }
        lastAttemptedStreamURL = masterURL
        player.replaceCurrentItem(with: item)
        installEndAndStallObservers(for: item)
        itemObserverTask?.cancel()
        for await status in item.statusStream {
            switch status {
            case .readyToPlay:
                playerLog.notice("[benchmark] readyToPlay — webView/HLS — videoId=\(video.id) title=\(video.title)")
                playerLog.notice("✅ [webView/HLS] readyToPlay")
                // Refresh duration from AVPlayerItem — the YouTube API metadata may be
                // absent (nil) or inaccurate, leaving duration=0 and breaking scrubbing.
                let itemDur = item.duration.seconds
                if itemDur.isFinite && itemDur > 0 {
                    let prevDur = self.duration
                    self.duration = itemDur
                    playerLog.notice("[duration] updated from webView/HLS AVPlayerItem: \(String(format: "%.1f", itemDur))s (was \(String(format: "%.1f", prevDur))s)")
                } else if self.duration == 0 {
                    durationObserverTask?.cancel()
                    durationObserverTask = Task { [weak self, weak item] in
                        guard let self, let item else { return }
                        for await seconds in item.firstValidDurationStream {
                            guard !Task.isCancelled else { return }
                            let prev = self.duration
                            self.duration = seconds
                            playerLog.notice("[duration] deferred KVO update (webView/HLS): \(String(format: "%.1f", seconds))s (was \(String(format: "%.1f", prev))s)")
                            break
                        }
                    }
                }
                // Try the standard #EXT-X-MEDIA path (works if manifest has audio groups).
                // For YouTube's YT-EXT-AUDIO-CONTENT-ID format, loadAudioTracks returns nil
                // but tracks are already loaded via loadHLSVariantTracks above.
                loadAudioTracks(from: item)
                needsQuickStartup = false
                isLoading = false
                timeToPlayMs = Int(Date().timeIntervalSince(videoLoadStartedAt) * 1000)
                lastSuccessfulStreamType = "webView/HLS"
                if timeToPlayMs > 4_000 {
                    DiagnosticsLogger.recordSlowVideoLoad(
                        videoId: video.id,
                        elapsedMs: timeToPlayMs,
                        streamType: "webView/HLS",
                        hasError: false
                    )
                }
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                qualityManager.isMuxedFallback = false
                // Fast-start quality ramp: first frame is on screen at 360p. Upgrade ABR hints
                // to preferred quality (same pattern as primary HLS path in loadAsync).
                Task { [weak self, weak item] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, !Task.isCancelled else { return }
                    self.timeToHighQualityMs = Int(Date().timeIntervalSince(self.videoLoadStartedAt) * 1000)
                    item?.preferredForwardBufferDuration = 0
                    if preferredHeight > 0 {
                        item?.preferredMaximumResolution = CGSize(width: 7680, height: preferredHeight)
                        playerLog.notice("[webView/HLS] ABR ramp → \(preferredHeight)p + buffer unconstrained")
                    } else {
                        item?.preferredMaximumResolution = .zero
                        playerLog.notice("[webView/HLS] ABR ramp → Auto (unconstrained) + buffer unconstrained")
                    }
                }
                return true
            case .failed:
                let err = item.error?.localizedDescription ?? "nil"
                playerLog.error("❌ [webView/HLS] AVPlayerItem failed: \(err)")
                // If the CDN denied access (permission error), a fresh WKWebView extraction
                // will produce the same URL signed by the same CDN session → same 403.
                // Flag this so exhaustiveRetry skips the serial extraction entirely.
                if err.lowercased().contains("permission") || err.lowercased().contains("not have access") {
                    wkHLSPermissionDenied = true
                    playerLog.notice("[webView/HLS] CDN permission error — serial extraction will be skipped")
                }
                return false
            case .unknown: continue
            @unknown default: continue
            }
        }
        return false
    }

    /// Reloads the WKWebView HLS AVPlayerItem with the master manifest filtered for a
    /// dubbed-audio language (or original when contentID is nil). Called when the user
    /// selects an audio track from the picker via AudioTrackManager.onHLSLanguageChange.
    private func switchHLSLanguage(
        to contentID: String?,
        masterURL: URL,
        manifestText: String,
        nSolver: (unsolved: String, solved: String)?,
        webViewCookies: [HTTPCookie],
        for video: Video,
        seekTo position: Double
    ) async {
        let idDisplay = contentID ?? "original"
        playerLog.notice("[wkHLS/lang] switching to contentID=\(idDisplay)")

        // Update hlsVariantURLs so quality switching preserves the selected language.
        let langVariants = parseHLSVariantURLsForLanguage(contentID, from: manifestText,
                                                          baseURL: masterURL)
        if !langVariants.isEmpty {
            hlsVariantURLs = langVariants
            let variantSummary = langVariants.keys.sorted(by: >).map { "\($0)p" }.joined(separator: ", ")
            playerLog.notice("[wkHLS/lang] updated hlsVariantURLs: \(variantSummary)")
        }

        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        let proxyLoader = YTHLSProxyLoader(ua: ua, nSolver: nSolver, webViewCookies: webViewCookies,
                                           selectedLanguageContentID: contentID)
        guard let proxyURL = masterURL.proxyURL else {
            playerLog.error("❌ [wkHLS/lang] failed to build proxy URL")
            return
        }
        let asset = AVURLAsset(url: proxyURL)
        asset.resourceLoader.setDelegate(proxyLoader, queue: DispatchQueue.global(qos: .userInitiated))
        webHLSProxyLoader = proxyLoader

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 2.0
        if let best = langVariants.keys.filter({ $0 >= 720 }).max() ?? langVariants.keys.max(), best > 0 {
            item.preferredMaximumResolution = CGSize(width: 7680, height: best)
        }
        Task { [weak item] in
            try? await Task.sleep(for: .seconds(5))
            item?.preferredForwardBufferDuration = 0
        }

        player.replaceCurrentItem(with: item)
        installEndAndStallObservers(for: item)
        for await status in item.statusStream {
            switch status {
            case .readyToPlay:
                let posStr = String(format: "%.1f", position)
                playerLog.notice("[benchmark] readyToPlay — wkHLS/lang — videoId=\(video.id) title=\(video.title)")
                playerLog.notice("✅ [wkHLS/lang] readyToPlay — seeking to \(posStr)s")
                if position > 0 {
                    let target = CMTime(seconds: position, preferredTimescale: 600)
                    await item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                player.rate = Float(settings.playbackSpeed)
                return
            case .failed:
                let err = item.error?.localizedDescription ?? "nil"
                playerLog.error("❌ [wkHLS/lang] AVPlayerItem failed: \(err)")
                return
            case .unknown: continue
            @unknown default: continue
            }
        }
    }

    /// Extracts all cookies from the WKWebView's httpCookieStore, including googlevideo.com
    /// cookies required for rqh=1-enforced CDN segment requests.
    private func extractWKWebViewCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let gvCount = cookies.filter { $0.domain.contains("googlevideo") }.count
                playerLog.notice("[webView/HLS] extracted \(cookies.count) cookies (\(gvCount) googlevideo) for proxy")
                cont.resume(returning: cookies)
            }
        }
    }

    /// Probes a cached WKWebView HLS master manifest URL with a lightweight HEAD request
    /// to detect expiry before constructing an AVPlayerItem.
    /// Returns `true` if the URL is still accessible (2xx/3xx); `false` on 4xx or timeout.
    func isWKHLSURLValid(_ url: URL) async -> Bool {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 8
        if let (_, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
           let http = response as? HTTPURLResponse {
            playerLog.notice("[wkHLS/probe] HEAD returned HTTP \(http.statusCode)")
            return http.statusCode < 400
        }
        playerLog.notice("[wkHLS/probe] HEAD probe timeout or failed — treating as expired")
        return false
    }

    /// Parses YouTube's HLS master manifest for dubbed-audio language tracks encoded via
    /// YT-EXT-AUDIO-CONTENT-ID attributes on #EXT-X-STREAM-INF lines.
    ///
    /// YouTube does NOT use standard #EXT-X-MEDIA:TYPE=AUDIO groups for dubbed content.
    /// Instead each quality level appears N times — once per audio language — with
    /// YT-EXT-AUDIO-CONTENT-ID="xx-XX.N" identifying the language. The original audio
    /// variant has no YT-EXT-AUDIO-CONTENT-ID and is NOT returned here.
    ///
    /// The YT-EXT-XTAGS attribute on each variant is base64-encoded protobuf containing
    /// "acont=original" or "acont=dubbed-auto" plus "lang=xx-XX". We use this to mark
    /// the `acont=original` track as isOriginal=true.
    ///
    /// Returns deduplicated AudioTrack array (original first if present, then dubbed).
    private func parseHLSAudioLanguages(from manifest: String) -> [AudioTrack] {
        YouTubeCore.parseHLSAudioLanguages(from: manifest)
    }

    /// Parses a map of stream height → variant URL from the HLS master manifest for a
    /// specific dubbed-audio content ID. Used by switchHLSLanguage to update hlsVariantURLs.
    /// If `contentID` is nil, returns original-audio variant URLs (no YT-EXT-AUDIO-CONTENT-ID).
    private func parseHLSVariantURLsForLanguage(
        _ contentID: String?,
        from manifest: String,
        baseURL: URL
    ) -> [Int: URL] {
        YouTubeCore.parseHLSVariantURLsForLanguage(contentID, from: manifest, baseURL: baseURL)
    }

    /// Extracts the value of a quoted HLS attribute (e.g. `ATTR="value"`) from a tag line.
    private func extractQuotedHLSAttribute(_ name: String, from line: String) -> String? {
        YouTubeCore.extractQuotedHLSAttribute(name, from: line)
    }

    /// Parses an HLS master M3U8 manifest and returns a map of stream height → variant URL
    /// for all streams present. Handles both absolute and relative URIs.
    /// Returns one URL per quality level — the first variant seen per height (original audio when
    /// available, first dubbed entry as fallback when the manifest omits no-CONTENT-ID variants).
    private func parseHLSAllVariants(from manifest: String, baseURL: URL) -> [Int: URL] {
        YouTubeCore.parseHLSAllVariants(from: manifest, baseURL: baseURL)
    }

    /// Parses an HLS master M3U8 manifest and returns the URL of the best stream at ≥ `minHeight`.
    /// Handles both absolute URIs and relative paths (resolved against `baseURL`).
    private func parseHLSBestVariant(from manifest: String, baseURL: URL, minHeight: Int) -> URL? {
        let result = YouTubeCore.parseHLSBestVariant(from: manifest, baseURL: baseURL, minHeight: minHeight)
        if let result {
            playerLog.notice("[webView/HLS] best variant ≥\(minHeight)p: \(result.absoluteString.prefix(80))")
        }
        return result
    }

    /// Proactively extracts and caches the WKWebView HLS master manifest URL for a neighbour
    /// video while the current video is already playing. Stores the result in VideoPreloadCache
    /// so that when the user swipes to the neighbour, exhaustiveRetry skips the 5–9 s
    /// WKWebView extraction step and plays from the cached URL directly.
    ///
    /// Skips silently if the URL is already cached or if extraction returns nil.
    func preExtractWKHLSForVideo(_ videoId: String) async {
        guard await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) == nil else {
            playerLog.notice("[wkHLS] pre-extract skipped — already cached for \(videoId)")
            return
        }
        playerLog.notice("[wkHLS] pre-extracting HLS URL for neighbour \(videoId)")
        guard let url = await YouTubeWebViewHLSExtractor.shared.extractHLSURL(videoId: videoId) else {
            playerLog.notice("[wkHLS] pre-extract returned nil for \(videoId)")
            return
        }
        await VideoPreloadCache.shared.store(wkHLSManifestURL: url, for: videoId)
        playerLog.notice("✅ [wkHLS] pre-extract done for \(videoId)")
    }
    #endif

    #if targetEnvironment(simulator)
    /// Loads a yt-dlp `hls_playlist` URL directly into AVPlayer. Kept for backward compatibility.
    private func tryYtDlpHLS(_ url: URL, for video: Video) async -> Bool {
        playerLog.notice("[ytDlp[sim]/HLS]: \(url.absoluteString.prefix(120))")
        let ua = "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)"
        let uaOpts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]]
        let asset = AVURLAsset(url: url, options: uaOpts)
        let item  = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 2.0
        Task { [weak item] in
            try? await Task.sleep(for: .seconds(5))
            item?.preferredForwardBufferDuration = 0
        }
        player.replaceCurrentItem(with: item)
        installEndAndStallObservers(for: item)
        itemObserverTask?.cancel()
        for await status in item.statusStream {
            switch status {
            case .readyToPlay:
                playerLog.notice("[benchmark] readyToPlay — ytDlp/HLS — videoId=\(video.id) title=\(video.title)")
                playerLog.notice("✅ [ytDlp[sim]/HLS] readyToPlay")
                needsQuickStartup = false
                isLoading = false
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                return true
            case .failed:
                let err = item.error?.localizedDescription ?? "nil"
                playerLog.error("❌ [ytDlp[sim]/HLS] AVPlayerItem failed: \(err)")
                return false
            case .unknown: continue
            @unknown default: continue
            }
        }
        return false
    }
    #endif

}
