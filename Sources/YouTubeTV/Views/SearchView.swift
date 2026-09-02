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

            let keys = SearchModel.keys
            let characterCount = keys.firstIndex { $0.isWide } ?? keys.count
            let rows = Int(ceil(Double(characterCount) / Double(SearchModel.columns)))

            VStack(spacing: rem(0.4)) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: rem(0.4)) {
                        ForEach(0..<SearchModel.columns, id: \.self) { column in
                            let index = row * SearchModel.columns + column
                            if index < characterCount {
                                key(at: index)
                            } else {
                                Color.clear.frame(width: keySize, height: keySize)
                            }
                        }
                    }
                }
                HStack(spacing: rem(0.4)) {
                    ForEach(characterCount..<keys.count, id: \.self) { index in
                        key(at: index)
                    }
                }
            }
        }
        .frame(width: keySize * CGFloat(SearchModel.columns) + rem(0.4) * CGFloat(SearchModel.columns - 1))
    }

    private var keySize: CGFloat { rem(2.6) }

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

    @ViewBuilder
    private func key(at index: Int) -> some View {
        let entry = SearchModel.keys[index]
        let isFocused = model.focus == .key(index)
        let wide = entry.isWide

        Text(entry.label)
            .font(.system(size: wide ? rem(0.85) : rem(1.2),
                          weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? Theme.canvas : Theme.textPrimary)
            .frame(width: wide ? nil : keySize, height: keySize)
            .frame(maxWidth: wide ? .infinity : nil)
            .background {
                RoundedRectangle(cornerRadius: rem(0.5), style: .continuous)
                    .fill(isFocused ? Theme.focusRing : Theme.control.opacity(0.5))
            }
            .animation(Theme.stateChange, value: isFocused)
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
