import Foundation
import os

private let serviceLog = Logger(subsystem: appSubsystem, category: "Lyrics")

// MARK: - LyricsService
//
// Walks the five providers in chain order and decides which answer to show.
// An actor because it is network-bound and holds a cache; the now-playing view
// model owns the observable state around it.

public actor LyricsService {

    private let api: InnerTubeAPI
    private let session: URLSession
    private let defaults: UserDefaults

    /// Fetched lyrics, by video id. An hour is plenty — the same song is
    /// re-opened within a session, not across days.
    private var cache = TTLCache<String, Lyrics>(ttl: 3600, maxEntries: 60)

    /// One chain walk in flight per track — without this, skipping back onto
    /// a song already loading (or two views racing the same track) started
    /// the whole five-provider chain a second time; the cache is only
    /// written at the end, so it doesn't catch this on its own.
    private var inFlight: [String: Task<Lyrics?, Never>] = [:]

    /// Manual corrections, which outrank everything and never expire.
    private var pinned: [String: Lyrics]
    private static let pinnedKey = "lyrics.pinned.v1"
    /// A correction is one song's worth of text; keeping the last hundred is
    /// well under a megabyte and covers any realistic amount of fixing.
    private static let pinnedLimit = 100

    public init(api: InnerTubeAPI, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.session = session
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pinnedKey),
           let decoded = try? JSONDecoder().decode([String: Lyrics].self, from: data) {
            pinned = decoded
        } else {
            pinned = [:]
        }
    }

    // MARK: - The chain

    /// Lyrics for a track, or nil when no source cleared the confidence bar.
    ///
    /// - Parameter ytMusicBrowseId: `MPLY…` from the track's `/next` response.
    ///   Without it the last link in the chain is simply skipped.
    public func lyrics(for track: MusicTrack, ytMusicBrowseId: String?) async -> Lyrics? {
        if let correction = pinned[track.id] { return correction }
        if let cached = cache.get(track.id) { return cached }
        if let running = inFlight[track.id] { return await running.value }

        let task = Task { await self.runChain(for: track, ytMusicBrowseId: ytMusicBrowseId) }
        inFlight[track.id] = task
        let result = await task.value
        inFlight[track.id] = nil
        return result
    }

    private func runChain(for track: MusicTrack, ytMusicBrowseId: String?) async -> Lyrics? {
        let query = LyricsQuery(track: track)
        var gathered: [LyricsCandidate] = []

        for provider in providers(ytMusicBrowseId: ytMusicBrowseId) {
            do {
                guard let candidate = try await provider.candidate(for: query, session: session) else {
                    serviceLog.notice("\(provider.source.rawValue, privacy: .public): no match above threshold")
                    continue
                }
                gathered.append(candidate)
                serviceLog.notice("""
                    \(provider.source.rawValue, privacy: .public): \
                    score \(String(format: "%.2f", candidate.score), privacy: .public) \
                    synced=\(candidate.lyrics.isSynced, privacy: .public)
                    """)
                // A confident, timed match is not worth four more round trips to
                // confirm. Anything less keeps walking so `resolve` has something
                // to cross-check against. An unsynced match can still be
                // confident enough on its own (Genius routinely scores 0.95+
                // on title/artist alone) — requiring `isSynced` here meant a
                // near-certain Genius hit always burned the rest of the chain,
                // including a Musixmatch token mint, for nothing.
                let confidentAndSynced = candidate.score >= LyricsMatching.confidentThreshold
                    && candidate.lyrics.isSynced
                let veryConfident = candidate.score >= 0.95
                if confidentAndSynced || veryConfident {
                    break
                }
            } catch {
                serviceLog.notice("\(provider.source.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
        }

        guard let resolved = LyricsMatching.resolve(gathered) else {
            serviceLog.notice("no lyrics for \(track.title, privacy: .public)")
            return nil
        }
        cache.set(resolved, for: track.id)
        return resolved
    }

    private func providers(ytMusicBrowseId: String?) -> [any LyricsProvider] {
        [
            LRCLIBProvider(),
            NetEaseProvider(),
            GeniusProvider(),
            MusixmatchProvider(),
            YouTubeMusicLyricsProvider(api: api, browseId: ytMusicBrowseId),
        ]
    }

    // MARK: - Manual override (opt-in, plan 9.4)

    /// Free-text search across the searchable providers, for the "search & fix
    /// lyrics" control. Results are ordered by score, best first.
    ///
    /// YouTube Music is absent by design: it has no searchable lyrics endpoint,
    /// only a per-video browse id.
    public func search(_ term: String) async -> [LyricsCandidate] {
        let searchable: [any LyricsProvider] = [
            LRCLIBProvider(), NetEaseProvider(), GeniusProvider(), MusixmatchProvider(),
        ]
        var results: [LyricsCandidate] = []
        // Sequential rather than concurrent: four unofficial endpoints hit at
        // once from one IP is exactly the pattern that gets an app rate limited,
        // and this runs from a deliberate user action, not a hot path.
        for provider in searchable {
            guard let found = try? await provider.search(term, session: session) else { continue }
            results.append(contentsOf: found.filter { !$0.lyrics.isEmpty })
        }
        return results.sorted { $0.score > $1.score }
    }

    /// Records the user's correction for a track. It outranks the chain from
    /// then on, on this device.
    public func pin(_ lyrics: Lyrics, forTrackId id: String) {
        pinned[id] = lyrics
        if pinned.count > Self.pinnedLimit {
            // No access times are kept, so evict arbitrarily rather than build a
            // second index for a cap that is unlikely ever to be reached.
            for key in pinned.keys.prefix(pinned.count - Self.pinnedLimit) {
                pinned.removeValue(forKey: key)
            }
        }
        cache.set(lyrics, for: id)
        persistPinned()
    }

    public func clearPin(forTrackId id: String) {
        pinned.removeValue(forKey: id)
        persistPinned()
    }

    public func hasPin(forTrackId id: String) -> Bool {
        pinned[id] != nil
    }

    private func persistPinned() {
        guard let data = try? JSONEncoder().encode(pinned) else { return }
        defaults.set(data, forKey: Self.pinnedKey)
    }
}
