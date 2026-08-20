import Foundation
import YouTubeCore

/// Display formatting for card and player metadata.
///
/// `YouTubeCore` has `formatDuration` and `Video.formattedViewCount`, but the
/// latter tops out at millions — 1.2B renders as "1200.0M views" — and there is
/// no relative-age formatter anywhere in the codebase. Both live here rather
/// than in Core because they are presentation, and because Core is deliberately
/// kept as close to upstream as possible.
enum Format {

    /// "336K views" · "2.3M views" · "1.2B views" · "812 views" · "1 view".
    ///
    /// Thresholds and rounding match what YouTube shows: one decimal place, and
    /// the decimal dropped when it would be a trailing zero ("2M", not "2.0M").
    static func viewCount(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        if count == 1 { return "1 view" }
        return "\(compact(count)) views"
    }

    /// Compact number: 812 · 1.2K · 336K · 2.3M · 1.2B.
    static func compact(_ value: Int) -> String {
        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        let n = Double(value)
        for (index, unit) in units.enumerated() where n >= unit.threshold {
            var scaled = n / unit.threshold
            var suffix = unit.suffix

            // Rounding can push a value past its own unit: 999,500 scales to
            // 999.5 K and rounds to "1000K" rather than "1M". When that happens,
            // promote to the next unit up.
            if scaled.rounded() >= 1000, index > 0 {
                scaled = n / units[index - 1].threshold
                suffix = units[index - 1].suffix
            }

            // One decimal below 10 (2.3M), none above (23M) — matching YouTube.
            if scaled < 10 {
                let rounded = (scaled * 10).rounded() / 10
                let text = rounded == rounded.rounded()
                    ? String(Int(rounded))
                    : String(format: "%.1f", rounded)
                return text + suffix
            }
            return String(Int(scaled.rounded())) + suffix
        }
        return String(value)
    }

    /// Age of a video, as "5 minutes ago" / "3 months ago".
    ///
    /// Prefers `Video.publishedTimeText`, which is YouTube's own string — its doc
    /// comment calls it "the honest approximation" and it is already localized
    /// and already matches what the real client shows. The computed fallback is
    /// only for videos sourced from RSS or tile renderers, where that field is
    /// nil and we would otherwise show nothing.
    static func age(_ video: Video, now: Date = Date()) -> String? {
        if let text = video.publishedTimeText, !text.isEmpty { return text }
        guard let published = video.publishedAt else { return nil }
        return relative(from: published, to: now)
    }

    static func relative(from date: Date, to now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // A clock skew or a scheduled premiere can put this slightly in the
        // future; "0 seconds ago" reads better than "in 3 seconds".
        guard seconds > 0 else { return "just now" }

        let units: [(seconds: Double, name: String)] = [
            (31_536_000, "year"),
            (2_592_000, "month"),
            (604_800, "week"),
            (86_400, "day"),
            (3_600, "hour"),
            (60, "minute"),
        ]
        for unit in units where seconds >= unit.seconds {
            let count = Int(seconds / unit.seconds)
            return "\(count) \(unit.name)\(count == 1 ? "" : "s") ago"
        }
        return "just now"
    }

    /// The `4K` / `LIVE` style chips YouTube puts before the view count.
    ///
    /// `Video.badges` carries raw InnerTube strings, so only the ones the real
    /// client actually surfaces on a card are shown; anything unrecognised is
    /// dropped rather than rendered as a mystery chip.
    static func qualityBadge(_ video: Video) -> String? {
        let wanted: [(match: String, label: String)] = [
            ("8K", "8K"), ("4K", "4K"), ("2160", "4K"), ("HDR", "HDR"),
        ]
        for badge in video.badges {
            let upper = badge.uppercased()
            for candidate in wanted where upper.contains(candidate.match) {
                return candidate.label
            }
        }
        return nil
    }

    /// The single metadata line under a card: "336K views • 3 months ago".
    static func metaLine(_ video: Video) -> String {
        [viewCount(video.viewCount), age(video)]
            .compactMap { $0 }
            .joined(separator: " • ")
    }
}
