import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let musicLog = Logger(subsystem: appSubsystem, category: "YTMusic")

// MARK: - YouTube Music (WEB_REMIX)
//
// A second InnerTube host with its own client identity. Three things make it
// different from every transport in `InnerTubeAPI+Networking.swift`, and all
// three were confirmed against live responses:
//
//  1. **Host and origin are `music.youtube.com`**, not `www.youtube.com`. The
//     SAPISIDHASH signature is bound to the origin, so it has to be computed
//     with the music origin or the request comes back signed-out.
//  2. **Auth is cookies only.** The TV device-flow Bearer token is refused here
//     (as it is by every other `www`-side web client — see `postMWEB`'s note),
//     so the library endpoints need the SAPISID that
//     `AuthService+YouTubeCookies` already fetches. Sign-in is required for the
//     library; browse/search/album/artist work signed-out too.
//  3. **The client version is a date stamp**, see `InnerTubeClients.WebRemix`.
//
// Requests carry the shared cookie jar (`SOCS=CAI` plus whatever MergeSession
// left behind for `.youtube.com`, which covers the `music.` subdomain).

extension InnerTubeAPI {

    var webRemixClientContext: [String: Any] {
        [
            "client": [
                "hl": "en",
                "gl": "US",
                "clientName": InnerTubeClients.WebRemix.name,
                "clientVersion": InnerTubeClients.WebRemix.version,
            ],
            "user": [:] as [String: Any],
        ]
    }

    // MARK: - Transport

    func postMusic(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard var components = URLComponents(string: "\(InnerTubeClients.WebRemix.origin)/youtubei/v1/\(endpoint)") else {
            throw APIError.invalidURL(endpoint)
        }
        components.queryItems = [
            URLQueryItem(name: "alt", value: "json"),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        guard let url = components.url else { throw APIError.invalidURL(endpoint) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(InnerTubeClients.WebRemix.origin, forHTTPHeaderField: "Origin")
        request.setValue(InnerTubeClients.WebRemix.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(InnerTubeClients.WebRemix.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeClients.WebRemix.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.WebRemix.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        // The signature is origin-bound — signing with the www origin authenticates
        // nothing here, which shows up as an empty library rather than an error.
        if let sapisid {
            request.setValue(
                InnerTubeAPI.sapisidhash(sapisid: sapisid, origin: InnerTubeClients.WebRemix.origin),
                forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "X-Origin")
        }

        Self.setConsentCookieIfNeeded()

        var fullBody = body
        fullBody["context"] = webRemixClientContext
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let authLabel = sapisid != nil ? "SAPISIDHASH" : "none"
        musicLog.notice("POST /\(endpoint, privacy: .public) [WEB_REMIX] auth=\(authLabel, privacy: .public)")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            musicLog.error("❌ HTTP \(statusCode, privacy: .public) for /\(endpoint, privacy: .public) [WEB_REMIX]")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        if let error = json["error"] as? [String: Any] {
            musicLog.error("❌ API error [WEB_REMIX]: \(String(describing: error["message"] ?? error), privacy: .public)")
        }
        updateVisitorData(from: json)
        return json
    }

    /// YouTube Music serves an EU consent interstitial instead of JSON when the
    /// jar has no consent cookie. `seedVisionOSSession` sets the same cookie, but
    /// only once playback has started — the Music tab can be opened first.
    private nonisolated static func setConsentCookieIfNeeded() {
        let jar = HTTPCookieStorage.shared
        guard let url = URL(string: InnerTubeClients.WebRemix.origin),
              jar.cookies(for: url)?.contains(where: { $0.name == "SOCS" }) != true,
              let cookie = HTTPCookie(properties: [
                  .domain: ".youtube.com",
                  .path: "/",
                  .name: "SOCS",
                  .value: "CAI",
                  .secure: true,
                  .expires: Date(timeIntervalSinceNow: 365 * 24 * 60 * 60),
              ]) else { return }
        jar.setCookie(cookie)
    }

    // MARK: - Browse

    /// YouTube Music's home: the mixed carousels ("Quick picks", "Listen again", …).
    public func fetchMusicHome() async throws -> [MusicShelf] {
        let response = try await postMusic(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        return MusicParse.shelves(response)
    }

    /// An album, single or EP page with its full track list.
    /// - Parameter browseId: `MPRE…`, from search, a carousel tile, or the library.
    public func fetchMusicAlbum(browseId: String) async throws -> MusicAlbumPage {
        guard browseId.hasPrefix("MPRE") else { throw APIError.invalidURL("album browseId \(browseId)") }
        let response = try await postMusic(endpoint: "browse", body: ["browseId": browseId])
        guard let page = MusicParse.albumPage(response, browseId: browseId) else {
            throw APIError.decodingError("No album header in browse response")
        }
        return page
    }

    /// An artist page: top songs plus the albums/singles/videos carousels.
    /// - Parameter channelId: `UC…`. `MPLA`-prefixed ids are the same artist with
    ///   a library marker on the front, which the endpoint does not accept.
    public func fetchMusicArtist(channelId: String) async throws -> MusicArtistPage {
        let id = channelId.hasPrefix("MPLA") ? String(channelId.dropFirst(4)) : channelId
        let response = try await postMusic(endpoint: "browse", body: ["browseId": id])
        guard let page = MusicParse.artistPage(response, channelId: id) else {
            throw APIError.decodingError("No artist header in browse response")
        }
        return page
    }

    /// A playlist page. Accepts a bare playlist id or one already `VL`-prefixed.
    public func fetchMusicPlaylist(playlistId: String) async throws -> MusicPlaylistPage {
        let bare = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let response = try await postMusic(endpoint: "browse", body: ["browseId": "VL" + bare])
        guard let page = MusicParse.playlistPage(response, playlistId: bare) else {
            throw APIError.decodingError("No playlist content in browse response")
        }
        return page
    }

    // MARK: - Search

    public func searchMusic(
        query: String,
        filter: MusicSearchFilter = .all
    ) async throws -> MusicSearchResults {
        var body: [String: Any] = ["query": query]
        if let params = filter.params { body["params"] = params }
        let response = try await postMusic(endpoint: "search", body: body)
        return MusicParse.searchResults(response)
    }

    // MARK: - Library (signed in)

    /// The four library shelves, fetched concurrently.
    ///
    /// Each browse id is independent, so one failing (a brand-new account has no
    /// liked songs at all) leaves the rest intact rather than emptying the tab.
    public func fetchMusicLibrary() async throws -> MusicLibrary {
        guard sapisid != nil else { throw APIError.notAuthenticated }

        async let playlistItems = musicLibraryTiles(browseId: "FEmusic_liked_playlists")
        async let albumItems = musicLibraryTiles(browseId: "FEmusic_liked_albums")
        async let artistItems = musicLibraryTiles(browseId: "FEmusic_library_corpus_track_artists")
        async let songItems = musicLibraryTiles(browseId: "FEmusic_liked_videos")

        var library = MusicLibrary()
        for item in await playlistItems {
            if case let .playlist(playlist) = item { library.playlists.append(playlist) }
        }
        for item in await albumItems {
            if case let .album(album) = item { library.albums.append(album) }
        }
        for item in await artistItems {
            if case let .artist(artist) = item { library.artists.append(artist) }
        }
        for item in await songItems {
            if case let .track(track) = item, !track.isPodcastEpisode { library.songs.append(track) }
        }
        return library
    }

    private func musicLibraryTiles(browseId: String) async -> [MusicItem] {
        do {
            let response = try await postMusic(endpoint: "browse", body: ["browseId": browseId])
            return MusicParse.libraryTiles(response)
        } catch {
            musicLog.notice("library \(browseId, privacy: .public) failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Queue (`/next`)

    /// The queue YouTube Music builds around a track or playlist.
    ///
    /// - Parameters:
    ///   - videoId: the track being started. With no `playlistId` it seeds
    ///     `RDAMVM<videoId>`, YouTube Music's own "this track's mix" id.
    ///   - playlistId: an album (`OLAK5uy_…`), playlist, or radio (`RD…`) id.
    ///   - radio: ask for an endless similar-tracks queue rather than the
    ///     playlist's own contents.
    ///   - shuffle: shuffle a playlist server-side (ignored when `radio`).
    public func fetchMusicQueue(
        videoId: String? = nil,
        playlistId: String? = nil,
        radio: Bool = false,
        shuffle: Bool = false
    ) async throws -> MusicQueuePage {
        guard videoId != nil || playlistId != nil else {
            throw APIError.invalidURL("music queue needs a videoId or a playlistId")
        }

        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        var resolvedPlaylistId = playlistId
        if let videoId {
            body["videoId"] = videoId
            if resolvedPlaylistId == nil { resolvedPlaylistId = "RDAMVM" + videoId }
            if !radio && !shuffle {
                body["watchEndpointMusicSupportedConfigs"] = [
                    "watchEndpointMusicConfig": [
                        "hasPersistentPlaylistPanel": true,
                        "musicVideoType": "MUSIC_VIDEO_TYPE_ATV",
                    ]
                ]
            }
        }
        if let resolvedPlaylistId {
            // `VL` is a browse prefix; `/next` wants the bare id.
            body["playlistId"] = resolvedPlaylistId.hasPrefix("VL")
                ? String(resolvedPlaylistId.dropFirst(2))
                : resolvedPlaylistId
        }
        // Opaque protobuf selections, as sent by YouTube Music's own web app.
        if radio {
            body["params"] = "wAEB"
        } else if shuffle, playlistId != nil {
            body["params"] = "wAEB8gECKAE%3D"
        }

        let response = try await postMusic(endpoint: "next", body: body)
        guard let page = MusicParse.queuePage(response) else {
            throw APIError.decodingError("No watch-next results in /next response")
        }
        return page
    }

    /// Pulls the next page of an infinite (radio) queue.
    public func fetchMusicQueueContinuation(_ token: String) async throws -> MusicQueuePage {
        let response = try await postMusic(endpoint: "next", body: ["continuation": token])
        guard let page = MusicParse.queueContinuation(response) else {
            throw APIError.decodingError("No continuation contents in /next response")
        }
        return page
    }

    // MARK: - Lyrics

    /// YouTube Music's own lyrics for a track.
    ///
    /// Always plain text on this client — the timestamped variant is only served
    /// to `ANDROID_MUSIC`. This is the *last* entry in the lyrics chain by
    /// explicit direction (plan 9.3), not the first.
    /// - Parameter browseId: `MPLY…`, from `fetchMusicQueue`.
    public func fetchMusicLyrics(browseId: String) async throws -> (text: String, source: String?)? {
        let response = try await postMusic(endpoint: "browse", body: ["browseId": browseId])
        return MusicParse.lyrics(response)
    }
}
