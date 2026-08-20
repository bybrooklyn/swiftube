import Foundation
import Testing
import YouTubeCore
@testable import YouTubeTV

@Suite("Format")
struct FormatTests {

    @Test("compact numbers match what YouTube shows")
    func compactNumbers() {
        #expect(Format.compact(0) == "0")
        #expect(Format.compact(812) == "812")
        #expect(Format.compact(1_200) == "1.2K")
        #expect(Format.compact(336_000) == "336K")
        #expect(Format.compact(2_300_000) == "2.3M")
        #expect(Format.compact(23_000_000) == "23M")
        // The case YouTubeCore's formattedViewCount gets wrong — it renders
        // this as "1200.0M views".
        #expect(Format.compact(1_200_000_000) == "1.2B")
    }

    @Test("rounding never spills past a unit boundary")
    func roundingPromotesUnit() {
        // 999,500 scales to 999.5K and rounds to 1000 — it must promote to "1M"
        // rather than render "1000K".
        #expect(Format.compact(999_500) == "1M")
        #expect(Format.compact(999_499_999) == "999M")
        #expect(Format.compact(999_500_000) == "1B")
    }

    @Test("a round value drops its trailing decimal")
    func roundValuesDropDecimal() {
        #expect(Format.compact(2_000_000) == "2M")
        #expect(Format.compact(5_000) == "5K")
    }

    @Test("view count is singular at one")
    func singularView() {
        #expect(Format.viewCount(1) == "1 view")
        #expect(Format.viewCount(2) == "2 views")
        #expect(Format.viewCount(nil) == nil)
    }

    @Test("relative ages read like the real client")
    func relativeAges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            Format.relative(from: now.addingTimeInterval(-seconds), to: now)
        }
        #expect(ago(30) == "just now")
        #expect(ago(60) == "1 minute ago")
        #expect(ago(300) == "5 minutes ago")
        #expect(ago(3_600) == "1 hour ago")
        #expect(ago(86_400) == "1 day ago")
        #expect(ago(604_800) == "1 week ago")
        #expect(ago(2_592_000 * 3) == "3 months ago")
        #expect(ago(31_536_000) == "1 year ago")
    }

    @Test("a future timestamp does not produce a negative age")
    func futureTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Format.relative(from: now.addingTimeInterval(120), to: now) == "just now")
    }

    @Test("YouTube's own age string is preferred over the computed one")
    func prefersPublishedTimeText() {
        var video = Video(id: "a", title: "t", channelTitle: "c")
        video.publishedAt = Date(timeIntervalSince1970: 0)
        video.publishedTimeText = "17 minutes ago"
        // Not "56 years ago" — the API string wins because it is what the real
        // client displays and it is already localized.
        #expect(Format.age(video) == "17 minutes ago")
    }

    @Test("age falls back to the timestamp for RSS videos with no text")
    func fallsBackForRSS() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var video = Video(id: "a", title: "t", channelTitle: "c")
        video.publishedAt = now.addingTimeInterval(-7_200)
        video.publishedTimeText = nil
        #expect(Format.age(video, now: now) == "2 hours ago")
    }

    @Test("the metadata line joins what exists and omits what doesn't")
    func metaLineJoins() {
        var video = Video(id: "a", title: "t", channelTitle: "c")
        video.viewCount = 336_000
        video.publishedTimeText = "3 months ago"
        #expect(Format.metaLine(video) == "336K views • 3 months ago")

        var noViews = Video(id: "b", title: "t", channelTitle: "c")
        noViews.publishedTimeText = "1 hour ago"
        #expect(Format.metaLine(noViews) == "1 hour ago")
    }

    @Test("quality badges are recognised, unknown ones dropped")
    func qualityBadges() {
        var v = Video(id: "a", title: "t", channelTitle: "c")
        v.badges = ["BADGE_STYLE_TYPE_4K"]
        #expect(Format.qualityBadge(v) == "4K")
        v.badges = ["BADGE_STYLE_TYPE_SOMETHING_ELSE"]
        #expect(Format.qualityBadge(v) == nil)
    }
}
