/// YTProgressiveProxyLoader.swift
/// Serves a progressive (muxed MP4) stream to AVPlayer through URLSession so the
/// correct client User-Agent reaches googlevideo.
///
/// Same gap `YTHLSProxyLoader` fills for HLS, for the non-HLS case:
/// `AVURLAssetHTTPHeaderFieldsKey` does not reliably reach CoreMedia's network
/// stack, so an `itag=18` URL signed `c=ANDROID_VR` is fetched with
/// AVFoundation's own User-Agent and the CDN answers `HTTP 403: Forbidden` —
/// while the identical URL fetched by URLSession with the Oculus UA returns 206.
/// Measured on this machine, both.
///
/// Routing the asset through a custom scheme puts every byte range under our
/// control, where the header actually sticks.

import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os.log

private let progressiveScheme = "ytprog"
private let proxyLog = Logger(subsystem: "dev.bybrooklyn.youtubetv", category: "Player")

final class YTProgressiveProxyLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    private let userAgent: String
    private let session: URLSession
    /// Consulted per range request rather than captured once: `rqh=1` serves a
    /// free byte budget (measured: ~3.2 MB) before it starts answering 403, and
    /// BotGuard mints the token well inside that window. Reading it late means
    /// playback starts immediately and keeps going once the token lands.
    private let poToken: @Sendable () async -> String?
    /// Asks for a freshly signed URL for the same track.
    ///
    /// `rqh=1` grants a signed URL a fixed free budget — measured here, exactly
    /// 3,276,800 bytes, after which every range is refused, always at that same
    /// offset. The minted `pot=` token does not lift it: that token is bound to
    /// the WEB visitor session, not to the ANDROID_VR one this URL belongs to.
    /// A new `/player` response, though, comes with a new signature and a new
    /// budget — so the way to keep playing is to re-sign, not to re-ask.
    private let renewURL: @Sendable () async -> URL?
    /// The URL currently being served: the original, or the latest renewal.
    private var liveURL: URL?
    /// Total byte length, learned from the first ranged probe and reused after.
    private var contentLength: Int64?
    private var contentType: String?

    /// AVFoundation asks for "everything from here on" for a progressive file.
    /// Answering a bounded slice and finishing makes it come back for the next
    /// one, which keeps memory flat and cancellation responsive.
    ///
    /// 128 KB is not arbitrary. An `rqh=1` URL enforces SABR by range size:
    /// measured here, `bytes=0-1` and `bytes=0-131071` are answered `206`,
    /// while `bytes=0-4194303` is answered `403`. Staying at the size the CDN
    /// already serves is what turns a forbidden stream into a playing one.
    private static let maximumChunk: Int64 = 128 * 1024

    /// The delegate is not retained by the asset, so assets are kept alive here
    /// for as long as the player might use them.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var live: [ObjectIdentifier: YTProgressiveProxyLoader] = [:]

    private init(
        userAgent: String,
        poToken: @escaping @Sendable () async -> String?,
        renewURL: @escaping @Sendable () async -> URL?
    ) {
        self.userAgent = userAgent
        self.poToken = poToken
        self.renewURL = renewURL
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        super.init()
    }

    /// Builds an asset whose every request is routed through this loader.
    /// Returns nil when the URL cannot carry the custom scheme.
    static func makeAsset(
        url: URL,
        userAgent: String,
        poToken: @escaping @Sendable () async -> String? = { nil },
        renewURL: @escaping @Sendable () async -> URL? = { nil }
    ) -> AVURLAsset? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = progressiveScheme
        guard let proxied = components.url else { return nil }

        let loader = YTProgressiveProxyLoader(userAgent: userAgent, poToken: poToken, renewURL: renewURL)
        let asset = AVURLAsset(url: proxied)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "yt.progressive.proxy"))

        lock.lock(); live[ObjectIdentifier(asset)] = loader; lock.unlock()
        return asset
    }

    /// Drops the retained delegate for an asset that is finished with.
    static func release(_ asset: AVURLAsset) {
        lock.lock(); live[ObjectIdentifier(asset)] = nil; lock.unlock()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxied = loadingRequest.request.url,
              var components = URLComponents(url: proxied, resolvingAgainstBaseURL: false) else { return false }
        components.scheme = "https"
        guard let real = components.url else { return false }

        Task { [weak self] in
            guard let self else { return }
            await self.serve(loadingRequest, from: real)
        }
        return true
    }

    private func serve(_ request: AVAssetResourceLoadingRequest, from url: URL) async {
        // Content information: length, type, and that ranges are supported.
        // Learned from a two-byte probe, whose Content-Range carries the total.
        if let info = request.contentInformationRequest {
            if contentLength == nil, !(await probe(url)) {
                request.finishLoading(with: URLError(.badServerResponse))
                return
            }
            info.isByteRangeAccessSupported = true
            info.contentLength = contentLength ?? 0
            if let type = contentType,
               let uti = UTType(mimeType: type)?.identifier {
                info.contentType = uti
            } else {
                info.contentType = UTType.mpeg4Movie.identifier
            }
        }

        guard let data = request.dataRequest else {
            request.finishLoading()
            return
        }

        let offset = data.currentOffset
        // `requestedLength` is Int; for "to the end" it arrives as a very large
        // value, so it is clamped rather than trusted.
        var length = Int64(data.requestedLength)
        if let total = contentLength { length = min(length, total - offset) }
        length = min(length, Self.maximumChunk)
        guard length > 0 else { request.finishLoading(); return }

        let base = await withPoToken(liveURL ?? url)
        var req = URLRequest(url: rangedURL(base, from: offset, to: offset + length - 1))
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        do {
            var (body, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                // Budget exhausted — re-sign and serve the same bytes again.
                if http.statusCode == 403, let fresh = await renewURL() {
                    liveURL = fresh
                    proxyLog.notice("[ProgressiveProxy] HTTP 403 at \(offset) — renewed URL, retrying range")
                    let freshBase = await withPoToken(fresh)
                    var retry = URLRequest(url: rangedURL(freshBase, from: offset, to: offset + length - 1))
                    retry.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    retry.timeoutInterval = 20
                    (body, response) = try await session.data(for: retry)
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    proxyLog.error("[ProgressiveProxy] HTTP \(http.statusCode) for bytes=\(offset)-\(offset + length - 1)")
                    request.finishLoading(with: URLError(.badServerResponse))
                    return
                }
            }
            guard !request.isCancelled else { return }
            data.respond(with: body)
            request.finishLoading()
        } catch {
            guard !request.isCancelled else { return }
            proxyLog.error("[ProgressiveProxy] range fetch failed: \(error.localizedDescription)")
            request.finishLoading(with: error)
        }
    }

    /// Expresses the byte range as a `range=` query parameter rather than a
    /// `Range` header.
    ///
    /// This is how YouTube's own player fetches progressive and DASH chunks,
    /// and the two are not policed alike: measured here, `Range:` headers on an
    /// `rqh=1` URL are refused from offset 3,276,800 onwards no matter how the
    /// URL is re-signed, while `range=` in the query is served.
    private func rangedURL(_ url: URL, from offset: Int64, to end: Int64) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "range" }
        items.append(URLQueryItem(name: "range", value: "\(offset)-\(end)"))
        components.queryItems = items
        return components.url ?? url
    }

    /// Adds `pot=<token>` to a CDN URL once BotGuard has minted one. Without it
    /// the CDN stops serving an `rqh=1` stream partway through.
    private func withPoToken(_ url: URL) async -> URL {
        guard let token = await poToken(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name == "pot" })
        else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "pot", value: token)]
        return components.url ?? url
    }

    /// Learns total length and MIME type. `bytes=0-1` is answered by googlevideo
    /// with `206` and a `Content-Range: bytes 0-1/<total>` even for rqh=1 URLs.
    private func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: rangedURL(url, from: 0, to: 1))
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else {
            proxyLog.error("[ProgressiveProxy] probe failed")
            return false
        }
        guard http.statusCode < 400 else {
            proxyLog.error("[ProgressiveProxy] probe HTTP \(http.statusCode)")
            return false
        }
        contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map(String.init)
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let value = Int64(total) {
            contentLength = value
        } else if let clen = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "clen" })?.value, let value = Int64(clen) {
            // A `range=` response is a 200 covering just that slice, so its
            // Content-Length is the slice. The full size is in the URL's own
            // `clen=` parameter, which is what the web player reads too.
            contentLength = value
        } else if http.expectedContentLength > 0 {
            contentLength = http.expectedContentLength
        }
        proxyLog.notice("[ProgressiveProxy] probe ok — length=\(self.contentLength ?? -1) type=\(self.contentType ?? "nil")")
        return contentLength != nil
    }
}
