import Testing
import YouTubeCore
@testable import YouTubeTV

@Suite("Comment composer")
struct CommentComposerTests {

    @Test("every key, including Post, is reachable by walking the grid")
    func allKeysReachable() {
        let keys = CommentComposer.keys
        var seen: Set<Int> = [0]
        var frontier = [0]
        while let index = frontier.popLast() {
            for direction in [MoveDirection.up, .down, .left, .right] {
                if let next = SearchModel.nextKey(from: index, direction: direction, keys: keys),
                   seen.insert(next).inserted {
                    frontier.append(next)
                }
            }
        }
        #expect(seen.count == keys.count)
        #expect(keys.last == .submit)
    }

    @Test("post is refused while the text is blank")
    @MainActor
    func postNeedsText() {
        let composer = CommentComposer()
        let post = CommentComposer.keys.firstIndex(of: .submit)!
        // Down lands on the wide row, then Right walks to Post at its end.
        // Bounded: the grid is finite and Right stops at the last key.
        func walkToPost() {
            for _ in 0..<12 where composer.keyIndex != post { composer.move(.down) }
            for _ in 0..<12 where composer.keyIndex != post { composer.move(.right) }
        }
        walkToPost()
        #expect(composer.keyIndex == post)
        #expect(composer.select() == false)
        // Type "a" (Up from the wide row lands on the last character row; walk
        // Up and Left to the corner) then return to Post.
        for _ in 0..<12 where composer.keyIndex != 0 { composer.move(.up) }
        for _ in 0..<12 where composer.keyIndex != 0 { composer.move(.left) }
        #expect(composer.keyIndex == 0)
        #expect(composer.select() == false)
        #expect(composer.text == "a")
        walkToPost()
        #expect(composer.select() == true)
    }

    @Test("a playlist tile is a card whose id is its playlist id")
    func playlistTile() {
        let tile = Video(id: "PL1", title: "Mix", channelTitle: "", playlistId: "PL1")
        let video = Video(id: "v1", title: "Song", channelTitle: "", playlistId: "PL1")
        #expect(tile.isPlaylistTile)
        #expect(!video.isPlaylistTile)
    }
}
