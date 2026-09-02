import Foundation
import Observation

private let musicSessionLog = ViewModelLogger(category: "MusicSession")

// MARK: - MusicSession
//
// The music queue's session layer: owns a `MusicQueue`, fills it from YouTube
// Music's `/next`, and publishes the track that should be playing. It does not
// own a player — whoever presents the now-playing surface observes
// `currentTrack` and drives audio-only playback from it.
//
// Splitting it this way keeps every rule about *what plays next* in the tested
// value type below it, and leaves this class as the part that talks to the
// network and to the clock.

@MainActor
@Observable
public final class MusicSession {

    /// How the current queue was started, which decides what the shuffle and
    /// radio affordances mean on the now-playing screen.
    public enum Source: Equatable, Sendable {
        case album(id: String, title: String)
        case playlist(id: String, title: String)
        case artistRadio(name: String)
        /// A single track, with YouTube Music's own mix behind it.
        case trackRadio(title: String)
        case library
    }

    private let api: InnerTubeAPI

    public private(set) var queue = MusicQueue() {
        didSet { queueGeneration += 1 }
    }
    /// Bumped on every mutation of `queue`, in place or wholesale. Lets an
    /// in-flight `/next`/continuation request notice the queue it was about
    /// to write into is not the one it started against — switching albums
    /// mid-flight used to let a radio tail (and its continuation token) land
    /// in whatever queue existed when the response came back, with no check.
    private var queueGeneration = 0

    /// The "opt out of the queue" setting, mirrored from `AppSettings` by
    /// `MusicModel`. Gates the one-track auto-extend in
    /// `refreshTrackContext` — without this, opting out only delayed the
    /// radio tail by one round trip instead of actually not building one.
    public var autoExtendsQueue = true
    public private(set) var source: Source?
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    /// The track the player should be on. Re-set (not merely re-read) on every
    /// queue move, so a view can observe it and reload playback.
    public private(set) var currentTrack: MusicTrack?

    /// `MPLY…` browse id for the current track's YouTube Music lyrics, when the
    /// `/next` response offered one. The last resort in the lyrics chain.
    public private(set) var lyricsBrowseId: String?

    public init(api: InnerTubeAPI) {
        self.api = api
    }

    // MARK: - Starting playback

    /// Plays an album from `startIndex`, with the rest of it queued behind.
    public func play(album: MusicAlbumPage, startIndex: Int = 0) {
        let tracks = album.tracks.filter { !$0.isPodcastEpisode }
        guard !tracks.isEmpty else { return }
        source = .album(id: album.album.id, title: album.album.title)
        queue = MusicQueue(tracks: tracks, startAt: startIndex,
                           shuffled: queue.isShuffled, repeatMode: queue.repeatMode)
        didChangeTrack()
    }

    /// Plays a playlist from `startIndex`.
    public func play(playlist: MusicPlaylistPage, startIndex: Int = 0) {
        let tracks = playlist.tracks.filter { !$0.isPodcastEpisode }
        guard !tracks.isEmpty else { return }
        source = .playlist(id: playlist.playlist.id, title: playlist.playlist.title)
        queue = MusicQueue(tracks: tracks, startAt: startIndex,
                           shuffled: queue.isShuffled, repeatMode: queue.repeatMode)
        didChangeTrack()
    }

    /// Plays one track and asks YouTube Music for the mix that belongs behind it.
    ///
    /// The track plays immediately off the local metadata; the queue tail fills
    /// in when `/next` answers, so a slow response delays the *tail*, never the
    /// first note.
    public func play(track: MusicTrack, from tracks: [MusicTrack]? = nil) {
        if let tracks, let index = tracks.firstIndex(where: { $0.id == track.id }) {
            source = .trackRadio(title: track.title)
            queue = MusicQueue(tracks: tracks.filter { !$0.isPodcastEpisode }, startAt: index,
                               shuffled: queue.isShuffled, repeatMode: queue.repeatMode)
        } else {
            source = .trackRadio(title: track.title)
            queue = MusicQueue(tracks: [track], shuffled: false, repeatMode: queue.repeatMode)
        }
        didChangeTrack()
    }

    /// Starts an artist's radio or shuffle playlist.
    public func playRadio(playlistId: String, artistName: String) async {
        source = .artistRadio(name: artistName)
        await loadQueue(videoId: nil, playlistId: playlistId, radio: true)
    }

    // MARK: - Transport

    public func next() {
        queue.advance()
        didChangeTrack()
    }

    /// Previous, with the standard "restart if we are past the intro" behaviour.
    /// - Parameter playbackPosition: seconds into the current track.
    /// - Returns: `true` when the caller should seek to zero instead of loading
    ///   a new track.
    @discardableResult
    public func previous(playbackPosition: TimeInterval) -> Bool {
        if playbackPosition > 3, currentTrack != nil { return true }
        queue.rewind()
        didChangeTrack()
        return false
    }

    /// What the player should do now that a track has played to its end.
    public enum EndOfTrack: Equatable, Sendable {
        /// Repeat-one: seek to zero and keep playing the same item.
        case replayCurrent
        /// Load and play this track.
        case play(MusicTrack)
        /// The queue is done.
        case finished
    }

    /// Called when the current track plays to its end.
    ///
    /// Returns an instruction rather than just publishing a track, because
    /// repeat-one produces no change to `currentTrack` and a view observing it
    /// would see nothing happen.
    @discardableResult
    public func trackDidFinish() -> EndOfTrack {
        // What track to land on is MusicQueue.advanceAfterPlayback's call
        // (tested there) rather than re-decided here — this used to branch on
        // repeatMode without ever calling it. Still checked here too, to
        // choose .replayCurrent vs .play: a same-id result isn't a reliable
        // signal on its own (repeat-all wrapping a one-track queue lands back
        // on the same id without it being a repeat-one replay).
        let repeatingOne = queue.repeatMode == .one && currentTrack != nil
        guard let next = queue.advanceAfterPlayback() else {
            currentTrack = nil
            return .finished
        }
        if repeatingOne {
            refillIfNeeded()
            return .replayCurrent
        }
        didChangeTrack()
        return .play(next)
    }

    public func jump(toPlayPosition position: Int) {
        guard queue.jump(toPlayPosition: position) != nil else { return }
        didChangeTrack()
    }

    public func toggleShuffle() {
        queue.toggleShuffle()
        // Shuffling never interrupts what is playing (see `MusicQueue`), so no
        // track change is published here.
    }

    public func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
    }

    public func playNext(_ track: MusicTrack) {
        queue.playNext(track)
    }

    public func addToQueue(_ track: MusicTrack) {
        queue.append([track])
    }

    public func remove(atPlayPosition position: Int) {
        let wasCurrent = position == queue.currentPosition
        queue.remove(atPlayPosition: position)
        if wasCurrent { didChangeTrack() }
    }

    public func stop() {
        queue = MusicQueue()
        source = nil
        currentTrack = nil
        lyricsBrowseId = nil
    }

    // MARK: - Loading

    private func didChangeTrack() {
        currentTrack = queue.currentTrack
        lyricsBrowseId = nil
        guard let track = currentTrack else { return }
        Task { await refreshTrackContext(for: track) }
        refillIfNeeded()
    }

    private func refillIfNeeded() {
        guard queue.shouldExtendRadio, let token = queue.radioContinuation else { return }
        Task { await extendRadio(token: token) }
    }

    private func loadQueue(videoId: String?, playlistId: String?, radio: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.fetchMusicQueue(videoId: videoId, playlistId: playlistId, radio: radio)
            let tracks = page.tracks.filter { !$0.isPodcastEpisode }
            guard !tracks.isEmpty else { return }
            queue = MusicQueue(tracks: tracks, shuffled: queue.isShuffled,
                               repeatMode: queue.repeatMode, radioContinuation: page.continuation)
            lyricsBrowseId = page.lyricsBrowseId
            currentTrack = queue.currentTrack
        } catch {
            lastError = error
            musicSessionLog.error("queue load failed: \(error)")
        }
    }

    /// One `/next` call per track, serving both purposes it can: it is the only
    /// place the track's lyrics browse id exists, and when the queue is a lone
    /// track it is also where the mix behind it comes from.
    ///
    /// Deliberately fired *after* the track is published, so a slow response
    /// delays the queue tail rather than the first note.
    private func refreshTrackContext(for track: MusicTrack) async {
        let generation = queueGeneration
        do {
            let page = try await api.fetchMusicQueue(videoId: track.id, playlistId: track.playlistId)
            // A slow response must not stomp a queue the user has since changed.
            guard currentTrack?.id == track.id else { return }
            lyricsBrowseId = page.lyricsBrowseId
            guard autoExtendsQueue, queue.count == 1, generation == queueGeneration else { return }
            queue.radioContinuation = page.continuation
            queue.append(page.tracks.filter { !$0.isPodcastEpisode })
        } catch {
            musicSessionLog.notice("track context failed: \(error)")
        }
    }

    private func extendRadio(token: String) async {
        // Clear first: `refillIfNeeded` fires on every track change, and without
        // this the same token is spent several times over.
        queue.radioContinuation = nil
        // Snapshotted *after* the clear above, which itself bumps the
        // generation — otherwise every call would see its own clear as "the
        // queue changed" and refuse to write its own result.
        let generation = queueGeneration
        do {
            let page = try await api.fetchMusicQueueContinuation(token)
            // The queue was replaced (a different album/playlist/track started)
            // while this was in flight — the radio tail belongs to a queue
            // that no longer exists; do not inject it or its continuation
            // token into whatever queue exists now.
            guard generation == queueGeneration else { return }
            queue.append(page.tracks.filter { !$0.isPodcastEpisode })
            queue.radioContinuation = page.continuation
        } catch {
            musicSessionLog.notice("radio continuation failed: \(error)")
        }
    }

}
