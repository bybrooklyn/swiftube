import Foundation

// MARK: - Lyrics matching (plan 9.4)
//
// Every function here is pure. Matching is the part of the lyrics feature that
// is actually hard — "Bloom" by "Radiohead - Topic" has to find "Bloom" by
// "Radiohead" and reject "Bloom" by "The Paper Kites" — and it is also the part
// that can be pinned down in tests without touching the network.

public enum LyricsMatching {

    // MARK: - Normalisation

    /// Bracketed fragments containing one of these are upload noise, not part of
    /// the song's name.
    ///
    /// `live`, `acoustic`, `demo` and `remix` are deliberately **absent**: those
    /// name genuinely different recordings with genuinely different lyrics
    /// timing, and folding them away is how you end up showing the studio
    /// version's lyrics over a live take.
    private static let noiseWords: Set<String> = [
        "official", "video", "audio", "lyric", "lyrics", "lyricvideo",
        "mv", "m/v", "hd", "hq", "4k", "1080p", "720p",
        "visualizer", "visualiser", "explicit", "clean",
        "remaster", "remastered", "remasterd",
        "musicvideo", "officialvideo", "officialaudio", "fullalbum",
        "colorcoded", "colourcoded", "freedownload", "download",
    ]

    /// Strips upload noise from a track title.
    ///
    /// Bracketed groups are removed only when they *contain* a noise word, so
    /// "(Turning in somersaults)" and "(feat. Beyoncé)" survive the bracket rule
    /// — the featured-artist case is then handled separately, because a
    /// featuring credit is real information that no lyrics database indexes on.
    public static func normalizeTitle(_ raw: String) -> String {
        var text = raw

        text = removeNoiseBrackets(from: text)
        text = removeFeaturedCredits(from: text)
        // "Radiohead - Bloom (Official Video)" style dash suffixes, once the
        // bracket has already gone: only trailing fragments that are pure noise.
        text = removeNoiseDashSuffix(from: text)

        return canonical(text)
    }

    /// Strips the artifacts YouTube attaches to channel names.
    public static func normalizeArtist(_ raw: String) -> String {
        var text = raw
        // Auto-generated art tracks come from "<Artist> - Topic" channels.
        if let range = text.range(of: " - Topic", options: [.caseInsensitive, .backwards]) {
            text = String(text[..<range.lowerBound])
        }
        for suffix in ["VEVO", "Official", "Music", "Records", "TV"] {
            if text.count > suffix.count, text.hasSuffix(suffix),
               text.dropLast(suffix.count).last?.isWhitespace == true {
                text = String(text.dropLast(suffix.count))
            }
        }
        text = removeNoiseBrackets(from: text)
        return canonical(text)
    }

    private static func removeNoiseBrackets(from raw: String) -> String {
        var result = ""
        var buffer = ""
        var depth = 0
        for character in raw {
            if character == "(" || character == "[" || character == "{" {
                if depth == 0 { buffer = "" } else { buffer.append(character) }
                depth += 1
            } else if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
                if depth == 0 {
                    if !isNoise(buffer) {
                        result += "(" + buffer + ")"
                    }
                    buffer = ""
                } else {
                    buffer.append(character)
                }
            } else if depth > 0 {
                buffer.append(character)
            } else {
                result.append(character)
            }
        }
        // An unclosed bracket: keep whatever came after it unless it was noise.
        if depth > 0, !isNoise(buffer) { result += " " + buffer }
        return result
    }

    private static func isNoise(_ fragment: String) -> Bool {
        let words = fragment
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard !words.isEmpty else { return true }
        // "Remastered 2011" is noise; "Turning in somersaults" is not. One noise
        // word is enough, because real lyrics fragments do not contain them.
        return words.contains { noiseWords.contains($0) }
    }

    /// Drops "feat. X", "ft X", "featuring X" and "with X" up to the next
    /// bracket or dash. Lyrics databases index the primary artist only.
    public static func removeFeaturedCredits(from raw: String) -> String {
        let markers = ["feat.", "feat ", "ft.", "ft ", "featuring ", "with "]
        var text = raw
        for marker in markers {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let tail = text[range.upperBound...]
            // Keep anything after the credit that starts a new clause: a bracket,
            // or a *spaced* dash. A bare hyphen does not count — "Jay-Z" is one
            // name, and splitting on it leaves "-Z" glued to the title.
            let bracket = tail.firstIndex { $0 == "(" || $0 == "[" }
            let dash = tail.range(of: " - ")?.lowerBound
            let stop = [bracket, dash].compactMap { $0 }.min()
            let remainder = stop.map { String(tail[$0...]) } ?? ""
            text = String(text[..<range.lowerBound]) + remainder
        }
        return text
    }

    private static func removeNoiseDashSuffix(from raw: String) -> String {
        guard let range = raw.range(of: " - ", options: .backwards) else { return raw }
        let suffix = String(raw[range.upperBound...])
        return isNoise(suffix) ? String(raw[..<range.lowerBound]) : raw
    }

    /// Lowercase, punctuation-free, single-spaced — the form everything is
    /// compared in.
    public static func canonical(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        let cleaned = folded.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Similarity

    /// Sørensen–Dice over character bigrams, 0…1.
    ///
    /// Chosen over edit distance because it degrades gracefully on word-order
    /// differences and on the extra words that survive normalisation, which is
    /// what actually varies between a YouTube title and a lyrics database's.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }

        let left = bigrams(a)
        let right = bigrams(b)
        guard !left.isEmpty, !right.isEmpty else {
            return a == b ? 1 : 0
        }

        var counts: [String: Int] = [:]
        for gram in left { counts[gram, default: 0] += 1 }
        var shared = 0
        for gram in right where (counts[gram] ?? 0) > 0 {
            counts[gram]! -= 1
            shared += 1
        }
        return 2 * Double(shared) / Double(left.count + right.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return characters.map(String.init) }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    // MARK: - Scoring

    /// A result a provider offered, described in the terms scoring needs.
    public struct Candidate: Sendable {
        public let title: String
        public let artist: String
        public let album: String?
        public let duration: TimeInterval?

        public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }
    }

    /// Below this, a candidate is not shown at all and the chain moves on —
    /// wrong lyrics are worse than none.
    public static let acceptanceThreshold = 0.62

    /// At or above this a match is good enough to stop the chain early rather
    /// than spend four more round trips confirming it.
    public static let confidentThreshold = 0.88

    /// Two scores within this of each other are a real ambiguity, not a ranking.
    public static let ambiguityWindow = 0.08

    /// Duration agreement inside this many seconds counts as exact — encodes
    /// and uploads differ by a second or two routinely.
    public static let durationTolerance: TimeInterval = 2

    /// How well a candidate answers a query, 0…1.
    ///
    /// Title carries the most weight, artist confirms it, and duration is the
    /// tie-breaker that separates a cover or a remix from the real thing. When
    /// either side is missing a duration its weight is redistributed rather than
    /// scored as a mismatch — most providers omit it for some entries.
    public static func score(_ candidate: Candidate, against query: LyricsQuery) -> Double {
        let titleScore = similarity(normalizeTitle(candidate.title), query.normalizedTitle)
        let artistScore = query.normalizedArtist.isEmpty
            ? titleScore    // nothing to confirm against; don't punish the title
            : similarity(normalizeArtist(candidate.artist), query.normalizedArtist)

        guard let wanted = query.duration, let got = candidate.duration, wanted > 0, got > 0 else {
            return 0.65 * titleScore + 0.35 * artistScore
        }
        let delta = abs(wanted - got)
        let durationScore: Double
        if delta <= durationTolerance {
            durationScore = 1
        } else {
            // Linear decay to zero at 15 s out: a different arrangement.
            durationScore = max(0, 1 - (delta - durationTolerance) / 13)
        }
        return 0.55 * titleScore + 0.30 * artistScore + 0.15 * durationScore
    }

    /// Best-scoring candidate that clears the acceptance threshold.
    public static func best<T>(
        of candidates: [T],
        describe: (T) -> Candidate,
        for query: LyricsQuery
    ) -> (item: T, score: Double)? {
        candidates
            .map { ($0, score(describe($0), against: query)) }
            .filter { $0.1 >= acceptanceThreshold }
            .max { $0.1 < $1.1 }
            .map { (item: $0.0, score: $0.1) }
    }

    // MARK: - Cross-checking

    /// Whether two sets of lyrics are telling the same story.
    ///
    /// Compared on canonical text so punctuation, capitalisation and line breaks
    /// (which every source disagrees about) do not register as a difference.
    public static func agree(_ a: Lyrics, _ b: Lyrics) -> Bool {
        similarity(canonical(a.plainText), canonical(b.plainText)) >= 0.72
    }

    /// Picks the result to show from everything the chain gathered.
    ///
    /// Straight "highest score wins" is wrong here: scores within
    /// `ambiguityWindow` of each other are noise, not a ranking, so those are
    /// settled by chain order instead — which is the user's stated preference
    /// order, not an accident of decimal places. When two near-tied candidates
    /// also disagree on the actual words, the winner is flagged ambiguous so the
    /// panel can offer the manual fixer.
    public static func resolve(_ candidates: [LyricsCandidate]) -> Lyrics? {
        let usable = candidates.filter { !$0.lyrics.isEmpty && $0.score >= acceptanceThreshold }
        guard let leader = usable.max(by: { $0.score < $1.score }) else { return nil }

        let nearTied = usable.filter { leader.score - $0.score <= ambiguityWindow }
        var contenders = nearTied
        // Synced beats unsynced inside the window — a line-highlighted panel is
        // the whole point, and at equal confidence there is no reason not to.
        // Outside the window the better match still wins: correct plain lyrics
        // beat wrong timed ones.
        if contenders.contains(where: { $0.lyrics.isSynced }) {
            contenders = contenders.filter { $0.lyrics.isSynced }
        }
        // Chain order breaks what is left, so an earlier source wins a photo finish.
        guard let winner = contenders.min(by: {
            $0.lyrics.source.chainPosition < $1.lyrics.source.chainPosition
        }) else { return nil }

        var result = winner.lyrics
        // Ambiguity is judged over everything that was near-tied, including the
        // unsynced ones the synced-preference just filtered out: a plain-text
        // source telling a different story is exactly the signal worth flagging.
        let disagreeing = nearTied.contains {
            $0.lyrics.source != winner.lyrics.source && !agree($0.lyrics, winner.lyrics)
        }
        result.isAmbiguous = disagreeing
        return result
    }
}
