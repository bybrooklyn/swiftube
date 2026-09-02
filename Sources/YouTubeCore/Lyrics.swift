import Foundation

// MARK: - Lyrics models

/// Where a set of lyrics came from, in the order the chain tries them.
///
/// The order is deliberate and not a ranking of popularity: LRCLIB is free,
/// open and synced; NetEase carries romanisation for non-Latin scripts; Genius
/// is unsynced but has the widest catalogue; Musixmatch is an unofficial
/// reverse-engineered endpoint; and YouTube Music's own lyrics sit *last*
/// despite being right there next to the catalog, because in practice they are
/// frequently wrong (plan 9.3).
public enum LyricsSource: String, Codable, Sendable, CaseIterable {
    case lrclib
    case netease
    case genius
    case musixmatch
    case youtubeMusic

    /// Chain order — `allCases` already matches, but relying on declaration
    /// order for behaviour is the kind of thing that breaks in a refactor.
    public static let chain: [LyricsSource] = [.lrclib, .netease, .genius, .musixmatch, .youtubeMusic]

    public var displayName: String {
        switch self {
        case .lrclib:       return "LRCLIB"
        case .netease:      return "NetEase Cloud Music"
        case .genius:       return "Genius"
        case .musixmatch:   return "Musixmatch"
        case .youtubeMusic: return "YouTube Music"
        }
    }

    /// Position in the chain, used to break near-ties toward the earlier source.
    public var chainPosition: Int {
        Self.chain.firstIndex(of: self) ?? Self.chain.count
    }
}

/// One line of lyrics. `start` is nil for a source with no timing at all, which
/// is what makes the UI degrade to plain scrollable text without a second mode.
public struct LyricLine: Hashable, Codable, Sendable {
    public let text: String
    public let start: TimeInterval?
    /// Latin transliteration of `text`, when the source carries one.
    public var romanized: String?

    public init(text: String, start: TimeInterval? = nil, romanized: String? = nil) {
        self.text = text
        self.start = start
        self.romanized = romanized
    }
}

/// A matched set of lyrics, ready to display.
public struct Lyrics: Hashable, Codable, Sendable {
    public let lines: [LyricLine]
    public let source: LyricsSource
    /// The title/artist the source actually matched, so the manual override can
    /// show what it picked and the user can tell when it is wrong.
    public let matchedTitle: String
    public let matchedArtist: String
    /// How well the match scored, 0…1.
    public let confidence: Double
    /// True when a second source in the chain scored close enough to be a real
    /// alternative. The panel offers the manual fixer more readily in that case.
    public var isAmbiguous: Bool

    public init(
        lines: [LyricLine],
        source: LyricsSource,
        matchedTitle: String,
        matchedArtist: String,
        confidence: Double,
        isAmbiguous: Bool = false
    ) {
        self.lines = lines
        self.source = source
        self.matchedTitle = matchedTitle
        self.matchedArtist = matchedArtist
        self.confidence = confidence
        self.isAmbiguous = isAmbiguous
    }

    /// True when at least one line carries a timestamp — the line-highlight UI
    /// turns itself on from this, rather than from a separate mode flag.
    public var isSynced: Bool {
        lines.contains { $0.start != nil }
    }

    public var hasRomanization: Bool {
        lines.contains { $0.romanized?.isEmpty == false }
    }

    public var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// Credit shown at the bottom of the panel once the song ends — the Apple
    /// Music / YouTube Music convention, not a banner during playback.
    public var attribution: String {
        "Lyrics via \(source.displayName)"
    }

    /// Index of the line that should be highlighted at `time`.
    ///
    /// Binary search rather than a scan: this runs off the player's periodic
    /// time observer, several times a second, for the whole song.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        // Search only the timed lines — an untimed line (a blank spacer, or a
        // merged/partial LRC's stray header) has no ordering to binary-search
        // against, so filter it out first rather than special-casing it mid
        // search: discarding the wrong half around it returned a stale index.
        let timed = lines.enumerated().compactMap { index, line in
            line.start.map { (index: index, start: $0) }
        }
        var low = 0
        var high = timed.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if timed[mid].start <= time {
                found = timed[mid].index
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

/// What the chain is looking for. Built from a `MusicTrack`, and normalised
/// once here rather than at every provider.
public struct LyricsQuery: Hashable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let duration: TimeInterval?

    /// `title`/`artist` with the noise every YouTube upload carries stripped
    /// out, which is what makes scoring mean anything.
    public let normalizedTitle: String
    public let normalizedArtist: String

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.normalizedTitle = LyricsMatching.normalizeTitle(title)
        self.normalizedArtist = LyricsMatching.normalizeArtist(artist)
    }

    public init(track: MusicTrack) {
        self.init(title: track.title,
                  artist: track.artists.first?.name ?? "",
                  album: track.album?.name,
                  duration: track.duration)
    }

    /// What to send to a provider that takes one free-text search string.
    public var searchTerm: String {
        normalizedArtist.isEmpty ? normalizedTitle : "\(normalizedArtist) \(normalizedTitle)"
    }
}

/// One provider's answer, before the chain decides which to keep.
public struct LyricsCandidate: Sendable {
    public let lyrics: Lyrics
    /// Match score, 0…1, from `LyricsMatching.score`.
    public let score: Double

    public init(lyrics: Lyrics, score: Double) {
        self.lyrics = lyrics
        self.score = score
    }
}
