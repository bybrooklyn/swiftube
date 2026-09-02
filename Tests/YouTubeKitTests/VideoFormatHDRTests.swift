import Foundation
import Testing
@testable import YouTubeCore

@Suite("VideoFormat HDR and Video dedupe")
struct VideoFormatHDRTests {

    @Test("HDR is part of the quality label, so it keeps its own picker row")
    func hdrLabel() {
        let sdr = VideoFormat(label: "1080p60", width: 1920, height: 1080, fps: 60, mimeType: "video/mp4; codecs=\"av01.0.08M.08\"")
        let hdr = VideoFormat(label: "1080p60 HDR", width: 1920, height: 1080, fps: 60, mimeType: "video/mp4; codecs=\"av01.0.08M.10\"", isHDR: true)
        #expect(sdr.qualityLabel == "1080p60")
        #expect(hdr.qualityLabel == "1080p60 HDR")
        #expect(hdr.applyingNothing().isHDR)
    }

    @Test("deduplicatedByID keeps the first occurrence in order")
    func dedupe() {
        let videos = ["a", "b", "a", "c", "b"].map { Video(id: $0, title: $0, channelTitle: "") }
        #expect(videos.deduplicatedByID().map(\.id) == ["a", "b", "c"])
    }
}

private extension VideoFormat {
    /// `applyingPoToken` rebuilds every format; the flag has to survive it.
    func applyingNothing() -> VideoFormat {
        PlayerInfo(video: Video(id: "v", title: "v", channelTitle: ""), formats: [self],
                   hlsURL: nil, dashURL: nil, captionTracks: [], trackingURLs: nil, endCards: [])
            .applyingPoToken("t").formats[0]
    }
}
