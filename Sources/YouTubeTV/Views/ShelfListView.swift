import SwiftUI
import YouTubeCore

/// The vertical stack of horizontal shelves.
///
/// Scrolling is driven entirely by focus: rows and cards travel so the focused
/// element parks at a fixed position. Content moves to meet the focus; the focus
/// never drifts to the screen edge before anything scrolls.
///
/// Both axes use explicit offsets rather than ScrollViews.
/// `ScrollViewReader.scrollTo(_:anchor:)` aligns *fractions* of the target to the
/// same fraction of the viewport, which cannot express "park at a fixed inset" —
/// `.leading` pins a card flush under the guide, and no other anchor gives a
/// constant inset because the required fraction depends on viewport width.
///
/// Because offsets mean nothing is virtualised, each row renders a **window**
/// around its parked card rather than the whole array. The real client does the
/// same thing: its virtual list keeps a fixed-width inner div, not the full row.
struct ShelfListView: View {

    @Bindable var model: AppModel
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        let shelves = model.shelves
        // Falls back to the shelf last focused, not zero. `shelfIndex` is nil
        // for the guide and the top bar, so keying straight off it scrolled the
        // whole feed back to the first shelf the moment the guide opened — and
        // animated it back down on the way out.
        let parkedRow = model.parkedShelf

        VStack(alignment: .leading, spacing: Theme.Metrics.shelfGap(viewport)) {
            ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                // Only rows near the parked one build their cards.
                //
                // Nothing here is virtualised — the whole feed is one VStack
                // translated vertically — so without this every shelf kept ten
                // live cards, each with a decoded thumbnail and five text runs.
                // At ten shelves that is a hundred cards being re-laid-out on
                // every focus change, which is what made moving along a row
                // drop frames. A parked row is the only one fully on screen and
                // its neighbours are the only ones that can scroll into view.
                ShelfRow(shelf: shelf,
                         shelfIndex: index,
                         isHero: index == 0,
                         buildsCards: abs(index - parkedRow) <= 2,
                         model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Rows above the focused one translate off the top; the focused header
        // parks near the top of the content area.
        .offset(y: -model.rowOffset(upTo: parkedRow, viewport: viewport))
        .animation(Theme.travel, value: parkedRow)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

private struct ShelfRow: View {

    let shelf: AppModel.Shelf
    let shelfIndex: Int
    let isHero: Bool
    /// False for rows too far from the parked one to be seen — they reserve
    /// their height and draw nothing, so the feed costs what is on screen.
    let buildsCards: Bool
    @Bindable var model: AppModel
    @Environment(\.viewportSize) private var viewport

    private var isActive: Bool { model.focus.shelfIndex == shelfIndex }
    private var inset: CGFloat { Theme.Metrics.contentInset(viewport) }

    /// How far ahead of the parked card to build.
    ///
    /// The window only ever *grows*: it starts at the front of the row and
    /// extends as focus advances. An earlier version slid a window along
    /// (`parked-2 ..< parked+8`), which meant moving left or right changed which
    /// cards existed — SwiftUI then animated those insertions and removals at
    /// the same time as the row's offset, so cards visibly popped in and out
    /// mid-travel. Growing only keeps every card that has ever been on screen
    /// alive, so a move is purely a translate.
    private static let windowAhead = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.75, viewport)) {
            Text(shelf.title)
                .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .medium))
                // The header gets its own block rather than hugging the text, so
                // it clears the search pill above it the way the reference does.
                .frame(height: Theme.Metrics.rem(2.625, viewport), alignment: .bottom)
                // The active shelf's header brightens — with several rows on
                // screen it says which one you are in before you look at cards.
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
                .animation(Theme.stateChange, value: isActive)
                .padding(.leading, inset)

            if !buildsCards {
                // Same height as `cards`, so the vertical offsets that park a
                // row stay correct whether or not the row is built.
                Color.clear.frame(height: rowHeight)
            } else if shelf.videos.isEmpty {
                placeholder
            } else {
                cards
            }
        }
    }

    /// Height of the card block — thumbnail, the gap, and the metadata.
    private var rowHeight: CGFloat {
        let width = Theme.Metrics.cardWidth(viewport, hero: isHero)
        return width / Theme.Metrics.cardAspect
            + Theme.Metrics.thumbToMeta(viewport)
            + Theme.Metrics.metaBlockHeight(viewport)
    }

    private var cards: some View {
        let width = Theme.Metrics.cardWidth(viewport, hero: isHero)
        let step = width + Theme.Metrics.cardGutter(viewport)
        let parked = model.parkedIndex(forShelf: shelfIndex)

        let upper = min(shelf.videos.count, parked + Self.windowAhead)
        let window = Array(shelf.videos.prefix(upper).enumerated())

        // The wide strip of cards is an OVERLAY on a zero-width spacer, not a
        // laid-out child.
        //
        // A row is deliberately far wider than the window — it is a long strip
        // translated left — and as a normal child it made every ancestor adopt
        // that width. A ZStack takes the size of its largest child, so the whole
        // root inflated, and anything using `maxWidth: .infinity` inherited the
        // oversized proposal: the player's scrubber ran off the right edge and
        // its right-hand button cluster was laid out off-screen entirely.
        // `.clipped()` does not help — clipping changes what is drawn, never the
        // layout size. An overlay does not contribute to its parent's size at
        // all, which is exactly the property needed here.
        return Color.clear
            .frame(height: rowHeight)
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: Theme.Metrics.cardGutter(viewport)) {
                    ForEach(window, id: \.element.id) { index, video in
                        VideoCard(video: video,
                                  isFocused: model.isFocused(shelf: shelfIndex, index: index),
                                  isHero: isHero)
                            .onHover { inside in
                                if inside { model.hover(shelf: shelfIndex, index: index) }
                            }
                            .onTapGesture { model.click(shelf: shelfIndex, index: index) }
                    }
                }
                .offset(x: -CGFloat(parked) * step)
                .fixedSize()
            }
        // Pad first so the cards sit at the content inset, then clip in that
        // same padded space so nothing draws to the left of it.
        //
        // The clip is pulled back by `focusRingInset`, because the focused
        // card's ring is drawn *outside* the thumbnail by exactly that much.
        // Clipping at the card edge sliced the ring's left side off, which read
        // as the selection running into the sidebar. Pulled back it still stops
        // 0.5rem clear of the collapsed rail, so nothing is drawn under it.
        //
        // A rectangular `clipShape` rather than `.mask(Rectangle())`: a mask is
        // an alpha composite, so every row rendered its whole strip of cards
        // into an offscreen buffer and blended it back on each frame. Ten rows
        // of that is pure cost for a clip that is axis-aligned anyway.
        //
        // The shape overflows vertically so only the horizontal edges clip and
        // a focused card's ring is never squared off top or bottom.
        .padding(.leading, inset)
        .clipShape(ShelfClip(leading: inset - Theme.Metrics.focusRingInset(viewport),
                             verticalOverflow: viewport.height))
        .animation(Theme.travel, value: parked)
    }

    private var placeholder: some View {
        let width = Theme.Metrics.cardWidth(viewport, hero: isHero)
        return HStack(spacing: Theme.Metrics.cardGutter(viewport)) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Metrics.thumbCorner(viewport))
                    .fill(Theme.surface)
                    .frame(width: width, height: width / Theme.Metrics.cardAspect)
            }
        }
        .padding(.leading, inset)
        .redacted(reason: .placeholder)
    }
}

/// Clips a shelf to the content inset horizontally while letting it overflow
/// vertically, so a focused card's ring is not squared off top or bottom.
private struct ShelfClip: Shape {
    let leading: CGFloat
    let verticalOverflow: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX + leading,
                    y: rect.minY - verticalOverflow,
                    width: max(rect.width - leading, 0),
                    height: rect.height + verticalOverflow * 2))
    }
}
