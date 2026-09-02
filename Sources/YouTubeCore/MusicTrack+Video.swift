import Foundation

// MARK: - MusicTrack → Video
//
// The playback pipeline is `Video`-shaped all the way down, and rewriting it to
// be generic over "something with an id and a title" would be a large change to
// ported code for no gain. A track projects onto a `Video` losing only the
// structure playback never looks at (the album, the identified artists), which
// the Music tab keeps hold of separately.

public extension MusicTrack {
    var asVideo: Video {
        Video(
            id: id,
            title: title,
            channelTitle: artistLine,
            channelId: artists.first?.id,
            thumbnailURL: thumbnailURL,
            duration: duration,
            playlistId: playlistId
        )
    }
}
