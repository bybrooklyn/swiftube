import Foundation
import Observation
import SwiftUI
import YouTubeCore
import YouTubeMedia

/// Top-level state for the browse surface: what is loaded, where focus is, and
/// what a directional press means right now.
///
/// Intent handling lives here rather than in the views so that the views stay
/// pure renderers of `focus` — no view ever decides where focus goes next.
@MainActor
@Observable
final class AppModel {

    /// One InnerTube session for the whole app.
    ///
    /// Each view model defaults to constructing its own `InnerTubeAPI`, and each
    /// instance keeps its own `visitorData` — the identity YouTube binds a PO
    /// token to. With separate instances the player's session had no
    /// visitorData at all (it had never made a browse call), so the token minted
    /// against the browse session could not match and the CDN rejected every
    /// stream URL. Sharing one actor keeps a single identity across browse and
    /// playback.
    let api: InnerTubeAPI

    let home: HomeViewModel

    init() {
        let api = InnerTubeAPI()
        self.api = api
        self.home = HomeViewModel(api: api)
    }

    private(set) var focus: BrowseFocus = .card(shelf: 0, index: 0)
    private(set) var isRailExpanded = false

    /// Non-nil while the player is up. The player is a modal surface: when it
    /// exists it takes the whole intent stream, so no browse element can be
    /// reached behind it.
    private(set) var player: PlayerModel?

    @ObservationIgnored private var memory = BrowseNavigator.ColumnMemory()
    @ObservationIgnored private let input = InputRouter()

    /// Shelves that currently have content, in display order. Sections that have
    /// not loaded yet keep their slot so shelf indices stay stable as the feed
    /// fills in.
    var shelves: [HomeViewModel.SectionState] { home.sections }

    var layout: BrowseLayout {
        BrowseLayout(chipCount: 0, shelfSizes: shelves.map(\.videos.count))
    }

    func start() {
        input.start { [weak self] intent in
            self?.handle(intent)
        }
        home.load()
    }

    func stop() {
        input.stop()
    }

    // MARK: - Intents

    func handle(_ intent: NavigationIntent) {
        if let player {
            player.handle(intent)
            if player.didRequestDismiss { dismissPlayer() }
            return
        }

        switch intent {
        case let .move(direction):
            let next = BrowseNavigator.next(from: focus, direction: direction,
                                            layout: layout, memory: &memory)
            guard next != focus else { return }
            withAnimation(Theme.focusSpring) {
                focus = next
                isRailExpanded = next.isInRail
            }
            prefetchIfNearRowEnd()

        case .select:
            if case let .card(shelf, index) = focus,
               let video = video(shelf: shelf, index: index) {
                present(video)
            }

        case .back:
            // From content, back opens the guide — the same affordance as
            // pressing left at the start of a row. From the guide it does
            // nothing; there is nowhere further left to go.
            guard !focus.isInRail else { return }
            withAnimation(Theme.focusSpring) {
                memory.remember(focus)
                focus = .rail(memory.railItem)
                isRailExpanded = true
            }

        case .menu, .playPause, .seek:
            // Meaningful only while the player is up (M4).
            break
        }
    }

    private func present(_ video: Video) {
        let model = PlayerModel(api: api)
        withAnimation(Theme.panelSpring) { player = model }
        model.play(video)
    }

    private func dismissPlayer() {
        withAnimation(Theme.panelSpring) { player = nil }
    }

    /// Re-clamps focus after the feed changes shape underneath it. Shelves load
    /// asynchronously, so the focused card can be replaced or removed while the
    /// user is looking at it.
    func layoutDidChange() {
        let clamped = BrowseNavigator.clamped(focus, to: layout)
        if clamped != focus { focus = clamped }
    }

    func video(shelf: Int, index: Int) -> Video? {
        guard shelves.indices.contains(shelf),
              shelves[shelf].videos.indices.contains(index) else { return nil }
        return shelves[shelf].videos[index]
    }

    /// The card each shelf is parked on — the focused one for the active shelf,
    /// and each other shelf's remembered column. Rows hold their position while
    /// focus is elsewhere, so coming back to a row finds it where you left it.
    func parkedIndex(forShelf shelf: Int) -> Int {
        if case let .card(activeShelf, index) = focus, activeShelf == shelf { return index }
        return memory.index(forShelf: shelf, layout: layout)
    }

    func isFocused(shelf: Int, index: Int) -> Bool {
        focus == .card(shelf: shelf, index: index)
    }

    /// Pulls the next page in as the focus approaches the end of a row, so the
    /// row grows before the user reaches its edge rather than stopping dead.
    private func prefetchIfNearRowEnd() {
        guard case let .card(shelf, index) = focus,
              shelves.indices.contains(shelf) else { return }
        let section = shelves[shelf]
        guard index >= section.videos.count - 5 else { return }
        home.loadMore(sectionId: section.id)
    }
}

extension BrowseFocus {
    var isInRail: Bool {
        if case .rail = self { return true }
        return false
    }

    var shelfIndex: Int? {
        if case let .card(shelf, _) = self { return shelf }
        return nil
    }
}
