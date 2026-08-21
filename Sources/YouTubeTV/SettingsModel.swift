import Foundation
import Observation
import YouTubeCore
import YouTubeMedia

/// Backs the settings surface.
///
/// Each row reads and writes `AppSettings` through `SettingsStore`, which
/// persists on every set — so a change takes effect on the next video without
/// an explicit save step. Selecting a row cycles it to its next value; there
/// are no sub-menus, because a d-pad makes them expensive to escape.
@MainActor
@Observable
final class SettingsModel {

    struct Row: Identifiable {
        enum Kind { case header, setting }
        let id: String
        let kind: Kind
        let title: String
        var value: String = ""
        var advance: (() -> Void)?
    }

    private let store: SettingsStore
    private let auth: AuthService
    private let onSignIn: () -> Void

    private(set) var focusedRow: Int = 0

    init(store: SettingsStore, auth: AuthService, onSignIn: @escaping () -> Void) {
        self.store = store
        self.auth = auth
        self.onSignIn = onSignIn
        // Start on the first selectable row, not a header.
        focusedRow = rows.firstIndex { $0.kind == .setting } ?? 0
    }

    var settings: AppSettings { store.settings }

    var rows: [Row] {
        var rows: [Row] = []

        rows.append(Row(id: "h.sponsor", kind: .header, title: "SponsorBlock"))
        rows.append(Row(id: "sb.enabled", kind: .setting, title: "SponsorBlock",
                        value: settings.sponsorBlockEnabled ? "On" : "Off") { [weak self] in
            self?.mutate { $0.sponsorBlockEnabled.toggle() }
        })
        if settings.sponsorBlockEnabled {
            for category in SponsorSegment.Category.allCases {
                rows.append(Row(id: "sb.\(category.rawValue)", kind: .setting,
                                title: Self.label(for: category),
                                value: Self.label(for: settings.sponsorAction(for: category))) { [weak self] in
                    self?.cycleSponsorAction(category)
                })
            }
            rows.append(Row(id: "sb.min", kind: .setting, title: "Ignore segments shorter than",
                            value: "\(Int(settings.sponsorBlockMinSegmentDuration))s") { [weak self] in
                self?.cycle(Self.minSegmentOptions, current: { $0.sponsorBlockMinSegmentDuration }) {
                    $0.sponsorBlockMinSegmentDuration = $1
                }
            })
        }

        rows.append(Row(id: "h.playback", kind: .header, title: "Playback"))
        rows.append(Row(id: "pb.quality", kind: .setting, title: "Preferred quality",
                        value: settings.preferredQuality.rawValue.capitalized) { [weak self] in
            self?.cycle(AppSettings.VideoQuality.allCases, current: { $0.preferredQuality }) {
                $0.preferredQuality = $1
            }
        })
        rows.append(Row(id: "pb.speed", kind: .setting, title: "Playback speed",
                        value: String(format: "%gx", settings.playbackSpeed)) { [weak self] in
            self?.cycle(AppSettings.availableSpeeds, current: { $0.playbackSpeed }) {
                $0.playbackSpeed = $1
            }
        })
        rows.append(Row(id: "pb.autoplay", kind: .setting, title: "Autoplay next video",
                        value: settings.autoplayEnabled ? "On" : "Off") { [weak self] in
            self?.mutate { $0.autoplayEnabled.toggle() }
        })
        rows.append(Row(id: "pb.back", kind: .setting, title: "Seek back",
                        value: "\(settings.seekBackSeconds)s") { [weak self] in
            self?.cycle(AppSettings.availableSeekOptions, current: { $0.seekBackSeconds }) {
                $0.seekBackSeconds = $1
            }
        })
        rows.append(Row(id: "pb.forward", kind: .setting, title: "Seek forward",
                        value: "\(settings.seekForwardSeconds)s") { [weak self] in
            self?.cycle(AppSettings.availableSeekOptions, current: { $0.seekForwardSeconds }) {
                $0.seekForwardSeconds = $1
            }
        })

        rows.append(Row(id: "h.content", kind: .header, title: "Content"))
        rows.append(Row(id: "c.shorts", kind: .setting, title: "Hide Shorts",
                        value: settings.hideShorts ? "On" : "Off") { [weak self] in
            self?.mutate { $0.hideShorts.toggle() }
        })
        rows.append(Row(id: "c.dearrow", kind: .setting, title: "DeArrow titles",
                        value: settings.deArrowEnabled ? "On" : "Off") { [weak self] in
            self?.mutate { $0.deArrowEnabled.toggle() }
        })
        rows.append(Row(id: "c.history", kind: .setting, title: "Watch history",
                        value: settings.historyState == .enabled ? "On" : "Off") { [weak self] in
            self?.mutate { $0.historyState = $0.historyState == .enabled ? .disabled : .enabled }
        })

        rows.append(Row(id: "h.account", kind: .header, title: "Account"))
        rows.append(Row(id: "a.session", kind: .setting,
                        title: auth.isSignedIn ? "Signed in" : "Account",
                        value: auth.isSignedIn ? (auth.accountName ?? "Sign out") : "Sign in") { [weak self] in
            guard let self else { return }
            if auth.isSignedIn { auth.signOut() } else { onSignIn() }
        })

        return rows
    }

    // MARK: - Navigation

    func move(_ direction: MoveDirection) {
        let rows = rows
        switch direction {
        case .down:
            focusedRow = nextSelectable(from: focusedRow, step: 1, in: rows) ?? focusedRow
        case .up:
            focusedRow = nextSelectable(from: focusedRow, step: -1, in: rows) ?? focusedRow
        case .left, .right:
            break
        }
    }

    /// Headers are skipped: they exist to group rows, not to be landed on.
    private func nextSelectable(from index: Int, step: Int, in rows: [Row]) -> Int? {
        var candidate = index + step
        while rows.indices.contains(candidate) {
            if rows[candidate].kind == .setting { return candidate }
            candidate += step
        }
        return nil
    }

    func select() {
        let rows = rows
        guard rows.indices.contains(focusedRow) else { return }
        rows[focusedRow].advance?()
    }

    // MARK: - Mutation

    private func mutate(_ change: (inout AppSettings) -> Void) {
        var settings = store.settings
        change(&settings)
        store.settings = settings
    }

    private func cycle<Value: Equatable>(
        _ options: [Value],
        current: (AppSettings) -> Value,
        set: @escaping (inout AppSettings, Value) -> Void
    ) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex(of: current(store.settings)) ?? -1
        let next = options[(index + 1) % options.count]
        mutate { set(&$0, next) }
    }

    private func cycleSponsorAction(_ category: SponsorSegment.Category) {
        let options = AppSettings.SponsorBlockAction.allCases
        let index = options.firstIndex(of: settings.sponsorAction(for: category)) ?? -1
        let next = options[(index + 1) % options.count]
        mutate { $0.sponsorBlockActions[category] = next }
    }

    /// Short segments are usually mislabelled, so skipping them is more
    /// annoying than leaving them in.
    private static let minSegmentOptions: [Double] = [0, 1, 2, 3, 5, 10]

    // MARK: - Labels

    static func label(for category: SponsorSegment.Category) -> String {
        switch category {
        case .sponsor:       "Sponsored segments"
        case .selfPromo:     "Self-promotion"
        case .interaction:   "Subscribe reminders"
        case .intro:         "Intros"
        case .outro:         "Endcards / credits"
        case .preview:       "Recaps and previews"
        case .filler:        "Filler tangents"
        case .musicOfftopic: "Non-music sections"
        case .poiHighlight:  "Jump to highlight"
        }
    }

    static func label(for action: AppSettings.SponsorBlockAction) -> String {
        switch action {
        case .skip:      "Skip"
        case .showToast: "Show toast"
        case .nothing:   "Off"
        }
    }
}
