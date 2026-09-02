import SwiftUI
import YouTubeCore

/// The search surface: on-screen keyboard on the left, live results on the right.
struct SearchView: View {

    @Bindable var model: SearchModel
    var onBack: () -> Void = {}
    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        VStack(alignment: .leading, spacing: rem(1)) {
            BackChip(action: onBack)
            HStack(alignment: .top, spacing: rem(3)) {
                keyboard
                results
            }
        }
        .padding(.leading, Theme.Metrics.contentInset(viewport))
        .padding(.trailing, rem(2))
        .padding(.top, rem(3))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }

    // MARK: - Keyboard

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: rem(1)) {
            queryField
            OnScreenKeyboard(keys: SearchModel.keys, focusedIndex: focusedKey)
        }
        .frame(width: OnScreenKeyboard.width(viewport))
    }

    private var focusedKey: Int? {
        if case let .key(index) = model.focus { return index }
        return nil
    }

    private var queryField: some View {
        Text(model.query.isEmpty ? "Search" : model.query)
            .font(.system(size: rem(1.4), weight: .medium))
            .foregroundStyle(model.query.isEmpty ? Theme.textTertiary : Theme.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, rem(1))
            .frame(height: Theme.Metrics.searchPillHeight(viewport))
            .background(Theme.control, in: .capsule)
    }

    // MARK: - Results

    private var results: some View {
        VStack(alignment: .leading, spacing: rem(0.75)) {
            Text(model.results.isEmpty
                 ? (model.query.count < 2 ? "Type to search" : (model.isSearching ? "Searching…" : "No results"))
                 : "Results")
                .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            // A single horizontal row, parked like a shelf, so search results
            // behave the same way as every other row in the app.
            let step = Theme.Metrics.cardWidth(viewport, hero: false) + Theme.Metrics.cardGutter(viewport)
            let parked = parkedIndex

            HStack(alignment: .top, spacing: Theme.Metrics.cardGutter(viewport)) {
                ForEach(Array(model.results.prefix(parked + 8).enumerated()), id: \.element.id) { index, video in
                    VideoCard(video: video,
                              isFocused: model.focus == .result(index),
                              isHero: false)
                }
            }
            .offset(x: -CGFloat(parked) * step)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask(Rectangle().padding(.vertical, -viewport.height))
            .animation(Theme.travel, value: parked)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var parkedIndex: Int {
        if case let .result(index) = model.focus { return index }
        return 0
    }
}
