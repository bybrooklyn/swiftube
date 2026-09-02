import SwiftUI

struct RootView: View {

    @State private var model = AppModel()

    var body: some View {
        // One GeometryReader at the root publishes the viewport size; every
        // metric downstream is a fraction of it, so the layout holds its
        // proportions from a small window up to a 4K television.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.canvas.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    TopBar(focus: model.focus,
                           accountAvatarURL: model.auth.accountAvatarURL,
                           isPremium: false)
                    if let channel = model.channelHeader {
                        ChannelHeader(channel: channel,
                                      isFocused: model.focus == .topBar(.subscribe))
                            .padding(.horizontal, Theme.Metrics.contentInset(geo.size))
                            .padding(.bottom, Theme.Metrics.rem(1.25, geo.size))
                            .transition(.opacity)
                    }
                    ShelfListView(model: model)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The guide pushes the content column right rather than
                // covering it — measured as a constant translate, with the
                // cards keeping their size and simply clipping further off the
                // right edge.
                .offset(x: model.isRailExpanded ? Theme.Metrics.guidePush(geo.size) : 0)
                .animation(Theme.travel, value: model.isRailExpanded)

                // The guide floats above the shelves so expanding it covers the
                // content edge rather than reflowing every row.
                GuideRail(items: model.railItems,
                          focus: model.focus,
                          isExpanded: model.isRailExpanded,
                          selected: model.selectedRailItem,
                          channels: model.guideChannels,
                          accountName: model.auth.accountName,
                          accountAvatarURL: model.auth.accountAvatarURL)

                if model.isLoading {
                    loadingState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let empty = model.emptyState {
                    SurfaceMessage(title: empty.title, detail: empty.detail, symbol: empty.symbol)
                }

                if let search = model.search {
                    SearchView(model: search, onBack: { model.closeSearch() })
                        .zIndex(3)
                }

                if let settings = model.settings {
                    SettingsView(model: settings, onBack: { model.closeSettings() })
                        .zIndex(3)
                }

                // Hosted outside the conditional so the dialog's glass
                // materialises in and out rather than cutting (see GlassHost).
                GlassHost {
                    if let cardMenu = model.cardMenu {
                        CardMenuView(model: cardMenu, onBack: { model.closeCardMenu() })
                            .transition(.opacity)
                    }
                    if model.isConfirmingSignOut {
                        ConfirmDialog(
                            title: "Sign out of YouTube?",
                            detail: "Your home feed and subscriptions go back to signed-out, and signing back in means approving a device code again.",
                            symbol: "person.crop.circle.badge.xmark",
                            onCancel: { model.cancelSignOut() }
                        )
                        .transition(Theme.panelTransition)
                    }
                }
                .zIndex(4)

                if model.isSigningIn {
                    SignInView(auth: model.auth) { model.finishSignIn() }
                        .zIndex(2)
                }

                if let player = model.player {
                    TVPlayerView(model: player)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            // Pinned to the window, and clipped.
            //
            // A ZStack takes the size of its largest child, and the shelf rows
            // are deliberately far wider than the window — they are long
            // horizontal strips translated left. Without this the whole root
            // adopted that width, and every full-width child inherited it: the
            // player's scrubber ran past the right edge and its right-hand
            // button cluster was laid out entirely off-screen.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .environment(\.viewportSize, geo.size)
            .environment(\.liquidGlass, model.settingsStore.settings.liquidGlassEnabled)
            // The hidden titlebar still reserves a safe area, which pushed the
            // whole page down by ~34pt. A 10-foot UI owns the entire window.
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tvWindow()
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.layout) { _, _ in model.layoutDidChange() }
    }

    /// Laid out like `SurfaceMessage`, its sibling in the same if/else, so the
    /// two states of an empty surface read as one design.
    private var loadingState: some View {
        GeometryReader { geo in
            VStack(spacing: Theme.Metrics.rem(0.9, geo.size)) {
                LoadingIndicator()
                Text("Loading your feed…")
                    .font(.system(size: Theme.Metrics.rem(1.05, geo.size)))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, Theme.Metrics.contentInset(geo.size))
        }
    }
}
