import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let lyricsLog = Logger(subsystem: appSubsystem, category: "Lyrics")

// MARK: - Provider protocol

/// One source in the chain. Providers do request-shaping and parsing only —
/// scoring, cross-checking and the decision of which answer to show all belong
/// to `LyricsMatching`, so that logic stays testable without the network.
public protocol LyricsProvider: Sendable {
    var source: LyricsSource { get }

    /// Best match this provider can offer for `query`, already scored, or nil
    /// when nothing clears `LyricsMatching.acceptanceThreshold`.
    func candidate(for query: LyricsQuery, session: URLSession) async throws -> LyricsCandidate?

    /// Free-text search behind the opt-in manual "search & fix lyrics" control.
    /// Returns several options for the user to choose between.
    func search(_ term: String, session: URLSession) async throws -> [LyricsCandidate]
}

public extension LyricsProvider {
    func search(_ term: String, session: URLSession) async throws -> [LyricsCandidate] {
        let query = LyricsQuery(title: term, artist: "")
        return try await candidate(for: query, session: session).map { [$0] } ?? []
    }
}

// MARK: - Shared HTTP helpers

enum LyricsHTTP {
    /// A plain desktop-browser UA. Genius serves an interstitial to anything
    /// that does not look like a browser, and the Musixmatch desktop endpoint
    /// expects one too.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func json(_ url: URL, session: URLSession, headers: [String: String] = [:],
                     body: String? = nil) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.httpError(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func html(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.httpError(status) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

// MARK: - 1. LRCLIB
//
// Free, open, no auth, no rate limit worth speaking of, and synced. First in the
// chain for all of those reasons.

public struct LRCLIBProvider: LyricsProvider {
    public let source = LyricsSource.lrclib
    public init() {}

    public func candidate(for query: LyricsQuery, session: URLSession) async throws -> LyricsCandidate? {
        try await best(from: results(term: query.searchTerm, session: session), for: query)
    }

    public func search(_ term: String, session: URLSession) async throws -> [LyricsCandidate] {
        let query = LyricsQuery(title: term, artist: "")
        return try await results(term: term, session: session).compactMap {
            candidate(from: $0, score: LyricsMatching.score(describe($0), against: query))
        }
    }

    private func results(term: String, session: URLSession) async throws -> [JSONCursor] {
        guard let url = URL(string: "https://lrclib.net/api/search?q=\(LyricsHTTP.escaped(term))") else {
            return []
        }
        return JSONCursor(try await LyricsHTTP.json(url, session: session)).array
    }

    private func describe(_ entry: JSONCursor) -> LyricsMatching.Candidate {
        LyricsMatching.Candidate(
            title: entry["trackName"].string ?? entry["name"].string ?? "",
            artist: entry["artistName"].string ?? "",
            album: entry["albumName"].string,
            duration: entry["duration"].raw as? Double
        )
    }

    private func best(from entries: [JSONCursor], for query: LyricsQuery) -> LyricsCandidate? {
        guard let hit = LyricsMatching.best(of: entries, describe: describe, for: query) else { return nil }
        return candidate(from: hit.item, score: hit.score)
    }

    private func candidate(from entry: JSONCursor, score: Double) -> LyricsCandidate? {
        // Instrumentals come back with empty lyrics — a real answer, but not one
        // worth showing over a source that might have the words.
        if entry["instrumental"].bool { return nil }
        let lines: [LyricLine]
        if let synced = entry["syncedLyrics"].string, !synced.isEmpty {
            lines = LRCParser.parse(synced)
        } else if let plain = entry["plainLyrics"].string, !plain.isEmpty {
            lines = LRCParser.parsePlain(plain)
        } else {
            return nil
        }
        let lyrics = Lyrics(lines: lines, source: .lrclib,
                            matchedTitle: entry["trackName"].string ?? "",
                            matchedArtist: entry["artistName"].string ?? "",
                            confidence: score)
        return lyrics.isEmpty ? nil : LyricsCandidate(lyrics: lyrics, score: score)
    }
}

// MARK: - 2. NetEase Cloud Music
//
// Unofficial but long-lived and unauthenticated. The reason it sits this high is
// `romalrc`: it is the one source in the chain that ships a romanisation for
// CJK tracks, which is what the panel's romanisation toggle displays.
//
// ponytail: line-level sync only. NetEase's word-by-word `yrc` track exists but
// is served only by the encrypted `eapi` endpoint (AES + RSA handshake); the
// plain web API does not return it at any `yv` value. Implementing that
// handshake is its own project — revisit if karaoke-level sync is wanted.

public struct NetEaseProvider: LyricsProvider {
    public let source = LyricsSource.netease
    public init() {}

    public func candidate(for query: LyricsQuery, session: URLSession) async throws -> LyricsCandidate? {
        let songs = try await search(term: query.searchTerm, session: session)
        guard let hit = LyricsMatching.best(of: songs, describe: describe, for: query),
              let id = hit.item["id"].int else { return nil }
        return try await lyrics(songId: id, entry: hit.item, score: hit.score, session: session)
    }

    public func search(_ term: String, session: URLSession) async throws -> [LyricsCandidate] {
        let query = LyricsQuery(title: term, artist: "")
        var found: [LyricsCandidate] = []
        for song in try await search(term: term, session: session).prefix(5) {
            guard let id = song["id"].int else { continue }
            let score = LyricsMatching.score(describe(song), against: query)
            if let candidate = try? await lyrics(songId: id, entry: song, score: score, session: session) {
                found.append(candidate)
            }
        }
        return found
    }

    private func search(term: String, session: URLSession) async throws -> [JSONCursor] {
        guard let url = URL(string: "https://music.163.com/api/search/get") else { return [] }
        let json = try await LyricsHTTP.json(
            url, session: session,
            headers: ["Referer": "https://music.163.com"],
            body: "s=\(LyricsHTTP.escaped(term))&type=1&limit=10&offset=0")
        return JSONCursor(json).at("result.songs").array
    }

    private func describe(_ song: JSONCursor) -> LyricsMatching.Candidate {
        LyricsMatching.Candidate(
            title: song["name"].string ?? "",
            artist: song.at("artists.0.name").string ?? "",
            album: song.at("album.name").string,
            duration: song["duration"].int.map { TimeInterval($0) / 1000 }
        )
    }

    private func lyrics(songId: Int, entry: JSONCursor, score: Double,
                        session: URLSession) async throws -> LyricsCandidate? {
        guard let url = URL(string:
            "https://music.163.com/api/song/lyric?os=pc&id=\(songId)&lv=-1&kv=-1&tv=-1&rv=-1") else { return nil }
        let json = JSONCursor(try await LyricsHTTP.json(
            url, session: session, headers: ["Referer": "https://music.163.com"]))

        guard let native = json.at("lrc.lyric").string, !native.isEmpty else { return nil }
        var lines = LRCParser.parse(native)
        if lines.isEmpty { lines = LRCParser.parsePlain(native) }

        if let roman = json.at("romalrc.lyric").string, !roman.isEmpty {
            lines = LRCParser.merge(romanized: LRCParser.parse(roman), into: lines)
        }

        let lyrics = Lyrics(lines: lines, source: .netease,
                            matchedTitle: entry["name"].string ?? "",
                            matchedArtist: entry.at("artists.0.name").string ?? "",
                            confidence: score)
        return lyrics.isEmpty ? nil : LyricsCandidate(lyrics: lyrics, score: score)
    }
}

// MARK: - 3. Genius
//
// Unsynced, but the widest catalogue of the five. The documented api.genius.com
// needs a registered access token, so this uses the same public JSON endpoint
// the website's own search box calls, then reads the words off the song page —
// they are not in any API response. Both need a browser User-Agent; without one
// Genius answers with an interstitial page instead.

public struct GeniusProvider: LyricsProvider {
    public let source = LyricsSource.genius
    public init() {}

    public func candidate(for query: LyricsQuery, session: URLSession) async throws -> LyricsCandidate? {
        let hits = try await hits(term: query.searchTerm, session: session)
        guard let best = LyricsMatching.best(of: hits, describe: describe, for: query),
              let path = best.item["url"].string, let url = URL(string: path) else { return nil }
        return try await candidate(pageURL: url, entry: best.item, score: best.score, session: session)
    }

    public func search(_ term: String, session: URLSession) async throws -> [LyricsCandidate] {
        let query = LyricsQuery(title: term, artist: "")
        var found: [LyricsCandidate] = []
        for hit in try await hits(term: term, session: session).prefix(5) {
            guard let path = hit["url"].string, let url = URL(string: path) else { continue }
            let score = LyricsMatching.score(describe(hit), against: query)
            if let candidate = try? await candidate(pageURL: url, entry: hit, score: score, session: session) {
                found.append(candidate)
            }
        }
        return found
    }

    private func hits(term: String, session: URLSession) async throws -> [JSONCursor] {
        guard let url = URL(string:
            "https://genius.com/api/search/multi?per_page=5&q=\(LyricsHTTP.escaped(term))") else { return [] }
        let json = JSONCursor(try await LyricsHTTP.json(
            url, session: session, headers: ["Accept": "application/json",
                                             "Referer": "https://genius.com/"]))
        return json.at("response.sections").array
            .flatMap { $0["hits"].array }
            .filter { $0["type"].string == "song" }
            .map { $0["result"] }
    }

    private func describe(_ hit: JSONCursor) -> LyricsMatching.Candidate {
        LyricsMatching.Candidate(
            title: hit["title"].string ?? "",
            artist: hit["artist_names"].string ?? hit.at("primary_artist.name").string ?? "",
            album: nil,
            duration: nil    // Genius does not expose track length
        )
    }

    private func candidate(pageURL: URL, entry: JSONCursor, score: Double,
                           session: URLSession) async throws -> LyricsCandidate? {
        let html = try await LyricsHTTP.html(pageURL, session: session)
        let text = GeniusLyricsExtractor.extract(from: html)
        guard !text.isEmpty else { return nil }
        let lyrics = Lyrics(lines: LRCParser.parsePlain(text), source: .genius,
                            matchedTitle: entry["title"].string ?? "",
                            matchedArtist: entry["artist_names"].string ?? "",
                            confidence: score)
        return lyrics.isEmpty ? nil : LyricsCandidate(lyrics: lyrics, score: score)
    }
}

/// Pulls the words out of a Genius song page.
///
/// Its own separate type because it is pure string work over a hostile input,
/// and the one part of the Genius provider worth testing directly.
public enum GeniusLyricsExtractor {

    /// Genius wraps every verse in `<div data-lyrics-container="true">…</div>`,
    /// with `<br/>` for line breaks and inline `<a>`/`<i>`/`<b>` markup for
    /// annotations. Section headers ("[Verse 1]") are kept — they are part of
    /// how the page reads.
    public static func extract(from html: String) -> String {
        var verses: [String] = []
        var remainder = Substring(html)

        while let open = remainder.range(of: "data-lyrics-container=\"true\"") {
            guard let contentStart = remainder[open.upperBound...].firstIndex(of: ">") else { break }
            let body = remainder[remainder.index(after: contentStart)...]
            guard let close = body.range(of: "</div>") else { break }
            verses.append(plainText(from: String(body[..<close.lowerBound])))
            remainder = body[close.upperBound...]
        }

        return verses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Strips tags, turning `<br>` into newlines, and decodes the handful of
    /// entities that appear in lyrics.
    static func plainText(from fragment: String) -> String {
        var text = fragment
        for tag in ["<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        var stripped = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true }
            else if character == ">" { insideTag = false }
            else if !insideTag { stripped.append(character) }
        }

        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#x27;": "'", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, character) in entities {
            stripped = stripped.replacingOccurrences(of: entity, with: character)
        }
        return stripped
    }
}

// MARK: - 4. Musixmatch (unofficial)
//
// The desktop app's endpoint, reached with a user token minted by `token.get`.
//
// Included at the user's explicit direction with the licensing risk understood:
// Musixmatch's own API terms call unauthorised reproduction of lyrics a
// violation, and the community wrappers this mirrors describe themselves as for
// educational use. It is fourth in the chain, not first.
//
// Practical note, measured: `token.get` is severely rate limited — a second call
// from the same IP inside the window answers `401 hint: captcha`. A token stays
// good for a long time once issued, so it is cached and a captcha response backs
// the provider off for an hour rather than retrying.

public actor MusixmatchTokenStore {
    public static let shared = MusixmatchTokenStore()

    private var token: String?
    private var issuedAt: Date?
    private var blockedUntil: Date?
    /// One mint in flight at a time — `await LyricsHTTP.json` suspends inside
    /// this actor, so N callers arriving before the first returns all pass
    /// the `token == nil` check above and each fire their own `token.get`.
    /// One IP minting N tokens at once is exactly what trips the captcha.
    private var inFlight: Task<String?, Never>?

    /// Tokens have no published lifetime; ten hours is comfortably inside what
    /// the desktop app reuses one for.
    private let tokenLifetime: TimeInterval = 10 * 60 * 60
    private let backoff: TimeInterval = 60 * 60

    public func currentToken(session: URLSession) async -> String? {
        if let token, let issuedAt, Date().timeIntervalSince(issuedAt) < tokenLifetime {
            return token
        }
        if let blockedUntil, Date() < blockedUntil { return nil }
        if let inFlight { return await inFlight.value }

        let task = Task { await self.mintToken(session: session) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// A non-2xx/captcha response here backs the provider off the same as a
    /// refused token.get — previously only token.get itself set `blockedUntil`,
    /// so a captcha on this call just threw and was silently retried (and
    /// re-tripped) on the very next track.
    public func recordFailure() {
        blockedUntil = Date().addingTimeInterval(backoff)
    }

    private func mintToken(session: URLSession) async -> String? {
        guard let url = URL(string:
            "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0&format=json"),
              let json = try? await LyricsHTTP.json(url, session: session, headers: ["Cookie": "AWSELB=0"])
        else {
            blockedUntil = Date().addingTimeInterval(backoff)
            return nil
        }

        let cursor = JSONCursor(json)
        guard let issued = cursor.at("message.body.user_token").string, issued != "UpgradeOnlyUpgradeOnly" else {
            let hint = cursor.at("message.header.hint").string ?? "unknown"
            lyricsLog.notice("musixmatch token refused (\(hint, privacy: .public)) — backing off")
            blockedUntil = Date().addingTimeInterval(backoff)
            return nil
        }
        token = issued
        issuedAt = Date()
        blockedUntil = nil
        return issued
    }

    /// Test seam: preloads a token so the provider can be exercised without a
    /// live `token.get`.
    public func seed(token: String) {
        self.token = token
        self.issuedAt = Date()
        self.blockedUntil = nil
    }
}

public struct MusixmatchProvider: LyricsProvider {
    public let source = LyricsSource.musixmatch
    public init() {}

    public func candidate(for query: LyricsQuery, session: URLSession) async throws -> LyricsCandidate? {
        guard let token = await MusixmatchTokenStore.shared.currentToken(session: session) else { return nil }

        var components = URLComponents(string:
            "https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namespace", value: "lyrics_richsynched"),
            URLQueryItem(name: "subtitle_format", value: "lrc"),
            URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0"),
            URLQueryItem(name: "usertoken", value: token),
            URLQueryItem(name: "q_track", value: query.normalizedTitle),
            URLQueryItem(name: "q_artist", value: query.normalizedArtist),
        ]
        if let duration = query.duration {
            components.queryItems?.append(URLQueryItem(name: "q_duration", value: "\(Int(duration))"))
        }
        guard let url = components.url else { return nil }

        let response: Any
        do {
            response = try await LyricsHTTP.json(url, session: session, headers: ["Cookie": "AWSELB=0"])
        } catch {
            // A captcha lands here too, not only on token.get — without this
            // the backoff only ever triggered on the mint call, and a captcha
            // on the macro call itself just got silently retried next track.
            await MusixmatchTokenStore.shared.recordFailure()
            throw error
        }
        let json = JSONCursor(response)
        let calls = json.at("message.body.macro_calls")

        // What the server thinks it matched, which is what gets scored.
        let matched = calls.at("matcher.track.get.message.body.track")
        let candidate = LyricsMatching.Candidate(
            title: matched["track_name"].string ?? query.title,
            artist: matched["artist_name"].string ?? query.artist,
            album: matched["album_name"].string,
            // `track_length` is 0 rather than absent for a lot of entries.
            duration: (matched["track_length"].int).flatMap { $0 > 0 ? TimeInterval($0) : nil }
        )
        let score = LyricsMatching.score(candidate, against: query)
        guard score >= LyricsMatching.acceptanceThreshold else { return nil }

        var lines: [LyricLine] = []
        if let lrc = calls.at("track.subtitles.get.message.body.subtitle_list.0.subtitle.subtitle_body").string,
           !lrc.isEmpty {
            lines = LRCParser.parse(lrc)
        }
        if lines.isEmpty,
           let plain = calls.at("track.lyrics.get.message.body.lyrics.lyrics_body").string, !plain.isEmpty {
            // The free tier truncates plain lyrics with a notice; drop that.
            let cleaned = plain.components(separatedBy: "...\n\n*******").first ?? plain
            lines = LRCParser.parsePlain(cleaned)
        }
        guard !lines.isEmpty else { return nil }

        let lyrics = Lyrics(lines: lines, source: .musixmatch,
                            matchedTitle: candidate.title, matchedArtist: candidate.artist,
                            confidence: score)
        return lyrics.isEmpty ? nil : LyricsCandidate(lyrics: lyrics, score: score)
    }
}

// MARK: - 5. YouTube Music
//
// Last, by explicit direction: it is right there next to the catalog and costs
// nothing, but in real use its lyrics are frequently the wrong song. Plain text
// only on WEB_REMIX — the timestamped variant is served to ANDROID_MUSIC alone.
//
// The only provider that cannot search: it is addressed by the `MPLY…` browse id
// that came back with the queue, so there is nothing to score against beyond the
// fact that YouTube itself associated it with this exact video.

public struct YouTubeMusicLyricsProvider: LyricsProvider {
    public let source = LyricsSource.youtubeMusic

    private let api: InnerTubeAPI
    private let browseId: String?

    public init(api: InnerTubeAPI, browseId: String?) {
        self.api = api
        self.browseId = browseId
    }

    public func candidate(for query: LyricsQuery, session: URLSession) async throws -> LyricsCandidate? {
        guard let browseId else { return nil }
        guard let result = try await api.fetchMusicLyrics(browseId: browseId) else { return nil }

        let lyrics = Lyrics(lines: LRCParser.parsePlain(result.text), source: .youtubeMusic,
                            matchedTitle: query.title, matchedArtist: query.artist,
                            // The id came from this video's own /next response, so
                            // the association is YouTube's, not a fuzzy match — but
                            // it is scored below `confidentThreshold` on purpose so
                            // it never wins a tie against a searched-and-scored source.
                            confidence: 0.75)
        return lyrics.isEmpty ? nil : LyricsCandidate(lyrics: lyrics, score: 0.75)
    }

    public func search(_ term: String, session: URLSession) async throws -> [LyricsCandidate] {
        []    // no searchable lyrics endpoint on this client
    }
}
