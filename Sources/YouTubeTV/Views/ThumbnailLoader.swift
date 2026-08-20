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

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// In-flight requests, so two cards showing the same thumbnail cause one fetch.
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
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
        if let image { cache.setObject(image, forKey: url as NSURL) }
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
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let loaded = await ThumbnailLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }
}
