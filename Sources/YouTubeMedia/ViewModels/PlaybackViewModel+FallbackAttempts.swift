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

// MARK: - Attempt helpers: one URL, one adaptive composition, phase-2 launch (split out of +Fallback)
extension PlaybackViewModel {

    // MARK: - Attempt Helpers

    /// Tries a single URL in AVPlayer. Returns true if `.readyToPlay` is received.
    /// `statusStream` finishes after `.readyToPlay` or `.failed`, making it safe to await inline.
    func attemptURL(_ url: URL, for video: Video, info: PlayerInfo, label: String) async -> Bool {
        playerLog.notice("[\(label)]: \(url.absoluteString.prefix(120))")

        playerInfo = info
        let isHLSManifest = label.contains("/HLS")
        let hlsPolicy = HLSPlaybackPolicy.resolve(label: label, isHLS: isHLSManifest)
        let newFormats = Self.deduplicatedVideoFormats(info.formats)
        // Never reduce quality options for adaptive/HLS streams — preserve the richest set seen.
        // Exception: muxed fallback (label contains "/muxed") always resets availableFormats to
        // the muxed-only formats. This prevents stale rqh=1-blocked adaptive formats from
        // appearing in the quality picker when they can never actually play.
        let maxCurrentHeight = availableFormats.map(\.height).max() ?? 0
        let maxNewHeight = newFormats.map(\.height).max() ?? 0
        let isMuxedFallback = label.contains("/muxed")
        if isMuxedFallback || newFormats.count > availableFormats.count || maxNewHeight > maxCurrentHeight || availableFormats.isEmpty {
            availableFormats = newFormats
        }
        playerLog.notice("[\(label)] availableFormats after dedup: input=\(info.formats.count) output=\(newFormats.count) kept=\(availableFormats.count) maxH=\(availableFormats.map(\.height).max() ?? 0)")
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        var effectiveURL = url
        var applyHLSHints = false
        if let hlsURL = info.hlsURL, url == hlsURL {
            let videoId = video.id
            let allVariantURLs: [Int: URL]
            if hlsPolicy.filtersMasterManifest {
                let fetched = await qualityManager.fetchHLSVariantURLs(
                    url: hlsURL, userAgent: hlsPolicy.userAgent
                )
                if fetched.isEmpty,
                   let cached = PlaybackQualityManager.cachedHLSVariants(for: videoId) {
                    allVariantURLs = cached
                } else {
                    allVariantURLs = fetched
                }
                if !fetched.isEmpty {
                    PlaybackQualityManager.cacheHLSVariants(fetched, for: videoId)
                }
            } else if let cached = PlaybackQualityManager.cachedHLSVariants(for: videoId) {
                playerLog.notice("[\(label)] HLS: using cached manifest for \(videoId) variantCount=\(cached.count)")
                allVariantURLs = cached
            } else {
                let fetched = await fetchHLSVariantURLs(url: hlsURL)
                allVariantURLs = fetched
                if !fetched.isEmpty {
                    PlaybackQualityManager.cacheHLSVariants(fetched, for: videoId)
                }
            }
            let variantURLs = hlsPolicy.maximumHeight.map { cap in
                allVariantURLs.filter { $0.key <= cap }
            } ?? allVariantURLs
            playerLog.notice("[\(label)] HLS: hlsURL=yes variantCount=\(variantURLs.count) effectiveQuality=\(effectiveQuality)")
            if hlsPolicy.requiresH264 {
                availableFormats = availableFormats.filter { format in
                    hlsPolicy.allowsFormat(height: format.height, mimeType: format.mimeType)
                }
            }
            if !variantURLs.isEmpty {
                hlsVariantURLs = variantURLs
                let playableFormats = availableFormats.filter { variantURLs.keys.contains($0.height) }
                availableFormats = playableFormats
                // Use a variant playlist URL directly rather than the master manifest URL.
                // The master manifest (hls_variant) stalls AVPlayer on manifest.googlevideo.com
                // because it requires session-level auth that AVPlayer's isolated network stack
                // cannot provide. Variant playlist URLs (hls_playlist) are directly downloadable
                // — yt-dlp confirms 720p in 13 s, 1080p in 29 s for the same video.
                // Per-video pick (when set) takes precedence over the persisted default —
                // a mid-playback 403 recovery must not silently revert the user's choice.
                let preferredMaxH = hlsPolicy.cappedHeight(requested: effectiveQuality.maxHeight)
                let chosen = preferredMaxH
                    .flatMap { h in variantURLs.filter { $0.key <= h }.max(by: { $0.key < $1.key }) }
                    ?? variantURLs.max(by: { $0.key < $1.key })
                if let chosen {
                    if hlsPolicy.filtersMasterManifest {
                        effectiveURL = hlsURL
                        playerLog.notice("[\(label)] HLS: using H.264-filtered master with \(chosen.key)p cap and audio renditions")
                    } else {
                        effectiveURL = chosen.value
                        playerLog.notice("[\(label)] HLS: selected variant \(chosen.key)p")
                    }
                    // DIAGNOSTIC D-14: probe variant playlist + first segment before handing to AVPlayer.
                    // Ephemeral session → no cookies, no shared state.
                    // 200 → URL is publicly accessible; 403 → YouTube session (SAPISID) required.
                    // Also logs first segment URL to determine if rqh=1 is enforced at segment level.
                    let variantURL = chosen.value
                    let capturedLabel = label
                    let capturedAuthToken = currentAuthToken
                    Task.detached {
                        var diagReq = URLRequest(url: variantURL)
                        diagReq.setValue(
                            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
                            forHTTPHeaderField: "User-Agent"
                        )
                        diagReq.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                        diagReq.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
                        diagReq.timeoutInterval = 8
                        guard let (diagData, diagResp) = try? await URLSession(configuration: .ephemeral).data(for: diagReq),
                              let http = diagResp as? HTTPURLResponse else {
                            playerLog.notice("[\(capturedLabel)] D-14 HLS variant probe: fail/timeout (no-cookie/Safari UA)")
                            return
                        }
                        let playlistText = String(data: diagData, encoding: .utf8) ?? ""
                        // Find first absolute segment URL (https:// line not starting with #)
                        let firstSegURL = playlistText.components(separatedBy: "\n")
                            .first { $0.hasPrefix("https://") } ?? "(no absolute URL found)"
                        // rqh=1 appears as /rqh/1/ path-style in HLS URLs (not ?rqh=1 query-style)
                        let hasRqh = firstSegURL.contains("/rqh/1") || firstSegURL.contains("rqh=1") || firstSegURL.contains("rqh%3D1")
                        playerLog.notice("[\(capturedLabel)] D-14 HLS variant probe: HTTP \(http.statusCode) bytes=\(diagData.count) firstSeg_rqh=\(hasRqh) firstSeg=\(firstSegURL.prefix(600))")
                        // If no absolute URL, log the first non-comment line to see relative segment format
                        if !firstSegURL.hasPrefix("https://") {
                            let firstNonComment = playlistText.components(separatedBy: "\n")
                                .first { !$0.hasPrefix("#") && !$0.isEmpty } ?? "(empty)"
                            playerLog.notice("[\(capturedLabel)] D-14 first non-comment line: \(firstNonComment.prefix(200))")
                        }
                        // Also test first segment URL (if absolute) to see if segments need auth
                        if firstSegURL.hasPrefix("https://"), let segURL = URL(string: firstSegURL) {
                            var segReq = URLRequest(url: segURL)
                            segReq.setValue(
                                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
                                forHTTPHeaderField: "User-Agent"
                            )
                            segReq.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                            segReq.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
                            segReq.timeoutInterval = 8
                            // Range request — just the first byte to test access
                            segReq.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                            if let (_, segResp) = try? await URLSession(configuration: .ephemeral).data(for: segReq),
                               let segHttp = segResp as? HTTPURLResponse {
                                playerLog.notice("[\(capturedLabel)] D-14 segment probe (Safari UA/no-cookie): HTTP \(segHttp.statusCode) rqh=\(hasRqh)")
                            } else {
                                playerLog.notice("[\(capturedLabel)] D-14 segment probe: fail/timeout")
                            }

                            // D-15: probe same segment WITH Bearer token — determines if
                            // OAuth2 Bearer satisfies rqh=1 for HLS path-style segments.
                            // If this returns 200/206, resource-loader interception is viable.
                            if let bearerToken = capturedAuthToken, hasRqh {
                                var segBearerReq = URLRequest(url: segURL)
                                segBearerReq.setValue(
                                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
                                    forHTTPHeaderField: "User-Agent"
                                )
                                segBearerReq.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                                segBearerReq.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
                                segBearerReq.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                                segBearerReq.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                                segBearerReq.timeoutInterval = 8
                                if let (_, segResp2) = try? await URLSession(configuration: .ephemeral).data(for: segBearerReq),
                                   let segHttp2 = segResp2 as? HTTPURLResponse {
                                    playerLog.notice("[\(capturedLabel)] D-15 segment probe (Safari UA+Bearer): HTTP \(segHttp2.statusCode) rqh=\(hasRqh)")
                                } else {
                                    playerLog.notice("[\(capturedLabel)] D-15 segment probe (Bearer): fail/timeout")
                                }
                            }
                        }
                    }
                }
            } else {
                playerLog.notice("[\(label)] HLS manifest fetch returned 0 variants — using master as-is")
            }
            qualityManager.configureHLSPlayback(
                userAgent: hlsPolicy.userAgent,
                maximumHeight: hlsPolicy.maximumHeight,
                requiredVideoCodec: hlsPolicy.requiresH264 ? "avc1" : nil
            )
            qualityManager.setSelectedFormatForCurrentPreference()
            applyHLSHints = true
        } else {
            playerLog.notice("[\(label)] non-HLS URL — no EXT-X-MEDIA, audio tracks will be unavailable")
        }

        lastAttemptedStreamURL = effectiveURL
        // WebSafari HLS variant playlists are served from manifest.googlevideo.com and
        // signed for a browser WEB client. The CDN checks that the requesting UA matches
        // a web browser; sending the iOS YouTube UA returns 403. Use the Safari macOS UA
        // for WebSafari HLS, and Origin + Referer for all HLS (browser-style headers).
        let hlsUA = hlsPolicy.userAgent
        var hlsHeaders: [String: String] = ["User-Agent": hlsUA]
        if isHLSManifest {
            hlsHeaders["Origin"] = "https://www.youtube.com"
            hlsHeaders["Referer"] = "https://www.youtube.com/"
        }

        let item: AVPlayerItem
        if applyHLSHints {
            // Use AVURLAsset with custom UA headers for HLS — AVFoundation handles
            // HLS natively and sends our YouTube UA for ALL requests (manifest +
            // segments). AetherEngine cannot be used here because FFmpegBuild has
            // no HTTP protocol handler, so segment sub-requests inside HLS always
            // fail regardless of the io_open callback approach.
            let uaOpts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": hlsHeaders]
            let asset = qualityManager.makeHLSAsset(url: effectiveURL, options: uaOpts)
            playerLog.notice("[\(label)] HLS via AVURLAsset (native stack) url=\(effectiveURL.lastPathComponent)")
            item = AVPlayerItem(asset: asset)
        } else if let proxied = YTProgressiveProxyLoader.makeAsset(
            url: effectiveURL,
            userAgent: hlsUA,
            poToken: { [api, id = video.id] in await api.currentPoToken(for: id) },
            renewURL: { [api, id = video.id] in
                guard let fresh = try? await api.fetchPlayerInfoAndroidVR(videoId: id) else { return nil }
                return fresh.formats.first { $0.mimeType.hasPrefix("video/mp4") && $0.url != nil }?.url
            }
        ) {
            // Non-HLS (muxed / DASH) through the resource-loader proxy.
            //
            // `AVURLAssetHTTPHeaderFieldsKey` does not reach CoreMedia's network
            // stack — the same gap `YTHLSProxyLoader` exists to close for HLS.
            // Measured here: an itag-18 URL signed `c=ANDROID_VR` returned
            // `HTTP 403: Forbidden` through AVURLAsset with the Oculus UA set in
            // that option, and `206` through URLSession with the identical
            // header. Owning the byte ranges is what makes the UA stick.
            playerLog.notice("[\(label)] progressive via resource-loader proxy ua=\(hlsUA.prefix(28))")
            item = AVPlayerItem(asset: proxied)
        } else {
            let uaOpts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": hlsHeaders]
            item = AVPlayerItem(asset: AVURLAsset(url: effectiveURL, options: uaOpts))
        }
        item.audioTimePitchAlgorithm = .spectral
        // Reduce startup latency: begin playback after 0.5 s of buffered content
        // (matches the primary HLS path). Reset to system default after readyToPlay.
        item.preferredForwardBufferDuration = 0.5
        Task { [weak item] in
            try? await Task.sleep(for: .seconds(5))
            item?.preferredForwardBufferDuration = 0
        }
        if applyHLSHints {
            if let maxH = hlsPolicy.cappedHeight(requested: effectiveQuality.maxHeight) {
                item.preferredMaximumResolution = CGSize(width: CGFloat(maxH) * 4, height: CGFloat(maxH))
                item.preferredPeakBitRate = peakBitRate(for: maxH)
                playerLog.notice("[\(label)] HLS ABR hints: maxH=\(maxH)p peakBitRate=\(peakBitRate(for: maxH) / 1_000_000)Mbps (master URL preserved)")
            } else {
                // Auto: remove all constraints so AVPlayer picks the best available variant.
                item.preferredMaximumResolution = .zero
                item.preferredPeakBitRate = 0
                playerLog.notice("[\(label)] HLS ABR hints cleared (Auto quality, unconstrained)")
            }
        }
        // fix235: Guard cancellation and video identity immediately before touching the player.
        // Covers adaptive/muxed paths: a stale exhaustiveRetry (cancelled by load() or stop())
        // must not swap the AVPlayerItem under a correctly-playing video.
        guard !Task.isCancelled, currentVideo?.id == video.id else {
            playerLog.notice("⚠️ [\(label)] fix235: task cancelled or video changed (current=\(currentVideo?.id ?? "nil") expected=\(video.id)) — aborting replaceCurrentItem")
            return false
        }
        player.replaceCurrentItem(with: item)
        installEndAndStallObservers(for: item)
        itemObserverTask?.cancel()

        for await status in item.statusStream {
            switch status {
            case .readyToPlay:
                playerLog.notice("[benchmark] readyToPlay — \(label) — videoId=\(video.id) title=\(video.title)")
                playerLog.notice("✅ [\(label)] readyToPlay")
                let itemDur = item.duration.seconds
                if itemDur.isFinite && itemDur > 0 {
                    let prevDur = self.duration
                    self.duration = itemDur
                    playerLog.notice("[duration] updated from AVPlayerItem: \(String(format: "%.1f", itemDur))s (was \(String(format: "%.1f", prevDur))s from metadata)")
                } else if self.duration == 0 {
                    durationObserverTask?.cancel()
                    durationObserverTask = Task { [weak self, weak item] in
                        guard let self, let item else { return }
                        for await seconds in item.firstValidDurationStream {
                            guard !Task.isCancelled else { return }
                            let prev = self.duration
                            self.duration = seconds
                            playerLog.notice("[duration] deferred KVO update: \(String(format: "%.1f", seconds))s (was \(String(format: "%.1f", prev))s)")
                            break
                        }
                    }
                }
                if let pos = savedPositionToRestore, pos > 0 {
                    savedPositionToRestore = nil
                    seek(to: pos)
                }
                loadAudioTracks(from: item)
                needsQuickStartup = false
                isLoading = false
                timeToPlayMs = Int(Date().timeIntervalSince(videoLoadStartedAt) * 1000)
                lastSuccessfulStreamType = label
                if timeToPlayMs > 4_000 {
                    DiagnosticsLogger.recordSlowVideoLoad(
                        videoId: video.id,
                        elapsedMs: timeToPlayMs,
                        streamType: label,
                        hasError: false
                    )
                }
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                launchPhase2(video: video, info: info)
                // Track whether the succeeded stream is muxed so quality-switch attempts
                // can detect the state and trigger fresh WKWebView extraction (#210).
                qualityManager.isMuxedFallback = isMuxedFallback
                return true
            case .failed:
                let err = item.error.map { "\($0)" } ?? "nil"
                let nsErr = item.error as? NSError
                let failURL = nsErr?.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
                    ?? nsErr?.userInfo["NSErrorFailingURLKey"] as? String
                playerLog.error("❌ [\(label)] AVPlayerItem failed: \(err)")
                if let failURL {
                    playerLog.error("❌ [\(label)] failing URL: \(failURL.prefix(200))")
                }
                return false
            case .unknown:
                continue
            @unknown default:
                continue
            }
        }
        return false
    }

    /// Composes a video-only + audio-only adaptive stream pair via `AVMutableComposition`.
    /// Returns true on successful `.readyToPlay`.
    func attemptComposition(
        videoURL: URL, audioURL: URL,
        for video: Video, info: PlayerInfo, label: String
    ) async -> Bool {
        let videoItag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let audioItag = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let videoRqh = videoURL.absoluteString.contains("rqh=1") || videoURL.absoluteString.contains("/rqh/1")

        // Use the client UA that matches the URL's signing client.
        let clientParam = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value?.uppercased() ?? ""

        // Skip every rqh=1 stream by default — no client works without a pot= token.
        // Exception: TVAuth (TVHTML5) with a valid Bearer token. The official YouTube TV
        // app plays TVHTML5 rqh=1 adaptive streams without BotGuard — Bearer token may
        // satisfy CDN auth for authenticated TV sessions. An 8-second timeout (added to
        // the raceStream below) prevents indefinite hangs if the CDN holds the connection.
        // NOTE: BotGuard websafe fallback token (json[3] from GenerateIT) is NOT accepted
        // by the CDN for rqh=1 segments — only the full minting path (getMinter) produces
        // a CDN-accepted token, which requires a real browser JS context (WKWebView).
        // hasMintedPoToken is set in exhaustiveRetry when BotGuardWebViewRunner succeeds
        // with a full getMinter-minted token — those ARE accepted by the CDN.
        let isTVAuthBearer    = label.contains("TVAuth") && hasAuthToken && currentAuthToken != nil
        let isAndroidVR       = clientParam == "ANDROID_VR"
        #if canImport(WebKit)
        let isBotGuardMinted  = label == "BotGuardWV" && hasMintedPoToken
        #else
        let isBotGuardMinted  = false
        #endif
        if videoRqh && !isTVAuthBearer && !isAndroidVR && !isBotGuardMinted {
            playerLog.notice("[\(label)/adaptive] skipping rqh=1 (client=\(clientParam)) — not exempt")
            return false
        }
        if videoRqh && isBotGuardMinted {
            playerLog.notice("[\(label)/adaptive] attempting rqh=1 with WKWebView-minted BotGuard token (client=\(clientParam)) — CDN should accept")
        } else if videoRqh {
            playerLog.notice("[\(label)/adaptive] attempting rqh=1 TVAuth with Bearer — CDN auth experiment")
        }
        let ua: String
        switch clientParam {
        case "ANDROID_VR":   ua = InnerTubeClients.AndroidVR.userAgent
        case "ANDROID":      ua = InnerTubeClients.Android.userAgent
        case "VISIONOS":     ua = InnerTubeClients.VisionOS.userAgent
        case "TVHTML5":      ua = InnerTubeClients.TV.userAgent
        case "MWEB":         ua = InnerTubeClients.MWEB.userAgent
        case "WEB_CREATOR":  ua = InnerTubeClients.Web.userAgent
        default:             ua = InnerTubeClients.iOS.userAgent
        }

        playerLog.notice("[\(label)/adaptive] videoItag=\(videoItag) client=\(clientParam) audioItag=\(audioItag)")

        playerInfo = info
        let newFormats = Self.deduplicatedVideoFormats(info.formats)
        // Never reduce quality options — same policy as attemptURL.
        let maxCurrentHeight = availableFormats.map(\.height).max() ?? 0
        let maxNewHeight = newFormats.map(\.height).max() ?? 0
        if newFormats.count > availableFormats.count || maxNewHeight > maxCurrentHeight || availableFormats.isEmpty {
            availableFormats = newFormats
        }
        playerLog.notice("[\(label)/adaptive] availableFormats after dedup: input=\(info.formats.count) output=\(newFormats.count) kept=\(availableFormats.count) maxH=\(availableFormats.map(\.height).max() ?? 0)")
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        // Inject Bearer only for TVAuth (TVHTML5 authenticated) — CDN validates the
        // TV session token for rqh=1 streams. Android VR uses Oculus UA without OAuth;
        // injecting a TV Bearer token causes CDN to hold the connection and reject it.
        var assetHeaders: [String: String] = ["User-Agent": ua]
        if videoRqh && isTVAuthBearer, let token = currentAuthToken {
            assetHeaders["Authorization"] = "Bearer \(token)"
            playerLog.notice("[\(label)/adaptive] injecting Bearer auth into CDN headers for TVAuth rqh=1")
        }
        if videoRqh && isBotGuardMinted {
            // Inject youtube.com cookies (VISITOR_INFO1_LIVE) cross-domain to googlevideo.com.
            // The CDN validates bui= against VISITOR_INFO1_LIVE — without it, the CDN holds
            // the connection (no immediate 403, but our 3s loadTracks timeout fires).
            // BotGuardWebViewRunner.propagateWebViewCookies() copies WKWebView session cookies
            // into HTTPCookieStorage.shared, making VISITOR_INFO1_LIVE available here.
            let ytCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.youtube.com")!) ?? []
            if !ytCookies.isEmpty {
                assetHeaders["Cookie"] = ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                playerLog.notice("[\(label)/adaptive] injecting \(ytCookies.count) youtube.com cookies for BotGuard rqh=1 CDN auth")
            }
        }

        // CDN probe for Android VR rqh=1 — avoids loadTracks timeout when CDN enforces
        // SABR at the content level. URLSession.data(for:) accumulates the full response
        // body before returning; if the CDN stalls mid-body the 1.5s timeout fires → nil.
        //
        // Range must cover the moov atom. The CDN returns HTTP 206 for small byte ranges
        // (including bytes=0-0 and bytes=0-1023) even for SABR-enforced videos — it
        // serves the initial container bytes (ftyp box, partial moov header) freely —
        // but then stalls larger sequential reads that AVURLAsset.loadTracks needs to
        // parse track metadata. The moov atom for a typical YouTube 720p video is
        // 20–200 KB; using bytes=0-131071 (128 KB) ensures we cover it. A stalling CDN
        // delivers a few KB then hangs; URLSession.data(for:) won't return until the
        // complete 128 KB body arrives, so the 1.5s timeout fires and we bail early.
        //
        // Timing: 128 KB at 148 Mbps ≈ 7 ms; at 10 Mbps ≈ 100 ms; stall → 1.5s.
        // TVAuth with Bearer is intentionally excluded — injecting an OAuth token into
        // a bare URLSession changes CDN session state, separate from AVURLAsset context.
        if videoRqh && isAndroidVR {
            var probeReq = URLRequest(url: videoURL)
            probeReq.setValue(ua, forHTTPHeaderField: "User-Agent")
            probeReq.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
            probeReq.timeoutInterval = 1.5
            if let (_, probeResp) = try? await URLSession(configuration: .ephemeral).data(for: probeReq),
               let http = probeResp as? HTTPURLResponse {
                if http.statusCode == 403 || http.statusCode == 401 {
                    playerLog.notice("❌ [\(label)/adaptive] rqh=1 probe: HTTP \(http.statusCode) — CDN enforcing rqh, skipping composition")
                    return false
                }
                playerLog.notice("[\(label)/adaptive] rqh=1 probe: HTTP \(http.statusCode) 128KB delivered — moov atom accessible, proceeding")
            } else {
                // CDN stalled before delivering 128 KB. This predicts loadTracks failure
                // (moov atom not accessible), so bail immediately rather than waiting 2s.
                playerLog.notice("⚠️ [\(label)/adaptive] rqh=1 probe: timeout after 1.5s (128KB stall) — CDN enforcing SABR, skipping composition")
                return false
            }
        }

        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": assetHeaders])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": assetHeaders])

        do {
            // loadTracks can stall indefinitely when rqh=1 CDN URLs don't fail fast.
            // @MainActor task-group child tasks are subject to main-actor scheduling
            // pressure (XCTest accessibility callbacks), so withThrowingTaskGroup is
            // unreliable here even with Task.detached wrappers.
            //
            // Solution: use AsyncStream as a cross-thread coordination channel.
            // Both the loadTracks work AND the 8-second timeout run in fully-detached
            // tasks (thread pool, no actor isolation). Whichever finishes first yields
            // to the stream. The main-actor consumer resumes when either signal arrives,
            // regardless of main-actor scheduling pressure.
            let vTracks: [AVAssetTrack]
            let aTracks: [AVAssetTrack]
            do {
                // AVAssetTrack is not Sendable in Swift 6 strict mode.
                // Wrap the pair so AsyncStream<TrackBox?> satisfies Sendable.
                // Ownership is transferred atomically through the stream; no concurrent
                // access occurs after the box is read on the main actor.
                struct TrackBox: @unchecked Sendable {
                    let video: [AVAssetTrack]
                    let audio: [AVAssetTrack]
                }
                let (raceStream, raceCont) = AsyncStream<TrackBox?>.makeStream()

                // loadTracks on thread pool — yields result or nil on error
                Task.detached {
                    let box: TrackBox? = try? await { () async throws -> TrackBox in
                        async let v = videoAsset.loadTracks(withMediaType: .video)
                        async let a = audioAsset.loadTracks(withMediaType: .audio)
                        let (vv, aa) = try await (v, a)
                        return TrackBox(video: vv, audio: aa)
                    }()
                    raceCont.yield(box)
                    raceCont.finish()
                }

                // Timeout task — prevents indefinite CDN hang for rqh=1 Bearer experiments.
                // After finish() is called by either task, subsequent yield/finish are no-ops.
                // On tvOS/iOS: AndroidVR gets 2s — the firstByte probe (Range: bytes=0-0) is a
                // false positive for rqh=1 CDN enforcement: the CDN serves the first byte (206)
                // but stalls actual AVURLAsset segment requests. fast non-rqh videos complete
                // loadTracks in ~0.4s, so 2s is a safe margin on both platforms.
                // fix1/tvOS: 2s validated correct. fix_task240: apply same 2s cap to iOS — log
                // shows 8s × 2 (race + serial) = 16s wasted on `cnsKl2JouOc` class of video.
                let isVRAttempt = clientParam == "ANDROID_VR"
                #if os(tvOS)
                let timeoutNs: UInt64 = isVRAttempt ? 2_000_000_000 : 3_000_000_000
                #elseif os(macOS)
                // macOS gets a far longer budget than the iOS caps below.
                //
                // Those caps exist for a specific false positive: on iOS the
                // rqh=1 CDN answers the one-byte probe with a 206 and then
                // stalls the real segment requests, so a short timeout avoids
                // wasting 8s per attempt. On this machine the probe reports
                // "HTTP 206 128KB delivered — moov atom accessible" and
                // loadTracks *is* progressing — it simply needs longer than 2s
                // to pull the moov atom over a cold connection. Cutting it off
                // at the iOS value threw away a working stream, which is the
                // difference between playback and none at all.
                let timeoutNs: UInt64 = isVRAttempt ? 12_000_000_000 : 15_000_000_000
                #else
                // fix30 (task #230): 1.5s for non-VR iOS first-video loads.
                // fix_task240: 2s for AndroidVR (was 8s) — false-positive probe scenario.
                let timeoutNs: UInt64 = isVRAttempt ? 2_000_000_000 : (needsQuickStartup ? 1_500_000_000 : 8_000_000_000)
                #endif
                Task.detached {
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    raceCont.yield(nil)
                    raceCont.finish()
                }

                if let firstOrNil = await raceStream.first(where: { @Sendable _ in true }),
                   let box = firstOrNil {
                    vTracks = box.video
                    aTracks = box.audio
                } else {
                    #if os(tvOS)
                    let timeoutSec = isVRAttempt ? 2 : 3
                    #elseif os(macOS)
                    let timeoutSec = isVRAttempt ? 12 : 15
                    #else
                    let timeoutSec = isVRAttempt ? 2 : (needsQuickStartup ? 1 : 8)  // VR=2s (fix_task240), non-VR quick=1.5s (fix30)
                    #endif
                    let reason = "timed out after \(timeoutSec)s or loadTracks failed"
                    playerLog.error("❌ [\(label)/adaptive] loadTracks \(reason) (rqh=\(videoRqh))")
                    return false
                }
            }

            guard let sourceVideoTrack = vTracks.first,
                  let sourceAudioTrack = aTracks.first else {
                playerLog.error("❌ [\(label)/adaptive] no tracks in remote assets (rqh=\(videoRqh))")
                return false
            }

            let videoDuration = try await videoAsset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: videoDuration)
            let composition = AVMutableComposition()

            guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                playerLog.error("❌ [\(label)/adaptive] could not add composition tracks")
                return false
            }

            try compVideo.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            try compAudio.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)

            playerLog.notice("✅ [\(label)/adaptive] composition built — testing playback for \(video.id)")
            lastAttemptedStreamURL = videoURL
            let compositeItem = AVPlayerItem(asset: composition)
            compositeItem.audioTimePitchAlgorithm = .spectral
            // fix11: Fast-start — fire readyToPlay after 0.5 s of buffered content.
            // Without this, AVMutableComposition items use the system default heuristic
            // (effectively unconstrained), which adds 0.3–0.5 s to initial buffering.
            // Reset to system default (0) in a ramp Task so downstream buffering is
            // not constrained after startup (same pattern as HLS paths).
            compositeItem.preferredForwardBufferDuration = 0.5
            Task { [weak compositeItem] in
                try? await Task.sleep(for: .seconds(5))
                compositeItem?.preferredForwardBufferDuration = 0
            }
            // fix235: Guard cancellation and video identity before touching the player.
            guard !Task.isCancelled, currentVideo?.id == video.id else {
                playerLog.notice("⚠️ [\(label)/adaptive] fix235: task cancelled or video changed (current=\(currentVideo?.id ?? "nil") expected=\(video.id)) — aborting replaceCurrentItem")
                return false
            }
            player.replaceCurrentItem(with: compositeItem)
            installEndAndStallObservers(for: compositeItem)
            itemObserverTask?.cancel()

            for await status in compositeItem.statusStream {
                switch status {
                case .readyToPlay:
                    playerLog.notice("[benchmark] readyToPlay — \(label)/adaptive — videoId=\(video.id) title=\(video.title)")
                    playerLog.notice("✅ [\(label)/adaptive] readyToPlay")
                    let compDur = compositeItem.duration.seconds
                    if compDur.isFinite && compDur > 0 {
                        let prevDur = self.duration
                        self.duration = compDur
                        playerLog.notice("[duration] updated from composition AVPlayerItem: \(String(format: "%.1f", compDur))s (was \(String(format: "%.1f", prevDur))s from metadata)")
                    } else if self.duration == 0 {
                        durationObserverTask?.cancel()
                        durationObserverTask = Task { [weak self, weak compositeItem] in
                            guard let self, let compositeItem else { return }
                            for await seconds in compositeItem.firstValidDurationStream {
                                guard !Task.isCancelled else { return }
                                let prev = self.duration
                                self.duration = seconds
                                playerLog.notice("[duration] deferred KVO update: \(String(format: "%.1f", seconds))s (was \(String(format: "%.1f", prev))s)")
                                break
                            }
                        }
                    }
                    if let pos = savedPositionToRestore, pos > 0 {
                        savedPositionToRestore = nil
                        seek(to: pos)
                    }
                    loadAudioTracks(from: compositeItem)
                    needsQuickStartup = false
                    isLoading = false
                    timeToPlayMs = Int(Date().timeIntervalSince(videoLoadStartedAt) * 1000)
                    if timeToPlayMs > 4_000 {
                        DiagnosticsLogger.recordSlowVideoLoad(
                            videoId: video.id,
                            elapsedMs: timeToPlayMs,
                            streamType: "\(label)/adaptive",
                            hasError: false
                        )
                    }
                    player.rate = Float(settings.playbackSpeed)
                    isPlaying = true
                    launchPhase2(video: video, info: info)
                    return true
                case .failed:
                    let nsErr = compositeItem.error as? NSError
                    let httpStatus = (nsErr?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -12660 ? 403 : (nsErr?.code ?? -1)
                    playerLog.error("❌ [\(label)/adaptive] AVPlayerItem failed: domain=\(nsErr?.domain ?? "?") code=\(nsErr?.code ?? -1) httpStatus=\(httpStatus)")
                    return false
                case .unknown:
                    continue
                @unknown default:
                    continue
                }
            }
            return false
        } catch {
            let nsErr = error as NSError
            let httpStatus = (nsErr.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -12660 ? 403 : nsErr.code
            playerLog.error("❌ [\(label)/adaptive] setup failed: domain=\(nsErr.domain) code=\(nsErr.code) httpStatus=\(httpStatus)")
            return false
        }
    }

    func launchPhase2(video: Video, info: PlayerInfo, cached: CachedVideoData? = nil) {
        phase2Task?.cancel()
        phase2Task = Task(priority: .utility) { [weak self] in
            // Use the caller-supplied cached data when available so Phase 2 can use
            // already-consumed nextInfo/endCards/sponsorSegments instead of re-fetching.
            // Falls back to empty (full network fetch) when no cached data is passed
            // (e.g. from the 3-attempt retry loop which doesn't have the original cached struct).
            let p2Cached = cached ?? CachedVideoData(
                playerInfo: nil, trackingURLs: nil, nextInfo: nil,
                endCards: nil, sponsorSegments: nil, deArrowBranding: nil,
                staleFields: []
            )
            await self?.loadAsyncPhase2(
                video: video, cached: p2Cached, info: info,
                cachedTrackingURLs: cached?.trackingURLs ?? nil, authTrackingTask: nil,
                sponsorCached: cached?.sponsorSegments != nil
            )
        }
        // Background pre-warming runs alongside phase2:
        //  • muxed fallback → fetch AndroidVR playerInfo so quality-tap skips 403 recovery
        //  • adaptive playing → pre-warm tracks for the user's preferred quality tier
        prefetchTask?.cancel()
        if info.bestAdaptiveAudioURL == nil {
            prefetchTask = Task(priority: .utility) { [weak self] in
                await self?.fetchAndCacheAdaptivePlayerInfo(video: video, muxedInfo: info)
            }
        } else if settings.preferredQuality != .auto {
            prefetchTask = Task(priority: .utility) { [weak self] in
                await self?.prefetchPreferredQualityTracks(info: info)
            }
        }
    }

    /// Called from `launchPhase2` when muxed 360p is the only available stream
    /// (`info.bestAdaptiveAudioURL == nil`).  Fetches AndroidVR player info in the
    /// background and upgrades `self.playerInfo` so that the first quality-tap skips
    /// the 17-second 403-recovery cycle.
    private func fetchAndCacheAdaptivePlayerInfo(video: Video, muxedInfo: PlayerInfo) async {
        playerLog.notice("[prefetch] muxed fallback — fetching AndroidVR playerInfo in background")
        do {
            let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
            guard !Task.isCancelled else { return }
            guard vrInfo.bestAdaptiveAudioURL != nil else {
                playerLog.notice("[prefetch] AndroidVR returned no adaptive audio — playerInfo not upgraded")
                return
            }
            guard currentVideo?.id == video.id, playerInfo?.bestAdaptiveAudioURL == nil else {
                playerLog.notice("[prefetch] playerInfo already upgraded or video changed — discarding prefetch result")
                return
            }
            playerInfo = vrInfo
            let vrFormats = Self.deduplicatedVideoFormats(vrInfo.formats)
            let maxCurrentH = availableFormats.map(\.height).max() ?? 0
            let maxVRH = vrFormats.map(\.height).max() ?? 0
            // Only update availableFormats (quality-picker options) when at least one format
            // is rqh-free. rqh=1 formats are immediately reverted by reloadDASHItem's rqh guard
            // and should not appear in the picker.
            let hasRqhFreeFormat = vrFormats.contains { fmt in
                guard let url = fmt.url else { return false }
                return !PlaybackQualityManager.urlHasRqhEnforcement(url)
            }
            if hasRqhFreeFormat && (vrFormats.count > availableFormats.count || maxVRH > maxCurrentH) {
                availableFormats = vrFormats
            }
            playerLog.notice("⚡ [prefetch] playerInfo upgraded to AndroidVR (\(vrFormats.count) formats) — quality switches skip 403 recovery")
            await prefetchPreferredQualityTracks(info: vrInfo)
        } catch {
            playerLog.notice("[prefetch] background AndroidVR fetch failed: \(error)")
        }
    }

    /// Pre-loads `AVAssetTrack` arrays for `settings.preferredQuality` into
    /// `AVAssetTrackCache` so that the first quality-tap after initial playback
    /// is a cache hit rather than a CDN round-trip.
    private func prefetchPreferredQualityTracks(info: PlayerInfo) async {
        guard settings.preferredQuality != .auto,
              let maxH = settings.preferredQuality.maxHeight else { return }
        guard let videoURL = PlaybackQualityManager.selectBestVideoFormat(
                  from: info.formats, preferredMaxHeight: maxH,
                  preferH264: settings.preferH264
              )?.url,
              let audioURL = info.bestAdaptiveAudioURL else { return }
        if AVAssetTrackCache.shared.videoTracks(for: videoURL) != nil { return }
        let itag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let ua = InnerTubeClients.iOS.userAgent
        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        playerLog.notice("[prefetch] pre-warming tracks for preferredQuality=\(maxH)p (itag=\(itag))")
        struct PrefetchTrackBox: @unchecked Sendable {
            let video: [AVAssetTrack]; let audio: [AVAssetTrack]
        }
        let (stream, cont) = AsyncStream<PrefetchTrackBox?>.makeStream()
        Task.detached {
            let box: PrefetchTrackBox? = try? await { () async throws -> PrefetchTrackBox in
                async let v = videoAsset.loadTracks(withMediaType: .video)
                async let a = audioAsset.loadTracks(withMediaType: .audio)
                let (vv, aa) = try await (v, a)
                return PrefetchTrackBox(video: vv, audio: aa)
            }()
            cont.yield(box)
            cont.finish()
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
            cont.yield(nil)
            cont.finish()
        }
        if let result = await stream.first(where: { @Sendable _ in true }),
           let box = result, !box.video.isEmpty, !box.audio.isEmpty {
            AVAssetTrackCache.shared.store(videoTracks: box.video, audioTracks: box.audio,
                                            videoURL: videoURL, audioURL: audioURL)
            playerLog.notice("⚡ [prefetch] tracks cached for preferredQuality=\(maxH)p (itag=\(itag))")
        } else {
            playerLog.notice("[prefetch] track prefetch timed out/failed for preferredQuality=\(maxH)p")
        }
    }

    /// Prefetches `AVAssetTrack` metadata for ALL available quality tiers at `.userInitiated`
    /// priority. Call this when the quality picker opens so that by the time the user taps a
    /// quality, the tracks are already cached and the switch completes in < 100ms (Fix 2A).
    func prefetchAllQualityTracks() async {
        guard let info = playerInfo else { return }
        guard info.hlsURL == nil else { return } // HLS doesn't need DASH track prefetch
        guard let audioURL = info.bestAdaptiveAudioURL else { return }
        guard !PlaybackQualityManager.urlHasRqhEnforcement(audioURL) else { return }

        let formats = Self.deduplicatedVideoFormats(info.formats)
        let ua = InnerTubeClients.iOS.userAgent

        // Load audio tracks once — shared across all video qualities.
        let audioTracks: [AVAssetTrack]
        if let cached = AVAssetTrackCache.shared.audioTracks(for: audioURL), !cached.isEmpty {
            audioTracks = cached
        } else {
            let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
            guard let loaded = try? await audioAsset.loadTracks(withMediaType: .audio), !loaded.isEmpty else { return }
            audioTracks = loaded
        }

        for fmt in formats.prefix(6) {
            guard !Task.isCancelled else { return }
            guard let videoURL = fmt.url else { continue }
            guard !PlaybackQualityManager.urlHasRqhEnforcement(videoURL) else { continue }
            guard AVAssetTrackCache.shared.videoTracks(for: videoURL) == nil else { continue }
            let itag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
            let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
            playerLog.notice("[prefetch/picker] pre-warming \(fmt.height)p itag=\(itag)")
            if let vTracks = try? await videoAsset.loadTracks(withMediaType: .video), !vTracks.isEmpty {
                AVAssetTrackCache.shared.store(videoTracks: vTracks, audioTracks: audioTracks,
                                               videoURL: videoURL, audioURL: audioURL)
                playerLog.notice("⚡ [prefetch/picker] cached \(fmt.height)p itag=\(itag)")
            }
        }
    }

    /// Rebuilds the `AVMutableComposition` during a quality switch for DASH/MP4-only videos
    /// (where `hlsURL == nil`). Mirrors `attemptComposition` but does not reset `playerInfo`
    /// or `availableFormats` and does not call `launchPhase2` — this is a mid-playback swap.
    func rebuildCompositionForQuality(videoURL: URL, audioURL: URL, seekTo: TimeInterval) async {
        let videoItag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let audioItag = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        // Always use the iOS UA regardless of URL signing (c=ANDROID or c=IOS).
        // The initial attemptComposition path uses iOS UA for all URLs including
        // Android-client-signed ones, and it succeeds. Using Android UA for c=ANDROID
        // URLs was an incorrect assumption — it caused HTTP 403 instead of preventing it.
        let ua = InnerTubeClients.iOS.userAgent
        playerLog.notice("[quality/DASH] rebuilding composition — videoItag=\(videoItag) audioItag=\(audioItag) ua=iOS")

        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])

        do {
            // ── loadTracks with 60-second timeout ────────────────────────────────────
            // Without a timeout, rqh=1 CDN URLs hold the TCP connection open indefinitely,
            // causing quality-switch composition to hang forever (player stays at 360p).
            // The AsyncStream + Task.detached pattern mirrors attemptComposition to avoid
            // @MainActor scheduling pressure on withThrowingTaskGroup child tasks.
            let vTracks: [AVAssetTrack]
            let aTracks: [AVAssetTrack]
            let cachedV = AVAssetTrackCache.shared.videoTracks(for: videoURL)
            let cachedA = AVAssetTrackCache.shared.audioTracks(for: audioURL)
            if let cv = cachedV, let ca = cachedA, !cv.isEmpty, !ca.isEmpty {
                vTracks = cv
                aTracks = ca
                playerLog.notice("⚡ [quality/DASH] loadTracks cache hit (itag=\(videoItag)) — skipping CDN round-trip")
            } else {
            do {
                struct TrackBox: @unchecked Sendable {
                    let video: [AVAssetTrack]
                    let audio: [AVAssetTrack]
                }
                let (raceStream, raceCont) = AsyncStream<TrackBox?>.makeStream()
                Task.detached {
                    let box: TrackBox? = try? await { () async throws -> TrackBox in
                        async let v = videoAsset.loadTracks(withMediaType: .video)
                        async let a = audioAsset.loadTracks(withMediaType: .audio)
                        let (vv, aa) = try await (v, a)
                        return TrackBox(video: vv, audio: aa)
                    }()
                    raceCont.yield(box)
                    raceCont.finish()
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(10))
                    raceCont.yield(nil)
                    raceCont.finish()
                }
                if let firstOrNil = await raceStream.first(where: { @Sendable _ in true }),
                   let box = firstOrNil {
                    vTracks = box.video
                    aTracks = box.audio
                    AVAssetTrackCache.shared.store(videoTracks: vTracks, audioTracks: aTracks,
                                                    videoURL: videoURL, audioURL: audioURL)
                } else {
                    playerLog.error("❌ [quality/DASH] loadTracks timed out after 10s — triggering 403 recovery retry")
                    selectedFormat = nil
                    if statsForNerdsVisible { updateStatsSnapshot() }
                    if let video = currentVideo {
                        await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                        HLSManifestCache.shared.invalidate(for: video.id)
                        await retryWith403Recovery(video: video, originalError: nil)
                    }
                    return
                }
            }
            } // end cache-miss else
            // ─────────────────────────────────────────────────────────────────────────

            guard let sourceVideoTrack = vTracks.first,
                  let sourceAudioTrack = aTracks.first else {
                playerLog.error("❌ [quality/DASH] no tracks in remote assets — triggering 403 recovery retry")
                selectedFormat = nil
                if statsForNerdsVisible { updateStatsSnapshot() }
                if let video = currentVideo {
                    await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                    HLSManifestCache.shared.invalidate(for: video.id)
                    await retryWith403Recovery(video: video, originalError: nil)
                }
                return
            }

            let videoDuration = try await videoAsset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: videoDuration)
            let composition = AVMutableComposition()

            guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                playerLog.error("❌ [quality/DASH] could not add composition tracks")
                selectedFormat = nil
                if statsForNerdsVisible { updateStatsSnapshot() }
                return
            }

            try compVideo.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            try compAudio.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            playerLog.notice("✅ [quality/DASH] composition built — swapping item")

            lastAttemptedStreamURL = videoURL
            let compositeItem = AVPlayerItem(asset: composition)
            isQualityChangePending = true
            isSwappingItem = true
            player.replaceCurrentItem(with: compositeItem)
            installEndAndStallObservers(for: compositeItem)
            isSwappingItem = false
            itemObserverTask?.cancel()

            for await status in compositeItem.statusStream {
                switch status {
                case .readyToPlay:
                    let size = compositeItem.presentationSize
                    let benchVid = self.currentVideo?.id ?? "nil"
                    let benchTitle = self.currentVideo?.title ?? "nil"
                    playerLog.notice("[benchmark] readyToPlay — quality/DASH — videoId=\(benchVid) title=\(benchTitle)")
                    playerLog.notice("✅ [quality/DASH] readyToPlay — presentationSize=\(Int(size.width))x\(Int(size.height))")
                    isQualityChangePending = false
                    // Use currentTime (preserved by time observer freeze) instead of seekTo
                    // to honour any user seek that occurred during the DASH rebuild transition.
                    let seekTarget = currentTime > 0 ? currentTime : seekTo
                    playerLog.notice("[quality/DASH] readyToPlay — seekTarget=\(seekTarget)s (currentTime=\(currentTime)s savedSeekTo=\(seekTo)s)")
                    if seekTarget > 0 { seek(to: seekTarget) }
                    loadAudioTracks(from: compositeItem)
                    player.rate = Float(settings.playbackSpeed)
                    isPlaying = true
                    return
                case .failed:
                    let itemError = compositeItem.error
                    let errStr = itemError.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ [quality/DASH] AVPlayerItem failed: \(errStr) — triggering 403 recovery retry")
                    selectedFormat = nil
                    if statsForNerdsVisible { updateStatsSnapshot() }
                    if let video = currentVideo {
                        await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                        HLSManifestCache.shared.invalidate(for: video.id)
                        await retryWith403Recovery(video: video, originalError: itemError)
                    }
                    return
                case .unknown:
                    continue
                @unknown default:
                    continue
                }
            }
        } catch {
            playerLog.error("❌ [quality/DASH] composition build error: \(error) — triggering 403 recovery retry")
            selectedFormat = nil
            if statsForNerdsVisible { updateStatsSnapshot() }
            if let video = currentVideo {
                await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                HLSManifestCache.shared.invalidate(for: video.id)
                await retryWith403Recovery(video: video, originalError: error)
            }
        }
    }

    // MARK: - Helpers

    /// Returns the AVFoundation User-Agent for `url` based on its `c=` signing parameter.
    /// NOTE: This helper is no longer used by `rebuildCompositionForQuality`, which now always
    /// uses iOS UA. Kept for reference — the original assumption (Android UA needed for
    /// c=ANDROID URLs) was incorrect; the initial `attemptComposition` path proves iOS UA
    /// works for all URL signing variants.
    static func userAgent(for url: URL) -> String {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value ?? ""
        return client.hasPrefix("ANDROID") ? InnerTubeClients.Android.userAgent : InnerTubeClients.iOS.userAgent
    }

    /// Returns the best adaptive video-only MP4 URL, respecting the user's quality preference.
    /// When `preferredQuality != .auto`, filters to formats at or below `maxHeight`, sorts
    /// by height descending then bitrate descending. Falls back to highest bitrate when no
    /// format meets the height cap.
    /// When `preferredQuality == .auto`, caps at the display's native resolution so the
    /// player never fetches a resolution higher than the screen can render.
    ///
    /// H.264 (avc1) is preferred over AV1 (av01) at any given resolution because Android-client
    /// AV1 streams require a proof-of-origin token (pot) that the app does not supply, causing
    /// systematic HTTP 403 errors on adaptive composition. H.264 streams are served without
    /// that restriction and are well-supported by AVFoundation.
    func qualityCapVideoURL(from formats: [YouTubeCore.VideoFormat]) -> URL? {
        let maxH: Int
        if settings.preferredQuality != .auto, let h = settings.preferredQuality.maxHeight {
            maxH = h
        } else {
            // Auto: cap at the display's native resolution — no benefit loading higher
            // than what the screen can actually render.
            maxH = Self.displayMaxVideoHeight()
        }
        return PlaybackQualityManager.selectBestVideoFormat(
            from: formats,
            preferredMaxHeight: maxH,
            preferH264: true
        )?.url
    }

    /// Returns the maximum video height (pixels) that this display can render for
    /// landscape 16:9 content. Used to cap quality in Auto mode.
    ///
    /// The shorter native-pixel dimension equals the landscape height — the maximum
    /// video height the screen can actually show for standard 16:9 YouTube content.
    static func displayMaxVideoHeight() -> Int {
        #if canImport(UIKit)
        let bounds = UIScreen.main.nativeBounds
        return Int(max(bounds.width, bounds.height))
        #else
        // On a landscape desktop display the short side *is* the maximum height
        // a 16:9 video can occupy, so take the minimum rather than the maximum.
        // (iOS reports `nativeBounds` portrait-oriented, which is why that branch
        // takes the max instead — the two are asking for the same number.)
        let size = PlatformScreen.nativePixelSize
        return Int(min(size.width, size.height))
        #endif
    }

}
