import SwiftUI
import YouTubeCore
import YouTubeMedia

/// The settings surface.
///
/// A flat list of rows, each showing a label and its current value, changed by
/// pressing Select — no nested dialogs. That is how the TV client does it, and
/// it is the only shape that works when the only input is a d-pad.
struct SettingsView: View {

    @Bindable var model: SettingsModel
    var onBack: () -> Void = {}
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private func content(in size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: Theme.Metrics.contentInset(viewport))

            VStack(alignment: .leading, spacing: Theme.Metrics.rem(1.0, viewport)) {
                HStack(spacing: Theme.Metrics.rem(1.0, viewport)) {
                    BackChip(action: onBack)
                    Text("Settings")
                        .font(.system(size: Theme.Metrics.rem(2.0, viewport), weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.bottom, Theme.Metrics.rem(0.5, viewport))

                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    switch row.kind {
                    case .header:
                        Text(row.title)
                            .font(.system(size: Theme.Metrics.rem(1.1, viewport), weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, Theme.Metrics.rem(0.75, viewport))
                    case .setting:
                        settingRow(row, isFocused: model.focusedRow == index)
                    }
                }
            }
            .frame(maxWidth: Theme.Metrics.rem(40, viewport), alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Metrics.rem(3, viewport))
        // The list is longer than the window once SponsorBlock is expanded, so
        // it travels to keep the focused row on screen — the same rule the
        // shelves and the guide use.
        .offset(y: scrollOffset(in: size))
        .animation(Theme.travel, value: model.focusedRow)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// Zero until the focused row would fall past the bottom, then exactly
    /// enough to bring it back with a row of lookahead.
    private func scrollOffset(in size: CGSize) -> CGFloat {
        let rowHeight = Theme.Metrics.rem(2.6, viewport)
        let spacing = Theme.Metrics.rem(1.0, viewport)
        let headerHeight = Theme.Metrics.rem(1.1, viewport) + Theme.Metrics.rem(0.75, viewport)
        var bottom = Theme.Metrics.rem(3, viewport) + Theme.Metrics.rem(2.0, viewport) * 2

        for (index, row) in model.rows.enumerated() {
            bottom += (row.kind == .header ? headerHeight : rowHeight)
            if index == model.focusedRow { break }
            bottom += spacing
        }

        return -max(bottom + rowHeight * 2 - size.height, 0)
    }

    private func settingRow(_ row: SettingsModel.Row, isFocused: Bool) -> some View {
        HStack(spacing: Theme.Metrics.rem(1, viewport)) {
            Text(row.title)
                .font(.system(size: Theme.Metrics.rem(1.15, viewport)))
            Spacer(minLength: Theme.Metrics.rem(2, viewport))
            Text(row.value)
                .font(.system(size: Theme.Metrics.rem(1.15, viewport), weight: .semibold))
                .foregroundStyle(isFocused ? .black : Theme.textSecondary)
        }
        .foregroundStyle(isFocused ? .black : Theme.textPrimary)
        .padding(.horizontal, Theme.Metrics.rem(1.0, viewport))
        .frame(height: Theme.Metrics.rem(2.6, viewport))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.railPillCorner(viewport), style: .continuous)
                .fill(isFocused ? Theme.focusRing : Color.clear)
        }
        .animation(Theme.stateChange, value: isFocused)
    }
}
