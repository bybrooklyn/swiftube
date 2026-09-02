import Foundation
import Testing
@testable import YouTubeCore

// Two parser defects that quietly corrupted card metadata.
//
// 1. `viewCount` was "the first metadata line containing a digit", with no
//    view-count marker. `extractNumber("2 days ago")` falls through the K/M/B
//    branch, strips non-digits, and returns 2 — so a TVHTML5 tile whose second
//    line holds only a relative date got a view count of 2. The sibling
//    `publishedAt` loop always got this right by demanding "N <unit> ago".
//
// 2. `extractText` handled `simpleText` and `runs` but not `{"content": …}`,
//    the shape YouTube's ViewModel-era renderers use. Four call sites had
//    learned to try `["content"]` locally; the helper had not.

@Suite("View counts and text shapes")
struct ViewCountAndTextShapeTests {

    // MARK: - Fixtures

    /// A TVHTML5 tile whose second metadata line holds exactly `secondLine`.
    private func tile(id: String, secondLine: String) -> [String: Any] {
        [
            "contentType": "TILE_CONTENT_TYPE_VIDEO",
            "contentId": id,
            "onSelectCommand": ["watchEndpoint": ["videoId": id]],
            "header": [
                "tileHeaderRenderer": [
                    "thumbnail": ["thumbnails": [["url": "https://example.com/t.jpg", "width": 1280, "height": 720]]]
                ]
            ],
            "metadata": [
                "tileMetadataRenderer": [
                    "title": ["simpleText": "A Video"],
                    "lines": [
                        ["lineRenderer": ["items": [
                            ["lineItemRenderer": ["text": ["simpleText": "A Channel"]]]
                        ]]],
                        ["lineRenderer": ["items": [
                            ["lineItemRenderer": ["text": ["simpleText": secondLine]]]
                        ]]]
                    ]
                ]
            ]
        ]
    }

    private func tileResponse(_ tiles: [[String: Any]]) -> [String: Any] {
        [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        ["itemSectionRenderer": ["contents": tiles.map { ["tileRenderer": $0] }]]
                    ]
                ]
            ]
        ]
    }

    /// A lockupViewModel whose second metadata row holds `parts`.
    private func lockupResponse(id: String, parts: [String]) -> [String: Any] {
        let lockup: [String: Any] = [
            "lockupViewModel": [
                "contentId": id,
                "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                "rendererContext": ["commandContext": ["onTap": [
                    "innertubeCommand": ["watchEndpoint": ["videoId": id]]
                ]]],
                "contentImage": ["thumbnailViewModel": [
                    "image": ["sources": [["url": "https://example.com/t.jpg", "width": 336, "height": 188]]]
                ]],
                "metadata": ["lockupMetadataViewModel": [
                    "title": ["content": "A Video"],
                    "metadata": ["contentMetadataViewModel": [
                        "metadataRows": [
                            ["metadataParts": [["text": ["content": "A Channel"]]]],
                            ["metadataParts": parts.map { ["text": ["content": $0]] }]
                        ]
                    ]]
                ]]
            ]
        ]
        return [
            "contents": [
                "sectionListRenderer": [
                    "contents": [["itemSectionRenderer": ["contents": [lockup]]]]
                ]
            ]
        ]
    }

    // MARK: - The defect

    @Test("a tile with only a relative date has no view count, not two")
    func relativeDateIsNotAViewCount() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            tileResponse([tile(id: "aaaaaaaaaaa", secondLine: "2 days ago")]), title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == nil)
    }

    @Test("every relative-date unit is rejected, not counted")
    func everyRelativeUnitIsRejected() async throws {
        let api = InnerTubeAPI()
        for line in ["3 hours ago", "5 minutes ago", "1 week ago", "11 months ago", "7 years ago"] {
            let group = try await api.parseVideoGroupForTesting(
                tileResponse([tile(id: "bbbbbbbbbbb", secondLine: line)]), title: nil)
            let video = try #require(group.videos.first, "no video for \(line)")
            #expect(video.viewCount == nil, "\"\(line)\" was read as a view count")
        }
    }

    @Test("a lockup with only a relative date has no view count either")
    func lockupRelativeDateIsNotAViewCount() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            lockupResponse(id: "ccccccccccc", parts: ["21 hours ago"]), title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == nil)
    }

    // MARK: - Still parsing what it should

    @Test("a real view count still parses, plain and compact")
    func realViewCountsStillParse() async throws {
        let api = InnerTubeAPI()
        let cases: [(String, Int)] = [
            ("1,234 views", 1234),
            ("1.2M views", 1_200_000),
            ("457K views", 457_000),
            ("1 view", 1)
        ]
        for (line, expected) in cases {
            let group = try await api.parseVideoGroupForTesting(
                tileResponse([tile(id: "ddddddddddd", secondLine: line)]), title: nil)
            let video = try #require(group.videos.first, "no video for \(line)")
            #expect(video.viewCount == expected, "\"\(line)\" → \(String(describing: video.viewCount))")
        }
    }

    @Test("a live stream's concurrent-viewer line counts as a view count")
    func watchingCountsAsViews() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            tileResponse([tile(id: "eeeeeeeeeee", secondLine: "12K watching")]), title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == 12_000)
    }

    @Test("a lockup carrying both views and a date takes the views")
    func lockupTakesViewsNotDate() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            lockupResponse(id: "fffffffffff", parts: ["457K views", "21 hours ago"]), title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == 457_000)
    }

    @Test("the date is still parsed even when it sits beside a view count")
    func publishedDateSurvives() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            lockupResponse(id: "ggggggggggg", parts: ["457K views", "21 hours ago"]), title: nil)
        let video = try #require(group.videos.first)
        #expect(video.publishedAt != nil)
    }

    // MARK: - The ViewModel text shape

    // Tested against the helper directly rather than through a lockup: the lockup
    // parser already worked around this locally with its own `["content"]` check,
    // so a lockup fixture would pass with or without the helper fix. The call
    // sites that had no workaround — `parseChannel`'s title being the visible one
    // — go through `extractText`, so that is what needs pinning.

    @Test("extractText reads the ViewModel content shape")
    func extractTextReadsContentShape() async throws {
        let api = InnerTubeAPI()
        #expect(await api.extractText(["content": "Nieuwsuur"]) == "Nieuwsuur")
    }

    @Test("extractText still prefers simpleText and runs where they are present")
    func extractTextPrefersOlderShapes() async throws {
        let api = InnerTubeAPI()
        #expect(await api.extractText(["simpleText": "Plain"]) == "Plain")
        #expect(await api.extractText(["runs": [["text": "Two "], ["text": "runs"]]]) == "Two runs")
        // simpleText wins over content when a renderer somehow carries both.
        #expect(await api.extractText(["simpleText": "Wins", "content": "Loses"]) == "Wins")
    }

    @Test("extractText returns nil for a dictionary with no text at all")
    func extractTextReturnsNilForNoText() async throws {
        let api = InnerTubeAPI()
        #expect(await api.extractText(["accessibility": ["label": "not text"]]) == nil)
    }

    @Test("simpleText and runs still win where they are present")
    func olderShapesStillWork() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            tileResponse([tile(id: "iiiiiiiiiii", secondLine: "1,000 views")]), title: nil)
        let video = try #require(group.videos.first)
        #expect(video.title == "A Video")
        #expect(video.channelTitle == "A Channel")
        #expect(video.viewCount == 1000)
    }
}
