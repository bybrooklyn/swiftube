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
        // No `ignoresSafeArea` on the video surface: the window is already
        // borderless with a full-size content view, so it gains nothing — and it
        // widened the ZStack past the window, which the overlay then inherited.
        // That is what pushed the transport's right-hand cluster off frame and
        // ran the scrubber past the right edge.
        ZStack {
            Color.black
            PlayerSurface(player: model.playback.player,
                          pipRequest: model.pipRequest,
                          onPictureInPictureActive: { model.pictureInPicture(active: $0) },
                          onPictureInPictureRestore: { model.onPictureInPictureRestore() })

            if model.playback.isLoading {
                ProgressView().controlSize(.large).tint(.white)
            }

            // Captions sit under the chrome but over the video, and are drawn
            // whether or not the transport is up — a subtitle that only appears
            // while the control bar happens to be visible is not a subtitle.
            CaptionOverlay(playback: model.playback,
                           controlsVisible: model.areControlsVisible)

            if model.areControlsVisible {
                overlay.transition(.opacity)
            }

            if model.isStatsVisible {
                StatsOverlay(playback: model.playback)
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .zIndex(2)
            }

            if model.hasFailed {
                PlaybackErrorPanel(playback: model.playback)
                    .transition(.opacity)
                    .zIndex(3)
            }

            // The host wraps the *conditional*, not the menu: it has to outlive
            // the panel for the glass to materialise in and out (see GlassHost).
            GlassHost {
                if let menu = model.menu {
                    PlayerMenuView(model: menu, onBack: { model.closeMenu() })
                        .transition(Theme.panelTransition)
                }
            }
            .zIndex(2)

            // Shown independently of the controls: a skip prompt is useless if
            // it only appears while the transport happens to be up.
            if let segment = model.playback.currentToastSegment {
                sponsorToast(segment)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.travel, value: model.areControlsVisible)
        .animation(Theme.stateChange, value: model.isStatsVisible)
        .animation(Theme.stateChange, value: model.hasFailed)
        .animation(Theme.stateChange, value: model.isDescriptionOpen)
        .animation(Theme.stateChange, value: model.playback.currentToastSegment)
        .animation(Theme.stateChange, value: model.menu == nil)
    }

    /// The SponsorBlock prompt, for categories set to "show toast" rather than
    /// auto-skip. Press Select to take it.
    private func sponsorToast(_ segment: SponsorSegment) -> some View {
        HStack(spacing: rem(0.6)) {
            Image(systemName: "forward.end.alt.fill")
                .font(.system(size: rem(0.9), weight: .semibold))
            Text("Skip \(Self.label(for: segment.category))")
                .font(.system(size: rem(1.0), weight: .semibold))
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, rem(1.1))
        .padding(.vertical, rem(0.7))
        .background(.black.opacity(0.82), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.focusRing, lineWidth: rem(0.1)))
        .padding(.trailing, inset)
        // Sits clear of the transport row so it never collides with the
        // controls when both are on screen.
        .padding(.bottom, viewport.height * 0.26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    static func label(for category: SponsorSegment.Category) -> String {
        switch category {
        case .sponsor:       "sponsor"
        case .selfPromo:     "self-promo"
        case .interaction:   "reminder"
        case .intro:         "intro"
        case .outro:         "endcards"
        case .preview:       "recap"
        case .filler:        "filler"
        case .musicOfftopic: "non-music"
        case .poiHighlight:  "to highlight"
        }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            footer
        }
        .overlay(alignment: .trailing) {
            if model.isCommentsOpen {
                CommentsPanel(model: model)
                    .padding(.trailing, inset)
                    .padding(.vertical, inset)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if model.isDescriptionOpen {
                // Same column as the comments — they are mutually exclusive, and
                // sharing the position keeps the video's visible area constant.
                DescriptionPanel(model: model)
                    .padding(.trailing, inset)
                    .padding(.vertical, inset)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Scrims top and bottom rather than a full-width glass panel: glass
            // across the whole width would blur live video the entire time the
            // controls are up, which is the one place in this UI where it
            // measurably costs frames. Glass is kept for the small pills below.
            // Bottom scrim only. The reference has no top gradient at all — the
            // title is legible because it sits on its own black run, which keeps
            // the top third of the frame unobscured.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: viewport.height * 0.40)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        // Each line sits on its own opaque black run rather than over a
        // gradient. That is what the real client does, and it is what keeps a
        // title legible over a bright frame without dimming the whole video.
        VStack(alignment: .leading, spacing: rem(0.35)) {
            Text(model.title)
                .font(.system(size: Theme.Metrics.playerTitleSize(viewport), weight: .black))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .padding(.horizontal, rem(0.2))
                .background(Color.black)
            Text(model.metaLine)
                .font(.system(size: Theme.Metrics.playerMetaSize(viewport)))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, rem(0.2))
                .background(Color.black)
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
            if model.isUpNextOpen {
                UpNextRail(model: model)
                    .padding(.top, rem(1.0))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
    }

    private var timeline: some View { TimelineLabels(model: model) }

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
            // Without this the HStack sizes to its content, so the ZStack
            // collapsed around the left cluster and the right one was pushed
            // off the frame entirely.
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
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
            pill([.like, .dislike, .comments, .save, .addToPlaylist])
            pill([.stats, .pip, .settings])
        }
    }

    private func pill(_ controls: [PlayerControl]) -> some View {
        // No `GlassEffectContainer`, for the reason GuideRail.swift:47 spells out:
        // it only earns its cost when its children apply `.glassEffect`, and none
        // of these do — the pill is a flat `Theme.control` capsule. An empty
        // container is a render pass for nothing.
        HStack(spacing: 0) {
            ForEach(controls, id: \.self) { pillButton($0) }
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

// MARK: - Per-tick views

/// Current position with the chapter name, and the total duration opposite —
/// the chapter name is what makes long videos navigable on a TV.
///
/// Its own `View` rather than a computed property on `TVPlayerView` for a
/// reason that matters: with `@Observable`, whichever body *reads*
/// `playback.currentTime` is the body that gets invalidated when it changes.
/// Read inline, that was `TVPlayerView.body` — so the title, the metadata, the
/// whole transport row and both glass pills were rebuilt ten times a second
/// while a video played, for a label that is the only thing that changed.
private struct TimelineLabels: View {

    @Bindable var model: PlayerModel
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        HStack {
            Text(model.positionLabel)
                .padding(.horizontal, Theme.Metrics.rem(0.2, viewport))
                .background(Color.black)
            Spacer()
            Text(formatDuration(model.playback.duration))
                .padding(.horizontal, Theme.Metrics.rem(0.2, viewport))
                .background(Color.black)
        }
        .font(.system(size: Theme.Metrics.timeLabelSize(viewport), weight: .medium))
        .foregroundStyle(Theme.textPrimary)
    }
}

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
                // Keyed on the segment's own id: two overlapping segments can
                // share a start time, and `id: \.start` then dropped one.
                ForEach(model.playback.sponsorSegments) { segment in
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
