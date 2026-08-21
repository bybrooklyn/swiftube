import SwiftUI

/// Shown when a surface has nothing to display.
///
/// Without this a section that returns no videos rendered as an entirely blank
/// page — no title, no explanation, nothing to act on. Several surfaces legally
/// return nothing (Subscriptions and Library need an account; a category can
/// come back empty), and "blank" reads as a broken app rather than as a state.
struct SurfaceMessage: View {

    let title: String
    let detail: String
    var symbol: String = "tray"

    @Environment(\.viewportSize) private var viewport

    var body: some View {
        VStack(spacing: Theme.Metrics.rem(0.9, viewport)) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Metrics.rem(3, viewport), weight: .thin))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.system(size: Theme.Metrics.rem(1.6, viewport), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: Theme.Metrics.rem(1.05, viewport)))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, Theme.Metrics.contentInset(viewport))
    }
}
