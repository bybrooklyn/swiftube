import Foundation
import Testing
@testable import YouTubeCore

// Regression tests for the up-next / related rail returning nothing.
//
// `parseRelatedVideos` only understood `compactVideoRenderer`. YouTube has since
// migrated the watch page's secondary column to `lockupViewModel`, so on a live
// `/next` (checked 2026-08-21, signed out) the response carried 20
// `lockupViewModel`, 10 `shortsLockupViewModel` and **zero**
// `compactVideoRenderer` — and the parser logged `found=0` for every video. The
// up-next rail was empty, and with it autoplay had nothing to advance to.
//
// The fixtures below are trimmed from that captured response, keeping the exact
// key path each field really lives at.

/// Serves one canned `/next` body for any POST.
private final class NextEndpointURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var body: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.httpMethod == "POST"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = (try? JSONSerialization.data(withJSONObject: Self.body)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Related videos: lockupViewModel", .serialized)
struct RelatedVideosLockupTests {

    // MARK: - Fixtures

    /// The shape a related video actually arrives in now.
    private func lockup(id: String, title: String, channel: String) -> [String: Any] {
        [
            "lockupViewModel": [
                "contentId": id,
                "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                "rendererContext": [
                    "commandContext": [
                        "onTap": [
                            "innertubeCommand": [
                                "watchEndpoint": ["videoId": id]
                            ]
                        ]
                    ]
                ],
                "contentImage": [
                    "thumbnailViewModel": [
                        "image": [
                            "sources": [
                                ["url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                                 "width": 336, "height": 188]
                            ]
                        ],
                        "overlays": [
                            ["thumbnailBottomOverlayViewModel": [
                                "badges": [["thumbnailBadgeViewModel": ["text": "21:14"]]]
                            ]]
                        ]
                    ]
                ],
                "metadata": [
                    "lockupMetadataViewModel": [
                        "title": ["content": title],
                        "metadata": [
                            "contentMetadataViewModel": [
                                "metadataRows": [
                                    ["metadataParts": [["text": ["content": channel]]]],
                                    ["metadataParts": [
                                        ["text": ["content": "457K views"]],
                                        ["text": ["content": "21 hours ago"]]
                                    ]]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

    /// The classic shape, which the TV client still emits.
    private func compact(id: String, title: String) -> [String: Any] {
        [
            "compactVideoRenderer": [
                "videoId": id,
                "title": ["simpleText": title],
                "shortBylineText": ["runs": [["text": "Some Channel"]]],
                "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(id)/hq.jpg"]]]
            ]
        ]
    }

    private func nextResponse(results: [[String: Any]]) -> [String: Any] {
        [
            "contents": [
                "twoColumnWatchNextResults": [
                    "secondaryResults": [
                        "secondaryResults": ["results": results]
                    ]
                ]
            ]
        ]
    }

    private func makeAPI() -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NextEndpointURLProtocol.self]
        return InnerTubeAPI(authToken: nil, session: URLSession(configuration: config))
    }

    // MARK: - Tests

    @Test("lockupViewModel related videos are parsed — the shape YouTube returns now")
    func lockupsAreParsed() async throws {
        NextEndpointURLProtocol.body = nextResponse(results: [
            lockup(id: "kpSTWG7_SUE", title: "I Made a SCANNER", channel: "PrestonPlayz"),
            lockup(id: "aaaaaaaaaaa", title: "Second one", channel: "Someone Else")
        ])
        let info = try await makeAPI().fetchNextInfo(videoId: "dQw4w9WgXcQ")
        #expect(info.relatedVideos.map(\.id) == ["kpSTWG7_SUE", "aaaaaaaaaaa"])
        #expect(info.relatedVideos.first?.title == "I Made a SCANNER")
        #expect(info.relatedVideos.first?.channelTitle == "PrestonPlayz")
    }

    @Test("compactVideoRenderer still works — the TV client has not migrated")
    func compactsStillParse() async throws {
        NextEndpointURLProtocol.body = nextResponse(results: [
            compact(id: "oldshape001", title: "Classic renderer")
        ])
        let info = try await makeAPI().fetchNextInfo(videoId: "dQw4w9WgXcQ")
        #expect(info.relatedVideos.map(\.id) == ["oldshape001"])
    }

    @Test("both shapes in one response are kept, in document order")
    func mixedShapesKeepOrder() async throws {
        NextEndpointURLProtocol.body = nextResponse(results: [
            lockup(id: "lockup00001", title: "New", channel: "A"),
            compact(id: "compact0001", title: "Old"),
            lockup(id: "lockup00002", title: "New again", channel: "B")
        ])
        let info = try await makeAPI().fetchNextInfo(videoId: "dQw4w9WgXcQ")
        #expect(info.relatedVideos.map(\.id) == ["lockup00001", "compact0001", "lockup00002"])
    }

    @Test("a video repeated across shapes is returned once")
    func duplicatesAreDeduped() async throws {
        NextEndpointURLProtocol.body = nextResponse(results: [
            lockup(id: "samevideo01", title: "New", channel: "A"),
            compact(id: "samevideo01", title: "Old"),
            lockup(id: "othervideo1", title: "Other", channel: "B")
        ])
        let info = try await makeAPI().fetchNextInfo(videoId: "dQw4w9WgXcQ")
        #expect(info.relatedVideos.map(\.id) == ["samevideo01", "othervideo1"])
    }

    @Test("a response with no related videos yields an empty list, not a failure")
    func emptyStaysEmpty() async throws {
        NextEndpointURLProtocol.body = nextResponse(results: [])
        let info = try await makeAPI().fetchNextInfo(videoId: "dQw4w9WgXcQ")
        #expect(info.relatedVideos.isEmpty)
    }

    @Test("the rail is capped at 25 so one response cannot flood the up-next queue")
    func resultsAreCapped() async throws {
        let many = (0..<40).map { lockup(id: String(format: "vid%08d", $0), title: "V\($0)", channel: "C") }
        NextEndpointURLProtocol.body = nextResponse(results: many)
        let info = try await makeAPI().fetchNextInfo(videoId: "dQw4w9WgXcQ")
        #expect(info.relatedVideos.count == 25)
    }
}
