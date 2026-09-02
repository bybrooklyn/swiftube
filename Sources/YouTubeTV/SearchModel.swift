import Foundation
import Observation
import YouTubeCore

/// Backs the search surface: an on-screen keyboard on the left, results on the
/// right.
///
/// A TV has no text field, so the keyboard is part of the UI and is navigated
/// with the d-pad like everything else. Focus is a grid position rather than a
/// responder, for the same reason the browse surface uses `BrowseNavigator` —
/// the movement rules need to be explicit and testable.
///
/// Results come in rows, the way the real client groups them: what you have
/// already watched that matches (instant, from the account's history), then
/// channels, then videos.
@MainActor
@Observable
final class SearchModel {

    /// Where focus is on the search surface.
    enum Focus: Equatable {
        case key(Int)
        case result(row: Int, index: Int)
    }

    /// A key on the on-screen keyboard.
    enum Key: Equatable {
        case character(String)
        case space
        case backspace
        case clear
        /// Only on the comment composer's keyboard; search has no submit.
        case submit

        var label: String {
            switch self {
            case let .character(c): c
            case .space:            "space"
            case .backspace:        "delete"
            case .clear:            "clear"
            case .submit:           "post"
            }
        }

        /// The wide keys occupy the whole bottom row, so they get their own span.
        var isWide: Bool {
            if case .character = self { return false }
            return true
        }
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let videos: [Video]
    }

    /// Six columns of letters and digits, then a row of the three wide keys.
    /// Matching the real client's grid matters less than the shape being
    /// predictable: every letter is exactly `columns` apart vertically.
    /// `nonisolated`: the layout and the movement rules below are pure geometry,
    /// not UI state, so they need no main-actor hop and can be tested directly.
    nonisolated static let columns = 6
    nonisolated static let keys: [Key] = {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            .map { Key.character(String($0)) }
        return characters + [.space, .backspace, .clear]
    }()

    private(set) var query = ""
    private(set) var focus: Focus = .key(0)
    private(set) var results: [Video] = []
    private(set) var channelResults: [Video] = []
    private(set) var isSearching = false

    /// The account's watch history, fetched once when search opens, so the
    /// "From your history" row can answer before the network does.
    private var historyVideos: [Video] = []

    private let api: any InnerTubeAPIProtocol
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(api: any InnerTubeAPIProtocol) {
        self.api = api
        Task { [weak self, api] in
            let history = (try? await api.fetchHistory())?.videos ?? []
            self?.historyVideos = history
        }
    }

    // MARK: - Rows

    var rows: [Row] {
        var rows: [Row] = []
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.count >= 2 {
            let local = historyVideos.filter {
                $0.title.localizedCaseInsensitiveContains(text)
                    || $0.channelTitle.localizedCaseInsensitiveContains(text)
            }
            if !local.isEmpty {
                rows.append(Row(id: "history", title: "From your history", videos: Array(local.prefix(12))))
            }
        }
        if !channelResults.isEmpty {
            rows.append(Row(id: "channels", title: "Channels", videos: channelResults))
        }
        if !results.isEmpty {
            rows.append(Row(id: "results", title: "Results", videos: results))
        }
        return rows
    }

    // MARK: - Navigation

    func move(_ direction: MoveDirection) {
        switch focus {
        case let .key(index):
            focus = .key(Self.nextKey(from: index, direction: direction) ?? index)
            // Right off the last column crosses into the results.
            if case .key(let i) = focus, i == index,
               direction == .right, !rows.isEmpty,
               Self.isLastColumn(index) {
                focus = .result(row: 0, index: 0)
            }
        case let .result(row, index):
            let rows = rows
            guard rows.indices.contains(row) else { focus = .key(0); return }
            switch direction {
            case .left:
                if index == 0 { focus = .key(Self.columns - 1) } else { focus = .result(row: row, index: index - 1) }
            case .right:
                focus = .result(row: row, index: min(index + 1, max(rows[row].videos.count - 1, 0)))
            case .up:
                if row > 0 { focus = .result(row: row - 1, index: min(index, rows[row - 1].videos.count - 1)) }
            case .down:
                if row + 1 < rows.count { focus = .result(row: row + 1, index: min(index, rows[row + 1].videos.count - 1)) }
            }
        }
    }

    nonisolated static func isLastColumn(_ index: Int) -> Bool {
        guard index < keys.count, !keys[index].isWide else { return true }
        return index % columns == columns - 1
    }

    /// Pure grid movement over the key list, so it can be tested without a view.
    nonisolated static func nextKey(from index: Int, direction: MoveDirection) -> Int? {
        nextKey(from: index, direction: direction, keys: keys)
    }

    /// The same rules over any key list — the comment composer's keyboard
    /// has the same grid with a different last row.
    nonisolated static func nextKey(from index: Int, direction: MoveDirection, keys: [Key]) -> Int? {
        let wideStart = keys.firstIndex { $0.isWide } ?? keys.count
        let isWide = index >= wideStart

        switch direction {
        case .left:
            return index > 0 ? index - 1 : nil
        case .right:
            if isWide { return index + 1 < keys.count ? index + 1 : nil }
            return (index % columns == columns - 1) ? nil : min(index + 1, keys.count - 1)
        case .up:
            if isWide {
                // Land on the last row of characters, roughly under the key.
                let column = min(index - wideStart, columns - 1)
                return max(wideStart - columns + column, 0)
            }
            return index - columns >= 0 ? index - columns : nil
        case .down:
            if isWide { return nil }
            let below = index + columns
            if below < wideStart { return below }
            // Below the last character row is the wide row.
            let column = index % columns
            return min(wideStart + min(column, keys.count - wideStart - 1), keys.count - 1)
        }
    }

    // MARK: - Editing

    func select() {
        switch focus {
        case let .key(index):
            guard Self.keys.indices.contains(index) else { return }
            apply(Self.keys[index])
        case .result:
            break
        }
    }

    /// A physical keyboard: letters go straight into the query.
    func type(_ text: String) {
        if text == "\u{8}" {
            if !query.isEmpty { query.removeLast() }
        } else {
            query += text
        }
        scheduleSearch()
    }

    /// The video under focus, when focus is in the results.
    var focusedResult: Video? {
        guard case let .result(row, index) = focus else { return nil }
        let rows = rows
        guard rows.indices.contains(row), rows[row].videos.indices.contains(index) else { return nil }
        return rows[row].videos[index]
    }

    private func apply(_ key: Key) {
        switch key {
        case let .character(c): query += c
        case .space:            query += " "
        case .backspace:        if !query.isEmpty { query.removeLast() }
        case .clear:            query = ""
        case .submit:           break   // not on the search keyboard
        }
        scheduleSearch()
    }

    /// Debounced: a TV keyboard produces a keypress per letter, and firing a
    /// search on each one would issue a request per character.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            channelResults = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        isSearching = true
        defer { isSearching = false }
        async let videos = try? api.search(query: text, continuationToken: nil, filter: .default)
        async let channels = try? api.searchChannels(query: text)
        let (group, found) = await (videos, channels)
        guard !Task.isCancelled else { return }
        results = group?.videos ?? []
        channelResults = (found ?? []).map(Video.channelTile)
        if !results.isEmpty { await SearchHistoryStore.shared.add(text) }
        if case let .result(row, index) = focus {
            let rows = rows
            if !rows.indices.contains(row) || !rows[row].videos.indices.contains(index) {
                focus = rows.isEmpty ? .key(0) : .result(row: 0, index: 0)
            }
        }
    }
}

extension Video {
    /// A channel drawn as a card: id is the channel id, and the badge tells
    /// the card and `AppModel.activate` what it is.
    static func channelTile(_ channel: Channel) -> Video {
        Video(id: channel.id,
              title: channel.title,
              channelTitle: channel.subscriberCount ?? "",
              thumbnailURL: channel.thumbnailURL,
              badges: ["CHANNEL"])
    }

    var isChannelTile: Bool { badges.contains("CHANNEL") }
}
