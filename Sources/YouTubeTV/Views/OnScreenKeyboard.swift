import SwiftUI

/// The d-pad keyboard grid: six columns of characters, then the wide row.
///
/// Pulled out of `SearchView` so the comment composer draws the same keys
/// the same way. Movement stays in `SearchModel.nextKey(from:direction:keys:)`;
/// this only renders focus.
struct OnScreenKeyboard: View {

    let keys: [SearchModel.Key]
    let focusedIndex: Int?

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    static func keySize(_ viewport: CGSize) -> CGFloat { Theme.Metrics.rem(2.6, viewport) }

    /// The grid's natural width, so a caller can size a field above it.
    static func width(_ viewport: CGSize) -> CGFloat {
        keySize(viewport) * CGFloat(SearchModel.columns)
            + Theme.Metrics.rem(0.4, viewport) * CGFloat(SearchModel.columns - 1)
    }

    private var keySize: CGFloat { Self.keySize(viewport) }

    var body: some View {
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
        .frame(width: Self.width(viewport))
    }

    @ViewBuilder
    private func key(at index: Int) -> some View {
        let entry = keys[index]
        let isFocused = focusedIndex == index
        let wide = entry.isWide

        Text(entry.label)
            .font(.system(size: wide ? rem(0.85) : rem(1.2),
                          weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? Theme.canvas : Theme.textPrimary)
            .frame(width: wide ? nil : keySize, height: keySize)
            .frame(maxWidth: wide ? .infinity : nil)
            .background {
                RoundedRectangle(cornerRadius: Theme.Metrics.plateCorner(viewport), style: .continuous)
                    .fill(isFocused ? Theme.focusRing : Theme.control.opacity(0.5))
            }
            .animation(Theme.stateChange, value: isFocused)
    }
}
