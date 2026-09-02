import Foundation
import Testing
@testable import YouTubeCore

private func makeTracks(_ count: Int) -> [MusicTrack] {
    (1...count).map { MusicTrack(id: "t\($0)", title: "Track \($0)") }
}

@Suite("Music queue")
struct MusicQueueTests {

    @Test("A fresh queue starts on the requested track")
    func startsAtIndex() {
        let queue = MusicQueue(tracks: makeTracks(5), startAt: 2)
        #expect(queue.currentTrack?.id == "t3")
        #expect(queue.currentPosition == 2)
        #expect(queue.upcoming.map(\.id) == ["t4", "t5"])
    }

    @Test("An out-of-range start index falls back to the first track")
    func startIndexClamped() {
        #expect(MusicQueue(tracks: makeTracks(3), startAt: 99).currentTrack?.id == "t1")
        #expect(MusicQueue(tracks: [], startAt: 4).currentTrack == nil)
    }

    @Test("Advance walks forward and stops at the end with repeat off")
    func advanceStops() {
        var queue = MusicQueue(tracks: makeTracks(3))
        #expect(queue.advance()?.id == "t2")
        #expect(queue.advance()?.id == "t3")
        #expect(queue.hasNext == false)
        #expect(queue.advance() == nil)
        // A finished queue keeps its last track as current rather than blanking.
        #expect(queue.currentTrack?.id == "t3")
    }

    @Test("Repeat-all wraps to the top")
    func repeatAllWraps() {
        var queue = MusicQueue(tracks: makeTracks(2), repeatMode: .all)
        queue.advance()
        #expect(queue.advance()?.id == "t1")
        #expect(queue.hasNext)
    }

    @Test("Repeat-one replays on end of playback but not on a Next press")
    func repeatOne() {
        var queue = MusicQueue(tracks: makeTracks(3), repeatMode: .one)
        #expect(queue.advanceAfterPlayback()?.id == "t1")   // ended by itself
        #expect(queue.advance()?.id == "t2")                // deliberate skip
    }

    @Test("Repeat cycles off → all → one → off")
    func repeatCycle() {
        #expect(MusicRepeatMode.off.next == .all)
        #expect(MusicRepeatMode.all.next == .one)
        #expect(MusicRepeatMode.one.next == .off)
    }

    @Test("Rewind stops at the first track unless repeat-all is on")
    func rewind() {
        var queue = MusicQueue(tracks: makeTracks(3), startAt: 1)
        #expect(queue.rewind()?.id == "t1")
        #expect(queue.rewind()?.id == "t1")     // held at the top

        var looping = MusicQueue(tracks: makeTracks(3), repeatMode: .all)
        #expect(looping.rewind()?.id == "t3")
    }

    @Test("Shuffling keeps the current track playing and puts it first")
    func shuffleKeepsCurrent() {
        var queue = MusicQueue(tracks: makeTracks(20), startAt: 7)
        let playing = queue.currentTrack
        queue.setShuffled(true)
        #expect(queue.isShuffled)
        #expect(queue.currentTrack == playing)
        #expect(queue.currentPosition == 0)
        #expect(queue.playOrder.count == 20)
        #expect(Set(queue.playOrder.map(\.id)).count == 20)  // a permutation, not a resample
    }

    @Test("Unshuffling restores album order at the current track's real position")
    func unshuffleRestoresOrder() {
        var queue = MusicQueue(tracks: makeTracks(10), startAt: 4)
        queue.setShuffled(true)
        let playing = queue.currentTrack
        queue.setShuffled(false)
        #expect(!queue.isShuffled)
        #expect(queue.currentTrack == playing)
        #expect(queue.playOrder.map(\.id) == makeTracks(10).map(\.id))
        #expect(queue.currentPosition == 4)
    }

    @Test("Shuffle survives a full lap and stays a permutation")
    func shuffleAfterWrap() {
        var queue = MusicQueue(tracks: makeTracks(4), shuffled: true, repeatMode: .all)
        for _ in 0..<8 { queue.advance() }
        #expect(queue.playOrder.count == 4)
        #expect(Set(queue.playOrder.map(\.id)).count == 4)
        #expect(queue.currentTrack != nil)
    }

    @Test("Jumping by play position and by track id land on the same song")
    func jumping() {
        var queue = MusicQueue(tracks: makeTracks(5))
        #expect(queue.jump(toPlayPosition: 3)?.id == "t4")
        #expect(queue.jump(toPlayPosition: 99) == nil)
        #expect(queue.jump(toTrackId: "t2")?.id == "t2")
        #expect(queue.jump(toTrackId: "nope") == nil)
        #expect(queue.currentTrack?.id == "t2")
    }

    @Test("Appending drops ids already in the queue — radio re-serves its seed")
    func appendDeduplicates() {
        var queue = MusicQueue(tracks: makeTracks(2))
        queue.append([MusicTrack(id: "t2", title: "Track 2"), MusicTrack(id: "t3", title: "Track 3")])
        #expect(queue.playOrder.map(\.id) == ["t1", "t2", "t3"])
    }

    @Test("Play next lands directly after the current track")
    func playNext() {
        var queue = MusicQueue(tracks: makeTracks(3))
        queue.playNext(MusicTrack(id: "x", title: "Jumped the line"))
        #expect(queue.upcoming.first?.id == "x")
        #expect(queue.currentTrack?.id == "t1")
    }

    @Test("Play next on an already-queued track moves it instead of duplicating")
    func playNextMovesExisting() {
        var queue = MusicQueue(tracks: makeTracks(4))
        queue.playNext(MusicTrack(id: "t4", title: "Track 4"))
        #expect(queue.playOrder.map(\.id) == ["t1", "t4", "t2", "t3"])
        #expect(queue.currentTrack?.id == "t1")
    }

    @Test("Removing the current track advances onto the next one")
    func removeCurrent() {
        var queue = MusicQueue(tracks: makeTracks(3), startAt: 1)
        queue.remove(atPlayPosition: 1)
        #expect(queue.playOrder.map(\.id) == ["t1", "t3"])
        #expect(queue.currentTrack?.id == "t3")
    }

    @Test("Removing above the cursor leaves the current track playing")
    func removeAbove() {
        var queue = MusicQueue(tracks: makeTracks(3), startAt: 2)
        queue.remove(atPlayPosition: 0)
        #expect(queue.currentTrack?.id == "t3")
        #expect(queue.playOrder.map(\.id) == ["t2", "t3"])
    }

    @Test("A radio queue asks for more only when its tail runs short")
    func radioRefillThreshold() {
        var queue = MusicQueue(tracks: makeTracks(10), radioContinuation: "tok")
        #expect(!queue.shouldExtendRadio)
        for _ in 0..<7 { queue.advance() }
        #expect(queue.shouldExtendRadio)

        var noRadio = MusicQueue(tracks: makeTracks(2))
        noRadio.advance()
        #expect(!noRadio.shouldExtendRadio)
    }

    @Test("An empty queue answers every transport call without trapping")
    func emptyQueue() {
        var queue = MusicQueue()
        #expect(queue.isEmpty)
        #expect(queue.currentTrack == nil)
        #expect(queue.advance() == nil)
        #expect(queue.rewind() == nil)
        #expect(!queue.hasNext)
        queue.toggleShuffle()
        queue.remove(atPlayPosition: 0)
        #expect(queue.isEmpty)
    }

    @Test("The music queue is on by default, with an opt-out")
    func settingDefault() {
        #expect(AppSettings().musicQueueEnabled)
        #expect(AppSettings().manualLyricsSearchEnabled == false)
    }

    @Test("New settings survive a round trip through old stored JSON")
    func settingsForwardCompatible() throws {
        // Simulates a settings file written before these keys existed.
        let old = Data(#"{"settingsVersion": 1, "playbackSpeed": 1.5}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(decoded.playbackSpeed == 1.5)
        #expect(decoded.musicQueueEnabled)             // default, not a decode failure
        #expect(decoded.manualLyricsSearchEnabled == false)

        var changed = decoded
        changed.musicQueueEnabled = false
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        #expect(round.musicQueueEnabled == false)
    }
}
