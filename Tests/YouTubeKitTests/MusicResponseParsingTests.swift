import Foundation
import Testing
@testable import YouTubeCore

// Fixtures below are trimmed copies of live `music.youtube.com/youtubei/v1`
// responses (WEB_REMIX, 2026-09) — the same album/artist/next payloads the
// parsers were written against, with the noise fields removed.

private func json(_ string: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(string.utf8)) as! [String: Any]
}

@Suite("YT Music response parsing")
struct MusicResponseParsingTests {

    // MARK: - JSONCursor

    @Test("Cursor returns null rather than trapping on a missing path")
    func cursorTolerance() {
        let cursor = JSONCursor(json(#"{"a": {"b": [1, 2]}}"#))
        #expect(cursor.at("a.b.1").int == 2)
        #expect(cursor.at("a.b.9").exists == false)
        #expect(cursor.at("nope.deeper.still").exists == false)
        #expect(cursor["a"]["b"][0].int == 1)
    }

    @Test("Cursor concatenates text runs the way InnerTube nests them")
    func cursorText() {
        let cursor = JSONCursor(json(#"{"t": {"runs": [{"text": "Bloom"}, {"text": " (live)"}]}}"#))
        #expect(cursor["t"].text == "Bloom (live)")
        #expect(JSONCursor(json(#"{"t": {"simpleText": "x"}}"#))["t"].text == "x")
    }

    @Test("firstDescendant finds a renderer through unknown wrapper layers")
    func cursorDescendant() {
        let cursor = JSONCursor(json(#"{"a": {"b": [{"c": {"gridRenderer": {"items": [1]}}}]}}"#))
        #expect(cursor.firstDescendant("gridRenderer")["items"].array.count == 1)
        #expect(cursor.firstDescendant("missingRenderer").exists == false)
    }

    // MARK: - Leaf parsers

    @Test("Durations parse from both m:ss and h:mm:ss")
    func durations() {
        #expect(MusicParse.duration("5:14") == 314)
        #expect(MusicParse.duration("1:02:11") == 3731)
        #expect(MusicParse.duration("") == nil)
        #expect(MusicParse.duration("not a time") == nil)
    }

    @Test("Largest thumbnail wins")
    func thumbnails() {
        let node = JSONCursor(json(#"""
        {"thumbnails": [{"url": "https://x/small", "width": 60},
                        {"url": "https://x/big", "width": 544}]}
        """#))
        #expect(MusicParse.thumbnail(node["thumbnails"])?.absoluteString == "https://x/big")
        #expect(MusicParse.thumbnail(node["missing"]) == nil)
    }

    @Test("Subtitle runs split into type, artists, album and year")
    func subtitleRuns() {
        let runs = JSONCursor(json(#"""
        {"runs": [
          {"text": "Song"}, {"text": " • "},
          {"text": "Radiohead", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCr_iy"}}},
          {"text": " • "},
          {"text": "The King Of Limbs", "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_0"}}},
          {"text": " • "}, {"text": "2011"}
        ]}
        """#))["runs"].array

        let fields = MusicParse.subtitleFields(runs)
        #expect(fields.typeLabel == "Song")
        #expect(fields.artists.map(\.name) == ["Radiohead"])
        #expect(fields.artists.first?.id == "UCr_iy")
        #expect(fields.album?.name == "The King Of Limbs")
        #expect(fields.album?.id == "MPREb_0")
        #expect(fields.year == "2011")
    }

    @Test("An unlinked artist still lands in artists, not in the type label")
    func subtitleUnlinkedArtist() {
        let runs = JSONCursor(json(#"""
        {"runs": [{"text": "Some Band"}, {"text": " • "}, {"text": "2019"}]}
        """#))["runs"].array
        let fields = MusicParse.subtitleFields(runs)
        // "Some Band • 2019" — the leading run is skipped as a kind label only
        // when a real field follows it, and a year does qualify, so this is the
        // ambiguous case YouTube itself renders identically. Year must survive.
        #expect(fields.year == "2019")
    }

    // MARK: - Album page

    private static let albumFixture = #"""
    {"contents": {"twoColumnBrowseResultsRenderer": {
      "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [
        {"musicResponsiveHeaderRenderer": {
          "title": {"runs": [{"text": "The King Of Limbs"}]},
          "subtitle": {"runs": [{"text": "Album"}, {"text": " • "}, {"text": "2011"}]},
          "secondSubtitle": {"runs": [{"text": "8 songs"}, {"text": " • "}, {"text": "37 minutes"}]},
          "straplineTextOne": {"runs": [{"text": "Radiohead", "navigationEndpoint":
            {"browseEndpoint": {"browseId": "UCr_iyUANcn9OX_yy9piYoLw"}}}]},
          "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails":
            [{"url": "https://t/60", "width": 60}, {"url": "https://t/544", "width": 544}]}}},
          "buttons": [
            {"toggleButtonRenderer": {}},
            {"musicPlayButtonRenderer": {"playNavigationEndpoint": {"watchEndpoint":
              {"playlistId": "OLAK5uy_kkxS8q1"}}}}
          ]
        }}
      ]}}}}],
      "secondaryContents": {"sectionListRenderer": {"contents": [
        {"musicShelfRenderer": {"contents": [
          {"musicResponsiveListItemRenderer": {
            "index": {"runs": [{"text": "1"}]},
            "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer":
              {"playNavigationEndpoint": {"watchEndpoint": {
                "videoId": "IxBQ8Er8DYc", "playlistId": "OLAK5uy_kkxS8q1",
                "watchEndpointMusicSupportedConfigs": {"watchEndpointMusicConfig":
                  {"musicVideoType": "MUSIC_VIDEO_TYPE_ATV"}}}}}}}},
            "flexColumns": [
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Bloom"}]}}},
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {}}},
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "2.9M plays"}]}}}
            ],
            "fixedColumns": [
              {"musicResponsiveListItemFixedColumnRenderer": {"text": {"runs": [{"text": "5:14"}]}}}
            ]
          }}
        ]}},
        {"musicCarouselShelfRenderer": {"contents": [
          {"musicTwoRowItemRenderer": {
            "title": {"runs": [{"text": "Amnesiac", "navigationEndpoint": {"browseEndpoint": {
              "browseId": "MPREb_other",
              "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":
                {"pageType": "MUSIC_PAGE_TYPE_ALBUM"}}}}}]},
            "subtitle": {"runs": [{"text": "Album"}, {"text": " • "}, {"text": "2001"}]},
            "thumbnailRenderer": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails":
              [{"url": "https://t/a", "width": 226}]}}}
          }}
        ]}}
      ]}}
    }}}
    """#

    @Test("Album header, tracks and related albums come out of a live response")
    func albumPage() throws {
        let page = try #require(
            MusicParse.albumPage(json(Self.albumFixture), browseId: "MPREb_0MasdQ0OscT"))

        #expect(page.album.title == "The King Of Limbs")
        #expect(page.album.type == "Album")
        #expect(page.album.year == "2011")
        #expect(page.album.artists.map(\.name) == ["Radiohead"])
        #expect(page.album.artists.first?.id == "UCr_iyUANcn9OX_yy9piYoLw")
        #expect(page.album.trackCount == 8)
        #expect(page.album.durationText == "37 minutes")
        #expect(page.album.audioPlaylistId == "OLAK5uy_kkxS8q1")
        #expect(page.album.thumbnailURL?.absoluteString == "https://t/544")

        #expect(page.tracks.count == 1)
        let track = try #require(page.tracks.first)
        #expect(track.id == "IxBQ8Er8DYc")
        #expect(track.title == "Bloom")
        #expect(track.duration == 314)
        #expect(track.trackNumber == 1)
        #expect(track.videoType == "MUSIC_VIDEO_TYPE_ATV")
        #expect(track.playlistId == "OLAK5uy_kkxS8q1")
        // Album rows leave the artist column empty; the page's artists fill in.
        #expect(track.artists.map(\.name) == ["Radiohead"])
        #expect(track.album?.id == "MPREb_0MasdQ0OscT")

        #expect(page.relatedAlbums.map(\.title) == ["Amnesiac"])
        #expect(page.relatedAlbums.first?.year == "2001")
    }

    // MARK: - Artist page

    private static let artistFixture = #"""
    {"header": {"musicImmersiveHeaderRenderer": {
       "title": {"runs": [{"text": "Radiohead"}]},
       "subscriptionButton": {"subscribeButtonRenderer": {
          "channelId": "UCr_iyUANcn9OX_yy9piYoLw",
          "subscriberCountText": {"runs": [{"text": "8.2M"}]}}},
       "monthlyListenerCount": {"runs": [{"text": "31.4M monthly audience"}]},
       "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails":
          [{"url": "https://a/1", "width": 540}]}}},
       "playButton": {"buttonRenderer": {"navigationEndpoint": {"watchEndpoint":
          {"playlistId": "RDAOshuffle"}}}},
       "startRadioButton": {"buttonRenderer": {"navigationEndpoint": {"watchEndpoint":
          {"playlistId": "RDEMradio"}}}}
    }},
    "contents": {"singleColumnBrowseResultsRenderer": {"tabs": [{"tabRenderer": {"content":
      {"sectionListRenderer": {"contents": [
        {"musicShelfRenderer": {
          "title": {"runs": [{"text": "Top songs"}]},
          "contents": [
            {"musicResponsiveListItemRenderer": {
              "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer":
                {"playNavigationEndpoint": {"watchEndpoint": {"videoId": "abc123"}}}}}},
              "flexColumns": [
                {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Creep"}]}}},
                {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs":
                  [{"text": "Radiohead", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCr_iy"}}}]}}},
                {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs":
                  [{"text": "Pablo Honey", "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_ph"}}}]}}}
              ]
            }}
          ]}},
        {"musicCarouselShelfRenderer": {
          "header": {"musicCarouselShelfBasicHeaderRenderer": {"title": {"runs":
            [{"text": "Albums", "navigationEndpoint": {"browseEndpoint":
              {"browseId": "MPADmore", "params": "ggMA"}}}]}}},
          "contents": [
            {"musicTwoRowItemRenderer": {
              "title": {"runs": [{"text": "In Rainbows", "navigationEndpoint": {"browseEndpoint": {
                "browseId": "MPREb_rain",
                "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":
                  {"pageType": "MUSIC_PAGE_TYPE_ALBUM"}}}}}]},
              "subtitle": {"runs": [{"text": "2007"}]},
              "thumbnailRenderer": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails":
                [{"url": "https://r/1", "width": 226}]}}}
            }}
          ]}},
        {"musicDescriptionShelfRenderer": {"description": {"runs": [{"text": "Radiohead are an English rock band."}]}}}
      ]}}}}]}}}
    """#

    @Test("Artist header, top songs and carousels parse")
    func artistPage() throws {
        let page = try #require(
            MusicParse.artistPage(json(Self.artistFixture), channelId: "UCr_iyUANcn9OX_yy9piYoLw"))

        #expect(page.name == "Radiohead")
        #expect(page.subscribers == "8.2M")
        #expect(page.monthlyListeners == "31.4M")   // " monthly audience" stripped
        #expect(page.description == "Radiohead are an English rock band.")
        #expect(page.shufflePlaylistId == "RDAOshuffle")
        #expect(page.radioPlaylistId == "RDEMradio")

        #expect(page.topTracks.map(\.title) == ["Creep"])
        #expect(page.topTracks.first?.album?.name == "Pablo Honey")

        #expect(page.shelves.map(\.title) == ["Albums"])
        #expect(page.shelves.first?.moreBrowseId == "MPADmore")
        guard case let .album(album)? = page.shelves.first?.items.first else {
            Issue.record("expected an album tile"); return
        }
        #expect(album.title == "In Rainbows")
        #expect(album.year == "2007")
    }

    // MARK: - Queue

    private static let queueFixture = #"""
    {"contents": {"singleColumnMusicWatchNextResultsRenderer": {"tabbedRenderer":
      {"watchNextTabbedResultsRenderer": {"tabs": [
        {"tabRenderer": {"title": "Up next", "content": {"musicQueueRenderer": {"content":
          {"playlistPanelRenderer": {
            "playlistId": "RDAMVMIxBQ8Er8DYc",
            "continuations": [{"nextRadioContinuationData": {"continuation": "CONT123"}}],
            "contents": [
              {"playlistPanelVideoRenderer": {
                "videoId": "IxBQ8Er8DYc",
                "title": {"runs": [{"text": "Bloom"}]},
                "lengthText": {"runs": [{"text": "5:14"}]},
                "longBylineText": {"runs": [
                  {"text": "Radiohead", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCr_iy"}}},
                  {"text": " • "},
                  {"text": "The King Of Limbs", "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_0"}}},
                  {"text": " • "}, {"text": "2011"}]},
                "thumbnail": {"thumbnails": [{"url": "https://q/1", "width": 120}]},
                "navigationEndpoint": {"watchEndpoint": {"playlistId": "RDAMVMIxBQ8Er8DYc",
                  "watchEndpointMusicSupportedConfigs": {"watchEndpointMusicConfig":
                    {"musicVideoType": "MUSIC_VIDEO_TYPE_ATV"}}}}
              }},
              {"playlistPanelVideoRenderer": {"videoId": "dead", "title": {"runs": [{"text": "Gone"}]},
                "unplayableText": {"runs": [{"text": "Not available"}]}}}
            ]}}}}}},
        {"tabRenderer": {"title": "Lyrics", "endpoint": {"browseEndpoint": {
          "browseId": "MPLYt_0MasdQ0OscT-1",
          "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":
            {"pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"}}}}}},
        {"tabRenderer": {"title": "Related", "endpoint": {"browseEndpoint": {
          "browseId": "MPTRt_0MasdQ0OscT-1",
          "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":
            {"pageType": "MUSIC_PAGE_TYPE_TRACK_RELATED"}}}}}}
      ]}}}}}
    """#

    @Test("Queue tracks, lyrics browse id and continuation parse; unplayables drop")
    func queuePage() throws {
        let page = try #require(MusicParse.queuePage(json(Self.queueFixture)))

        #expect(page.playlistId == "RDAMVMIxBQ8Er8DYc")
        #expect(page.lyricsBrowseId == "MPLYt_0MasdQ0OscT-1")
        #expect(page.relatedBrowseId == "MPTRt_0MasdQ0OscT-1")
        #expect(page.continuation == "CONT123")

        #expect(page.tracks.count == 1)     // the unplayable row is dropped
        let track = try #require(page.tracks.first)
        #expect(track.title == "Bloom")
        #expect(track.duration == 314)
        #expect(track.artists.map(\.name) == ["Radiohead"])
        #expect(track.album?.name == "The King Of Limbs")
        #expect(track.videoType == "MUSIC_VIDEO_TYPE_ATV")
    }

    // MARK: - Search

    @Test("Search splits albums, artists and songs by browse id prefix")
    func searchResults() throws {
        let fixture = #"""
        {"contents": {"tabbedSearchResultsRenderer": {"tabs": [{"tabRenderer": {"content":
          {"sectionListRenderer": {"contents": [
            {"musicShelfRenderer": {"title": {"runs": [{"text": "Albums"}]}, "contents": [
              {"musicResponsiveListItemRenderer": {
                "navigationEndpoint": {"browseEndpoint": {"browseId": "MPREb_al"}},
                "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails":
                  [{"url": "https://s/1", "width": 226}]}}},
                "flexColumns": [
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "OK Computer"}]}}},
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [
                    {"text": "Album"}, {"text": " • "},
                    {"text": "Radiohead", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCr_iy"}}},
                    {"text": " • "}, {"text": "1997"}]}}}
                ]}}
            ]}},
            {"musicShelfRenderer": {"title": {"runs": [{"text": "Artists"}]}, "contents": [
              {"musicResponsiveListItemRenderer": {
                "navigationEndpoint": {"browseEndpoint": {"browseId": "UCr_iyUANcn9OX"}},
                "flexColumns": [
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Radiohead"}]}}},
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "8.2M subscribers"}]}}}
                ]}}
            ]}},
            {"musicShelfRenderer": {"title": {"runs": [{"text": "Songs"}]}, "contents": [
              {"musicResponsiveListItemRenderer": {
                "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer":
                  {"playNavigationEndpoint": {"watchEndpoint": {"videoId": "song1",
                    "watchEndpointMusicSupportedConfigs": {"watchEndpointMusicConfig":
                      {"musicVideoType": "MUSIC_VIDEO_TYPE_ATV"}}}}}}}},
                "flexColumns": [
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Karma Police"}]}}},
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [
                    {"text": "Song"}, {"text": " • "},
                    {"text": "Radiohead", "navigationEndpoint": {"browseEndpoint": {"browseId": "UCr_iy"}}},
                    {"text": " • "}, {"text": "4:24"}]}}}
                ]}},
              {"musicResponsiveListItemRenderer": {
                "overlay": {"musicItemThumbnailOverlayRenderer": {"content": {"musicPlayButtonRenderer":
                  {"playNavigationEndpoint": {"watchEndpoint": {"videoId": "pod1",
                    "watchEndpointMusicSupportedConfigs": {"watchEndpointMusicConfig":
                      {"musicVideoType": "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"}}}}}}}},
                "flexColumns": [
                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Some Episode"}]}}}
                ]}}
            ]}}
          ]}}}}]}}}
        """#

        let results = MusicParse.searchResults(json(fixture))
        #expect(results.albums.map(\.title) == ["OK Computer"])
        #expect(results.albums.first?.year == "1997")
        #expect(results.albums.first?.artists.map(\.name) == ["Radiohead"])
        #expect(results.artists.map(\.name) == ["Radiohead"])
        #expect(results.artists.first?.subscribers == "8.2M")
        // Podcast episodes are out of scope and must not reach the Music tab.
        #expect(results.tracks.map(\.title) == ["Karma Police"])
        #expect(results.tracks.first?.duration == 264)
    }

    // MARK: - Library

    @Test("Library grid yields playlists and albums; artist rows yield artists")
    func libraryTiles() {
        let gridFixture = #"""
        {"contents": {"singleColumnBrowseResultsRenderer": {"tabs": [{"tabRenderer": {"content":
          {"sectionListRenderer": {"contents": [{"itemSectionRenderer": {"contents": [
            {"gridRenderer": {"items": [
              {"musicTwoRowItemRenderer": {
                "title": {"runs": [{"text": "Late night", "navigationEndpoint": {"browseEndpoint": {
                  "browseId": "VLPLabc",
                  "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig":
                    {"pageType": "MUSIC_PAGE_TYPE_PLAYLIST"}}}}}]},
                "subtitle": {"runs": [{"text": "Playlist • 42 songs"}]},
                "thumbnailRenderer": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails":
                  [{"url": "https://l/1", "width": 226}]}}}
              }}
            ]}}
          ]}}]}}}}]}}}
        """#
        let items = MusicParse.libraryTiles(json(gridFixture))
        guard case let .playlist(playlist)? = items.first else {
            Issue.record("expected a playlist tile"); return
        }
        // The `VL` browse prefix must be stripped before the id is played.
        #expect(playlist.id == "PLabc")
        #expect(playlist.title == "Late night")
    }

    // MARK: - Lyrics

    @Test("YT Music lyrics read the credit from footer, not the stale runs path")
    func ytMusicLyrics() throws {
        let fixture = #"""
        {"contents": {"sectionListRenderer": {"contents": [
          {"musicDescriptionShelfRenderer": {
            "description": {"runs": [{"text": "Open your mouth wide\nA universal sigh"}]},
            "footer": {"runs": [{"text": "Source: Musixmatch"}]}}}
        ]}}}
        """#
        let parsed = try #require(MusicParse.lyrics(json(fixture)))
        #expect(parsed.text.hasPrefix("Open your mouth wide"))
        #expect(parsed.source == "Source: Musixmatch")
    }

    @Test("Lyrics parse returns nil when the shelf is absent")
    func ytMusicLyricsMissing() {
        #expect(MusicParse.lyrics(json(#"{"contents": {}}"#)) == nil)
    }

    // MARK: - Model behaviour

    @Test("Podcast episodes are identifiable from their video type")
    func podcastDetection() {
        #expect(MusicTrack(id: "a", title: "t", videoType: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE").isPodcastEpisode)
        #expect(!MusicTrack(id: "a", title: "t", videoType: "MUSIC_VIDEO_TYPE_ATV").isPodcastEpisode)
        #expect(!MusicTrack(id: "a", title: "t").isPodcastEpisode)
    }

    @Test("Search filter params are only sent for narrowed searches")
    func searchFilterParams() {
        #expect(MusicSearchFilter.all.params == nil)
        #expect(MusicSearchFilter.songs.params != nil)
        #expect(MusicSearchFilter.allCases.count == 5)
    }

    @Test("Client version is today's date stamp, as YT Music's own app sends")
    func clientVersionIsDated() {
        let version = InnerTubeClients.WebRemix.version
        #expect(version.hasPrefix("1."))
        #expect(version.hasSuffix(".01.00"))
        #expect(version.count == "1.20260902.01.00".count)
    }
}
