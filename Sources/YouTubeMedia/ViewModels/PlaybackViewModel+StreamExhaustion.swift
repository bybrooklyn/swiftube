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

// MARK: - Stream exhaustion: every stream one PlayerInfo offers, in order (split out of +Fallback)
extension PlaybackViewModel {

    // MARK: - Stream Exhaustion

    /// Tries HLS → adaptive composition → (optionally) muxed direct from one PlayerInfo.
    /// Returns true if any stream starts playing successfully.
    /// - Parameter skipMuxed: When `true`, the muxed direct-MP4 fallback is skipped so that
    ///   the caller can try higher-priority clients before accepting the 360p muxed last-resort.
    func tryAllStreams(video: Video, info: PlayerInfo, label: String,
                        skipMuxed: Bool = false) async -> Bool {
        let hasHLS = info.hlsURL != nil
        let hasDASH = info.dashURL != nil
        let hasAdaptiveVideo = qualityCapVideoURL(from: info.formats) != nil
        let hasAdaptiveAudio = info.bestAdaptiveAudioURL != nil
        let hasMuxed = info.bestMuxedDownloadURL != nil
        // Diagnostic: show first adaptive video URL prefix to detect SABR (c=TVHTML5) vs standard
        let firstAdaptiveURL = info.formats.first(where: {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        })?.url?.absoluteString.prefix(200) ?? "none"
        playerLog.notice("[\(label)] streams: HLS=\(hasHLS) DASH=\(hasDASH) adaptiveVideo=\(hasAdaptiveVideo) adaptiveAudio=\(hasAdaptiveAudio) muxed=\(hasMuxed) skipMuxed=\(skipMuxed) firstAdaptiveURL=\(firstAdaptiveURL)")

        // 1. HLS manifest — best quality, native AVPlayer ABR, alternate audio renditions
        if let hlsURL = info.hlsURL {
            playerLog.notice("[\(label)] Trying HLS")
            if await attemptURL(hlsURL, for: video, info: info, label: "\(label)/HLS") { return true }
            playerLog.notice("[\(label)] HLS failed — trying adaptive composition")
        }

        // 2. Adaptive composition — video-only + audio-only; avoids muxed CDN pot restrictions
        if let videoURL = qualityCapVideoURL(from: info.formats),
           let audioURL = info.bestAdaptiveAudioURL {
            // Guard: if every adaptive video URL is SABR (c=TVHTML5), AVURLAsset.loadTracks
            // will stall for 60 s then return -11828 "Cannot Open". Skip composition entirely
            // and let exhaustiveRetry's WKWebView path handle the video instead.
            if info.containsSabrFormats {
                playerLog.notice("[\(label)] All adaptive video URLs are SABR (c=TVHTML5) — skipping loadTracks stall, falling through")
            // Guard: if every adaptive video URL has rqh=1, AVURLAsset.loadTracks stalls
            // for ~8 s on the CDN's byte-range probe because rqh=1 requires CDN auth that
            // URLSession cannot provide (same class of stall as SABR but shorter timeout).
            // Skip composition and route to WKWebView HLS (spc=-authenticated).
            // Exception: if a WKWebView-extracted pot= token is available (Option B), the
            // adaptive URLs have already had &pot=<token> appended via applyingPoToken(),
            // so CDN auth may succeed — attempt composition before falling through.
            } else if info.containsRqhAdaptiveFormats {
                let hasPot = await api.hasPoToken(for: video.id)
                // ANDROID_VR is exempt from CDN rqh=1 enforcement (no GVS_PO_TOKEN_POLICY
                // defined for android_vr per yt-dlp source). attemptComposition also has
                // this exemption via isAndroidVR, but it was unreachable from here because
                // this guard returned early before calling it. Allow VR through directly.
                let isAndroidVRLabel = label.contains("AndroidVR") || label.contains("ANDROID_VR")
                if hasPot || isAndroidVRLabel {
                    #if os(tvOS)
                    // fix2: Pre-fetch TVEmbedded concurrently while AndroidVR rqh=1 composition
                    // times out (2s on tvOS). By the time the timeout fires and exhaustiveRetry
                    // reaches Phase 1, the result is ready — eliminating the sequential ~0.5s fetch.
                    // Fire for all AndroidVR attempts regardless of hasPot: the pot= token doesn't
                    // prevent the CDN from enforcing rqh=1 at the segment level (only firstByte
                    // probe returns 206; actual segments still reject with rqh=1).
                    if isAndroidVRLabel, tvEmbeddedEarlyTask == nil {
                        let prefetchVideoId = video.id
                        tvEmbeddedEarlyTask = Task { [weak self] in
                            guard let self else { return nil }
                            return try? await self.api.fetchPlayerInfoTVEmbedded(videoId: prefetchVideoId)
                        }
                        playerLog.notice("[\(label)] fix2: started TVEmbedded early pre-fetch alongside rqh=1 timeout")
                    }
                    #endif
                    playerLog.notice("[\(label)] rqh=1 but \(hasPot ? "pot= token available" : "ANDROID_VR exempt") — attempting adaptive composition")
                    if await attemptComposition(videoURL: videoURL, audioURL: audioURL,
                                                for: video, info: info, label: label) { return true }
                    playerLog.notice("[\(label)] adaptive composition with pot= failed — falling through")
                } else {
                    playerLog.notice("[\(label)] All adaptive video URLs are rqh=1 — skipping 8 s loadTracks stall, falling through")
                }
            } else {
                playerLog.notice("[\(label)] Trying adaptive composition")
                if await attemptComposition(videoURL: videoURL, audioURL: audioURL,
                                            for: video, info: info, label: label) {
                    return true
                }
                // A background prefetch may have stored an HLS URL in the cache while adaptive
                // was running (confirmed in logs: hls=true stored mid-retry for LSMQ3U1Thzw).
                // Check before falling through to muxed — HLS gives us multi-audio track support.
                let freshCachedInfo = await VideoPreloadCache.shared.consume(videoId: video.id).playerInfo
                if let freshHLSURL = freshCachedInfo?.hlsURL, freshHLSURL != info.hlsURL {
                    playerLog.notice("[\(label)] HLS URL appeared in cache after adaptive failed — trying HLS")
                    if await attemptURL(freshHLSURL, for: video, info: freshCachedInfo!,
                                        label: "\(label)/HLS-late") { return true }
                }
                playerLog.notice("[\(label)] Adaptive composition failed — trying muxed")
            }
        }

        // 3. Muxed direct MP4 (itag=18, 360p — last resort, skipped when skipMuxed=true)
        if !skipMuxed, let muxedURL = info.bestMuxedDownloadURL {
            // Guard: TVHTML5 SABR-protocol URLs serve binary data, not a standard MP4 container.
            // AVPlayer returns -11828 (AVFoundationErrorDomain "Cannot Open") for these.
            if muxedURL.absoluteString.contains("c=TVHTML5") {
                playerLog.notice("[\(label)] Skipping SABR muxed URL (c=TVHTML5) — not a playable MP4")
            } else {
                playerLog.notice("[\(label)] Trying muxed")
                let muxedItag = muxedURL.absoluteString
                    .components(separatedBy: "&")
                    .first(where: { $0.contains("itag=") })
                    .flatMap { $0.components(separatedBy: "=").last } ?? "?"
                let muxedBitrate = info.formats.first(where: { $0.url == muxedURL })?.bitrate.map { "\($0/1000)kbps" } ?? "?"
                playerLog.notice("[\(label)] muxed candidate: itag=\(muxedItag) bitrate=\(muxedBitrate) url=\(muxedURL.absoluteString.prefix(100))")
                if await attemptURL(muxedURL, for: video, info: info, label: "\(label)/muxed") { return true }
                playerLog.notice("[\(label)] Muxed failed — no more alternatives for this client")
            }
        }

        return false
    }

}
