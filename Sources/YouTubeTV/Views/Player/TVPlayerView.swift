import AVFoundation
import SwiftUI
import YouTubeCore
import YouTubeMedia

/// The full-screen player overlay, laid out to match the real TV client.
///
/// The arrangement is deliberately not the obvious one: the title sits at the
/// **top** left with its metadata (not above the transport), the channel mark is
/// top right, and the bottom band is three groups — text actions left, transport
/// centred, icon pills right. The progress bar is **white**, not the brand red
/// the web and mobile clients use.
struct TVPlayerView: View {

    @Bindable var model: PlayerModel
    @Environment(\.viewportSize) private var viewport

    private var inset: CGFloat { Theme.Metrics.playerInset(viewport) }
    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: model.playback.player).ignoresSafeArea()

            if model.playback.isLoading {
                ProgressView().controlSize(.large).tint(.white)
            }

            if model.areControlsVisible {
                overlay.transition(.opacity)
            }
        }
        .animation(Theme.travel, value: model.areControlsVisible)
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            footer
        }
        .background {
            // Scrims top and bottom rather than a full-width glass panel: glass
            // across the whole width would blur live video the entire time the
            // controls are up, which is the one place in this UI where it
            // measurably costs frames. Glass is kept for the small pills below.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.72), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: viewport.height * 0.32)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: viewport.height * 0.42)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: rem(0.5)) {
            Text(model.title)
                .font(.system(size: Theme.Metrics.playerTitleSize(viewport), weight: .black))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
            Text(model.metaLine)
                .font(.system(size: Theme.Metrics.playerMetaSize(viewport)))
                .foregroundStyle(Theme.textPrimary)
        }
        // The real client caps the title block at 36rem so it never runs into
        // the right edge of a 16:9 frame.
        .frame(maxWidth: rem(36), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, inset)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: rem(0.75)) {
            timeline
            Scrubber(model: model)
                .padding(.bottom, rem(0.5))
            transportRow
        }
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
    }

    /// Current position with the chapter name, and the total duration opposite —
    /// the chapter name is what makes long videos navigable on a TV.
    private var timeline: some View {
        HStack {
            Text(model.positionLabel)
            Spacer()
            Text(formatDuration(model.playback.duration))
        }
        .font(.system(size: Theme.Metrics.timeLabelSize(viewport), weight: .medium))
        .foregroundStyle(Theme.textTertiary)
    }

    private var transportRow: some View {
        ZStack {
            // The centre cluster is centred on the *frame*, not balanced between
            // the two side clusters — the real client keeps play/pause on the
            // screen's centre line regardless of how wide the side groups are.
            centreTransport

            HStack(spacing: 0) {
                leftActions
                Spacer(minLength: 0)
                rightActions
            }
        }
        .frame(height: Theme.Metrics.transportButtonLarge(viewport))
    }

    private var leftActions: some View {
        HStack(spacing: Theme.Metrics.transportGap(viewport)) {
            AvatarView(url: model.channelAvatarURL,
                       fallbackSymbol: "person.crop.circle",
                       size: Theme.Metrics.transportButton(viewport))
                .background(Theme.control, in: .circle)
            textButton(.description, "Description")
            iconButton(.subscribe)
        }
    }

    private var centreTransport: some View {
        HStack(spacing: Theme.Metrics.transportGap(viewport)) {
            iconButton(.previous)
            iconButton(.playPause, prominent: true)
            iconButton(.next)
        }
    }

    /// Two pills. Each supplies its own fill and its buttons are transparent
    /// until focused — that is how the real client draws them, and it keeps the
    /// glass to two small shapes rather than ten.
    private var rightActions: some View {
        HStack(spacing: Theme.Metrics.transportGap(viewport)) {
            pill([.like, .dislike, .comments, .save])
            pill([.stats, .settings])
        }
    }

    private func pill(_ controls: [PlayerControl]) -> some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(controls, id: \.self) { pillButton($0) }
            }
        }
        .background(Theme.control, in: .capsule)
    }

    // MARK: - Buttons

    private func textButton(_ control: PlayerControl, _ title: String) -> some View {
        let focused = model.focusedControl == control
        return Text(title)
            .font(.system(size: rem(1), weight: .medium))
            .foregroundStyle(focused ? .black : Theme.textPrimary)
            .frame(height: Theme.Metrics.transportButton(viewport))
            .padding(.horizontal, rem(1))
            .background(Capsule().fill(focused ? Theme.focusRing : Theme.control))
            .animation(Theme.stateChange, value: focused)
    }

    private func iconButton(_ control: PlayerControl, prominent: Bool = false) -> some View {
        let focused = model.focusedControl == control
        let size = prominent ? Theme.Metrics.transportButtonLarge(viewport)
                             : Theme.Metrics.transportButton(viewport)
        return Image(systemName: model.symbol(for: control))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(focused ? .black : Theme.textPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(focused ? Theme.focusRing : Theme.control))
            .animation(Theme.stateChange, value: focused)
    }

    private func pillButton(_ control: PlayerControl) -> some View {
        let focused = model.focusedControl == control
        let size = Theme.Metrics.transportButton(viewport)
        return Image(systemName: model.symbol(for: control))
            .font(.system(size: size * 0.40, weight: .medium))
            .foregroundStyle(focused ? .black : Theme.textPrimary)
            .frame(width: size, height: size)
            // Transparent inside the pill until focused; the pill supplies fill.
            .background { if focused { Circle().fill(Theme.focusRing) } }
            .animation(Theme.stateChange, value: focused)
    }
}

// MARK: - Scrubber

/// The progress bar: white played portion, chapter tick marks, and SponsorBlock
/// segments coloured in place.
private struct Scrubber: View {

    @Bindable var model: PlayerModel
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.playback.duration, 0.001)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)

                // SponsorBlock segments, drawn under the playhead so a skipped
                // stretch is visible before you reach it.
                ForEach(model.playback.sponsorSegments, id: \.start) { segment in
                    let x = CGFloat(segment.start / duration) * width
                    let w = CGFloat((segment.end - segment.start) / duration) * width
                    Capsule()
                        .fill(Color.green.opacity(0.85))
                        .frame(width: max(w, 2))
                        .offset(x: x)
                }

                // White, not brand red — the TV client's scrubber has no red in
                // it at all.
                Capsule()
                    .fill(Theme.textPrimary)
                    .frame(width: width * CGFloat(model.progress))

                // Chapter boundaries as gaps in the bar, which is how the real
                // client segments long videos.
                ForEach(model.playback.chapters) { chapter in
                    let x = CGFloat(chapter.startTime / duration) * width
                    if x > 1 {
                        Rectangle()
                            .fill(Color.black.opacity(0.85))
                            .frame(width: 2)
                            .offset(x: x)
                    }
                }
            }
        }
        .frame(height: Theme.Metrics.scrubberHeight(viewport))
    }
}
