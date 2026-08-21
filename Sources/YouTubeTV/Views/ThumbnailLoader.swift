import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Small in-memory thumbnail cache.
///
/// `AsyncImage` is not usable for a shelf grid: it restarts its fetch every time
/// a card leaves and re-enters the view tree, which on a horizontally scrolling
/// row means re-downloading the same thumbnail repeatedly and dropping frames
/// while it decodes on the main thread. (`VideoPreloadCache` in YouTubeCore
/// looks like it would help but caches player metadata, not images.)
///
/// Images are **fully decoded and downsampled off the main actor** and cached by
/// URL, and the cache is a cost-limited `NSCache` so long browsing sessions
/// cannot grow without bound.
actor ThumbnailLoader {

    static let shared = ThumbnailLoader()

    /// `nonisolated` so the cache can be peeked synchronously from a view body.
    /// `NSCache` is documented as thread-safe, so this is sound.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        // Bounded by bytes as well as count: 400 full-size thumbnails is over a
        // gigabyte of backing store, which is what pushed the app into swapping
        // during a long browse.
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    /// Cache identity is the URL *and* the size it was decoded at — avatars and
    /// cards ask for very different pixel sizes and must not collide.
    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(url.absoluteString)" as NSString
    }

    /// A cache hit without awaiting.
    ///
    /// Needed so a card that scrolls into view with an already-loaded thumbnail
    /// shows it on the same frame as its title. Going through the actor meant a
    /// hop, during which the view kept whatever image it had — which, for a
    /// recycled card, was the *previous* video's thumbnail. That is the
    /// "picture and caption out of sync" effect while moving along a row.
    nonisolated static func cachedImage(for url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// In-flight requests, so two cards showing the same thumbnail cause one fetch.
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]

    func image(for url: URL, maxPixel: Int) async -> NSImage? {
        let key = Self.key(url, maxPixel)
        if let cached = Self.cache.object(forKey: key) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200
            else { return nil }
            return Self.decode(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            Self.cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
        return image
    }

    /// Warms the cache for cards that have not been built yet.
    ///
    /// The other half of the picture-lags-the-title problem: a row only builds
    /// a window of cards, so the card arriving from the right started its
    /// download at the moment it appeared. Fetching ahead of the focus means it
    /// is already in the cache when it is built, and the synchronous cache read
    /// in `ThumbnailView` then shows it on its first frame.
    ///
    /// Four at a time — enough to stay ahead of a held direction, few enough
    /// not to compete with the video the user is about to play.
    func prefetch(_ urls: [URL], maxPixel: Int = 720) async {
        let wanted = urls.filter { Self.cache.object(forKey: Self.key($0, maxPixel)) == nil }
        guard !wanted.isEmpty else { return }
        for chunk in stride(from: 0, to: wanted.count, by: 4).map({
            Array(wanted[$0..<min($0 + 4, wanted.count)])
        }) {
            await withTaskGroup(of: Void.self) { group in
                for url in chunk {
                    group.addTask { _ = await self.image(for: url, maxPixel: maxPixel) }
                }
            }
            if Task.isCancelled { return }
        }
    }

    /// Decode and downsample in one step, on whatever thread this runs on.
    ///
    /// `NSImage(data:)` does **not** decode — it keeps the compressed bytes and
    /// decodes lazily at draw time, on the main thread. A row of ten 1280×720
    /// JPEGs therefore paid for ten JPEG decodes inside a single frame the first
    /// time it scrolled into view, which is exactly the stutter that was
    /// visible when moving along a shelf. `kCGImageSourceShouldCacheImmediately`
    /// forces the decode to happen here instead, and the thumbnail transform
    /// drops a 1280-wide source to the size actually drawn — so the GPU is not
    /// resampling a needlessly large texture on every frame either.
    private static func decode(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }
}

/// A thumbnail that fills its frame, keeping a placeholder until the image
/// arrives so rows never reflow mid-scroll.
struct ThumbnailView: View {
    let url: URL?
    /// Static CDN URLs to try when `url` fails.
    ///
    /// The URL that arrives on a renderer is a signed `sqp=` variant, and those
    /// expire and 404 — which rendered as a permanently blank card, since the
    /// loader simply returned nil and the view kept its placeholder. `Video`
    /// already exposes an ordered `thumbnailFallbackURLs` ladder
    /// (sd → hq → mq) that nothing was using.
    var fallbacks: [URL] = []

    /// Longest edge to decode at, in pixels. Cards and avatars differ by an
    /// order of magnitude and there is no reason to hold a 1280px bitmap for a
    /// 56pt circle.
    var maxPixel: Int = 720

    @State private var loaded: NSImage?
    /// Which URL `loaded` belongs to. Without this the state outlives the URL
    /// it was fetched for.
    @State private var loadedURL: URL?

    /// Resolved **during body evaluation**, not in a task.
    ///
    /// This is the fix for the picture lagging the title along a row. The
    /// previous version adopted the cached image inside `.task(id:)` — but a
    /// task is scheduled, not synchronous, so on the frame where a card took a
    /// new video the title updated immediately while the image was still the
    /// previous one, and at d-pad speed that reads as permanent desync.
    /// Reading state and the cache here means the image can never belong to a
    /// different video than the text beside it.
    private var image: NSImage? {
        if let url, loadedURL == url, let loaded { return loaded }
        return url.flatMap { ThumbnailLoader.cachedImage(for: $0, maxPixel: maxPixel) }
    }

    var body: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: url) {
            guard image == nil else { return }

            // Walk the ladder until one loads, so an expired signed URL costs a
            // retry rather than an empty card.
            let requested = url
            for candidate in ([url].compactMap { $0 } + fallbacks) {
                let result = await ThumbnailLoader.shared.image(for: candidate, maxPixel: maxPixel)
                guard !Task.isCancelled, requested == url else { return }
                if let result {
                    withAnimation(.easeOut(duration: 0.15)) {
                        loaded = result
                        loadedURL = requested
                    }
                    return
                }
            }
        }
    }
}
