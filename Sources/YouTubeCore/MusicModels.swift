import Foundation

// MARK: - YouTube Music catalog models
//
// These are deliberately *not* `Video`/`VideoGroup`. YouTube Music's catalog is
// album/artist shaped: a track knows its album and its (multiple, identified)
// artists, a shelf can mix albums with artists with playlists, and a "channel"
// is an artist page with releases rather than an uploads feed. Squeezing that
// through `Video` loses exactly the structure the Music tab is for.
//
// Shapes were confirmed against live `music.youtube.com/youtubei/v1` responses
// (WEB_REMIX), cross-checked with ytmusicapi (github.com/sigma67/ytmusicapi).

/// An artist reference as it appears in a subtitle run: a display name plus,
/// when YouTube links it, the channel id its artist page lives at.
public struct MusicArtistRef: Hashable, Codable, Sendable {
    public let name: String
    /// Channel id (`UC…`) — nil for artists YouTube renders as plain text.
    public let id: String?

    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }
}

/// An album reference from a track/subtitle run.
public struct MusicAlbumRef: Hashable, Codable, Sendable {
    public let name: String
    /// Album browse id (`MPRE…`).
    public let id: String?

    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }
}

/// One playable music track.
public struct MusicTrack: Identifiable, Hashable, Codable, Sendable {
    public let id: String                  // videoId
    public var title: String
    public var artists: [MusicArtistRef]
    public var album: MusicAlbumRef?
    public var duration: TimeInterval?
    public var thumbnailURL: URL?
    /// `MUSIC_VIDEO_TYPE_ATV` for catalog audio, `…_OMV`/`…_UGC` for music videos,
    /// `…_PODCAST_EPISODE` for podcasts (which the Music tab filters out).
    public var videoType: String?
    public var isExplicit: Bool
    /// Playlist the track was reached through, so the queue can resume it.
    public var playlistId: String?
    public var trackNumber: Int?

    public init(
        id: String,
        title: String,
        artists: [MusicArtistRef] = [],
        album: MusicAlbumRef? = nil,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        videoType: String? = nil,
        isExplicit: Bool = false,
        playlistId: String? = nil,
        trackNumber: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.videoType = videoType
        self.isExplicit = isExplicit
        self.playlistId = playlistId
        self.trackNumber = trackNumber
    }

    /// Artists joined the way YouTube Music renders them under a title.
    public var artistLine: String {
        artists.map(\.name).joined(separator: ", ")
    }

    /// Podcast episodes ride the same renderers as songs. Music mode is music
    /// only (plan 9.4), so every catalog surface filters on this.
    public var isPodcastEpisode: Bool {
        guard let videoType else { return false }
        return videoType.contains("PODCAST") || videoType.contains("EPISODE")
    }
}

/// An album/single/EP tile.
public struct MusicAlbum: Identifiable, Hashable, Codable, Sendable {
    /// Album browse id (`MPRE…`).
    public let id: String
    public var title: String
    public var artists: [MusicArtistRef]
    /// "Album", "Single", "EP" — YouTube's own label.
    public var type: String?
    public var year: String?
    public var thumbnailURL: URL?
    /// `OLAK5uy_…` — the playlist that plays the album.
    public var audioPlaylistId: String?
    public var isExplicit: Bool
    public var trackCount: Int?
    /// "1 hour, 17 minutes" — YouTube's own formatting.
    public var durationText: String?
    public var description: String?

    public init(
        id: String,
        title: String,
        artists: [MusicArtistRef] = [],
        type: String? = nil,
        year: String? = nil,
        thumbnailURL: URL? = nil,
        audioPlaylistId: String? = nil,
        isExplicit: Bool = false,
        trackCount: Int? = nil,
        durationText: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.type = type
        self.year = year
        self.thumbnailURL = thumbnailURL
        self.audioPlaylistId = audioPlaylistId
        self.isExplicit = isExplicit
        self.trackCount = trackCount
        self.durationText = durationText
        self.description = description
    }
}

/// A full album page: the header tile plus its track list.
public struct MusicAlbumPage: Sendable {
    public var album: MusicAlbum
    public var tracks: [MusicTrack]
    /// "Other versions" / "You might also like" carousels below the track list.
    public var relatedAlbums: [MusicAlbum]

    public init(album: MusicAlbum, tracks: [MusicTrack], relatedAlbums: [MusicAlbum] = []) {
        self.album = album
        self.tracks = tracks
        self.relatedAlbums = relatedAlbums
    }
}

/// An artist tile (from a carousel or search).
public struct MusicArtistCard: Identifiable, Hashable, Codable, Sendable {
    public let id: String        // channel id
    public var name: String
    public var subscribers: String?
    public var thumbnailURL: URL?

    public init(id: String, name: String, subscribers: String? = nil, thumbnailURL: URL? = nil) {
        self.id = id
        self.name = name
        self.subscribers = subscribers
        self.thumbnailURL = thumbnailURL
    }
}

/// A playlist tile.
public struct MusicPlaylist: Identifiable, Hashable, Codable, Sendable {
    /// Playlist id with the `VL` browse prefix already stripped.
    public let id: String
    public var title: String
    public var subtitle: String?
    public var thumbnailURL: URL?
    public var trackCount: Int?

    public init(id: String, title: String, subtitle: String? = nil, thumbnailURL: URL? = nil, trackCount: Int? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.trackCount = trackCount
    }
}

/// One item inside a mixed carousel — YouTube Music shelves interleave kinds.
public enum MusicItem: Identifiable, Hashable, Sendable {
    case track(MusicTrack)
    case album(MusicAlbum)
    case artist(MusicArtistCard)
    case playlist(MusicPlaylist)

    public var id: String {
        switch self {
        case let .track(t):    return "t:\(t.id)"
        case let .album(a):    return "a:\(a.id)"
        case let .artist(a):   return "r:\(a.id)"
        case let .playlist(p): return "p:\(p.id)"
        }
    }

    public var title: String {
        switch self {
        case let .track(t):    return t.title
        case let .album(a):    return a.title
        case let .artist(a):   return a.name
        case let .playlist(p): return p.title
        }
    }

    public var subtitle: String {
        switch self {
        case let .track(t):
            return t.artistLine
        case let .album(a):
            let artistNames: String = a.artists.map(\.name).joined(separator: ", ")
            let parts: [String?] = [a.type, artistNames, a.year]
            return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
        case let .artist(a):
            if let subscribers = a.subscribers { return "\(subscribers) subscribers" }
            return "Artist"
        case let .playlist(p):
            if let subtitle = p.subtitle { return subtitle }
            return "Playlist"
        }
    }

    public var thumbnailURL: URL? {
        switch self {
        case let .track(t):    return t.thumbnailURL
        case let .album(a):    return a.thumbnailURL
        case let .artist(a):   return a.thumbnailURL
        case let .playlist(p): return p.thumbnailURL
        }
    }

    /// Artist tiles are round in YouTube Music; everything else is square.
    public var isCircular: Bool {
        if case .artist = self { return true }
        return false
    }
}

/// A titled row on a YouTube Music browse page.
public struct MusicShelf: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var items: [MusicItem]
    /// `browseId` the shelf's "more" affordance points at, when there is one.
    public var moreBrowseId: String?
    public var moreParams: String?

    public init(id: String, title: String, items: [MusicItem], moreBrowseId: String? = nil, moreParams: String? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.moreBrowseId = moreBrowseId
        self.moreParams = moreParams
    }
}

/// A full artist page.
public struct MusicArtistPage: Sendable {
    public var id: String
    public var name: String
    public var subscribers: String?
    public var monthlyListeners: String?
    public var description: String?
    public var thumbnailURL: URL?
    /// Playlist id that starts the artist's radio.
    public var radioPlaylistId: String?
    /// Playlist id that shuffles all of the artist's music.
    public var shufflePlaylistId: String?
    /// "Top songs" — the flat list at the head of the page.
    public var topTracks: [MusicTrack]
    /// Albums / Singles / Videos / Featured-on carousels, in YouTube's order.
    public var shelves: [MusicShelf]

    public init(
        id: String,
        name: String,
        subscribers: String? = nil,
        monthlyListeners: String? = nil,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        radioPlaylistId: String? = nil,
        shufflePlaylistId: String? = nil,
        topTracks: [MusicTrack] = [],
        shelves: [MusicShelf] = []
    ) {
        self.id = id
        self.name = name
        self.subscribers = subscribers
        self.monthlyListeners = monthlyListeners
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.radioPlaylistId = radioPlaylistId
        self.shufflePlaylistId = shufflePlaylistId
        self.topTracks = topTracks
        self.shelves = shelves
    }
}

/// A playlist page: header plus tracks.
public struct MusicPlaylistPage: Sendable {
    public var playlist: MusicPlaylist
    public var tracks: [MusicTrack]

    public init(playlist: MusicPlaylist, tracks: [MusicTrack]) {
        self.playlist = playlist
        self.tracks = tracks
    }
}

/// The signed-in user's library, as the four shelves YouTube Music keeps.
public struct MusicLibrary: Sendable {
    public var playlists: [MusicPlaylist]
    public var albums: [MusicAlbum]
    public var artists: [MusicArtistCard]
    public var songs: [MusicTrack]

    public init(playlists: [MusicPlaylist] = [], albums: [MusicAlbum] = [],
                artists: [MusicArtistCard] = [], songs: [MusicTrack] = []) {
        self.playlists = playlists
        self.albums = albums
        self.artists = artists
        self.songs = songs
    }

    public var isEmpty: Bool {
        playlists.isEmpty && albums.isEmpty && artists.isEmpty && songs.isEmpty
    }
}

/// The result of `/next` — the queue YouTube Music builds around a track.
public struct MusicQueuePage: Sendable {
    public var tracks: [MusicTrack]
    public var playlistId: String?
    /// `MPLY…` browse id for YouTube Music's own lyrics (chain fallback of last
    /// resort — see plan 9.3).
    public var lyricsBrowseId: String?
    public var relatedBrowseId: String?
    /// Token for the next page of an infinite (radio) queue.
    public var continuation: String?

    public init(tracks: [MusicTrack], playlistId: String? = nil, lyricsBrowseId: String? = nil,
                relatedBrowseId: String? = nil, continuation: String? = nil) {
        self.tracks = tracks
        self.playlistId = playlistId
        self.lyricsBrowseId = lyricsBrowseId
        self.relatedBrowseId = relatedBrowseId
        self.continuation = continuation
    }
}

/// Search results, split by kind rather than flattened.
public struct MusicSearchResults: Sendable {
    public var topResult: MusicItem?
    public var tracks: [MusicTrack]
    public var albums: [MusicAlbum]
    public var artists: [MusicArtistCard]
    public var playlists: [MusicPlaylist]

    public init(topResult: MusicItem? = nil, tracks: [MusicTrack] = [], albums: [MusicAlbum] = [],
                artists: [MusicArtistCard] = [], playlists: [MusicPlaylist] = []) {
        self.topResult = topResult
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        topResult == nil && tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
    }
}

/// Which kind of result a music search should be narrowed to.
///
/// The `params` blobs are protobuf-encoded filter selections lifted from
/// ytmusicapi; there is no documented way to build them, so they are constants.
public enum MusicSearchFilter: String, CaseIterable, Sendable {
    case all
    case songs
    case albums
    case artists
    case playlists

    public var params: String? {
        switch self {
        case .all:       return nil
        case .songs:     return "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        case .albums:    return "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        case .artists:   return "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        case .playlists: return "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D"
        }
    }

    public var title: String {
        switch self {
        case .all:       return "All"
        case .songs:     return "Songs"
        case .albums:    return "Albums"
        case .artists:   return "Artists"
        case .playlists: return "Playlists"
        }
    }
}
