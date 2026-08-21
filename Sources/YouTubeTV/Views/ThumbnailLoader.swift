import AppKit
import Foundation
import SwiftUI

/// Small in-memory thumbnail cache.
///
/// `AsyncImage` is not usable for a shelf grid: it restarts its fetch every time
/// a card leaves and re-enters the view tree, which on a horizontally scrolling
/// row means re-downloading the same thumbnail repeatedly and dropping frames
/// while it decodes on the main thread. (`VideoPreloadCache` in YouTubeCore
/// looks like it would help but caches player metadata, not images.)
///
/// Images are decoded off the main actor and cached by URL, and the cache is a
/// count-limited `NSCache` so long browsing sessions cannot grow without bound.
actor ThumbnailLoader {

    static let shared = ThumbnailLoader()

    /// `nonisolated` so the cache can be peeked synchronously from a view body.
    /// `NSCache` is documented as thread-safe, so this is sound.
    nonisolated(unsafe) private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// A cache hit without awaiting.
    ///
    /// Needed so a card that scrolls into view with an already-loaded thumbnail
    /// shows it on the same frame as its title. Going through the actor meant a
    /// hop, during which the view kept whatever image it had — which, for a
    /// recycled card, was the *previous* video's thumbnail. That is the
    /// "picture and caption out of sync" effect while moving along a row.
    nonisolated static func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// In-flight requests, so two cards showing the same thumbnail cause one fetch.
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = Self.cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data)
            else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { Self.cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A thumbnail that fills its frame, keeping a placeholder until the image
/// arrives so rows never reflow mid-scroll.
struct ThumbnailView: View {
    let url: URL?
    @State private var image: NSImage?

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
            // Adopt the cached image (or nothing) synchronously, so the picture
            // always belongs to the video whose title is showing. Without this
            // the view kept the outgoing card's thumbnail until the next one
            // downloaded, and the image visibly lagged the text along a row.
            image = url.flatMap { ThumbnailLoader.cachedImage(for: $0) }
            guard let url, image == nil else { return }

            let loaded = await ThumbnailLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}
