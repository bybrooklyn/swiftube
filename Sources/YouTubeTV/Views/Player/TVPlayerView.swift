import AVFoundation
import SwiftUI
import YouTubeCore
import YouTubeMedia

/// The full-screen player: video, scrim, title, scrubber and transport row.
struct TVPlayerView: View {

    @Bindable var model: PlayerModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: model.playback.player)
                .ignoresSafeArea()

            if model.playback.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if model.areControlsVisible {
                controls
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Theme.panelSpring, value: model.areControlsVisible)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                scrubber
                transportRow
            }
            .padding(.horizontal, Theme.Metrics.contentInset)
            .padding(.bottom, 48)
            .padding(.top, 120)
            .background {
                // A scrim, not a glass panel: glass across the full width would
                // be compositing a blur over live 4K video for the entire time
                // the controls are up, which is the one place in this UI where
                // it measurably costs frames. The glass is kept for the button
                // cluster, which is small.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(model.channel)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(Theme.brand)
                        .frame(width: geometry.size.width * model.progress)
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .offset(x: geometry.size.width * model.progress - 8)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
            }
            .frame(height: 6)

            HStack {
                Text(formatDuration(model.playback.currentTime))
                Spacer()
                Text(formatDuration(model.playback.duration))
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var transportRow: some View {
        // One container so the focus highlight glides between buttons as a
        // single piece of glass rather than popping from one to the next.
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                ForEach(PlayerControl.allCases, id: \.self) { control in
                    transportButton(control)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func transportButton(_ control: PlayerControl) -> some View {
        let isFocused = model.focusedControl == control
        Image(systemName: control.symbol(isPlaying: model.playback.isPlaying))
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isFocused ? .black : .white)
            .frame(width: 54, height: 54)
            .glassEffect(
                isFocused ? .regular.tint(.white.opacity(0.92)).interactive() : .regular,
                in: .circle
            )
            .scaleEffect(isFocused ? 1.12 : 1)
            .animation(Theme.focusSpring, value: isFocused)
    }
}

extension PlayerControl {
    func symbol(isPlaying: Bool) -> String {
        switch self {
        case .previous:  "backward.end.fill"
        case .rewind:    "gobackward.10"
        case .playPause: isPlaying ? "pause.fill" : "play.fill"
        case .forward:   "goforward.10"
        case .next:      "forward.end.fill"
        case .captions:  "captions.bubble.fill"
        case .quality:   "slider.horizontal.3"
        case .more:      "ellipsis"
        }
    }
}
