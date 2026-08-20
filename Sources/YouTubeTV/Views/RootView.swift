import SwiftUI

struct RootView: View {

    @State private var model = AppModel()

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            HStack(spacing: 0) {
                GuideRail(focus: model.focus, isExpanded: model.isRailExpanded)
                ShelfListView(model: model)
                    .frame(maxWidth: .infinity)
            }

            if model.shelves.isEmpty && model.player == nil {
                loadingState
            }

            if let player = model.player {
                TVPlayerView(model: player)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .tvWindow()
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.layout) { _, _ in model.layoutDidChange() }
    }

    private var loadingState: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Loading your feed…")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
