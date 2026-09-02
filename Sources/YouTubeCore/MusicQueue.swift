import Foundation

// MARK: - MusicQueue
//
// The music queue is a value type with no player in it, for the same reason the
// focus engine is: "shuffle on, then repeat-one, then skip back twice" is a
// thing to pin down in tests, not to discover by pressing buttons on a TV.
// `MusicSession` owns one of these and is the only thing that talks to playback.

/// What happens when the queue runs off its end.
public enum MusicRepeatMode: String, CaseIterable, Sendable, Codable {
    /// Stop at the last track.
    case off
    /// Wrap around to the first.
    case all
    /// Replay the current track forever.
    case one

    public var next: MusicRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// An ordered list of tracks with a cursor, a shuffle order, and a repeat mode.
///
/// Shuffle is a *permutation of positions*, not a reordering of `tracks`. Keeping
/// the original order intact is what lets shuffle be turned off mid-song and
/// leave you exactly where you are in the album, which is what YouTube Music,
/// Apple Music and Spotify all do.
public struct MusicQueue: Sendable, Equatable {

    /// The tracks in the order they were added (album order, playlist order, …).
    public private(set) var tracks: [MusicTrack]

    /// Positions into `tracks`, in play order. Identity when not shuffled.
    private var order: [Int]

    /// Cursor into `order`, not into `tracks`.
    private var cursor: Int

    public private(set) var isShuffled: Bool
    public var repeatMode: MusicRepeatMode

    /// Where the endless tail continues from, when this queue came from a radio.
    public var radioContinuation: String?

    public init(
        tracks: [MusicTrack] = [],
        startAt index: Int = 0,
        shuffled: Bool = false,
        repeatMode: MusicRepeatMode = .off,
        radioContinuation: String? = nil
    ) {
        self.tracks = tracks
        self.order = Array(tracks.indices)
        self.cursor = 0
        self.isShuffled = false
        self.repeatMode = repeatMode
        self.radioContinuation = radioContinuation
        if tracks.indices.contains(index) { cursor = index }
        if shuffled { setShuffled(true) }
    }

    // MARK: - Reading

    public var isEmpty: Bool { tracks.isEmpty }
    public var count: Int { tracks.count }

    public var currentTrack: MusicTrack? {
        guard order.indices.contains(cursor), tracks.indices.contains(order[cursor]) else { return nil }
        return tracks[order[cursor]]
    }

    /// Position of the current track in the *play* order — what "3 of 12" means.
    public var currentPosition: Int { cursor }

    /// The tracks still ahead, in play order. This is what the up-next list shows.
    public var upcoming: [MusicTrack] {
        order.dropFirst(cursor + 1).compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }
    }

    /// The whole queue in play order, which is what a reorderable queue view renders.
    public var playOrder: [MusicTrack] {
        order.compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }
    }

    public var hasNext: Bool {
        if repeatMode != .off { return !tracks.isEmpty }
        return cursor + 1 < order.count
    }

    /// True when the tail is close enough that a radio queue should fetch more.
    public var shouldExtendRadio: Bool {
        radioContinuation != nil && order.count - cursor <= 3
    }

    // MARK: - Moving

    /// Skip forward. Honours repeat-all by wrapping; **ignores repeat-one**,
    /// because a deliberate press of Next means next, not "play this again".
    /// Returns the new current track, or nil when the queue is finished.
    @discardableResult
    public mutating func advance() -> MusicTrack? {
        guard !order.isEmpty else { return nil }
        if cursor + 1 < order.count {
            cursor += 1
        } else if repeatMode == .all {
            cursor = 0
            // A second pass through a shuffled queue gets a fresh permutation,
            // otherwise "shuffle" is one fixed order repeated forever.
            if isShuffled { reshuffleKeepingCurrent(false) }
        } else {
            return nil
        }
        return currentTrack
    }

    /// What to play when a track ends on its own. Unlike `advance()` this does
    /// honour repeat-one.
    @discardableResult
    public mutating func advanceAfterPlayback() -> MusicTrack? {
        if repeatMode == .one { return currentTrack }
        return advance()
    }

    /// Skip backward, stopping at the first track.
    ///
    /// The caller decides whether a Previous press restarts the current track
    /// instead (every music app restarts when you are more than a few seconds
    /// in) — that is a playback-position question, not a queue one.
    @discardableResult
    public mutating func rewind() -> MusicTrack? {
        guard !order.isEmpty else { return nil }
        if cursor > 0 {
            cursor -= 1
        } else if repeatMode == .all {
            cursor = order.count - 1
        }
        return currentTrack
    }

    /// Jump to a position in the *play* order — what tapping a row in the queue does.
    @discardableResult
    public mutating func jump(toPlayPosition position: Int) -> MusicTrack? {
        guard order.indices.contains(position) else { return nil }
        cursor = position
        return currentTrack
    }

    /// Jump to a track by id, wherever it sits in the play order.
    @discardableResult
    public mutating func jump(toTrackId id: String) -> MusicTrack? {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == id }),
              let position = order.firstIndex(of: trackIndex) else { return nil }
        cursor = position
        return currentTrack
    }

    // MARK: - Shuffle

    public mutating func setShuffled(_ shuffled: Bool) {
        guard shuffled != isShuffled else { return }
        isShuffled = shuffled
        if shuffled {
            reshuffleKeepingCurrent(true)
        } else {
            // Unshuffling leaves you on the same song, at its real position.
            let current = order.indices.contains(cursor) ? order[cursor] : 0
            order = Array(tracks.indices)
            cursor = order.firstIndex(of: current) ?? 0
        }
    }

    public mutating func toggleShuffle() { setShuffled(!isShuffled) }

    /// Builds a fresh permutation. With `keepingCurrent` the current track is
    /// moved to the front so shuffling never interrupts what is playing.
    private mutating func reshuffleKeepingCurrent(_ keepingCurrent: Bool) {
        let current = order.indices.contains(cursor) ? order[cursor] : nil
        var shuffled = Array(tracks.indices).shuffled()
        if keepingCurrent, let current, let position = shuffled.firstIndex(of: current) {
            shuffled.remove(at: position)
            shuffled.insert(current, at: 0)
            order = shuffled
            cursor = 0
        } else {
            order = shuffled
            cursor = 0
        }
    }

    // MARK: - Editing

    /// Appends tracks already known to the queue-building side (a radio page, or
    /// "add to queue"). Duplicates by video id are dropped: radio continuations
    /// routinely re-serve the seed track.
    public mutating func append(_ newTracks: [MusicTrack]) {
        let known = Set(tracks.map(\.id))
        let fresh = newTracks.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let firstNewIndex = tracks.count
        tracks.append(contentsOf: fresh)
        let appendedPositions = Array(firstNewIndex..<tracks.count)
        // Appended tracks keep their arrival order even in a shuffled queue —
        // a radio tail is already server-shuffled, and re-permuting it would
        // reorder tracks the user can see sitting in up-next.
        order.append(contentsOf: appendedPositions)
    }

    /// Inserts directly after the current track ("Play next").
    public mutating func playNext(_ track: MusicTrack) {
        guard !tracks.contains(where: { $0.id == track.id }) else {
            // Already queued: move it instead of duplicating. Already sitting
            // right after the cursor — nothing to do, and falling through
            // would walk the cursor itself backward off the current track.
            if let trackIndex = tracks.firstIndex(where: { $0.id == track.id }),
               let position = order.firstIndex(of: trackIndex), position != cursor {
                order.remove(at: position)
                let insertAt = min(cursor + (position <= cursor ? 0 : 1), order.count)
                order.insert(trackIndex, at: insertAt)
                if position <= cursor { cursor -= 1 }
            }
            return
        }
        tracks.append(track)
        order.insert(tracks.count - 1, at: min(cursor + 1, order.count))
    }

    /// Removes a track from the play order. Removing the current track advances
    /// onto the next one, which is what every queue UI does.
    ///
    /// Removes from `tracks` too, not just `order` — leaving it behind made
    /// `count`/`isEmpty` lie (they read `tracks.count`), let `setShuffled(false)`
    /// resurrect the removed track (it rebuilds `order` from `tracks.indices`),
    /// and made `append`'s id-dedup refuse to re-add it.
    public mutating func remove(atPlayPosition position: Int) {
        guard order.indices.contains(position) else { return }
        let trackIndex = order[position]
        guard tracks.indices.contains(trackIndex) else { return }

        tracks.remove(at: trackIndex)
        order.remove(at: position)
        // Every position after the removed track just shifted down by one.
        order = order.map { $0 > trackIndex ? $0 - 1 : $0 }

        if position < cursor {
            cursor -= 1
        } else if position == cursor {
            cursor = min(cursor, max(order.count - 1, 0))
        }
    }
}
