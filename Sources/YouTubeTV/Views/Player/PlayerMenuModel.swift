import Foundation
import Observation
import YouTubeCore
import YouTubeMedia

/// The in-player settings menu: categories on the left, their options on the
/// right.
///
/// Every action it performs already existed on `PlaybackViewModel` —
/// `selectFormat`, `selectCaption`, `setPlaybackSpeed`, `selectAudioTrack` —
/// with no UI attached to any of them, so quality, captions, speed and audio
/// track were unreachable while a video was playing.
@MainActor
@Observable
final class PlayerMenuModel {

    enum Category: String, CaseIterable, Identifiable {
        case quality, captions, speed, audio
        var id: String { rawValue }

        var title: String {
            switch self {
            case .quality:  "Quality"
            case .captions: "Subtitles"
            case .speed:    "Speed"
            case .audio:    "Audio"
            }
        }

        var symbol: String {
            switch self {
            case .quality:  "slider.horizontal.3"
            case .captions: "captions.bubble"
            case .speed:    "gauge.with.needle"
            case .audio:    "waveform"
            }
        }
    }

    struct Option: Identifiable {
        let id: String
        let title: String
        let isSelected: Bool
        let apply: () -> Void
    }

    /// Which column has focus. The menu is a two-column list, so movement is
    /// left/right between columns and up/down within one.
    enum Column { case categories, options }

    private let playback: PlaybackViewModel

    private(set) var category: Category = .quality
    private(set) var column: Column = .categories
    private(set) var optionIndex = 0

    init(playback: PlaybackViewModel) {
        self.playback = playback
        // Open on whichever category has something to offer.
        if playback.availableFormats.isEmpty {
            category = playback.availableCaptions.isEmpty ? .speed : .captions
        }
    }

    var categories: [Category] { Category.allCases }

    var options: [Option] {
        switch category {
        case .quality:
            let auto = Option(id: "auto", title: "Auto",
                              isSelected: playback.selectedFormat == nil) { [playback] in
                playback.selectFormat(nil)
            }
            // Distinct heights only: the format list repeats a resolution once
            // per codec, which would show "1080p" four times in a row.
            var seen = Set<Int>()
            let formats = playback.availableFormats
                .sorted { $0.height > $1.height }
                .filter { seen.insert($0.height).inserted }
                .map { format in
                    Option(id: "q\(format.height)", title: format.qualityLabel,
                           isSelected: playback.selectedFormat?.height == format.height) { [playback] in
                        playback.selectFormat(format)
                    }
                }
            return [auto] + formats

        case .captions:
            let off = Option(id: "off", title: "Off",
                             isSelected: playback.selectedCaption == nil) { [playback] in
                playback.selectCaption(nil)
            }
            return [off] + playback.availableCaptions.map { track in
                Option(id: track.id, title: track.name,
                       isSelected: playback.selectedCaption?.id == track.id) { [playback] in
                    playback.selectCaption(track)
                }
            }

        case .speed:
            return AppSettings.availableSpeeds.map { speed in
                Option(id: "s\(speed)", title: String(format: "%gx", speed),
                       isSelected: abs(playback.settings.playbackSpeed - speed) < 0.01) { [playback] in
                    playback.setPlaybackSpeed(speed)
                }
            }

        case .audio:
            return playback.availableAudioTracks.map { track in
                Option(id: track.id, title: track.name,
                       isSelected: playback.selectedAudioTrack?.id == track.id) { [playback] in
                    playback.selectAudioTrack(track)
                }
            }
        }
    }

    /// Shown next to the category name, so the current value is visible without
    /// entering the column.
    func summary(for category: Category) -> String {
        switch category {
        case .quality:  playback.pendingQualityLabel
        case .captions: playback.selectedCaption?.name ?? "Off"
        case .speed:    String(format: "%gx", playback.settings.playbackSpeed)
        case .audio:    playback.selectedAudioTrack?.name ?? "Default"
        }
    }

    // MARK: - Navigation

    func move(_ direction: MoveDirection) {
        switch direction {
        case .up:
            if column == .categories {
                if let index = categories.firstIndex(of: category), index > 0 {
                    category = categories[index - 1]
                    optionIndex = 0
                }
            } else {
                optionIndex = max(optionIndex - 1, 0)
            }
        case .down:
            if column == .categories {
                if let index = categories.firstIndex(of: category), index < categories.count - 1 {
                    category = categories[index + 1]
                    optionIndex = 0
                }
            } else {
                optionIndex = min(optionIndex + 1, max(options.count - 1, 0))
            }
        case .right:
            if column == .categories, !options.isEmpty {
                column = .options
                // Land on whatever is currently selected rather than the top.
                optionIndex = options.firstIndex { $0.isSelected } ?? 0
            }
        case .left:
            column = .categories
        }
    }

    /// Returns true when the menu should close.
    func select() -> Bool {
        guard column == .options, options.indices.contains(optionIndex) else {
            if column == .categories, !options.isEmpty { move(.right) }
            return false
        }
        options[optionIndex].apply()
        return false
    }
}
