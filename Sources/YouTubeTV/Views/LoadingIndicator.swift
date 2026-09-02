import SwiftUI

/// The one spinner, drawn to the theme and scaled with the viewport.
///
/// The stock `ProgressView` next to custom-drawn controls read as a
/// placeholder — system blue-grey, a fixed 32pt whatever the display. This
/// is the same control tinted to the tertiary text colour and sized in rem,
/// so it sits with the `SurfaceMessage` column rather than beside it.
struct LoadingIndicator: View {

    /// Size relative to the stock large control (which is ~32pt).
    var scale: CGFloat = 1

    @Environment(\.viewportSize) private var viewport

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(Theme.textTertiary)
            .scaleEffect(Theme.Metrics.rem(1, viewport) / 16 * scale)
            .frame(width: Theme.Metrics.rem(2.5, viewport) * scale,
                   height: Theme.Metrics.rem(2.5, viewport) * scale)
    }
}
