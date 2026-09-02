import Foundation
import Testing
@testable import YouTubeCore

@Suite("Lyrics — title and artist normalisation")
struct LyricsNormalizationTests {

    @Test("Upload noise is stripped from titles")
    func stripsNoise() {
        #expect(LyricsMatching.normalizeTitle("Bloom (Official Video)") == "bloom")
        #expect(LyricsMatching.normalizeTitle("Karma Police [Lyrics]") == "karma police")
        #expect(LyricsMatching.normalizeTitle("Creep (Remastered 2016)") == "creep")
        #expect(LyricsMatching.normalizeTitle("No Surprises - Official Music Video") == "no surprises")
        #expect(LyricsMatching.normalizeTitle("Idioteque (Audio) [4K]") == "idioteque")
    }

    @Test("Meaningful brackets survive — a live take is a different recording")
    func keepsMeaningfulBrackets() {
        // Folding these away is how you show studio lyrics over a live take.
        #expect(LyricsMatching.normalizeTitle("Everything In Its Right Place (Live)")
                == "everything in its right place live")
        #expect(LyricsMatching.normalizeTitle("Reckoner (Acoustic)") == "reckoner acoustic")
        #expect(LyricsMatching.normalizeTitle("Nude (Holy Fuck Remix)") == "nude holy fuck remix")
    }

    @Test("Featured-artist credits come out of the title")
    func stripsFeatures() {
        #expect(LyricsMatching.normalizeTitle("Walk On Water (feat. Beyoncé)") == "walk on water")
        #expect(LyricsMatching.normalizeTitle("Stan ft. Dido") == "stan")
        #expect(LyricsMatching.normalizeTitle("Numb / Encore featuring Jay-Z") == "numb encore")
    }

    @Test("Artist channels lose their YouTube suffixes")
    func normalizesArtists() {
        #expect(LyricsMatching.normalizeArtist("Radiohead - Topic") == "radiohead")
        #expect(LyricsMatching.normalizeArtist("EminemVEVO") == "eminemvevo")   // no space: left alone
        #expect(LyricsMatching.normalizeArtist("Eminem VEVO") == "eminem")
        #expect(LyricsMatching.normalizeArtist("Björk") == "bjork")             // diacritics folded
    }

    @Test("Canonicalisation is idempotent")
    func canonicalIdempotent() {
        let once = LyricsMatching.canonical("Don't Blow  Your Mind — With Whys!")
        #expect(LyricsMatching.canonical(once) == once)
        #expect(once == "don t blow your mind with whys")
    }
}

@Suite("Lyrics — similarity and scoring")
struct LyricsScoringTests {

    @Test("Similarity is 1 for identical strings and 0 for disjoint ones")
    func similarityBounds() {
        #expect(LyricsMatching.similarity("bloom", "bloom") == 1)
        #expect(LyricsMatching.similarity("", "bloom") == 0)
        #expect(LyricsMatching.similarity("xyz", "bloom") < 0.2)
        #expect(LyricsMatching.similarity("karma police", "karma policd") > 0.8)
    }

    private let query = LyricsQuery(title: "Bloom (Official Video)",
                                    artist: "Radiohead - Topic",
                                    album: "The King Of Limbs",
                                    duration: 314)

    @Test("The right song scores high and a same-titled other song does not")
    func scoresDiscriminate() {
        let right = LyricsMatching.Candidate(title: "Bloom", artist: "Radiohead",
                                             album: "The King Of Limbs", duration: 314)
        let wrong = LyricsMatching.Candidate(title: "Bloom", artist: "The Paper Kites",
                                             album: "States", duration: 232)

        let rightScore = LyricsMatching.score(right, against: query)
        let wrongScore = LyricsMatching.score(wrong, against: query)
        #expect(rightScore > LyricsMatching.confidentThreshold)
        #expect(wrongScore < LyricsMatching.acceptanceThreshold)
        #expect(rightScore > wrongScore)
    }

    @Test("A missing duration redistributes its weight instead of scoring zero")
    func missingDurationIsNotAMismatch() {
        let withDuration = LyricsMatching.Candidate(title: "Bloom", artist: "Radiohead", duration: 314)
        let without = LyricsMatching.Candidate(title: "Bloom", artist: "Radiohead", duration: nil)
        // Genius never reports a length; it must not be penalised into rejection.
        #expect(LyricsMatching.score(without, against: query) >= LyricsMatching.acceptanceThreshold)
        #expect(LyricsMatching.score(withDuration, against: query)
                >= LyricsMatching.score(without, against: query) - 0.01)
    }

    @Test("A duration well off the mark pulls the score down")
    func durationPenalty() {
        let close = LyricsMatching.Candidate(title: "Bloom", artist: "Radiohead", duration: 315)
        let far = LyricsMatching.Candidate(title: "Bloom", artist: "Radiohead", duration: 420)
        #expect(LyricsMatching.score(close, against: query) > LyricsMatching.score(far, against: query))
    }

    @Test("With no artist to check against, the title carries the score")
    func noArtist() {
        let bare = LyricsQuery(title: "Bloom", artist: "")
        let candidate = LyricsMatching.Candidate(title: "Bloom", artist: "Radiohead")
        #expect(LyricsMatching.score(candidate, against: bare) > LyricsMatching.confidentThreshold)
    }

    @Test("best() rejects everything below the acceptance threshold")
    func bestFilters() {
        let candidates = [
            LyricsMatching.Candidate(title: "Completely Different", artist: "Nobody"),
            LyricsMatching.Candidate(title: "Also Wrong", artist: "Nobody Else"),
        ]
        #expect(LyricsMatching.best(of: candidates, describe: { $0 }, for: query) == nil)
    }
}

@Suite("Lyrics — LRC parsing")
struct LRCParsingTests {

    @Test("Timestamps parse at both two- and three-digit precision")
    func timestamps() {
        let lines = LRCParser.parse("""
        [00:12.34]First
        [01:00.5]Second
        [02:03]Third
        [10:00.123]Fourth
        """)
        #expect(lines.map(\.text) == ["First", "Second", "Third", "Fourth"])
        #expect(lines[0].start == 12.34)
        #expect(lines[1].start == 60.5)
        #expect(lines[2].start == 123)
        #expect(lines[3].start == 600.123)
    }

    @Test("Metadata tags are dropped and repeated timestamps expand")
    func metadataAndRepeats() {
        let lines = LRCParser.parse("""
        [ar:Radiohead]
        [ti:Bloom]
        [by:someone]
        [00:10.00][01:10.00]Chorus
        """)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.text == "Chorus" })
        #expect(lines.map(\.start) == [10, 70])
    }

    @Test("Blank timed lines are kept — they are the gaps between verses")
    func blankTimedLines() {
        let lines = LRCParser.parse("[00:01.00]One\n[00:05.00]\n[00:09.00]Two")
        #expect(lines.count == 3)
        #expect(lines[1].text.isEmpty)
    }

    @Test("Lines are sorted by time regardless of file order")
    func sorted() {
        let lines = LRCParser.parse("[00:30.00]Later\n[00:10.00]Earlier")
        #expect(lines.map(\.text) == ["Earlier", "Later"])
    }

    @Test("Plain lyrics keep internal blank lines but not the outer ones")
    func plainTrimming() {
        let lines = LRCParser.parsePlain("\n\nVerse one\n\nVerse two\n\n")
        #expect(lines.map(\.text) == ["Verse one", "", "Verse two"])
    }

    @Test("Romanisation merges onto lines with matching timestamps")
    func romanizationMerge() {
        let native = LRCParser.parse("[00:01.43]夜に駆ける\n[00:08.83]二人だけの")
        let roman = LRCParser.parse("[00:01.43]yoru ni kakeru\n[00:08.83]futari dake no")
        let merged = LRCParser.merge(romanized: roman, into: native)
        #expect(merged[0].romanized == "yoru ni kakeru")
        #expect(merged[1].romanized == "futari dake no")
        #expect(Lyrics(lines: merged, source: .netease, matchedTitle: "", matchedArtist: "",
                       confidence: 1).hasRomanization)
    }

    @Test("A romanisation track with no matching timestamps is ignored")
    func romanizationMismatch() {
        let native = LRCParser.parse("[00:01.00]line")
        let roman = LRCParser.parse("[04:00.00]unrelated")
        #expect(LRCParser.merge(romanized: roman, into: native)[0].romanized == nil)
    }
}

@Suite("Lyrics — line highlighting")
struct LyricsHighlightTests {

    private let synced = Lyrics(
        lines: [
            LyricLine(text: "one", start: 10),
            LyricLine(text: "two", start: 20),
            LyricLine(text: "three", start: 30),
        ],
        source: .lrclib, matchedTitle: "t", matchedArtist: "a", confidence: 1)

    @Test("The highlighted line is the last one that has started")
    func highlight() {
        #expect(synced.lineIndex(at: 0) == nil)
        #expect(synced.lineIndex(at: 9.9) == nil)
        #expect(synced.lineIndex(at: 10) == 0)
        #expect(synced.lineIndex(at: 19.9) == 0)
        #expect(synced.lineIndex(at: 25) == 1)
        #expect(synced.lineIndex(at: 9999) == 2)
    }

    @Test("Unsynced lyrics never highlight — the panel degrades to plain text")
    func unsyncedNeverHighlights() {
        let plain = Lyrics(lines: [LyricLine(text: "a"), LyricLine(text: "b")],
                           source: .genius, matchedTitle: "t", matchedArtist: "a", confidence: 1)
        #expect(!plain.isSynced)
        #expect(plain.lineIndex(at: 42) == nil)
    }

    @Test("Attribution names the source it actually came from")
    func attribution() {
        #expect(synced.attribution == "Lyrics via LRCLIB")
        #expect(LyricsSource.netease.displayName == "NetEase Cloud Music")
        #expect(LyricsSource.chain == [.lrclib, .netease, .genius, .musixmatch, .youtubeMusic])
        #expect(LyricsSource.youtubeMusic.chainPosition == 4)   // last resort, by direction
    }
}

@Suite("Lyrics — resolving between sources")
struct LyricsResolutionTests {

    private func lyrics(_ source: LyricsSource, text: String, synced: Bool, score: Double) -> LyricsCandidate {
        let lines = text.split(separator: "\n").enumerated().map { index, line in
            LyricLine(text: String(line), start: synced ? TimeInterval(index) * 5 : nil)
        }
        return LyricsCandidate(
            lyrics: Lyrics(lines: lines, source: source, matchedTitle: "t", matchedArtist: "a",
                           confidence: score),
            score: score)
    }

    private let words = "open your mouth wide\na universal sigh\nand while the ocean blooms"
    private let otherWords = "this is a completely different song\nwith nothing in common at all"

    @Test("Nothing above the threshold resolves to nothing at all")
    func rejectsWeakMatches() {
        #expect(LyricsMatching.resolve([lyrics(.lrclib, text: words, synced: true, score: 0.4)]) == nil)
        #expect(LyricsMatching.resolve([]) == nil)
    }

    @Test("A clearly better match wins even from later in the chain")
    func betterMatchWins() {
        let resolved = LyricsMatching.resolve([
            lyrics(.lrclib, text: otherWords, synced: true, score: 0.65),
            lyrics(.genius, text: words, synced: false, score: 0.95),
        ])
        #expect(resolved?.source == .genius)
    }

    @Test("A near-tie goes to the earlier source in the chain")
    func nearTieFavoursChainOrder() {
        let resolved = LyricsMatching.resolve([
            lyrics(.lrclib, text: words, synced: true, score: 0.83),
            lyrics(.musixmatch, text: words, synced: true, score: 0.86),
        ])
        #expect(resolved?.source == .lrclib)
    }

    @Test("Inside the window, timed lyrics beat plain ones")
    func syncedPreferredInWindow() {
        let resolved = LyricsMatching.resolve([
            lyrics(.netease, text: words, synced: true, score: 0.80),
            lyrics(.genius, text: words, synced: false, score: 0.85),
        ])
        #expect(resolved?.source == .netease)
        #expect(resolved?.isSynced == true)
    }

    @Test("Near-tied sources that disagree on the words flag the result ambiguous")
    func disagreementFlags() {
        let agreeing = LyricsMatching.resolve([
            lyrics(.lrclib, text: words, synced: true, score: 0.85),
            lyrics(.netease, text: words, synced: true, score: 0.84),
        ])
        #expect(agreeing?.isAmbiguous == false)

        let disagreeing = LyricsMatching.resolve([
            lyrics(.lrclib, text: words, synced: true, score: 0.85),
            lyrics(.netease, text: otherWords, synced: true, score: 0.84),
        ])
        #expect(disagreeing?.source == .lrclib)     // still the earlier source
        #expect(disagreeing?.isAmbiguous == true)   // but the panel offers the fixer
    }

    @Test("Agreement ignores punctuation and line breaks, which every source spells differently")
    func agreementIsFormattingBlind() {
        let a = lyrics(.lrclib, text: "Open your mouth wide,\nA universal sigh.", synced: true, score: 1).lyrics
        let b = lyrics(.genius, text: "open your mouth wide a universal sigh", synced: false, score: 1).lyrics
        #expect(LyricsMatching.agree(a, b))
    }

    @Test("Empty lyrics are never resolved to, whatever they scored")
    func emptyRejected() {
        let empty = LyricsCandidate(
            lyrics: Lyrics(lines: [LyricLine(text: "  ")], source: .lrclib,
                           matchedTitle: "t", matchedArtist: "a", confidence: 1),
            score: 0.99)
        #expect(LyricsMatching.resolve([empty]) == nil)
    }
}

@Suite("Lyrics — Genius page extraction")
struct GeniusExtractionTests {

    @Test("Verses come out of the lyrics containers, tags and entities resolved")
    func extraction() {
        let html = """
        <html><body><div>junk</div>
        <div data-lyrics-container="true" class="x">[Verse 1]<br/>Open your mouth wide<br>\
        A universal <i>sigh</i></div>
        <div>more junk</div>
        <div data-lyrics-container="true">[Chorus]<br><a href="/x">Don&#x27;t blow your mind</a> &amp; whys</div>
        </body></html>
        """
        let text = GeniusLyricsExtractor.extract(from: html)
        #expect(text == """
        [Verse 1]
        Open your mouth wide
        A universal sigh

        [Chorus]
        Don't blow your mind & whys
        """)
    }

    @Test("A page with no lyrics container yields nothing rather than the whole page")
    func noContainer() {
        #expect(GeniusLyricsExtractor.extract(from: "<html><body>Nope</body></html>").isEmpty)
    }
}

@Suite("Lyrics — query construction")
struct LyricsQueryTests {

    @Test("A query built from a track normalises once, up front")
    func fromTrack() {
        let track = MusicTrack(
            id: "x", title: "Bloom (Official Video)",
            artists: [MusicArtistRef(name: "Radiohead - Topic", id: "UC1")],
            album: MusicAlbumRef(name: "The King Of Limbs"), duration: 314)
        let query = LyricsQuery(track: track)
        #expect(query.normalizedTitle == "bloom")
        #expect(query.normalizedArtist == "radiohead")
        #expect(query.searchTerm == "radiohead bloom")
        #expect(query.duration == 314)
    }

    @Test("A track with no artist still produces a usable search term")
    func noArtist() {
        let query = LyricsQuery(track: MusicTrack(id: "x", title: "Bloom"))
        #expect(query.searchTerm == "bloom")
    }
}
