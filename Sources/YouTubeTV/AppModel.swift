import Foundation
import Observation
import SwiftUI
import YouTubeCore
import YouTubeMedia

/// Top-level state for the browse surface: what is loaded, where focus is, and
/// what a directional press means right now.
///
/// Intent handling lives here rather than in the views, so views stay pure
/// renderers of `focus` — no view ever decides where focus goes next.
@MainActor
@Observable
final class AppModel {

    /// One horizontal row of the home feed.
    ///
    /// A thin projection of `VideoGroup` so the views never touch a Core model
    /// with an optional title, and so shelf identity is stable across reloads
    /// (`VideoGroup.id` is a fresh `UUID` on every fetch, which would make
    /// SwiftUI tear down and rebuild every row on each refresh).
    struct Shelf: Identifiable, Equatable {
        let id: String
        var title: String
        var videos: [Video]
    }

    /// One InnerTube session for the whole app.
    ///
    /// Each view model defaults to constructing its own `InnerTubeAPI`, and each
    /// instance keeps its own `visitorData` — the identity YouTube binds a PO
    /// token to. With separate instances the player's session had no visitorData
    /// at all (it had never made a browse call), so a token minted against the
    /// browse session could not match and the CDN rejected every stream URL.
    let api: InnerTubeAPI

    /// The multi-shelf home feed.
    ///
    /// `BrowseViewModel` is used rather than `HomeViewModel` because it keeps the
    /// real shelves: `HomeViewModel` calls the same `fetchHomeRows()` and then
    /// flattens every shelf into one deduped array, discarding YouTube's own
    /// titles, and interleaves the result into two hardcoded sections. Signed
    /// out, one of those two is always empty — which is why the home screen
    /// showed a single row on an otherwise blank page.
    let browse: BrowseViewModel

    let auth = AuthService()
    let settingsStore = SettingsStore()

    /// Non-nil while the settings surface is up. Modal, like the player.
    private(set) var settings: SettingsModel?

    private(set) var focus: BrowseFocus = .card(shelf: 0, index: 0)
    private(set) var isRailExpanded = false

    /// True while the sign-in screen is up. It is modal for the same reason the
    /// player is: it owns the whole intent stream while visible.
    private(set) var isSigningIn = false

    /// Non-nil while the player is up. The player is a modal surface: when it
    /// exists it takes the whole intent stream.
    private(set) var player: PlayerModel?

    @ObservationIgnored private var memory = BrowseNavigator.ColumnMemory()
    @ObservationIgnored private let input = InputRouter()

    init() {
        let api = InnerTubeAPI()
        self.api = api
        self.browse = BrowseViewModel(api: api)
    }

    var shelves: [Shelf] {
        if let channelFeed { return [channelFeed] }

        // A category surface returns exactly one group, and its title is
        // whatever the fetcher produced. Those fetchers fall back to a plain
        // search when their browseId comes back empty, so the group arrives
        // named "Search: music" — which is the wrong title showing on those
        // pages. The section knows its own name; use it.
        if browse.videoGroups.count == 1, selectedRailItem != .home,
           let group = browse.videoGroups.first {
            return [Shelf(id: "section-\(browse.currentSection.id)",
                          title: browse.currentSection.title,
                          videos: group.videos)]
        }

        return browse.videoGroups.enumerated().map { index, group in
            Shelf(
                // Index is part of the id because YouTube repeats shelf titles
                // within one feed. Keying only on the title gave ForEach
                // duplicate ids, which SwiftUI resolves by dropping or aliasing
                // rows — cards appearing in the wrong shelf.
                id: "\(index)-\(group.title ?? "untitled")",
                title: group.title ?? "",
                videos: group.videos
            )
        }
    }

    var layout: BrowseLayout {
        BrowseLayout(railItems: railItems,
                     shelfSizes: shelves.map(\.videos.count),
                     hasTopBar: true)
    }

    /// Which guide entry is highlighted as the current section — distinct from
    /// which one has focus.
    private(set) var selectedRailItem: RailItem = .home

    /// Channels shown in the guide. From the account when signed in, from the
    /// local follow list otherwise, so the guide is never empty.
    private(set) var guideChannels: [Channel] = []

    /// The guide's entries in display order, with subscribed channels spliced in
    /// between Home and Subscriptions the way the real client does.
    var railItems: [RailItem] {
        // Order measured off the real client: Shorts sits directly under Home,
        // inside the first group; the category block is Music, Gaming, Live,
        // News, Podcasts, Sports; Settings is the last row.
        var items: [RailItem] = [.account, .search, .home, .shorts]
        // Capped: the guide is a menu, not the subscription manager.
        items += guideChannels.prefix(5).map { .channel($0.id) }
        items += [.subscriptions, .library,
                  .music, .gaming, .live, .news, .podcasts, .sports,
                  .settings]
        return items
    }

    var isLoading: Bool { browse.isLoading && browse.videoGroups.isEmpty }

    func start() {
        // A test seam, not a feature. Screens are otherwise only reachable by
        // navigating with a controller, which makes them impossible to verify
        // without synthetic key events — and those proved unreliable enough to
        // deliver phantom presses to the wrong app.
        //   YOUTUBETV_STATE=guide|signin|settings open build/YouTube.app
        switch ProcessInfo.processInfo.environment["YOUTUBETV_STATE"] {
        case "signin":   isSigningIn = true
        case "guide":    focus = .rail(.home); isRailExpanded = true
        case "settings": open(.settings)
        default:         break
        }
        input.start { [weak self] intent in
            self?.handle(intent)
        }

        // Push the stored token into the API *before* the first fetch.
        //
        // AuthService restores the session from the Keychain in its own init,
        // so the account avatar appeared — but nothing had told InnerTubeAPI,
        // VideoPreloadCache or the player about it. The feed was therefore
        // fetched unauthenticated on every launch, came back empty, and fell
        // back to a plain "popular" search. Only signing in *during* a session
        // ever applied the token.
        Task {
            if auth.isSignedIn {
                await applyAuthChange()
            } else {
                browse.loadContent(source: "AppModel.start")
                await loadGuideChannels()
            }
        }
    }

    /// Populates the guide's channel list. Signed in this is the real
    /// subscription list; signed out it falls back to locally followed channels
    /// so the guide still has the shape of the real one.
    private func loadGuideChannels() async {
        if auth.isSignedIn, let fetched = try? await api.fetchSubscribedChannels(), !fetched.isEmpty {
            guideChannels = fetched
            return
        }
        guideChannels = await LocalSubscriptionStore.shared.allChannels().map { $0.toChannel() }
    }

    func stop() { input.stop() }

    /// Called when the sign-in screen closes, whether it succeeded or not.
    func finishSignIn() {
        isSigningIn = false
        Task { await applyAuthChange() }
    }

    /// Switches the feed to a guide entry.
    ///
    /// Every category in the guide maps onto a `BrowseSection.SectionType` that
    /// `BrowseViewModel` already knows how to fetch, so selecting Music or
    /// Gaming loads a real feed rather than only moving a highlight.
    private func open(_ item: RailItem) {
        if case let .channel(id) = item {
            selectedRailItem = item
            memory.railItem = item
            // Channel pages are their own surface; until that exists, show the
            // channel's uploads in the feed rather than doing nothing.
            Task { await loadChannel(id) }
            return
        }

        if item == .settings {
            selectedRailItem = item
            memory.railItem = item
            openSettings()
            return
        }

        // Bail *before* mutating anything. Search and Podcasts have no section
        // to load yet; moving the selection highlight and clearing the channel
        // feed for them silently reverted the visible feed to Home while
        // claiming a different entry was selected.
        guard let name = item.sectionTypeName,
              let type = BrowseSection.SectionType(rawValue: name) else { return }

        selectedRailItem = item
        channelFeed = nil
        browse.select(section: BrowseSection(id: type.rawValue,
                                             title: type.defaultTitle,
                                             type: type))
        // A new surface starts at its first card. Column memory is per-shelf and
        // meaningless across surfaces, but the *guide* position is not — reset
        // it and reopening the guide would jump back to Home instead of the
        // entry you just chose.
        focus = .card(shelf: 0, index: 0)
        memory = BrowseNavigator.ColumnMemory()
        memory.railItem = item
        isRailExpanded = false
    }

    func openSettings() {
        isRailExpanded = false
        settings = SettingsModel(store: settingsStore, auth: auth) { [weak self] in
            // Sign-in replaces settings rather than stacking on top of it.
            self?.settings = nil
            self?.isSigningIn = true
        }
    }

    private func closeSettings() {
        settings = nil
        // Settings changes affect playback, so hand the new values to the
        // player the next time one is created — and to any that is live now.
        player?.playback.updateSettings(settingsStore.settings)
        focus = .rail(.settings)
        isRailExpanded = true
    }

    private func loadChannel(_ channelId: String) async {
        guard let (channel, group) = try? await api.fetchChannel(channelId: channelId) else { return }
        memory = BrowseNavigator.ColumnMemory()
        memory.railItem = .channel(channelId)
        channelFeed = Shelf(id: "channel-\(channelId)",
                            title: channel.title,
                            videos: group.videos)
        focus = .card(shelf: 0, index: 0)
        memory = BrowseNavigator.ColumnMemory()
        isRailExpanded = false
    }

    /// Set while a channel from the guide is being shown, which replaces the
    /// browse feed until another guide entry is chosen.
    private var channelFeed: Shelf?

    /// Fans a sign-in (or sign-out) out to every consumer that caches it.
    ///
    /// Four separate places hold the token, and missing any one of them fails
    /// silently and confusingly:
    ///
    ///  * the shared `InnerTubeAPI` — browse and player requests;
    ///  * `VideoPreloadCache.shared`, which owns a *separate* `InnerTubeAPI`;
    ///  * `BrowseViewModel`, which also reloads the feed on the change;
    ///  * every live `PlaybackViewModel` — its `hasAuthToken` is a local mirror,
    ///    and it is the gate on the authenticated TV stream path. Setting the
    ///    token only on the shared API leaves that path switched off, which is
    ///    exactly the state in which YouTube answers "Sign in to confirm you're
    ///    not a bot" and playback dead-ends.
    private func applyAuthChange() async {
        let token = auth.accessToken
        let sapisid = auth.sapisid

        await api.setAuthToken(token)
        await api.setSAPISID(sapisid)
        await VideoPreloadCache.shared.setAuthToken(token)
        await VideoPreloadCache.shared.setSAPISID(sapisid)

        player?.playback.updateAuthToken(token)
        player?.playback.updateSAPISID(sapisid)

        // BrowseViewModel reloads its content when the token changes.
        await browse.updateAuthToken(token)
        await loadGuideChannels()
    }

    // MARK: - Intents

    func handle(_ intent: NavigationIntent) {
        // Sign-in is modal, but it must still hear Back — swallowing every
        // intent here left the screen with no way out.
        if isSigningIn {
            if intent == .back {
                auth.cancelSignIn()
                finishSignIn()
            }
            return
        }

        if let settings {
            switch intent {
            case let .move(direction): settings.move(direction)
            case .select:              settings.select()
            case .back:                closeSettings()
            default:                   break
            }
            return
        }

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
            withAnimation(Theme.stateChange) {
                focus = next
                isRailExpanded = next.isInRail
            }
            loadMoreIfNearRowEnd()

        case .select:
            switch focus {
            case let .card(shelf, index):
                if let video = video(shelf: shelf, index: index) { present(video) }
            case .rail(.account):
                if auth.isSignedIn { auth.signOut(); Task { await applyAuthChange() } }
                else { isSigningIn = true }
            case let .rail(item):
                open(item)
            case .topBar:
                break
            }

        case .back:
            // From content, back opens the guide — the same affordance as
            // pressing left at the start of a row.
            guard !focus.isInRail else { return }
            withAnimation(Theme.stateChange) {
                memory.remember(focus)
                focus = .rail(memory.railItem)
                isRailExpanded = true
            }

        case .menu, .playPause, .seek:
            break
        }
    }

    /// Re-clamps focus after the feed changes shape underneath it. Shelves load
    /// asynchronously, so the focused card can be replaced while it is on screen.
    func layoutDidChange() {
        let clamped = BrowseNavigator.clamped(focus, to: layout)
        if clamped != focus { focus = clamped }
    }

    func video(shelf: Int, index: Int) -> Video? {
        let shelves = shelves
        guard shelves.indices.contains(shelf),
              shelves[shelf].videos.indices.contains(index) else { return nil }
        return shelves[shelf].videos[index]
    }

    func isFocused(shelf: Int, index: Int) -> Bool {
        focus == .card(shelf: shelf, index: index)
    }

    /// Total height of the shelves above `row`, so the list can translate them
    /// off the top and park the focused header near the top of the content area.
    ///
    /// Computed rather than a constant pitch because the first shelf uses larger
    /// hero tiles than the rest, so rows are not all the same height.
    func rowOffset(upTo row: Int, viewport: CGSize) -> CGFloat {
        guard row > 0 else { return 0 }
        let gap = Theme.Metrics.shelfGap(viewport)
        return (0..<row).reduce(into: CGFloat(0)) { total, index in
            total += shelfHeight(index: index, viewport: viewport) + gap
        }
    }

    private func shelfHeight(index: Int, viewport: CGSize) -> CGFloat {
        let width = Theme.Metrics.cardWidth(viewport, hero: index == 0)
        let header = Theme.Metrics.rem(2.625, viewport) + Theme.Metrics.rem(0.75, viewport)
        let thumb = width / Theme.Metrics.cardAspect

        // A shelf with no videos draws placeholder thumbnails and no metadata,
        // so counting the metadata block for it overshoots the scroll offset and
        // parks the focused header off the top. Shelves can empty in place when
        // a video or channel is hidden from the feed.
        let isEmpty = shelves.indices.contains(index) && shelves[index].videos.isEmpty
        guard !isEmpty else { return header + thumb }

        return header + thumb
            + Theme.Metrics.thumbToMeta(viewport)
            + Theme.Metrics.metaBlockHeight(viewport)
    }

    /// The shelf the feed is scrolled to. While focus is in the guide or the
    /// top bar the feed holds its position rather than jumping to the top.
    var parkedShelf: Int {
        if let shelf = focus.shelfIndex { return shelf }
        if case let .card(shelf, _)? = memory.contentFocus { return shelf }
        return 0
    }

    /// The card each shelf is parked on — the focused one for the active shelf,
    /// each other shelf's remembered column otherwise. Rows hold position while
    /// focus is elsewhere, so returning to a row finds it where you left it.
    func parkedIndex(forShelf shelf: Int) -> Int {
        if case let .card(activeShelf, index) = focus, activeShelf == shelf { return index }
        return memory.index(forShelf: shelf, layout: layout)
    }

    // MARK: - Player

    private func present(_ video: Video) {
        let model = PlayerModel(api: api)
        model.playback.updateSettings(settingsStore.settings)
        // The player keeps its own `hasAuthToken` mirror; setting the token on
        // the shared API is not enough to arm the authenticated stream paths.
        model.playback.updateAuthToken(auth.accessToken)
        model.playback.updateSAPISID(auth.sapisid)
        withAnimation(Theme.travel) { player = model }
        model.play(video)
    }

    private func dismissPlayer() {
        withAnimation(Theme.travel) { player = nil }
    }

    /// Pulls the next page in as focus approaches the end of a row, so the feed
    /// grows before the user reaches its edge rather than stopping dead.
    private func loadMoreIfNearRowEnd() {
        guard case let .card(shelf, index) = focus else { return }
        let shelves = shelves
        guard shelves.indices.contains(shelf) else { return }
        guard index >= shelves[shelf].videos.count - 5 else { return }

        // `loadMoreIfNeeded` only acts when the video belongs to the *last*
        // group — it guards on `videoGroups.last.videos.contains(lastVideo)`.
        // Passing the focused shelf's last card therefore did nothing at all
        // for every row except the bottom one, so those rows stopped dead at
        // their first page. Feed-level continuation is all BrowseViewModel
        // offers, so drive it from the final group.
        if let last = shelves.last?.videos.last {
            browse.loadMoreIfNeeded(lastVideo: last)
        }
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
