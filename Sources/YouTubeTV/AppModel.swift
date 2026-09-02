import AppKit
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

    /// Non-nil while search is up. Also modal — the on-screen keyboard needs
    /// every directional press.
    private(set) var search: SearchModel?

    /// True while the sign-out confirmation is up.
    ///
    /// Signing out used to happen on a single Select of the guide's first item —
    /// the easiest thing in the app to hit by accident, and recovering means the
    /// whole device-code flow again.
    private(set) var isConfirmingSignOut = false

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

    /// Applies the "Hide Shorts" setting.
    ///
    /// The setting had exactly one consumer — a log line — so the toggle in
    /// Settings did nothing. The predicate itself was already written and tested
    /// (`HideShortsFilterTests`); it just had no call site in this target.
    ///
    /// The Shorts guide entry is exempt: hiding every card on the surface whose
    /// whole purpose is Shorts would leave the user on a blank page with no
    /// explanation of why.
    private func hidingShorts(_ videos: [Video]) -> [Video] {
        guard settingsStore.settings.hideShorts, selectedRailItem != .shorts else { return videos }
        return videos.filter { !$0.isShort }
    }

    private func shelf(id: String, title: String, videos: [Video]) -> Shelf {
        Shelf(id: id, title: title, videos: hidingShorts(videos))
    }

    var shelves: [Shelf] {
        if !customShelves.isEmpty {
            return customShelves.map { shelf(id: $0.id, title: $0.title, videos: $0.videos) }
        }
        if let channelFeed {
            return [shelf(id: channelFeed.id, title: channelFeed.title, videos: channelFeed.videos)]
        }

        // A category surface returns exactly one group, and its title is
        // whatever the fetcher produced. Those fetchers fall back to a plain
        // search when their browseId comes back empty, so the group arrives
        // named "Search: music" — which is the wrong title showing on those
        // pages. The section knows its own name; use it.
        if browse.videoGroups.count == 1, selectedRailItem != .home,
           let group = browse.videoGroups.first {
            return [shelf(id: "section-\(browse.currentSection.id)",
                          title: browse.currentSection.title,
                          videos: group.videos)]
        }

        return browse.videoGroups.enumerated().map { index, group in
            shelf(
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
                     hasTopBar: true,
                     hasChannelHeader: channelHeader != nil)
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

    var isLoading: Bool { browse.isLoading && browse.videoGroups.isEmpty && channelFeed == nil }

    /// Non-nil when the current surface has nothing to show, and why.
    ///
    /// Several surfaces legitimately return nothing — Subscriptions and Library
    /// need an account, a category can come back empty — and rendering that as a
    /// blank page reads as a broken app. `BrowseViewModel.isAuthRequired` already
    /// distinguishes the two cases and was never read.
    var emptyState: (title: String, detail: String, symbol: String)? {
        guard !isLoading, shelves.allSatisfy(\.videos.isEmpty) else { return nil }
        if browse.isAuthRequired && !auth.isSignedIn {
            return ("Sign in to see this",
                    "\(browse.currentSection.title) needs your YouTube account.\nChoose your avatar at the top of the guide to sign in.",
                    "person.crop.circle")
        }
        return ("Nothing here yet",
                "\(browse.currentSection.title) came back empty.",
                "tray")
    }

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
        case "search":   openSearch()
        default:         break
        }

        // Same seam, for playback:
        //   YOUTUBETV_PLAY=<videoId> open build/YouTube.app
        // Starting a video otherwise takes a keypress, and a keypress needs the
        // window frontmost — which is not always available, and not something
        // to take from someone who is using their machine. This makes a change
        // to the playback pipeline checkable from the log alone.
        if let videoId = ProcessInfo.processInfo.environment["YOUTUBETV_PLAY"],
           !videoId.isEmpty {
            // Deferred a turn: `start()` runs from the root view's `.task`, and
            // presenting the player from inside that first update re-enters the
            // update it is part of — the app came up with no window at all and
            // 0% CPU, which looks exactly like the raw-binary launch trap in
            // CLAUDE.md and is not one.
            Task { @MainActor [weak self] in
                self?.present(Video(id: videoId, title: videoId, channelTitle: ""))
            }
        }
        input.start { [weak self] intent in
            self?.handle(intent)
        }

        // Keep the token holders current for the life of the session.
        //
        // AuthService refreshes the access token about once an hour and
        // updated only itself; the shared InnerTubeAPI, VideoPreloadCache and
        // any live player kept the expired one, so every call 401'd until the
        // next relaunch. The SAPISID cookie arrives seconds *after* sign-in
        // completes, by which time `finishSignIn` had already read it as nil.
        // TokenManager already yields both; nothing was listening.
        Task { [weak self, updates = auth.tokenManager.updates] in
            for await update in updates {
                guard let self else { return }
                switch update {
                case .refreshed, .sapisidChanged:
                    await pushAuth()
                case .signedOut:
                    // Covers the automatic sign-out on a revoked refresh token,
                    // which no UI path fans out.
                    await applyAuthChange()
                }
            }
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

    /// Whether the account follows `channelId`, per the guide's subscription
    /// list — the one authenticated source of that fact the app has.
    func isSubscribed(toChannel channelId: String) -> Bool {
        guideChannels.contains { $0.id == channelId }
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
    /// Sections visited, so Back retraces them. Search and Settings are
    /// overlays rather than sections and are deliberately not recorded.
    @ObservationIgnored private var sectionHistory: [RailItem] = []

    /// Search and Settings are overlays, not sections. They are excluded from the
    /// trail on *both* sides: `item` because you never go Back *into* one, and
    /// `selectedRailItem` because closing one leaves it as the current highlight —
    /// so opening a real section afterwards used to push `.search` onto the trail,
    /// and the next Back re-opened the search overlay instead of going back.
    private static func isOverlay(_ item: RailItem) -> Bool {
        item == .search || item == .settings
    }

    private func open(_ item: RailItem, recordingHistory: Bool = true) {
        if recordingHistory, item != selectedRailItem,
           !Self.isOverlay(item), !Self.isOverlay(selectedRailItem) {
            sectionHistory.append(selectedRailItem)
            // A guide has a dozen entries and a session can wander; keep the
            // trail short enough that Back stays predictable.
            if sectionHistory.count > 16 { sectionHistory.removeFirst() }
        }

        if item == .settings {
            selectedRailItem = item
            memory.railItem = item
            openSettings()
            return
        }

        if item == .search {
            openSearch()
            return
        }

        // The surfaces assembled here rather than by BrowseViewModel: a channel's
        // uploads, the search-backed Podcasts entry, and Library.
        //
        // Each used to spawn an unstored Task that wrote its shelves whenever
        // it finished — so opening Library and then a channel could land the
        // library shelves on top of the channel page a second later. And the
        // stale data was not even cleared first: `shelves` prefers
        // `customShelves` and then `channelFeed` over the browse feed, and only
        // the browse path below reset them, so Library from a channel page
        // showed the old channel until (and unless) the library arrived.
        let custom: (() async -> Void)? = switch item {
        case let .channel(id): { await self.loadChannel(id) }
        case .podcasts:        { await self.loadSearchSurface(query: "podcast", title: "Podcasts") }
        case .library:         { await self.loadLibrary() }
        default:               nil
        }
        if let custom {
            beginSection(item)
            isRailExpanded = false
            sectionTask = Task { await custom() }
            return
        }

        // Bail *before* mutating anything. Search and Podcasts have no section
        // to load yet; moving the selection highlight and clearing the channel
        // feed for them silently reverted the visible feed to Home while
        // claiming a different entry was selected.
        guard let name = item.sectionTypeName,
              let type = BrowseSection.SectionType(rawValue: name) else { return }

        beginSection(item)
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

    /// The in-flight load for a custom surface, cancelled when another entry
    /// is chosen. The loaders also check `selectedRailItem` after each await,
    /// since a cancelled Task still runs to its next check.
    @ObservationIgnored private var sectionTask: Task<Void, Never>?

    /// Marks `item` current and clears every shelf source, so nothing stale
    /// shows while the new surface loads.
    private func beginSection(_ item: RailItem) {
        sectionTask?.cancel()
        selectedRailItem = item
        memory.railItem = item
        channelFeed = nil
        channelHeader = nil
        customShelves = []
    }

    func openSearch() {
        isRailExpanded = false
        selectedRailItem = .search
        memory.railItem = .search
        search = SearchModel(api: api)
    }

    private func closeSearch() {
        search = nil
        focus = .rail(.search)
        isRailExpanded = true
    }

    /// Auth state as it was when Settings opened, so `closeSettings` can tell
    /// whether the account row changed it.
    @ObservationIgnored private var settingsWasSignedIn = false

    func openSettings() {
        isRailExpanded = false
        settingsWasSignedIn = auth.isSignedIn
        settings = SettingsModel(store: settingsStore, auth: auth) { [weak self] in
            // Sign-in replaces settings rather than stacking on top of it.
            self?.settings = nil
            self?.isSigningIn = true
        }
    }

    private func closeSettings() {
        let wasSignedIn = settingsWasSignedIn
        settings = nil
        // Settings changes affect playback, so hand the new values to the
        // player the next time one is created — and to any that is live now.
        player?.playback.updateSettings(settingsStore.settings)
        // Settings' account row calls auth.signOut() directly, so the four
        // token holders below never heard about it and kept using a dead token
        // until the next launch. The guide's own sign-out path already fans out.
        if wasSignedIn != auth.isSignedIn {
            Task { await applyAuthChange() }
        }
        focus = .rail(.settings)
        isRailExpanded = true
    }

    /// A surface backed by a search rather than a browse id.
    private func loadSearchSurface(query: String, title: String) async {
        let item = selectedRailItem
        guard let group = try? await api.search(query: query, continuationToken: nil, filter: .default),
              selectedRailItem == item else { return }
        customShelves = [Shelf(id: "search-\(query)", title: title, videos: group.videos.deduplicatedByID())]
        focus = .card(shelf: 0, index: 0)
        memory = BrowseNavigator.ColumnMemory()
        memory.railItem = item
    }

    /// Library: three shelves, matching what the real client keeps there.
    ///
    /// The guide entry used to map to `SectionType.playlists`, so it showed only
    /// playlists — no history, no downloads. Each part is fetched independently
    /// and an empty one is simply omitted rather than showing an empty row.
    private func loadLibrary() async {
        var shelves: [Shelf] = []

        if let history = try? await api.fetchHistory(), !history.videos.isEmpty {
            // History repeats a video once per viewing.
            shelves.append(Shelf(id: "lib-history", title: "History", videos: history.videos.deduplicatedByID()))
        }
        if let playlists = try? await api.fetchUserPlaylists(), !playlists.isEmpty {
            let videos = playlists.map { playlist in
                Video(id: playlist.id,
                      title: playlist.title,
                      channelTitle: playlist.videoCount.map { "\($0) videos" } ?? "",
                      thumbnailURL: playlist.thumbnailURL,
                      playlistId: playlist.id)
            }
            shelves.append(Shelf(id: "lib-playlists", title: "Playlists", videos: videos))
        }
        let downloads = DownloadStore.shared.entries
        if !downloads.isEmpty {
            shelves.append(Shelf(id: "lib-downloads", title: "Downloads",
                                 videos: downloads.map(\.video)))
        }

        guard selectedRailItem == .library else { return }
        customShelves = shelves
        focus = .card(shelf: 0, index: 0)
        memory = BrowseNavigator.ColumnMemory()
        memory.railItem = .library
    }

    /// Shelves assembled here rather than by BrowseViewModel — Library and the
    /// search-backed categories have no single browse section behind them.
    private var customShelves: [Shelf] = []

    private func loadChannel(_ channelId: String) async {
        guard let (fetched, group) = try? await api.fetchChannel(channelId: channelId),
              selectedRailItem == .channel(channelId) else { return }
        var channel = fetched
        // The WEB browse behind fetchChannel is unauthenticated, so its header
        // never says whether the account follows the channel. The guide does.
        channel.isSubscribed = isSubscribed(toChannel: channel.id) || isSubscribed(toChannel: channelId)
        channelHeader = channel
        memory = BrowseNavigator.ColumnMemory()
        memory.railItem = .channel(channelId)
        channelFeed = Shelf(id: "channel-\(channelId)",
                            title: channel.title,
                            videos: group.videos.deduplicatedByID())
        focus = .card(shelf: 0, index: 0)
        // (A second `memory = ColumnMemory()` used to sit here and undo the
        // `memory.railItem` set above, so Left from a channel's first card opened
        // the guide on Home instead of on the channel being viewed.)
        isRailExpanded = false
    }

    /// Set while a channel from the guide is being shown, which replaces the
    /// browse feed until another guide entry is chosen.
    private var channelFeed: Shelf?

    /// The channel whose page is showing: name, avatar, subscriber count and
    /// whether the account follows it. Nil on every other surface, which is
    /// also what tells `layout` whether a Subscribe button exists to focus.
    private(set) var channelHeader: Channel?

    /// Subscribes or unsubscribes from the channel whose page is showing.
    ///
    /// The button flips immediately and is put back if the request fails: a TV
    /// remote gives no other feedback, and waiting on a round trip before
    /// changing the label reads as a dropped press.
    func toggleSubscription() {
        guard let channel = channelHeader else { return }
        guard auth.isSignedIn else { isSigningIn = true; return }

        let wasSubscribed = channel.isSubscribed
        channelHeader?.isSubscribed = !wasSubscribed

        Task { [api, id = channel.id] in
            do {
                if wasSubscribed { try await api.unsubscribe(channelId: id) }
                else             { try await api.subscribe(channelId: id) }
                await loadGuideChannels()
            } catch {
                guard self.channelHeader?.id == id else { return }
                self.channelHeader?.isSubscribed = wasSubscribed
            }
        }
    }

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
        await pushAuth()
        // BrowseViewModel reloads its content when the token changes.
        await browse.updateAuthToken(auth.accessToken)
        await loadGuideChannels()
    }

    /// The token push alone, without reloading the feed. This is what a
    /// mid-session refresh needs: the same account, a new token, and the user
    /// left exactly where they are on the surface.
    private func pushAuth() async {
        let token = auth.accessToken
        let sapisid = auth.sapisid

        await api.setAuthToken(token)
        await api.setSAPISID(sapisid)
        await VideoPreloadCache.shared.setAuthToken(token)
        await VideoPreloadCache.shared.setSAPISID(sapisid)
        // The cache holds account-bound player responses and tracking URLs.
        // The player evicts them on sign-out too, but only if one is live.
        if token == nil { await VideoPreloadCache.shared.evictAuthSensitiveData() }

        player?.playback.updateAuthToken(token)
        player?.playback.updateSAPISID(sapisid)
    }

    // MARK: - Intents

    func handle(_ intent: NavigationIntent) {
        // Any key press re-anchors the pointer. Expanding the guide shifts the
        // shelves right under a stationary cursor, and SwiftUI then fires
        // `.onHover` for whichever card slid beneath it — which pulled focus
        // straight back out of the guide. Hover only counts once the pointer
        // has physically moved since the last key press.
        pointerAnchor = NSEvent.mouseLocation

        // Sign-in is modal, but it must still hear Back — swallowing every
        // intent here left the screen with no way out.
        if isSigningIn {
            if intent == .back {
                auth.cancelSignIn()
                finishSignIn()
            }
            return
        }

        if let search {
            switch intent.asMove(horizontal: true) {
            case let .move(direction): search.move(direction)
            case .select:
                // Selecting a result plays it; selecting a key types it.
                if let video = search.focusedResult { present(video) } else { search.select() }
            case .back:                closeSearch()
            default:                   break
            }
            return
        }

        if isConfirmingSignOut {
            switch intent {
            case .select: confirmSignOut()
            case .back:   cancelSignOut()
            default:      break   // nothing else is aimable, so nothing else acts
            }
            return
        }

        if let settings {
            switch intent.asMove(horizontal: false) {
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
            moveFocus(to: next)

        case let .tab(forward):
            let next = BrowseNavigator.nextInReadingOrder(from: focus, forward: forward,
                                                          layout: layout, memory: &memory)
            moveFocus(to: next)

        case .select:
            switch focus {
            case let .card(shelf, index):
                if let video = video(shelf: shelf, index: index) { present(video) }
            case .rail(.account):
                if auth.isSignedIn { withAnimation(Theme.stateChange) { isConfirmingSignOut = true } }
                else { isSigningIn = true }
            case let .rail(item):
                open(item)
            case .topBar(.search):
                // Selecting the pill opened nothing at all before; the search
                // surface was reachable only from the guide.
                openSearch()
            case .topBar(.subscribe):
                toggleSubscription()
            }

        case .back:
            // Back was a no-op from the guide and never left a section, so
            // Escape appeared dead once you had opened anything.
            if focus.isInRail {
                // From the guide, back returns to the content behind it.
                withAnimation(Theme.stateChange) {
                    focus = memory.contentFocus ?? BrowseNavigator.defaultContentFocus(layout: layout)
                    isRailExpanded = false
                }
                return
            }

            // From a section, back returns to the one before it.
            if let previous = sectionHistory.popLast() {
                open(previous, recordingHistory: false)
                return
            }

            // From home, back opens the guide — the same affordance as pressing
            // left at the start of a row.
            withAnimation(Theme.stateChange) {
                memory.remember(focus)
                focus = .rail(memory.railItem)
                isRailExpanded = true
            }

        case .menu, .playPause, .seek:
            break
        }
    }

    /// A key- or wheel-driven focus change on the browse surface, with the
    /// prefetching that follows it.
    private func moveFocus(to next: BrowseFocus) {
        guard next != focus else { return }
        withAnimation(Theme.stateChange) {
            focus = next
            isRailExpanded = next.isInRail
        }
        loadMoreIfNearRowEnd()
        prefetchFocusedVideo()
        prefetchThumbnails()
    }

    // MARK: - Pointer

    /// Where the cursor was when focus last moved by key press. Hover events
    /// arriving while the cursor is still there are the content moving under a
    /// still mouse, not the user pointing at something.
    @ObservationIgnored private var pointerAnchor: CGPoint = .zero

    private func pointerHasMoved() -> Bool {
        // A held button is a drag, not pointing. Moving the mouse with the
        // button down streams hover events; each one moved focus, the strip
        // travelled under the still cursor, and the next card's hover moved it
        // again — the page scrolled with the drag like an old browser's
        // autoscroll. Hover-driven focus waits for the button to come up.
        guard NSEvent.pressedMouseButtons == 0 else { return false }
        let now = NSEvent.mouseLocation
        return hypot(now.x - pointerAnchor.x, now.y - pointerAnchor.y) > 2
    }

    // Pointer access to the overlays. Each hovers through the same movement
    // gate the cards use and clicks through the same intent path a Select
    // press takes, so a click can never do something a key press could not.

    func hover(search target: SearchModel.Focus) {
        guard pointerHasMoved() else { return }
        search?.focus(on: target)
    }

    func click(search target: SearchModel.Focus) {
        pointerAnchor = .zero
        search?.focus(on: target)
        handle(.select)
    }

    func hover(settingsRow index: Int) {
        guard pointerHasMoved() else { return }
        settings?.focus(row: index)
    }

    func click(settingsRow index: Int) {
        pointerAnchor = .zero
        settings?.focus(row: index)
        handle(.select)
    }

    func hover(topBar item: TopBarItem) {
        guard pointerHasMoved(), focus != .topBar(item) else { return }
        withAnimation(Theme.stateChange) {
            memory.remember(focus)
            focus = .topBar(item)
            isRailExpanded = false
        }
    }

    func click(topBar item: TopBarItem) {
        pointerAnchor = .zero
        hover(topBar: item)
        focus = .topBar(item)
        handle(.select)
    }


    /// Moving the pointer over a card focuses it, exactly as arrowing onto it
    /// would. Focus stays the single source of truth: the mouse is another way
    /// to move it, never a second selection model running alongside.
    func hover(shelf: Int, index: Int) {
        guard pointerHasMoved() else { return }
        let target = BrowseFocus.card(shelf: shelf, index: index)
        guard focus != target, video(shelf: shelf, index: index) != nil else { return }
        withAnimation(Theme.stateChange) {
            focus = target
            isRailExpanded = false
        }
        prefetchFocusedVideo()
    }

    func hover(rail item: RailItem) {
        guard pointerHasMoved() else { return }
        let target = BrowseFocus.rail(item)
        guard focus != target else { return }
        withAnimation(Theme.stateChange) {
            memory.remember(focus)
            focus = target
            isRailExpanded = true
        }
    }

    /// A click focuses first and then activates, so clicking an unfocused card
    /// cannot play a different video than the one under the pointer.
    func click(shelf: Int, index: Int) {
        pointerAnchor = .zero          // a click is deliberate; never suppress it
        hover(shelf: shelf, index: index)
        if let video = video(shelf: shelf, index: index) { present(video) }
    }

    func confirmSignOut() {
        withAnimation(Theme.stateChange) { isConfirmingSignOut = false }
        guard auth.isSignedIn else { return }
        auth.signOut()
        Task { await applyAuthChange() }
    }

    func cancelSignOut() {
        withAnimation(Theme.stateChange) { isConfirmingSignOut = false }
    }

    func click(rail item: RailItem) {
        pointerAnchor = .zero
        hover(rail: item)
        if case .account = item {
            if auth.isSignedIn { withAnimation(Theme.stateChange) { isConfirmingSignOut = true } }
            else { isSigningIn = true }
            return
        }
        open(item)
    }

    /// Re-clamps focus after the feed changes shape underneath it. Shelves load
    /// asynchronously, so the focused card can be replaced while it is on screen.
    func layoutDidChange() {
        let clamped = BrowseNavigator.clamped(focus, to: layout)
        if clamped != focus { focus = clamped }
        // A freshly loaded shelf has no thumbnails in the cache yet; start on
        // them now rather than when the first card scrolls into view.
        prefetchThumbnails()
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
        let model = PlayerModel(api: api) { [weak self] channelId in
            self?.isSubscribed(toChannel: channelId) ?? false
        }
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
        // The player's Subscribe button writes through the API without
        // touching the guide; pick up any change now.
        Task { await loadGuideChannels() }
    }

    /// Starts resolving the focused video's stream after a short dwell.
    ///
    /// The real client begins an inline preview once focus settles on a card;
    /// this does the half that matters most on a slow path — it gets the player
    /// response, PO token and SponsorBlock segments in flight before Select is
    /// pressed, so opening a video is not a cold start. `VideoPreloadCache`
    /// already does all of this and was simply never being called.
    ///
    /// Debounced, because moving along a row would otherwise fire a /player
    /// request per keypress.
    private func prefetchFocusedVideo() {
        prefetchTask?.cancel()
        guard case let .card(shelf, index) = focus,
              let video = video(shelf: shelf, index: index) else { return }
        let categories = settingsStore.settings.activeSponsorCategories
        let token = auth.accessToken
        prefetchTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await VideoPreloadCache.shared.prefetch(videoId: video.id,
                                                    sponsorCategories: categories,
                                                    authToken: token,
                                                    priority: .visible)
        }
    }

    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    /// Warms thumbnails ahead of the focus.
    ///
    /// Not debounced, and deliberately so: this is what stops a card arriving
    /// from the right with its title up and its picture still downloading, and
    /// a debounce would defeat it exactly when a direction is being held. The
    /// loader already de-duplicates in-flight requests and skips what it has
    /// cached, so repeating the call is cheap.
    private func prefetchThumbnails() {
        guard case let .card(shelf, index) = focus else { return }
        let shelves = shelves
        guard shelves.indices.contains(shelf) else { return }

        var urls: [URL] = shelves[shelf].videos
            .dropFirst(index)
            .prefix(16)
            .compactMap(\.thumbnailURL)

        // A few from the neighbouring rows too, since Down is as likely as Right.
        for neighbour in [shelf - 1, shelf + 1] where shelves.indices.contains(neighbour) {
            urls += shelves[neighbour].videos.prefix(6).compactMap(\.thumbnailURL)
        }

        // Deliberately *not* cancelled between calls.
        //
        // This used to cancel the previous prefetch on every move, which is the
        // reason the picture still lagged the title: holding a direction fires
        // a move every ~150 ms, each one killing the download the last one
        // started, so a thumbnail was never actually finished ahead of the
        // focus. The loader already skips what is cached and joins what is
        // in flight, so letting overlapping calls run costs a dictionary lookup
        // and converges, where cancelling cost the entire feature.
        Task { await ThumbnailLoader.shared.prefetch(urls) }
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
