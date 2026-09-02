import Foundation

// MARK: - WEB_REMIX response parsing
//
// Deliberately free functions over `[String: Any]` rather than methods on the
// `InnerTubeAPI` actor: every one of them is pure, so the tests can feed them a
// recorded response without standing up an actor or a URLSession.
//
// Renderer names and paths were read off live `music.youtube.com` responses and
// cross-checked with ytmusicapi's `navigation.py`. Where the two disagree the
// live response wins — the divergences are called out at the site.

// MARK: - Tiny JSON navigator

/// A forgiving cursor over a decoded JSON tree.
///
/// InnerTube responses are deep, optional at almost every level, and reshuffled
/// by YouTube without notice, so the alternative here is fifty lines of nested
/// `as? [String: Any]` per parser. Every accessor returns a `.null` cursor
/// rather than failing, and the leaf accessors are the only place a real type
/// is asserted.
struct JSONCursor {
    let raw: Any?

    /// Computed, not a `static let`: `Any?` is not `Sendable`, so a stored one
    /// is a strict-concurrency error even though this value never changes.
    static var null: JSONCursor { JSONCursor(Optional<Any>.none) }

    init(_ raw: Any?) { self.raw = raw }

    subscript(key: String) -> JSONCursor {
        JSONCursor((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSONCursor {
        guard let array = raw as? [Any], array.indices.contains(index) else { return .null }
        return JSONCursor(array[index])
    }

    /// Follows a `"a.b.0.c"` path in one step.
    func at(_ path: String) -> JSONCursor {
        path.split(separator: ".").reduce(self) { cursor, part in
            if let index = Int(part) { return cursor[index] }
            return cursor[String(part)]
        }
    }

    var string: String? { raw as? String }
    var int: Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? String { return Int(value) }
        return nil
    }
    var bool: Bool { (raw as? Bool) ?? false }
    var dictionary: [String: Any]? { raw as? [String: Any] }
    var array: [JSONCursor] { (raw as? [Any])?.map(JSONCursor.init) ?? [] }
    var exists: Bool { raw != nil }

    /// The dictionary key present at this node, when a renderer is wrapped in a
    /// single-key envelope (`{"musicShelfRenderer": {…}}`).
    var soleKey: String? {
        guard let dictionary, dictionary.count == 1 else { return nil }
        return dictionary.keys.first
    }

    /// Concatenated `runs`/`simpleText` — InnerTube's universal text shape.
    var text: String? {
        if let simple = self["simpleText"].string { return simple }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        return runs.isEmpty ? nil : runs.joined()
    }

    /// Depth-first search for the first node carrying `key`, returning the value
    /// at that key. Library and search responses wrap their real content in a
    /// varying number of `itemSectionRenderer`/tab layers; walking for the
    /// renderer we want is shorter and more durable than encoding each variant.
    func firstDescendant(_ key: String) -> JSONCursor {
        if let dictionary = raw as? [String: Any] {
            if let hit = dictionary[key] { return JSONCursor(hit) }
            for value in dictionary.values {
                let found = JSONCursor(value).firstDescendant(key)
                if found.exists { return found }
            }
        } else if let array = raw as? [Any] {
            for element in array {
                let found = JSONCursor(element).firstDescendant(key)
                if found.exists { return found }
            }
        }
        return .null
    }
}

// MARK: - Shared leaf parsers

enum MusicParse {

    /// Largest thumbnail in a `thumbnails` array.
    static func thumbnail(_ cursor: JSONCursor) -> URL? {
        let candidates = cursor.array
        let best = candidates.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        guard let urlString = best?["url"].string else { return nil }
        return URL(string: urlString)
    }

    /// `thumbnail.musicThumbnailRenderer.thumbnail.thumbnails`, and the two other
    /// spellings YouTube Music uses for the same thing.
    static func thumbnailAnywhere(_ renderer: JSONCursor) -> URL? {
        for key in ["thumbnail", "thumbnailRenderer"] {
            let node = renderer[key]
            if let url = thumbnail(node.at("musicThumbnailRenderer.thumbnail.thumbnails")) { return url }
            if let url = thumbnail(node.at("croppedSquareThumbnailRenderer.thumbnail.thumbnails")) { return url }
            if let url = thumbnail(node.at("thumbnails")) { return url }
        }
        return nil
    }

    /// "3:07" / "1:02:11" → seconds.
    static func duration(_ text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.reduce(TimeInterval(0)) { total, part in total * 60 + TimeInterval(Int(part) ?? 0) }
    }

    /// "4:24" / "1:02:11". Plain character checks rather than a `Regex`, which
    /// cannot be a `static let` under strict concurrency (not `Sendable`).
    static func looksLikeDuration(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func looksLikeYear(_ text: String) -> Bool {
        text.count == 4 && text.allSatisfy(\.isNumber)
    }

    /// What a subtitle line ("Album • Radiohead • 2011", "Song • Eminem • 4:12")
    /// carries. YouTube separates every field with a literal " • " run, so the
    /// odd-indexed runs are separators and only the even ones hold data.
    struct SubtitleFields {
        var artists: [MusicArtistRef] = []
        var album: MusicAlbumRef?
        var year: String?
        var duration: TimeInterval?
        var typeLabel: String?
    }

    static func subtitleFields(_ runs: [JSONCursor], skipTypeLabel: Bool = true) -> SubtitleFields {
        var fields = SubtitleFields()
        var runs = runs

        // The leading unlinked run is the kind ("Song", "Album", "Single"), not
        // an artist — but only when something follows it.
        if skipTypeLabel, runs.count > 2,
           !runs[0].at("navigationEndpoint.browseEndpoint").exists,
           let label = runs[0]["text"].string,
           runs[1]["text"].string == " • " {
            fields.typeLabel = label
            runs = Array(runs.dropFirst(2))
        }

        for (index, run) in runs.enumerated() where index % 2 == 0 {
            guard let text = run["text"].string else { continue }
            let browseId = run.at("navigationEndpoint.browseEndpoint.browseId").string

            if let browseId {
                if browseId.hasPrefix("MPRE") || browseId.contains("release_detail") {
                    fields.album = MusicAlbumRef(name: text, id: browseId)
                } else {
                    fields.artists.append(MusicArtistRef(name: text, id: browseId))
                }
                continue
            }
            if looksLikeDuration(text) {
                fields.duration = duration(text)
            } else if looksLikeYear(text) {
                fields.year = text
            } else if text.hasSuffix(" views") || text.hasSuffix(" plays") || text.hasSuffix(" songs") {
                continue    // view/track counts are display-only here
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                fields.artists.append(MusicArtistRef(name: text, id: nil))
            }
        }
        return fields
    }

    // MARK: - musicResponsiveListItemRenderer (flat rows: album tracks, search songs, library songs)

    static func flexColumn(_ renderer: JSONCursor, _ index: Int) -> JSONCursor {
        renderer["flexColumns"][index]["musicResponsiveListItemFlexColumnRenderer"]["text"]
    }

    /// One flat track row. Returns nil when the row has no playable video id
    /// (headers, "shuffle all" rows, unavailable tracks).
    static func listItemTrack(_ renderer: JSONCursor, fallbackAlbum: MusicAlbumRef? = nil) -> MusicTrack? {
        let playEndpoint = renderer
            .at("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint")
        let titleColumn = flexColumn(renderer, 0)

        let videoId = playEndpoint["videoId"].string
            ?? titleColumn.at("runs.0.navigationEndpoint.watchEndpoint.videoId").string
        guard let videoId, !videoId.isEmpty else { return nil }
        guard let title = titleColumn.text, !title.isEmpty else { return nil }

        // Duration lives in fixedColumns on album/playlist pages and in the
        // second flex column's trailing run in search results.
        let fixedDuration = duration(
            renderer.at("fixedColumns.0.musicResponsiveListItemFixedColumnRenderer.text").text
        )

        let secondary = subtitleFields(flexColumn(renderer, 1)["runs"].array)
        // Album pages leave the artist column blank and expect the page's own
        // artists (confirmed live: flexColumns[1].text is `{}` there).
        var album = secondary.album
        if album == nil {
            // The third column is the album *only* when it links to one. On an
            // album page that slot holds a play count ("2.9M plays"), which
            // taking at face value would shadow the page's own album.
            let albumColumn = flexColumn(renderer, 2)
            if let browseId = albumColumn.at("runs.0.navigationEndpoint.browseEndpoint.browseId").string,
               let name = albumColumn.text, !name.isEmpty {
                album = MusicAlbumRef(name: name, id: browseId)
            }
        }

        return MusicTrack(
            id: videoId,
            title: title,
            artists: secondary.artists,
            album: album ?? fallbackAlbum,
            duration: fixedDuration ?? secondary.duration,
            thumbnailURL: thumbnailAnywhere(renderer),
            videoType: playEndpoint
                .at("watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType").string,
            isExplicit: renderer.at("badges.0.musicInlineBadgeRenderer").exists,
            playlistId: playEndpoint["playlistId"].string,
            trackNumber: renderer.at("index").text.flatMap { Int($0) }
        )
    }

    static func listItemTracks(_ contents: [JSONCursor], fallbackAlbum: MusicAlbumRef? = nil) -> [MusicTrack] {
        contents.compactMap { item in
            let renderer = item["musicResponsiveListItemRenderer"]
            guard renderer.exists else { return nil }
            return listItemTrack(renderer, fallbackAlbum: fallbackAlbum)
        }
    }

    // MARK: - musicTwoRowItemRenderer (carousel/grid tiles)

    /// One carousel tile. The tile's kind is decided by the `pageType` its title
    /// links to; tiles with no browse endpoint are songs or radio playlists.
    static func twoRowItem(_ renderer: JSONCursor) -> MusicItem? {
        guard let title = renderer.at("title").text, !title.isEmpty else { return nil }
        let browse = renderer.at("title.runs.0.navigationEndpoint.browseEndpoint")
        let pageType = browse
            .at("browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
        let browseId = browse["browseId"].string
        let thumbnailURL = thumbnailAnywhere(renderer)
        let subtitleRuns = renderer.at("subtitle.runs").array

        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            guard let browseId else { return nil }
            let fields = subtitleFields(subtitleRuns, skipTypeLabel: false)
            // "Album • 2011" leaves the kind in run 0 and the year in run 2.
            let firstRun = subtitleRuns.first?["text"].string
            let typeLabel = firstRun.flatMap { looksLikeYear($0) ? nil : $0 }
            return .album(MusicAlbum(
                id: browseId,
                title: title,
                artists: fields.artists.filter { $0.name != typeLabel },
                type: typeLabel,
                year: fields.year ?? (firstRun.flatMap { looksLikeYear($0) ? $0 : nil }),
                thumbnailURL: thumbnailURL,
                audioPlaylistId: renderer
                    .at("thumbnailOverlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint")
                    .at("watchPlaylistEndpoint.playlistId").string
                    ?? renderer
                    .at("thumbnailOverlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint")
                    .at("watchEndpoint.playlistId").string,
                isExplicit: renderer.at("subtitleBadges.0.musicInlineBadgeRenderer").exists
            ))

        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            guard let browseId else { return nil }
            let subscribers = renderer.at("subtitle").text?.split(separator: " ").first.map(String.init)
            return .artist(MusicArtistCard(id: browseId, name: title,
                                           subscribers: subscribers, thumbnailURL: thumbnailURL))

        case "MUSIC_PAGE_TYPE_PLAYLIST":
            guard let browseId else { return nil }
            // Playlist browse ids are the playlist id behind a `VL` prefix.
            let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
            return .playlist(MusicPlaylist(id: playlistId, title: title,
                                           subtitle: renderer.at("subtitle").text,
                                           thumbnailURL: thumbnailURL))

        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE":
            return nil    // podcasts are out of scope (plan 9.4)

        default:
            // No browse endpoint: a song tile, or a radio/mix tile.
            if let videoId = renderer.at("navigationEndpoint.watchEndpoint.videoId").string {
                let fields = subtitleFields(subtitleRuns)
                return .track(MusicTrack(
                    id: videoId,
                    title: title,
                    artists: fields.artists,
                    album: fields.album,
                    duration: fields.duration,
                    thumbnailURL: thumbnailURL,
                    videoType: renderer
                        .at("navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType")
                        .string,
                    playlistId: renderer.at("navigationEndpoint.watchEndpoint.playlistId").string
                ))
            }
            if let playlistId = renderer.at("navigationEndpoint.watchPlaylistEndpoint.playlistId").string {
                return .playlist(MusicPlaylist(id: playlistId, title: title,
                                               subtitle: renderer.at("subtitle").text,
                                               thumbnailURL: thumbnailURL))
            }
            return nil
        }
    }

    // MARK: - Shelves

    /// Turns one `sectionListRenderer.contents` entry into a shelf, if it is one.
    static func shelf(_ section: JSONCursor, index: Int) -> MusicShelf? {
        if section["musicCarouselShelfRenderer"].exists {
            let carousel = section["musicCarouselShelfRenderer"]
            let header = carousel.at("header.musicCarouselShelfBasicHeaderRenderer")
            let title = header.at("title").text ?? header.at("strapline").text ?? ""
            let items = carousel["contents"].array.compactMap { entry -> MusicItem? in
                if entry["musicTwoRowItemRenderer"].exists {
                    return twoRowItem(entry["musicTwoRowItemRenderer"])
                }
                if entry["musicResponsiveListItemRenderer"].exists,
                   let track = listItemTrack(entry["musicResponsiveListItemRenderer"]) {
                    return .track(track)
                }
                return nil
            }
            guard !items.isEmpty else { return nil }
            let more = header.at("title.runs.0.navigationEndpoint.browseEndpoint")
            return MusicShelf(id: "\(index)-\(title)", title: title, items: items,
                              moreBrowseId: more["browseId"].string,
                              moreParams: more["params"].string)
        }

        if section["musicShelfRenderer"].exists {
            let musicShelf = section["musicShelfRenderer"]
            let title = musicShelf.at("title").text ?? ""
            let tracks = listItemTracks(musicShelf["contents"].array)
            guard !tracks.isEmpty else { return nil }
            let more = musicShelf.at("title.runs.0.navigationEndpoint.browseEndpoint")
            return MusicShelf(id: "\(index)-\(title)", title: title,
                              items: tracks.map(MusicItem.track),
                              moreBrowseId: more["browseId"].string,
                              moreParams: more["params"].string)
        }

        return nil
    }

    /// `contents.singleColumnBrowseResultsRenderer.tabs[0]…sectionListRenderer.contents`,
    /// falling back to the two-column layout some pages A/B into.
    static func sectionList(_ response: [String: Any]) -> [JSONCursor] {
        let root = JSONCursor(response)
        let single = root.at("contents.singleColumnBrowseResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer.contents")
        if single.exists { return single.array }
        let two = root.at("contents.twoColumnBrowseResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer.contents")
        if two.exists { return two.array }
        return root.at("contents.sectionListRenderer.contents").array
    }

    static func shelves(_ response: [String: Any]) -> [MusicShelf] {
        sectionList(response).enumerated().compactMap { shelf($1, index: $0) }
    }

    // MARK: - Album page

    static func albumPage(_ response: [String: Any], browseId: String) -> MusicAlbumPage? {
        let root = JSONCursor(response)
        let twoColumn = root.at("contents.twoColumnBrowseResultsRenderer")
        let header = twoColumn
            .at("tabs.0.tabRenderer.content.sectionListRenderer.contents.0.musicResponsiveHeaderRenderer")
        guard let title = header.at("title").text else { return nil }

        let subtitleRuns = header.at("subtitle.runs").array
        let typeLabel = subtitleRuns.first?["text"].string
        let year = subtitleRuns.compactMap { $0["text"].string }
            .first { looksLikeYear($0) }

        let artists = header.at("straplineTextOne.runs").array.compactMap { run -> MusicArtistRef? in
            guard let name = run["text"].string, name != " • " else { return nil }
            return MusicArtistRef(name: name,
                                  id: run.at("navigationEndpoint.browseEndpoint.browseId").string)
        }

        let secondSubtitle = header.at("secondSubtitle.runs").array.compactMap { $0["text"].string }
        let trackCount = secondSubtitle.first.flatMap { Int($0.filter(\.isNumber)) }
        let durationText = secondSubtitle.count > 2 ? secondSubtitle[2] : secondSubtitle.first

        // The play button carries the album's audio playlist; YouTube spells the
        // endpoint `watchPlaylistEndpoint` on some responses and `watchEndpoint`
        // on others, so both are tried.
        var audioPlaylistId: String?
        for button in header["buttons"].array {
            let endpoint = button.at("musicPlayButtonRenderer.playNavigationEndpoint")
            if let id = endpoint.at("watchPlaylistEndpoint.playlistId").string
                ?? endpoint.at("watchEndpoint.playlistId").string {
                audioPlaylistId = id
                break
            }
        }

        let album = MusicAlbum(
            id: browseId,
            title: title,
            artists: artists,
            type: typeLabel,
            year: year,
            thumbnailURL: thumbnailAnywhere(header),
            audioPlaylistId: audioPlaylistId,
            isExplicit: header.at("subtitleBadges.0.musicInlineBadgeRenderer").exists,
            trackCount: trackCount,
            durationText: durationText,
            description: header.at("description.musicDescriptionShelfRenderer.description").text
        )

        let secondary = twoColumn.at("secondaryContents.sectionListRenderer.contents").array
        let shelfContents = secondary.first?["musicShelfRenderer"]["contents"].array ?? []
        var tracks = listItemTracks(shelfContents, fallbackAlbum: MusicAlbumRef(name: title, id: browseId))
        // Album track rows carry no artist of their own; inherit the album's.
        for index in tracks.indices where tracks[index].artists.isEmpty {
            tracks[index].artists = artists
        }
        if audioPlaylistId != nil {
            for index in tracks.indices where tracks[index].playlistId == nil {
                tracks[index].playlistId = audioPlaylistId
            }
        }

        let related = secondary.dropFirst().flatMap { section -> [MusicAlbum] in
            section["musicCarouselShelfRenderer"]["contents"].array.compactMap { entry in
                if case let .album(album)? = twoRowItem(entry["musicTwoRowItemRenderer"]) { return album }
                return nil
            }
        }

        return MusicAlbumPage(album: album, tracks: tracks, relatedAlbums: Array(related))
    }

    // MARK: - Artist page

    static func artistPage(_ response: [String: Any], channelId: String) -> MusicArtistPage? {
        let root = JSONCursor(response)
        let header = root.at("header.musicImmersiveHeaderRenderer")
        guard let name = header.at("title").text else { return nil }

        let subscribeButton = header.at("subscriptionButton.subscribeButtonRenderer")
        let sections = sectionList(response)

        var topTracks: [MusicTrack] = []
        var shelves: [MusicShelf] = []
        var description: String?

        for (index, section) in sections.enumerated() {
            if section["musicDescriptionShelfRenderer"].exists {
                description = section.at("musicDescriptionShelfRenderer.description").text
                continue
            }
            if topTracks.isEmpty, section["musicShelfRenderer"].exists {
                topTracks = listItemTracks(section.at("musicShelfRenderer.contents").array)
                if !topTracks.isEmpty { continue }
            }
            if let shelf = shelf(section, index: index) { shelves.append(shelf) }
        }

        return MusicArtistPage(
            id: subscribeButton["channelId"].string ?? channelId,
            name: name,
            subscribers: subscribeButton.at("subscriberCountText").text,
            monthlyListeners: header.at("monthlyListenerCount").text?
                .replacingOccurrences(of: " monthly audience", with: ""),
            description: description,
            thumbnailURL: thumbnailAnywhere(header),
            radioPlaylistId: header
                .at("startRadioButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId").string,
            shufflePlaylistId: header
                .at("playButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId").string,
            topTracks: topTracks,
            shelves: shelves
        )
    }

    // MARK: - Playlist page

    static func playlistPage(_ response: [String: Any], playlistId: String) -> MusicPlaylistPage? {
        let root = JSONCursor(response)
        // Both the 2024 two-column layout and the older single-column one put the
        // track shelf behind a `musicPlaylistShelfRenderer` or `musicShelfRenderer`.
        var shelfContents = root.firstDescendant("musicPlaylistShelfRenderer")["contents"].array
        if shelfContents.isEmpty {
            shelfContents = root.firstDescendant("musicShelfRenderer")["contents"].array
        }
        let tracks = listItemTracks(shelfContents)

        let header = root.firstDescendant("musicResponsiveHeaderRenderer").exists
            ? root.firstDescendant("musicResponsiveHeaderRenderer")
            : root.firstDescendant("musicDetailHeaderRenderer")
        let title = header.at("title").text ?? "Playlist"
        guard !tracks.isEmpty || header.exists else { return nil }

        let playlist = MusicPlaylist(
            id: playlistId,
            title: title,
            subtitle: header.at("straplineTextOne").text ?? header.at("subtitle").text,
            thumbnailURL: thumbnailAnywhere(header),
            trackCount: tracks.count
        )
        return MusicPlaylistPage(playlist: playlist, tracks: tracks)
    }

    // MARK: - Search

    static func searchResults(_ response: [String: Any]) -> MusicSearchResults {
        let root = JSONCursor(response)
        let sections = root
            .at("contents.tabbedSearchResultsRenderer.tabs.0.tabRenderer.content.sectionListRenderer.contents")
            .array

        var results = MusicSearchResults()
        for section in sections {
            if let card = section["musicCardShelfRenderer"].dictionary, results.topResult == nil {
                results.topResult = topResult(JSONCursor(card))
                // The card shelf's own `contents` hold the runner-up rows.
                for entry in JSONCursor(card)["contents"].array {
                    absorb(entry, into: &results)
                }
                continue
            }
            guard section["musicShelfRenderer"].exists else { continue }
            for entry in section.at("musicShelfRenderer.contents").array {
                absorb(entry, into: &results)
            }
        }
        return results
    }

    private static func absorb(_ entry: JSONCursor, into results: inout MusicSearchResults) {
        let renderer = entry["musicResponsiveListItemRenderer"]
        guard renderer.exists else { return }

        let browseId = renderer.at("navigationEndpoint.browseEndpoint.browseId").string
        let thumbnailURL = thumbnailAnywhere(renderer)
        let title = flexColumn(renderer, 0).text

        if let browseId, browseId.hasPrefix("MPRE"), let title {
            let fields = subtitleFields(flexColumn(renderer, 1)["runs"].array, skipTypeLabel: false)
            let runs = flexColumn(renderer, 1)["runs"].array.compactMap { $0["text"].string }
            let typeLabel = runs.first
            results.albums.append(MusicAlbum(
                id: browseId,
                title: title,
                artists: fields.artists.filter { $0.name != typeLabel },
                type: typeLabel,
                year: fields.year,
                thumbnailURL: thumbnailURL,
                audioPlaylistId: renderer
                    .at("overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchPlaylistEndpoint.playlistId")
                    .string
            ))
            return
        }

        if let browseId, browseId.hasPrefix("UC"), let title {
            results.artists.append(MusicArtistCard(
                id: browseId, name: title,
                subscribers: flexColumn(renderer, 1).text?.split(separator: " ").first.map(String.init),
                thumbnailURL: thumbnailURL))
            return
        }

        if let browseId, browseId.hasPrefix("VL") || browseId.hasPrefix("RD"), let title {
            let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
            results.playlists.append(MusicPlaylist(id: playlistId, title: title,
                                                   subtitle: flexColumn(renderer, 1).text,
                                                   thumbnailURL: thumbnailURL))
            return
        }

        if let track = listItemTrack(renderer), !track.isPodcastEpisode {
            results.tracks.append(track)
        }
    }

    private static func topResult(_ card: JSONCursor) -> MusicItem? {
        guard let title = card.at("title").text else { return nil }
        let thumbnailURL = thumbnailAnywhere(card)
        let browse = card.at("title.runs.0.navigationEndpoint.browseEndpoint")
        let browseId = browse["browseId"].string
        let subtitleRuns = card.at("subtitle.runs").array
        let fields = subtitleFields(subtitleRuns, skipTypeLabel: false)

        if let videoId = card.at("onTap.watchEndpoint.videoId").string {
            return .track(MusicTrack(id: videoId, title: title, artists: fields.artists,
                                     album: fields.album, duration: fields.duration,
                                     thumbnailURL: thumbnailURL,
                                     videoType: card
                                        .at("onTap.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType")
                                        .string))
        }
        guard let browseId else { return nil }
        if browseId.hasPrefix("MPRE") {
            return .album(MusicAlbum(id: browseId, title: title, artists: fields.artists,
                                     type: subtitleRuns.first?["text"].string, year: fields.year,
                                     thumbnailURL: thumbnailURL))
        }
        if browseId.hasPrefix("UC") {
            return .artist(MusicArtistCard(id: browseId, name: title, thumbnailURL: thumbnailURL))
        }
        if browseId.hasPrefix("VL") {
            return .playlist(MusicPlaylist(id: String(browseId.dropFirst(2)), title: title,
                                           subtitle: card.at("subtitle").text,
                                           thumbnailURL: thumbnailURL))
        }
        return nil
    }

    // MARK: - Queue (`/next`)

    static func queuePage(_ response: [String: Any]) -> MusicQueuePage? {
        let root = JSONCursor(response)
        let tabbed = root
            .at("contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer")
        guard tabbed.exists else { return nil }

        var lyricsBrowseId: String?
        var relatedBrowseId: String?
        for tab in tabbed["tabs"].array {
            let endpoint = tab.at("tabRenderer.endpoint.browseEndpoint")
            guard let browseId = endpoint["browseId"].string else { continue }
            let pageType = endpoint
                .at("browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string
            if pageType == "MUSIC_PAGE_TYPE_TRACK_LYRICS" { lyricsBrowseId = browseId }
            if pageType == "MUSIC_PAGE_TYPE_TRACK_RELATED" { relatedBrowseId = browseId }
        }

        let panel = tabbed
            .at("tabs.0.tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer")
        let tracks = panel["contents"].array.compactMap(queueTrack)

        return MusicQueuePage(
            tracks: tracks,
            playlistId: panel["playlistId"].string,
            lyricsBrowseId: lyricsBrowseId,
            relatedBrowseId: relatedBrowseId,
            continuation: panel.at("continuations.0.nextRadioContinuationData.continuation").string
                ?? panel.at("continuations.0.nextContinuationData.continuation").string
        )
    }

    /// Parses continuation pages, which arrive under a different envelope.
    static func queueContinuation(_ response: [String: Any]) -> MusicQueuePage? {
        let panel = JSONCursor(response).at("continuationContents.playlistPanelContinuation")
        guard panel.exists else { return nil }
        return MusicQueuePage(
            tracks: panel["contents"].array.compactMap(queueTrack),
            playlistId: panel["playlistId"].string,
            continuation: panel.at("continuations.0.nextRadioContinuationData.continuation").string
                ?? panel.at("continuations.0.nextContinuationData.continuation").string
        )
    }

    static func queueTrack(_ entry: JSONCursor) -> MusicTrack? {
        var renderer = entry["playlistPanelVideoRenderer"]
        if !renderer.exists {
            renderer = entry.at("playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer")
        }
        guard renderer.exists,
              let videoId = renderer["videoId"].string,
              let title = renderer.at("title").text,
              !renderer["unplayableText"].exists else { return nil }

        let fields = subtitleFields(renderer.at("longBylineText.runs").array)
        return MusicTrack(
            id: videoId,
            title: title,
            artists: fields.artists,
            album: fields.album,
            duration: duration(renderer.at("lengthText").text),
            thumbnailURL: thumbnail(renderer.at("thumbnail.thumbnails")),
            videoType: renderer
                .at("navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType")
                .string,
            playlistId: renderer.at("navigationEndpoint.watchEndpoint.playlistId").string
        )
    }

    // MARK: - Library

    static func libraryTiles(_ response: [String: Any]) -> [MusicItem] {
        let root = JSONCursor(response)
        let grid = root.firstDescendant("gridRenderer")
        if grid.exists {
            return grid["items"].array.compactMap { twoRowItem($0["musicTwoRowItemRenderer"]) }
        }
        let shelf = root.firstDescendant("musicShelfRenderer")
        return shelf["contents"].array.compactMap { entry -> MusicItem? in
            if entry["musicTwoRowItemRenderer"].exists {
                return twoRowItem(entry["musicTwoRowItemRenderer"])
            }
            let renderer = entry["musicResponsiveListItemRenderer"]
            guard renderer.exists else { return nil }
            // Library artists are rows whose only endpoint is a channel browse.
            if let browseId = renderer.at("navigationEndpoint.browseEndpoint.browseId").string,
               browseId.hasPrefix("UC") || browseId.hasPrefix("MPLA") {
                let id = browseId.hasPrefix("MPLA") ? String(browseId.dropFirst(4)) : browseId
                guard let name = flexColumn(renderer, 0).text else { return nil }
                return .artist(MusicArtistCard(
                    id: id, name: name,
                    subscribers: flexColumn(renderer, 1).text?.split(separator: " ").first.map(String.init),
                    thumbnailURL: thumbnailAnywhere(renderer)))
            }
            return listItemTrack(renderer).map(MusicItem.track)
        }
    }

    // MARK: - YouTube Music's own lyrics

    /// Plain (never synced) lyrics plus the provider credit YouTube shows.
    ///
    /// Note the divergence from ytmusicapi here: it reads the credit from the
    /// description shelf's own `runs`, but live responses put it under
    /// `footer.runs` ("Source: Musixmatch"). Both are tried, live shape first.
    static func lyrics(_ response: [String: Any]) -> (text: String, source: String?)? {
        let shelf = JSONCursor(response).firstDescendant("musicDescriptionShelfRenderer")
        guard let text = shelf.at("description").text, !text.isEmpty else { return nil }
        let source = shelf.at("footer").text ?? shelf.at("runs.0.text").string
        return (text, source)
    }
}
