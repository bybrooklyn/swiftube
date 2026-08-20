import SwiftUI
import YouTubeCore

/// The vertical stack of horizontal shelves.
///
/// Scrolling here is driven entirely by focus, never by the pointer: when focus
/// moves, the row scrolls so the focused element parks at a *fixed* anchor. That
/// is the signature of a leanback UI — content travels to meet the focus, rather
/// than the focus drifting to the screen edge before anything moves.
struct ShelfListView: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollViewReader { vertical in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                    ForEach(Array(model.shelves.enumerated()), id: \.element.id) { shelfIndex, section in
                        // A section that finished loading with nothing in it
                        // (Subscriptions while signed out, say) is skipped
                        // entirely rather than shown as a bare title over empty
                        // space. Its slot in `shelfIndex` is preserved so focus
                        // indices stay stable — BrowseNavigator already steps
                        // over zero-length shelves.
                        if !section.videos.isEmpty || section.isLoading {
                            ShelfRow(
                                title: section.section.title,
                                videos: section.videos,
                                isLoading: section.isLoading,
                                shelfIndex: shelfIndex,
                                model: model
                            )
                            .id(shelfIndex)
                        }
                    }
                }
                .padding(.vertical, 48)
            }
            .scrollDisabled(true)
            .onChange(of: model.focus) { _, newValue in
                guard let shelf = newValue.shelfIndex else { return }
                withAnimation(Theme.focusSpring) {
                    // The row parks a third of the way down rather than centred:
                    // a TV viewer wants to see what is coming next below, and a
                    // centred row wastes the bottom half of the screen.
                    vertical.scrollTo(shelf, anchor: UnitPoint(x: 0, y: Theme.Metrics.rowParkFraction))
                }
            }
        }
    }
}

private struct ShelfRow: View {

    let title: String
    let videos: [Video]
    let isLoading: Bool
    let shelfIndex: Int
    @Bindable var model: AppModel

    private var isActiveShelf: Bool { model.focus.shelfIndex == shelfIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 21, weight: .semibold))
                // The active row's title brightens. It is a small thing, but with
                // several rows onscreen it is what tells you which one you are in
                // before you have looked at the cards.
                .foregroundStyle(isActiveShelf ? Theme.textPrimary : Theme.textSecondary)
                .animation(Theme.focusSpring, value: isActiveShelf)
                .padding(.leading, Theme.Metrics.contentInset)

            if videos.isEmpty && isLoading {
                placeholderRow
            } else {
                cardRow
            }
        }
    }

    private var cardRow: some View {
        // Laid out with an explicit offset rather than a ScrollView.
        //
        // Scrolling here is entirely focus-driven — the user never drags a row —
        // and `ScrollViewReader.scrollTo(_:anchor:)` cannot express "park the
        // focused card at a fixed inset from the left". Its anchors align
        // *fractions* of the target to the same fraction of the viewport, so
        // `.leading` pins the card flush to the edge, tucked under the guide
        // rail, and no other anchor value gives a constant inset because the
        // required fraction depends on the viewport width. A direct offset is
        // exact, and it makes the parking rule a single readable line.
        let step = Theme.Metrics.cardWidth + Theme.Metrics.cardSpacing
        let parked = model.parkedIndex(forShelf: shelfIndex)

        return HStack(spacing: Theme.Metrics.cardSpacing) {
            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                VideoCard(video: video, isFocused: model.isFocused(shelf: shelfIndex, index: index))
            }
        }
        // Room for the focused card to scale up and cast its shadow without the
        // mask below shaving the top and bottom off it.
        .padding(.vertical, 26)
        .offset(x: -CGFloat(parked) * step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.Metrics.contentInset)
        // Horizontal clip only: cards scrolled off to the left must not draw
        // over the guide rail, but a vertical clip would cut the focused card's
        // shadow off square.
        .mask(Rectangle().padding(.vertical, -400))
        .animation(Theme.focusSpring, value: parked)
    }

    private var placeholderRow: some View {
        HStack(spacing: Theme.Metrics.cardSpacing) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner)
                    .fill(Theme.surface)
                    .frame(width: Theme.Metrics.cardWidth,
                           height: Theme.Metrics.cardWidth / Theme.Metrics.cardAspect)
            }
        }
        .padding(.horizontal, Theme.Metrics.contentInset)
        .padding(.vertical, 26)
        .redacted(reason: .placeholder)
    }
}
