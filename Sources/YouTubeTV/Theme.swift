import SwiftUI

/// Design tokens for the leanback surface.
///
/// Dark only, deliberately. The YouTube TV/console client has no light mode,
/// and a 10-foot UI on a living-room display should not have one — so there is
/// no light palette here to keep in sync, and the app pins
/// `.preferredColorScheme(.dark)` rather than following the system.
enum Theme {

    // MARK: Colour

    /// The page behind everything. Near-black rather than pure black: pure
    /// black crushes the Liquid Glass highlights into invisibility on OLED.
    static let canvas = Color(red: 0.059, green: 0.059, blue: 0.059)      // #0F0F0F
    /// Cards, chips and other raised surfaces.
    static let surface = Color(red: 0.129, green: 0.129, blue: 0.129)     // #212121
    static let brand = Color(red: 1.0, green: 0.0, blue: 0.0)             // #FF0000
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.667)                        // #AAAAAA

    // MARK: Metrics

    enum Metrics {
        static let cardCorner: CGFloat = 12
        static let cardAspect: CGFloat = 16.0 / 9.0
        /// Card width at a nominal 1080p window; rows scale from this.
        static let cardWidth: CGFloat = 300
        static let cardSpacing: CGFloat = 16
        static let shelfSpacing: CGFloat = 36
        static let railCollapsed: CGFloat = 88
        static let railExpanded: CGFloat = 280
        static let contentInset: CGFloat = 56

        /// Where the focused row parks vertically, as a fraction of the content
        /// height, and where the focused card parks horizontally.
        ///
        /// Fixed anchors are the whole point: rows and cards move to meet the
        /// focus rather than the focus drifting to the edge before anything
        /// scrolls. That is the difference between a TV app and a desktop app
        /// being driven with arrow keys.
        static let rowParkFraction: CGFloat = 0.34
        static let cardParkInset: CGFloat = 0
    }

    // MARK: Motion

    /// One spring for every focus transition in the app. Using a single curve
    /// everywhere is what makes the surface read as one moving object instead of
    /// several independently animated ones.
    static let focusSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Slightly slower for panels sliding in and out.
    static let panelSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Scale applied to a focused card.
    static let focusedScale: CGFloat = 1.07
}
