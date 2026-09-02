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
        let rows = model.rows
        let step = Theme.Metrics.cardWidth(viewport, hero: false) + Theme.Metrics.cardGutter(viewport)

        return VStack(alignment: .leading, spacing: rem(1.25)) {
            if rows.isEmpty {
                Text(model.query.count < 2 ? "Type to search" : (model.isSearching ? "Searching…" : "No results"))
                    .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }

            // Rows parked like shelves, so search results behave the same way
            // as every other row in the app.
            ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                let parked = parkedIndex(row: rowIndex)
                VStack(alignment: .leading, spacing: rem(0.75)) {
                    Text(row.title)
                        .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .medium))
                        .foregroundStyle(focusedRow == rowIndex ? Theme.textPrimary : Theme.textTertiary)
                    HStack(alignment: .top, spacing: Theme.Metrics.cardGutter(viewport)) {
                        ForEach(Array(row.videos.prefix(parked + 8).enumerated()), id: \.element.id) { index, video in
                            VideoCard(video: video,
                                      isFocused: model.focus == .result(row: rowIndex, index: index),
                                      isHero: false)
                        }
                    }
                    .offset(x: -CGFloat(parked) * step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(Theme.travel, value: parked)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // The focused row parks at the top, the same rule as the shelves.
        .offset(y: -CGFloat(focusedRow) * rowPitch)
        .animation(Theme.travel, value: focusedRow)
        .mask(Rectangle().padding(.vertical, -viewport.height))
    }

    private var focusedRow: Int {
        if case let .result(row, _) = model.focus { return row }
        return 0
    }

    private func parkedIndex(row: Int) -> Int {
        if case let .result(focusedRow, index) = model.focus, focusedRow == row { return index }
        return 0
    }

    /// Header, card, metadata and the gap to the next row.
    private var rowPitch: CGFloat {
        Theme.Metrics.shelfHeaderSize(viewport) + rem(0.75)
            + Theme.Metrics.cardWidth(viewport, hero: false) / Theme.Metrics.cardAspect
            + Theme.Metrics.thumbToMeta(viewport)
            + Theme.Metrics.metaBlockHeight(viewport)
            + rem(1.25)
    }
}
