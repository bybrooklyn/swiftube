import Foundation
import Observation
import SwiftUI
import YouTubeCore
import YouTubeMedia

/// Backs the Music tab.
///
/// The tab is its own surface rather than another browse section, because
/// YouTube Music's catalog is not a video feed: an album page is a header plus a
/// numbered track list, an artist page is a header plus carousels, and the
/// now-playing screen is a queue and a lyrics panel side by side. None of that
/// fits `BrowseViewModel`'s one-shape-fits-all shelf list.
///
/// Layout follows YouTube Music's own apps (there has never been a TV client to
/// copy): square art for releases, round art for artists, a header with
/// Play/Shuffle/Radio pills over a track list, and a player page whose right
/// half is a tab strip over UP NEXT and LYRICS.
@MainActor
@Observable
final class MusicModel {

    // MARK: - Pages

    enum Page: Equatable {
        case home
        case library
        case album(id: String)
        case artist(id: String)
        case playlist(id: String)
    }

    /// One row of the current page. Carousels, track lists and the header's
    /// action pills all reduce to this so a single navigator drives every page.
    struct Row: Identifiable {
        enum Content {
            case tiles([MusicItem])
            case tracks([MusicTrack])
            case actions([Action])
            /// The Home/Library switch at the top of the two root pages, the
            /// same chip bar YouTube Music's own web client puts there.
            case chips([Page])
        }

        let id: String
        let title: String
        let content: Content

        var count: Int {
            switch content {
            case let .tiles(items):     return items.count
            case let .tracks(tracks):   return tracks.count
            case let .actions(actions): return actions.count
            case let .chips(pages):     return pages.count
            }
        }
    }

    /// Chip labels, in the order `rootPages` lists them.
    static let rootPages: [Page] = [.home, .library]

    static func chipLabel(_ page: Page) -> String {
        switch page {
        case .home:    return "Home"
        case .library: return "Library"
        default:       return ""
        }
    }

    enum Action: Hashable {
        case play
        case shuffle
        case radio

        var label: String {
            switch self {
            case .play:    return "Play"
            case .shuffle: return "Shuffle"
            case .radio:   return "Radio"
            }
        }

        var symbol: String {
            switch self {
            case .play:    return "play.fill"
            case .shuffle: return "shuffle"
            case .radio:   return "dot.radiowaves.left.and.right"
            }
        }
    }

    /// The block above the rows on a detail page: art, title, and the grey line
    /// underneath it. Not focusable, so it is not part of the layout.
    struct Header {
        var title: String
        var subtitle: String
        var artworkURL: URL?
        var isCircularArtwork: Bool
        var description: String?
    }

    // MARK: - State

    private(set) var stack: [Page] = [.home]
    var page: Page { stack.last ?? .home }

    private(set) var rows: [Row] = []
    private(set) var header: Header?
    private(set) var isLoading = false
    private(set) var message: String?

    private(set) var focus = MusicFocus()
    var layout: MusicLayout {
        // Track lists are stacked, so up/down walk inside them; carousels,
        // chips and action pills are strung out and answer to left/right.
        let vertical = rows.indices.filter { index in
            if case .tracks = rows[index].content { return true }
            return false
        }
        return MusicLayout(rowSizes: rows.map(\.count), verticalRows: Set(vertical))
    }

    /// Set when Music should hand focus back to the guide.
    var didRequestExit = false

    let session: MusicSession
    let playback: PlaybackViewModel

    @ObservationIgnored private let api: InnerTubeAPI
    @ObservationIgnored private let lyricsService: LyricsService
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var memory = MusicNavigator.ColumnMemory()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?

    init(api: InnerTubeAPI, settingsStore: SettingsStore) {
        self.api = api
        self.settingsStore = settingsStore
        self.session = MusicSession(api: api)
        self.lyricsService = LyricsService(api: api)
        self.playback = PlaybackViewModel(api: api)

        var settings = settingsStore.settings
        // The Music tab is audio: there is no video track worth fetching, and
        // the existing audio-only path already knows how to pick the stream and
        // fall back to android_vr when the first URL is refused.
        settings.audioOnlyMode = true
        // Autoplay belongs to the music queue now, not to the video pipeline's
        // recommendations ladder.
        settings.autoplayEnabled = false
        playback.updateSettings(settings)
        playback.onPlaybackEnded = { [weak self] in self?.trackDidFinish() }
    }

    /// The music queue is on unless the user opted out, in which case selecting
    /// a track plays that one track and stops.
    private var queueEnabled: Bool { settingsStore.settings.musicQueueEnabled }

    var isManualLyricsFixEnabled: Bool { settingsStore.settings.manualLyricsSearchEnabled }

    // MARK: - Loading

    func start() {
        load(page: .home)
    }

    private func load(page: Page) {
        loadTask?.cancel()
        isLoading = true
        message = nil
        rows = []
        header = nil
        artistRadioPlaylistId = nil
        focus = MusicFocus()
        memory = MusicNavigator.ColumnMemory()

        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.fetch(page)
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.focus = MusicNavigator.clamped(self.focus, to: self.layout)
        }
    }

    private func fetch(_ page: Page) async {
        do {
            switch page {
            case .home:
                rows = [chipRow]
                let shelves = try await api.fetchMusicHome()
                guard !Task.isCancelled, self.page == page else { return }
                rows = [chipRow] + shelves.map { Row(id: $0.id, title: $0.title, content: .tiles($0.items)) }
                if rows.count == 1 { message = "YouTube Music had nothing to show." }

            case .library:
                rows = [chipRow]
                let library = try await api.fetchMusicLibrary()
                guard !Task.isCancelled, self.page == page else { return }
                rows = [chipRow] + libraryRows(library)
                if rows.count == 1 { message = "Your library is empty." }

            case let .album(id):
                let album = try await api.fetchMusicAlbum(browseId: id)
                guard !Task.isCancelled, self.page == page else { return }
                header = Header(
                    title: album.album.title,
                    subtitle: [album.album.type,
                               album.album.artists.map(\.name).joined(separator: ", "),
                               album.album.year,
                               album.album.trackCount.map { "\($0) songs" },
                               album.album.durationText]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "),
                    artworkURL: album.album.thumbnailURL,
                    isCircularArtwork: false,
                    description: album.album.description)
                var built: [Row] = [
                    Row(id: "actions", title: "", content: .actions([.play, .shuffle, .radio])),
                    Row(id: "tracks", title: "", content: .tracks(album.tracks)),
                ]
                if !album.relatedAlbums.isEmpty {
                    built.append(Row(id: "related", title: "You might also like",
                                     content: .tiles(album.relatedAlbums.map(MusicItem.album))))
                }
                rows = built

            case let .artist(id):
                let artist = try await api.fetchMusicArtist(channelId: id)
                guard !Task.isCancelled, self.page == page else { return }
                artistRadioPlaylistId = artist.radioPlaylistId ?? artist.shufflePlaylistId
                header = Header(
                    title: artist.name,
                    subtitle: [artist.monthlyListeners.map { "\($0) monthly listeners" },
                               artist.subscribers.map { "\($0) subscribers" }]
                        .compactMap { $0 }.joined(separator: " • "),
                    artworkURL: artist.thumbnailURL,
                    isCircularArtwork: true,
                    description: artist.description)
                var built: [Row] = [
                    Row(id: "actions", title: "", content: .actions([.shuffle, .radio])),
                ]
                if !artist.topTracks.isEmpty {
                    built.append(Row(id: "top", title: "Top songs", content: .tracks(artist.topTracks)))
                }
                built += artist.shelves.map { Row(id: $0.id, title: $0.title, content: .tiles($0.items)) }
                rows = built

            case let .playlist(id):
                let playlist = try await api.fetchMusicPlaylist(playlistId: id)
                guard !Task.isCancelled, self.page == page else { return }
                header = Header(
                    title: playlist.playlist.title,
                    subtitle: [playlist.playlist.subtitle,
                               playlist.playlist.trackCount.map { "\($0) songs" }]
                        .compactMap { $0 }.joined(separator: " • "),
                    artworkURL: playlist.playlist.thumbnailURL,
                    isCircularArtwork: false,
                    description: nil)
                rows = [
                    Row(id: "actions", title: "", content: .actions([.play, .shuffle, .radio])),
                    Row(id: "tracks", title: "", content: .tracks(playlist.tracks)),
                ]
            }
        } catch APIError.notAuthenticated {
            guard !Task.isCancelled else { return }
            message = "Sign in to see your music library."
        } catch {
            guard !Task.isCancelled else { return }
            message = "Could not reach YouTube Music."
        }
    }

    private var chipRow: Row {
        Row(id: "roots", title: "", content: .chips(Self.rootPages))
    }

    private func libraryRows(_ library: MusicLibrary) -> [Row] {
        var built: [Row] = []
        if !library.playlists.isEmpty {
            built.append(Row(id: "lib-playlists", title: "Playlists",
                             content: .tiles(library.playlists.map(MusicItem.playlist))))
        }
        if !library.albums.isEmpty {
            built.append(Row(id: "lib-albums", title: "Albums",
                             content: .tiles(library.albums.map(MusicItem.album))))
        }
        if !library.artists.isEmpty {
            built.append(Row(id: "lib-artists", title: "Artists",
                             content: .tiles(library.artists.map(MusicItem.artist))))
        }
        if !library.songs.isEmpty {
            built.append(Row(id: "lib-songs", title: "Songs", content: .tracks(library.songs)))
        }
        return built
    }

    // MARK: - Navigation

    private func push(_ page: Page) {
        stack.append(page)
        load(page: page)
    }

    private func pop() {
        guard stack.count > 1 else {
            didRequestExit = true
            return
        }
        stack.removeLast()
        load(page: page)
    }

    /// Switches between the tab's two roots without growing the stack.
    func showRoot(_ page: Page) {
        stack = [page]
        load(page: page)
    }

    var isAtRoot: Bool { stack.count == 1 }

    // MARK: - Intents

    func handle(_ intent: NavigationIntent) {
        if isNowPlayingOpen {
            handleNowPlaying(intent)
            return
        }

        switch intent {
        case let .move(direction):
            switch MusicNavigator.next(from: focus, direction: direction, layout: layout, memory: &memory) {
            case let .focus(next):
                withAnimation(Theme.travel) { focus = next }
            case .exitLeft:
                didRequestExit = true
            case .none:
                break
            }

        case .select:
            activate()

        case .back:
            pop()

        case .playPause:
            playback.togglePlayPause()

        case .menu:
            if session.currentTrack != nil { openNowPlaying() }

        case let .seek(direction):
            playback.seekRelative(seconds: direction == .forward ? 10 : -10)
        }
    }

    private func activate() {
        guard rows.indices.contains(focus.row) else { return }
        switch rows[focus.row].content {
        case let .tiles(items):
            guard items.indices.contains(focus.column) else { return }
            open(items[focus.column], within: items)
        case let .tracks(tracks):
            guard tracks.indices.contains(focus.column) else { return }
            play(tracks: tracks, startingAt: focus.column)
        case let .actions(actions):
            guard actions.indices.contains(focus.column) else { return }
            perform(actions[focus.column])
        case let .chips(pages):
            guard pages.indices.contains(focus.column), pages[focus.column] != page else { return }
            showRoot(pages[focus.column])
        }
    }

    private func open(_ item: MusicItem, within items: [MusicItem]) {
        switch item {
        case let .album(album):
            push(.album(id: album.id))
        case let .artist(artist):
            push(.artist(id: artist.id))
        case let .playlist(playlist):
            push(.playlist(id: playlist.id))
        case let .track(track):
            // A shelf of song tiles is a queue: playing one should continue into
            // the rest of the row, the way it does in YouTube Music's app.
            let tracks = items.compactMap { entry -> MusicTrack? in
                if case let .track(track) = entry { return track }
                return nil
            }
            let index = tracks.firstIndex { $0.id == track.id } ?? 0
            play(tracks: tracks, startingAt: index)
        }
    }

    private func perform(_ action: Action) {
        let tracks = rows.compactMap { row -> [MusicTrack]? in
            if case let .tracks(tracks) = row.content { return tracks }
            return nil
        }.first ?? []

        switch action {
        case .play:
            play(tracks: tracks, startingAt: 0)
        case .shuffle:
            guard let start = tracks.indices.randomElement() else { return }
            play(tracks: tracks, startingAt: start)
            if !session.queue.isShuffled { session.toggleShuffle() }
        case .radio:
            startRadio(seed: tracks.first)
        }
    }

    /// Radio prefers the artist page's own playlist id, which YouTube Music
    /// supplies in the header. Everywhere else it seeds a mix from a track,
    /// which is what `/next` does with no playlist.
    private func startRadio(seed: MusicTrack?) {
        if let playlistId = artistRadioPlaylistId {
            let artistName = header?.title ?? ""
            Task { [weak self] in
                guard let self else { return }
                await self.session.playRadio(playlistId: playlistId, artistName: artistName)
                self.syncPlayback()
                self.openNowPlaying()
            }
            return
        }
        guard let seed else { return }
        session.play(track: seed)
        syncPlayback()
        openNowPlaying()
    }

    /// Set while an artist page is showing; nil everywhere else.
    private(set) var artistRadioPlaylistId: String?

    private func play(tracks: [MusicTrack], startingAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        if queueEnabled {
            session.play(track: tracks[index], from: tracks)
        } else {
            // Opted out: one track, no queue behind it — the simpler pipeline
            // the setting promises.
            session.play(track: tracks[index])
        }
        syncPlayback()
        openNowPlaying()
    }

    // MARK: - Playback

    /// Loads whatever the session says should be playing, if it is not already.
    private func syncPlayback() {
        guard let track = session.currentTrack else { return }
        guard playback.currentVideo?.id != track.id else { return }
        playback.load(video: track.asVideo)
        loadLyrics(for: track)
    }

    private func trackDidFinish() {
        switch session.trackDidFinish() {
        case .replayCurrent:
            playback.seek(to: 0)
            if !playback.isPlaying { playback.togglePlayPause() }
        case .play:
            syncPlayback()
        case .finished:
            if playback.isPlaying { playback.togglePlayPause() }
            // Attribution appears once the song is over, matching Apple Music
            // and YouTube Music rather than sitting there during playback.
            showsLyricsAttribution = true
        }
    }

    // MARK: - Now playing

    enum NowPlayingTab: Int, CaseIterable {
        case upNext
        case lyrics

        var title: String {
            switch self {
            case .upNext: return "Up next"
            case .lyrics: return "Lyrics"
            }
        }
    }

    private(set) var isNowPlayingOpen = false
    private(set) var nowPlayingFocus = MusicFocus()
    private(set) var nowPlayingTab: NowPlayingTab = .upNext
    @ObservationIgnored private var nowPlayingMemory = MusicNavigator.ColumnMemory()

    /// Rows of the now-playing panel: transport, tab strip, then the tab's list.
    var nowPlayingLayout: MusicLayout {
        let listCount: Int
        switch nowPlayingTab {
        case .upNext:
            listCount = session.queue.playOrder.count
        case .lyrics:
            listCount = lyricsActions.count
        }
        // Transport and tab strip are always horizontal. The row below them
        // follows what it actually draws: the queue is a stacked list, the
        // lyrics controls are a pill row.
        return MusicLayout(rowSizes: [transportControls.count, NowPlayingTab.allCases.count, listCount],
                           verticalRows: nowPlayingTab == .upNext ? [2] : [])
    }

    enum Transport: Hashable, CaseIterable {
        case previous, playPause, next, shuffle, repeatMode

        func symbol(isPlaying: Bool, repeatMode: MusicRepeatMode) -> String {
            switch self {
            case .previous:   return "backward.fill"
            case .playPause:  return isPlaying ? "pause.fill" : "play.fill"
            case .next:       return "forward.fill"
            case .shuffle:    return "shuffle"
            case .repeatMode: return repeatMode == .one ? "repeat.1" : "repeat"
            }
        }
    }

    var transportControls: [Transport] { Transport.allCases }

    /// The actions offered under the lyrics, which is only ever the manual fixer
    /// and the romanisation toggle — and each only when it applies.
    var lyricsActions: [LyricsAction] {
        var actions: [LyricsAction] = []
        if lyrics?.hasRomanization == true { actions.append(.toggleRomanization) }
        if isManualLyricsFixEnabled, session.currentTrack != nil { actions.append(.fixMatch) }
        if isPickingLyrics { return [.cancelPick] + lyricsChoices.indices.map { .choose($0) } }
        return actions
    }

    enum LyricsAction: Hashable {
        case toggleRomanization
        case fixMatch
        case cancelPick
        case choose(Int)
    }

    func openNowPlaying() {
        guard session.currentTrack != nil else { return }
        withAnimation(Theme.travel) {
            isNowPlayingOpen = true
            nowPlayingFocus = MusicFocus(row: 0, column: 1)   // rest on play/pause
        }
        nowPlayingMemory = MusicNavigator.ColumnMemory()
    }

    func closeNowPlaying() {
        withAnimation(Theme.travel) { isNowPlayingOpen = false }
    }

    private func handleNowPlaying(_ intent: NavigationIntent) {
        switch intent {
        case let .move(direction):
            let move = MusicNavigator.next(from: nowPlayingFocus, direction: direction,
                                           layout: nowPlayingLayout, memory: &nowPlayingMemory)
            switch move {
            case let .focus(next):
                withAnimation(Theme.stateChange) { nowPlayingFocus = next }
                // Moving along the tab strip switches tab immediately, the way a
                // segmented control does — there is nothing to confirm.
                if next.row == 1, let tab = NowPlayingTab(rawValue: next.column) {
                    nowPlayingTab = tab
                }
            case .exitLeft, .none:
                break
            }

        case .select:
            activateNowPlaying()

        case .back, .menu:
            closeNowPlaying()

        case .playPause:
            playback.togglePlayPause()

        case let .seek(direction):
            playback.seekRelative(seconds: direction == .forward ? 10 : -10)
        }
    }

    private func activateNowPlaying() {
        switch nowPlayingFocus.row {
        case 0:
            guard transportControls.indices.contains(nowPlayingFocus.column) else { return }
            perform(transportControls[nowPlayingFocus.column])
        case 1:
            if let tab = NowPlayingTab(rawValue: nowPlayingFocus.column) { nowPlayingTab = tab }
        default:
            switch nowPlayingTab {
            case .upNext:
                session.jump(toPlayPosition: nowPlayingFocus.column)
                syncPlayback()
            case .lyrics:
                guard lyricsActions.indices.contains(nowPlayingFocus.column) else { return }
                perform(lyricsActions[nowPlayingFocus.column])
            }
        }
    }

    private func perform(_ control: Transport) {
        switch control {
        case .previous:
            if session.previous(playbackPosition: playback.currentTime) {
                playback.seek(to: 0)
            } else {
                syncPlayback()
            }
        case .playPause:
            playback.togglePlayPause()
        case .next:
            session.next()
            syncPlayback()
        case .shuffle:
            session.toggleShuffle()
        case .repeatMode:
            session.cycleRepeat()
        }
    }

    // MARK: - Lyrics

    private(set) var lyrics: Lyrics?
    private(set) var isLoadingLyrics = false
    private(set) var showsRomanization = false
    /// The credit shown once the song ends, not during it.
    private(set) var showsLyricsAttribution = false

    /// Index of the line to highlight, recomputed from the player's clock.
    var highlightedLyricLine: Int? {
        lyrics?.lineIndex(at: playback.currentTime)
    }

    private func loadLyrics(for track: MusicTrack) {
        lyricsTask?.cancel()
        lyrics = nil
        showsRomanization = false
        showsLyricsAttribution = false
        isPickingLyrics = false
        lyricsChoices = []
        isLoadingLyrics = true

        lyricsTask = Task { [weak self, lyricsService] in
            guard let self else { return }
            // The lyrics browse id arrives a moment after the track does — the
            // session fetches it from /next — and it is the last link in the
            // chain, so waiting a beat for it costs nothing and keeps the
            // fallback complete.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let found = await lyricsService.lyrics(for: track,
                                                   ytMusicBrowseId: self.session.lyricsBrowseId)
            guard !Task.isCancelled, self.session.currentTrack?.id == track.id else { return }
            self.lyrics = found
            self.isLoadingLyrics = false
        }
    }

    private(set) var isPickingLyrics = false
    private(set) var lyricsChoices: [LyricsCandidate] = []

    private func perform(_ action: LyricsAction) {
        switch action {
        case .toggleRomanization:
            withAnimation(Theme.stateChange) { showsRomanization.toggle() }

        case .fixMatch:
            // No text entry: the search runs on the track's own title and artist
            // and shows every source's candidates so the user can pick the right
            // one. Auto-matching picking the wrong candidate is the failure this
            // is for, not the user wanting to search for something else.
            guard let track = session.currentTrack else { return }
            isPickingLyrics = true
            lyricsChoices = []
            Task { [weak self, lyricsService] in
                let term = LyricsQuery(track: track).searchTerm
                let found = await lyricsService.search(term)
                guard let self, self.session.currentTrack?.id == track.id else { return }
                self.lyricsChoices = found
            }

        case .cancelPick:
            isPickingLyrics = false
            lyricsChoices = []

        case let .choose(index):
            guard lyricsChoices.indices.contains(index), let track = session.currentTrack else { return }
            let chosen = lyricsChoices[index].lyrics
            lyrics = chosen
            isPickingLyrics = false
            lyricsChoices = []
            Task { [lyricsService] in await lyricsService.pin(chosen, forTrackId: track.id) }
        }
    }

    // MARK: - Teardown

    func stop() {
        loadTask?.cancel()
        lyricsTask?.cancel()
        playback.onPlaybackEnded = nil
        playback.stop()
        session.stop()
    }
}
