import SwiftUI
import YouTubeCore
import YouTubeMedia

// The four surfaces the player produced state for and never drew.
//
// Each of these was already fully wired underneath: `CaptionsManager` has been
// updating `currentCaptionCue` every 0.5 s, `toggleStatsForNerds()` has been
// filling a fifteen-field snapshot, `/player` has been returning a description,
// and the retry ladder has been setting `error` for a long time. Nothing in the
// UI read any of it — the Description and Stats buttons were drawn, focusable,
// and fell through to `break`, and a stream that failed every rung of the ladder
// left a black rectangle with no message.

// MARK: - Captions

/// The subtitle line, over the video.
///
/// Kept as its own `View` for the same reason `TimelineLabels` is: it reads
/// `playback.currentCaptionCue`, which changes on the 0.5 s time observer, and
/// observing that from `TVPlayerView.body` would re-evaluate the whole player
/// twice a second.
///
/// Positioned above the transport rather than centred, so a cue and the control
/// bar never overlap — the real client raises captions the same way when its
/// chrome is up.
struct CaptionOverlay: View {

    let playback: PlaybackViewModel
    let controlsVisible: Bool

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let cue = playback.currentCaptionCue, !cue.text.isEmpty {
                Text(cue.text)
                    .font(.system(size: rem(1.6) * playback.settings.captionScale, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, rem(0.9))
                    .padding(.vertical, rem(0.45))
                    // A solid plate, not a material: captions have to stay legible
                    // over an arbitrary frame, and glass tracks what is behind it.
                    .background(Color.black.opacity(playback.settings.captionOpaqueBackground ? 1 : 0.75))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.badgeCorner(viewport), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.badgeCorner(viewport), style: .continuous)
                        .strokeBorder(Theme.divider.opacity(0.6), lineWidth: 1))
                    .frame(maxWidth: viewport.width * 0.8)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, controlsVisible ? rem(12) : rem(4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .animation(Theme.stateChange, value: controlsVisible)
    }
}

// MARK: - Stats for nerds

/// The diagnostics overlay, top-left, in a monospaced column.
struct StatsOverlay: View {

    let playback: PlaybackViewModel

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    /// Only the rows that have a value. A blank right-hand column reads as a bug.
    private var rows: [(String, String)] {
        let s = playback.statsSnapshot
        var out: [(String, String)] = []
        func add(_ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            out.append((label, value))
        }
        add("Video ID", s.videoId)
        add("Resolution", s.displayResolution)
        if s.fps > 0 { add("Frame rate", "\(s.fps) fps") }
        add("Codec", s.codec)
        add("Bitrate", s.nominalBitrate)
        add("Observed", s.observedBitrate)
        add("Dropped frames", "\(s.droppedFrames)")
        add("Stalls", "\(s.stalls)")
        add("Requested", s.pendingQualityLabel)
        if s.timeToPlayMs > 0 { add("Time to play", "\(s.timeToPlayMs) ms") }
        if s.timeToHighQualityMs > 0 { add("Time to HQ", "\(s.timeToHighQualityMs) ms") }
        add("Cache", s.cacheStatus)
        add("Stream", s.streamType)
        add("Host", s.streamURL)
        add("Report ID", s.reportID)
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rem(0.25)) {
            ForEach(rows, id: \.0) { label, value in
                HStack(alignment: .top, spacing: rem(0.6)) {
                    Text(label)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: rem(9), alignment: .leading)
                    Text(value)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: rem(0.85), design: .monospaced))
        .padding(rem(1))
        // Flat black on purpose — numbers over video must not track the frame
        // behind them. The hairline is what separates "plate" from "debug print".
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.plateCorner(viewport), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.plateCorner(viewport), style: .continuous)
            .strokeBorder(Theme.divider, lineWidth: 1))
        .frame(maxWidth: rem(34), alignment: .leading)
        .allowsHitTesting(false)
    }
}

// MARK: - Description

/// The video description, in the same right-hand column the comments use.
///
/// Up and Down scroll it a line at a time; Back closes.
///
/// The text is rendered plain. `findTimestamps(in:)` already exists and would
/// turn "12:04 The bit you want" into something selectable, but making a chip
/// seekable means giving this panel its own focus model, so it is left for when
/// chapters get a surface too.
struct DescriptionPanel: View {

    @Bindable var model: PlayerModel

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    private var width: CGFloat { min(viewport.width * 0.34, rem(30)) }

    var body: some View {
        VStack(alignment: .leading, spacing: rem(1.0)) {
            BackChip(action: { model.closeDescription() })

            Text(model.title)
                .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)

            Text(model.metaLine)
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                .foregroundStyle(Theme.textSecondary)

            Divider().overlay(Theme.divider)

            if model.descriptionText.isEmpty {
                Text("This video has no description.")
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                body(for: model.descriptionText)
            }

            Spacer(minLength: 0)
        }
        .padding(rem(1.5))
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.sheetCorner(viewport), style: .continuous))
    }

    private func body(for text: String) -> some View {
        GeometryReader { geo in
            Text(text)
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(rem(0.3))
                .frame(width: geo.size.width, alignment: .topLeading)
                // Scrolled by translation from the line offset, the same stateless
                // approach the guide and the comments column use: derived from the
                // index each time rather than accumulated, so it cannot drift.
                .offset(y: -CGFloat(model.descriptionScroll ?? 0) * rem(1.5))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .animation(Theme.travel, value: model.descriptionScroll)
        }
    }
}

// MARK: - Playback failure

/// Shown when the retry ladder has given up.
///
/// Before this existed, `exhaustiveRetry` ending in `.unavailable` simply set
/// `error`, cleared `isLoading`, and left the user looking at a black frame with
/// no message and no way to try again — `retryLoad()` had no caller anywhere in
/// the app. Select retries; Back leaves the player.
struct PlaybackErrorPanel: View {

    let playback: PlaybackViewModel

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        VStack(spacing: rem(1.0)) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: rem(3), weight: .light))
                .foregroundStyle(Theme.textSecondary)

            Text("This video would not play")
                .font(.system(size: rem(1.75), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(detail)
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: rem(40))

            Text("Press Select to try again, or Back to return")
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, rem(0.5))
        }
        .padding(rem(2))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        // Same hairline as the stats plate: a full-frame black wash with no
        // edge reads as a failed render, which is exactly what it is reporting.
        .overlay(Rectangle().strokeBorder(Theme.divider, lineWidth: 1))
    }

    /// `retryStatusMessage` is the human-readable line the ladder leaves behind;
    /// the raw error is the fallback when it has not set one.
    private var detail: String {
        if let status = playback.retryStatusMessage, !status.isEmpty { return status }
        if let error = playback.error { return error.localizedDescription }
        return "YouTube did not return a stream this client could play."
    }
}
