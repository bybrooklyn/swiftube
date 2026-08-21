import SwiftUI

/// Design tokens for the leanback surface.
///
/// Dark only, deliberately: the YouTube TV/console client has no light mode and a
/// 10-foot UI should not have one, so there is no light palette to keep in sync
/// and the app pins `.preferredColorScheme(.dark)` rather than following the system.
///
/// **Everything is expressed in `rem`, where 1rem = viewport width / 80.**
///
/// That is not an invention: the real leanback client sets
/// `html { font-size: viewportWidth / 80 }` and expresses every dimension in
/// rem. Verified across six viewports from 1280×720 to 3840×2160 — the ratio is
/// exactly 80 every time. Height is deliberately *not* part of the scale; a
/// shorter window simply shows less vertical content, which is what the real
/// client does.
enum Theme {

    // MARK: - Colour
    //
    // Sampled directly from the reference rather than eyeballed.

    /// The page behind everything. Sampled from the real client: #0F0F0F, not
    /// pure black — and the expanded guide is the *same* colour, so there is no
    /// separate panel shade.
    static let canvas = Color(hex: 0x0F0F0F)
    /// Unloaded thumbnail placeholder.
    static let surface = Color(hex: 0x212121)
    /// Search pill, transport buttons and pills, resolution badges.
    static let control = Color(hex: 0x373737)
    /// Only two things are red in the whole client: the wordmark and a card's
    /// watch-progress bar. And it is #FF0033, not #FF0000.
    static let brand = Color(hex: 0xFF0033)
    /// Focused text, focus rings, filled focus circles, scrubber progress.
    static let textPrimary = Color(hex: 0xF1F1F1)
    /// Channel names, view counts, and *unfocused card titles*.
    static let textSecondary = Color(hex: 0xAAAAAA)
    /// Inactive shelf headers, search placeholder, unselected guide icons.
    static let textTertiary = Color(hex: 0xB7B7B7)
    static let divider = Color(hex: 0x3F3F3F)
    /// Unfilled track: card watch-progress and the player scrubber.
    static let track = Color(hex: 0x606060)
    static let durationBadge = Color(hex: 0x060606)
    static let focusRing = Color(hex: 0xF1F1F1)

    // MARK: - Metrics

    enum Metrics {

        /// The one scale factor. 1rem = viewport width / 80.
        static func unit(_ s: CGSize) -> CGFloat { s.width / 80 }
        static func rem(_ n: CGFloat, _ s: CGSize) -> CGFloat { unit(s) * n }

        // MARK: Shelves and cards

        /// The first shelf uses larger "hero" tiles than the rest — 30rem vs
        /// 22rem. Uniform card sizing is one of the things that makes a
        /// reimplementation read as not-quite-right.
        static func cardWidth(_ s: CGSize, hero: Bool) -> CGFloat {
            rem(hero ? 30 : 22, s)
        }
        static func cardGutter(_ s: CGSize) -> CGFloat { rem(1.5, s) }
        /// Left inset for all content. Identical to the collapsed rail width.
        /// Content starts clear of the rail *plus* the focus ring.
        ///
        /// At exactly the rail width the first card's ring — which is drawn
        /// outside the thumbnail by `focusRingInset` — landed underneath the
        /// opaque rail, which paints over it, so the focused card looked clipped
        /// into the sidebar.
        static func contentInset(_ s: CGSize) -> CGFloat {
            railCollapsed(s) + focusRingInset(s) + rem(0.5, s)
        }
        static func thumbCorner(_ s: CGSize) -> CGFloat { rem(0.75, s) }

        /// The focus ring sits *outside* the thumbnail by this much, with a
        /// correspondingly larger corner radius so it stays concentric.
        static func focusRingWidth(_ s: CGSize) -> CGFloat { rem(0.375, s) }
        static func focusRingInset(_ s: CGSize) -> CGFloat { rem(0.35, s) }

        static func shelfHeaderSize(_ s: CGSize) -> CGFloat { rem(1.25, s) }
        static func shelfGap(_ s: CGSize) -> CGFloat { rem(1.5, s) }
        static func cardTitleSize(_ s: CGSize) -> CGFloat { rem(1.5, s) }
        static func cardMetaSize(_ s: CGSize) -> CGFloat { rem(1.0, s) }
        static func thumbToMeta(_ s: CGSize) -> CGFloat { rem(1.0, s) }
        /// Fixed regardless of content, so a row's height never changes.
        static func metaBlockHeight(_ s: CGSize) -> CGFloat { rem(7.125, s) }
        static func watchProgressHeight(_ s: CGSize) -> CGFloat { rem(0.25, s) }
        static func badgeInset(_ s: CGSize) -> CGFloat { rem(0.5, s) }

        // MARK: Top bar

        static func searchPillWidth(_ s: CGSize) -> CGFloat { rem(30, s) }
        static func searchPillHeight(_ s: CGSize) -> CGFloat { rem(3, s) }
        static func topBarTop(_ s: CGSize) -> CGFloat { rem(2.75, s) }

        // MARK: Guide

        static func railCollapsed(_ s: CGSize) -> CGFloat { rem(6.5, s) }
        static func railExpanded(_ s: CGSize) -> CGFloat { rem(22.25, s) }
        /// How far content slides right when the guide opens. The guide pushes
        /// content; it does not overlay it.
        static func guidePush(_ s: CGSize) -> CGFloat { rem(15.75, s) }
        static func railItemHeight(_ s: CGSize) -> CGFloat { rem(3.25, s) }
        static func railPillWidth(_ s: CGSize) -> CGFloat { rem(18.5, s) }
        static func railPillCorner(_ s: CGSize) -> CGFloat { rem(0.6, s) }
        static func railPillHeight(_ s: CGSize) -> CGFloat { rem(3.25, s) }
        /// Left edge of the selection shape, and of the dividers.
        static func railPillLeading(_ s: CGSize) -> CGFloat { rem(1.375, s) }
        /// Centre of the icon column — identical collapsed and expanded, which
        /// is why the icons do not move when the guide opens.
        static func railIconCentre(_ s: CGSize) -> CGFloat { rem(3.25, s) }
        /// Where labels begin.
        static func railLabelLeading(_ s: CGSize) -> CGFloat { rem(5.08, s) }
        static func railIconSize(_ s: CGSize) -> CGFloat { rem(1.45, s) }
        static func railLabelSize(_ s: CGSize) -> CGFloat { rem(1.4, s) }
        static func avatarSize(_ s: CGSize) -> CGFloat { rem(2.33, s) }

        // MARK: Player

        static func playerInset(_ s: CGSize) -> CGFloat { rem(4, s) }
        static func playerTitleSize(_ s: CGSize) -> CGFloat { rem(1.75, s) }
        static func playerMetaSize(_ s: CGSize) -> CGFloat { rem(1.0, s) }
        static func scrubberHeight(_ s: CGSize) -> CGFloat { rem(0.375, s) }
        static func timeLabelSize(_ s: CGSize) -> CGFloat { rem(0.875, s) }
        static func transportButton(_ s: CGSize) -> CGFloat { rem(3, s) }
        static func transportButtonLarge(_ s: CGSize) -> CGFloat { rem(4, s) }
        static func transportGap(_ s: CGSize) -> CGFloat { rem(0.5, s) }

        static let cardAspect: CGFloat = 16.0 / 9.0

        /// Where the focused shelf's header parks once scrolling begins — near
        /// the top, not centred. The leanback client optimises for seeing what
        /// comes *next*, which means putting the focused row high.
        static func rowPark(_ s: CGSize) -> CGFloat { rem(3, s) }
    }

    // MARK: - Motion

    /// The leanback scroll curve, read off the real client's computed styles:
    /// `transform 0.3s cubic-bezier(0.26, 0.86, 0.44, 0.985)`.
    ///
    /// Deliberately not a spring. A spring accelerates *into* the move; this
    /// curve leaves immediately and decelerates for the whole trip, which is the
    /// single most recognisable thing about how a TV UI moves.
    static let travel = Animation.timingCurve(0.26, 0.86, 0.44, 0.985, duration: 0.3)

    /// State changes that are not travel — a ring appearing, a colour swapping.
    static let stateChange = Animation.easeOut(duration: 0.15)

    /// The guide's selection highlight, which the real client moves on a short
    /// linear curve rather than the travel curve.
    static let highlight = Animation.linear(duration: 0.15)
}

// MARK: - Viewport size in the environment

private struct ViewportSizeKey: EnvironmentKey {
    // A sane 720p default so a view rendered before layout settles is never
    // divided by zero.
    static let defaultValue = CGSize(width: 1280, height: 720)
}

extension EnvironmentValues {
    /// Size of the whole app window, published once at the root.
    ///
    /// Written manually rather than with SwiftUI's `@Entry` macro: that macro's
    /// plugin ships with Xcode, and this project builds with the Command Line
    /// Tools only (see AGENTS.md).
    var viewportSize: CGSize {
        get { self[ViewportSizeKey.self] }
        set { self[ViewportSizeKey.self] = newValue }
    }
}

extension Color {
    /// `Color(hex: 0x0F0F0F)` — keeps the sampled values readable as the hex
    /// codes they were measured as.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
