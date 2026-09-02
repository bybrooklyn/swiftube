import Foundation
import os

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - Social interaction endpoints (like/dislike, next, comments)

extension InnerTubeAPI {

    // MARK: - Like / Dislike

    /// Sends a like for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.LIKE`.
    public func like(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/like", body: body)
    }

    /// Sends a dislike for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.DISLIKE`.
    public func dislike(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/dislike", body: body)
    }

    /// Removes any existing like or dislike for the given video (requires authentication).
    /// Mirrors Android's `LikeDislikePresenter` → `PostVideoAction.REMOVE_LIKE`.
    public func removeLike(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["target"] = ["videoId": videoId]
        _ = try await postTV(endpoint: "like/removelike", body: body)
    }

    /// Adds a video to the authenticated user's Watch Later playlist (id "WL").
    /// Uses the TVHTML5 client's `browse_edit_playlist` endpoint with ACTION_ADD_VIDEO,
    /// mirroring the Android SmartTube `PlaylistPresenter` → `ACTION_ADD_VIDEO` flow.
    /// Requires authentication.
    public func addToWatchLater(videoId: String) async throws {
        try await addToPlaylist(videoId: videoId, playlistId: "WL")
    }

    /// Removes a video from the authenticated user's Watch Later playlist (id \"WL\").
    /// Mirrors `addToWatchLater` but uses `ACTION_REMOVE_VIDEO` + `removedVideoId`.
    /// Requires authentication.
    public func removeFromWatchLater(videoId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["playlistId"] = "WL"
        body["actions"] = [["removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO"]]
        _ = try await postTV(endpoint: "browse/edit_playlist", body: body)
        tubeLog.notice("removeFromWatchLater videoId=\(videoId, privacy: .public)")
    }

    /// Sends a feed feedback signal to YouTube.
    /// Used for "Not interested", "Don't like this video", and "Don't recommend channel" —
    /// all three actions share this endpoint and differ only in their `feedbackToken`.
    /// Tokens are parsed from `videoRenderer.menu.menuRenderer.items` in the feed response.
    /// Requires authentication.
    /// Subscribes the authenticated user to a channel.
    ///
    /// The only write path the ported pipeline was missing: like, dislike and
    /// Watch Later were all here, so this follows their shape exactly —
    /// `postTV` with the TV client context. `channelIds` is an array because
    /// the endpoint accepts several at once, not because we send more than one.
    public func subscribe(channelId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["channelIds"] = [channelId]
        _ = try await postTV(endpoint: "subscription/subscribe", body: body)
    }

    /// Unsubscribes the authenticated user from a channel.
    public func unsubscribe(channelId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["channelIds"] = [channelId]
        _ = try await postTV(endpoint: "subscription/unsubscribe", body: body)
    }

    public func sendFeedback(token: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["feedbackTokens"] = [token]
        _ = try await postTV(endpoint: "feedback", body: body)
        tubeLog.notice("sendFeedback token=\(token.prefix(20), privacy: .public)…")
    }

    /// Sends a feed feedback signal when no pre-fetched token is available.
    ///
    /// The TV client home feed omits per-video feedback menu items, so
    /// `Video.notInterestedToken` / `dontLikeToken` / `hideChannelToken` are `nil`
    /// for authenticated home-feed results. This method fetches the token on-demand
    /// via a WEB client `/next` request for the given video, then calls `sendFeedback`.
    ///
    /// - Parameters:
    ///   - videoId: The YouTube video ID to act on.
    ///   - iconType: The InnerTube icon type string identifying the action:
    ///     `"NOT_INTERESTED"`, `"DISLIKE"`, or `"BLOCK_CHANNEL"`.
    ///
    /// If YouTube's response does not include a matching token, the method returns
    /// silently (it logs a warning but does not throw) so the caller's hide-from-feed
    /// notification can still be posted.
    public func sendFeedbackForVideo(videoId: String, iconType: String) async throws {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let nextData = try await post(endpoint: "next", body: body)
        guard let token = parseFeedbackToken(iconType: iconType, from: nextData) else {
            tubeLog.warning("sendFeedbackForVideo: no \(iconType, privacy: .public) token in /next for videoId=\(videoId, privacy: .public)")
            return
        }
        try await sendFeedback(token: token)
    }

    /// Walks a `/next` (WEB) response and returns the first `feedbackEndpoint` token
    /// whose `menuServiceItemRenderer.icon.iconType` matches `iconType`.
    private func parseFeedbackToken(iconType: String, from json: [String: Any]) -> String? {
        var found: String? = nil
        func walk(_ obj: Any, depth: Int = 0) {
            guard found == nil, depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let svc = dict["menuServiceItemRenderer"] as? [String: Any],
                   let endpoint = svc["serviceEndpoint"] as? [String: Any],
                   let token = (endpoint["feedbackEndpoint"] as? [String: Any])?["feedbackToken"] as? String,
                   let type = (svc["icon"] as? [String: Any])?["iconType"] as? String,
                   type == iconType {
                    found = token
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        return found
    }

    // MARK: - Next (related videos / SuggestionsController equivalent)

    /// Fetches related/suggested videos and the current like status for a video.
    /// When authenticated, uses TVHTML5 on youtubei.googleapis.com so the Bearer
    /// token is accepted and the response includes the user's current like state.
    /// Without auth, falls back to the WEB client (like status will be .none).
    /// Mirrors Android's SuggestionsController + LikeDislikePresenter.
    public func fetchNextInfo(videoId: String) async throws -> NextInfo {
        let isAuth = authToken != nil
        var tvBody = makeBody(client: isAuth ? tvClientContext : webClientContext)
        tvBody["videoId"] = videoId

        if isAuth {
            // TV client (/next) returns like status + related but omits
            // engagementPanels (where chapters live). Make a second sequential
            // WEB /next call to extract chapters — no auth needed.
            // (async let cannot be used here: [String:Any] is not Sendable in Swift 6.)
            var webBody = makeBody(client: webClientContext)
            webBody["videoId"] = videoId
            let tvData  = try await postTV(endpoint: "next", body: tvBody)
            let webData = try await post(endpoint: "next", body: webBody)
            let videos   = parseRelatedVideos(from: webData)   // WEB carries the richer secondary column; TV omits it
            let status   = parseLikeStatus(from: tvData)
            let chapters = parseChapters(from: webData)
            tubeLog.notice("fetchNextInfo (auth) → related=\(videos.count, privacy: .public) chapters=\(chapters.count, privacy: .public)")
            return NextInfo(relatedVideos: videos, likeStatus: status, chapters: chapters)
        } else {
            let data     = try await post(endpoint: "next", body: tvBody)
            let videos   = parseRelatedVideos(from: data)
            let chapters = parseChapters(from: data)
            tubeLog.notice("fetchNextInfo (anon) → related=\(videos.count, privacy: .public) chapters=\(chapters.count, privacy: .public)")
            return NextInfo(relatedVideos: videos, likeStatus: .none, chapters: chapters)
        }
    }

    // MARK: - Comments

    /// Fetches the first page of top-level comments for a video.
    /// Uses the WEB client: calls `/next` with the videoId to extract the
    /// comments continuation token from `engagementPanels`, then fetches comments.
    /// Returns an empty array when comments are disabled or the token is absent.
    public func fetchComments(videoId: String) async throws -> [Comment] {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let nextData = try await post(endpoint: "next", body: body)
        guard let token = parseCommentsContinuationToken(from: nextData) else {
            tubeLog.notice("fetchComments: no comments token for videoId=\(videoId, privacy: .public)")
            return []
        }
        let commentsBody = makeBody(client: webClientContext, continuationToken: token)
        let commentsData = try await post(endpoint: "next", body: commentsBody)
        let comments = parseComments(from: commentsData)
        tubeLog.notice("fetchComments videoId=\(videoId, privacy: .public) → \(comments.count, privacy: .public) comments")
        return comments
    }

    /// Posts a top-level comment. Not upstream.
    ///
    /// A signed-in WEB comments continuation carries the comment box, whose
    /// submit button holds `createCommentParams`; `comment/create_comment`
    /// takes that back with the text. Signed out there is no box, so this
    /// throws `.notAuthenticated` before making a request.
    public func postComment(videoId: String, text: String) async throws {
        guard authToken != nil else { throw APIError.notAuthenticated }
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let nextData = try await post(endpoint: "next", body: body, useAuth: true)
        guard let token = parseCommentsContinuationToken(from: nextData) else {
            throw APIError.unavailable("comments are off for this video")
        }
        let commentsBody = makeBody(client: webClientContext, continuationToken: token)
        let commentsData = try await post(endpoint: "next", body: commentsBody, useAuth: true)
        guard let params = firstString(forKey: "createCommentParams", in: commentsData) else {
            throw APIError.unavailable("no comment box in the response")
        }
        var create = makeBody(client: webClientContext)
        create["createCommentParams"] = params
        create["commentText"] = text
        _ = try await post(endpoint: "comment/create_comment", body: create, useAuth: true)
        tubeLog.notice("postComment videoId=\(videoId, privacy: .public) chars=\(text.count, privacy: .public)")
    }

    /// Depth-first search for the first string stored under `key`.
    private func firstString(forKey key: String, in json: Any, depth: Int = 0) -> String? {
        guard depth < 60 else { return nil }
        if let dict = json as? [String: Any] {
            if let value = dict[key] as? String { return value }
            for value in dict.values {
                if let found = firstString(forKey: key, in: value, depth: depth + 1) { return found }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = firstString(forKey: key, in: item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    // MARK: - Private social parsers

    /// Parses the user's current like/dislike state from a `/next` response.
    ///
    /// Handles two layouts:
    /// - WEB client: `videoPrimaryInfoRenderer.likeStatus` → string "LIKE" / "DISLIKE" / "INDIFFERENT"
    /// - TV/WEB client: `segmentedLikeDislikeButtonRenderer.{like,dislike}Button.toggleButtonRenderer.isToggled`
    private func parseLikeStatus(from json: [String: Any]) -> LikeStatus {
        var found: LikeStatus? = nil
        func walk(_ obj: Any, depth: Int = 0) {
            guard found == nil else { return }
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                // Strategy 1: direct likeStatus string (videoPrimaryInfoRenderer on WEB)
                if let statusStr = dict["likeStatus"] as? String {
                    switch statusStr {
                    case "LIKE":    found = .like
                    case "DISLIKE": found = .dislike
                    default:        found = LikeStatus.none
                    }
                    return
                }
                // Strategy 2: segmentedLikeDislikeButtonRenderer (WEB + TV clients)
                if let seg = dict["segmentedLikeDislikeButtonRenderer"] as? [String: Any] {
                    let liked = (seg["likeButton"] as? [String: Any])
                        .flatMap { $0["toggleButtonRenderer"] as? [String: Any] }
                        .flatMap { $0["isToggled"] as? Bool } ?? false
                    let disliked = (seg["dislikeButton"] as? [String: Any])
                        .flatMap { $0["toggleButtonRenderer"] as? [String: Any] }
                        .flatMap { $0["isToggled"] as? Bool } ?? false
                    found = liked ? .like : disliked ? .dislike : LikeStatus.none
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        tubeLog.notice("parseLikeStatus → \(String(describing: found ?? .none), privacy: .public)")
        return found ?? .none
    }

    /// Parses related / suggested videos from a `/next` response.
    ///
    /// Three shapes, because YouTube migrated the watch page's secondary column
    /// mid-flight and the two clients we ask are on opposite sides of it:
    ///
    /// * `compactVideoRenderer` — the classic WEB shape. Kept because the TV
    ///   client still emits it, and because a WEB response can regress to it.
    /// * `lockupViewModel` — what WEB actually returns now. Verified against a
    ///   live `/next` on 2026-08-21: the response carried **20** `lockupViewModel`
    ///   and **zero** `compactVideoRenderer`, so the old single-shape parser found
    ///   nothing and the up-next rail was empty on every video.
    /// * `shortsLockupViewModel` — related Shorts, which arrive inside a
    ///   `reelShelfRenderer` in the same list. Parsed with `isShort` set so
    ///   `hideShorts` can filter them; dropping them here instead would hide them
    ///   from a caller that wants them.
    ///
    /// Parsers for the latter two already existed for the home feed; this only
    /// reaches them. Results are deduped by video id and kept in document order —
    /// that order is YouTube's ranking, and it is what autoplay walks.
    private func parseRelatedVideos(from json: [String: Any]) -> [Video] {
        var videos: [Video] = []
        var seen: Set<String> = []
        var rendererKeysFound: Set<String> = []

        func append(_ video: Video?) -> Bool {
            guard let video else { return false }
            guard seen.insert(video.id).inserted else { return true }
            videos.append(video)
            return true
        }

        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                // Collect any *Renderer keys for diagnostics
                for k in dict.keys where k.hasSuffix("Renderer") { rendererKeysFound.insert(k) }

                if let r = dict["compactVideoRenderer"] as? [String: Any],
                   append(parseVideoRenderer(r)) {
                    return
                }
                if let r = dict["lockupViewModel"] as? [String: Any],
                   append(parseLockupViewModel(r)) {
                    return
                }
                if let r = dict["shortsLockupViewModel"] as? [String: Any],
                   append(parseShortsLockupViewModel(r)) {
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        tubeLog.notice("[parseRelatedVideos] found=\(videos.count, privacy: .public) rendererKeys=\(rendererKeysFound.sorted().joined(separator: ","), privacy: .public)")
        return Array(videos.prefix(25))
    }

    /// Parses video chapters from a `/next` response.
    /// Chapters live in `engagementPanels[].engagementPanelSectionListRenderer
    ///   .content.macroMarkersListRenderer.contents[].macroMarkersListItemRenderer`.
    /// Each item carries a `title` text object and either
    ///   - `onTap.watchEndpoint.startTimeSeconds` (Int) — preferred, or
    ///   - `timeDescription` text object — fallback (parsed via `parseDuration`).
    private func parseChapters(from json: [String: Any]) -> [Chapter] {
        var chapters: [Chapter] = []
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let renderer = dict["macroMarkersListItemRenderer"] as? [String: Any] {
                    let title = (renderer["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    // startTimeSeconds arrives as Int, Double, or NSNumber depending on
                    // how JSONSerialization bridges the JSON number — handle all three.
                    let startTime: TimeInterval? = {
                        if let watchEndpoint = (renderer["onTap"] as? [String: Any])
                            .flatMap({ $0["watchEndpoint"] as? [String: Any] }) {
                            let raw = watchEndpoint["startTimeSeconds"]
                            if let n = raw as? Int    { return TimeInterval(n) }
                            if let n = raw as? Double { return n }
                            if let n = raw as? NSNumber { return n.doubleValue }
                            if let s = raw as? String { return TimeInterval(s) }
                        }
                        // Fallback: parse the visible time description (e.g. "1:23")
                        return (renderer["timeDescription"] as? [String: Any])
                            .flatMap { extractText($0) }
                            .flatMap { parseDuration($0) }
                    }()
                    if let t = startTime {
                        chapters.append(Chapter(title: title, startTime: t))
                    }
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        return chapters.sorted { $0.startTime < $1.startTime }
    }

    /// Finds the comments continuation token inside the `engagementPanels` of a
    /// `/next` response — looks for the panel whose `panelIdentifier` or header title
    /// contains "comment".
    private func parseCommentsContinuationToken(from json: [String: Any]) -> String? {
        guard let panels = json["engagementPanels"] as? [[String: Any]] else { return nil }
        for panel in panels {
            guard let pslr = panel["engagementPanelSectionListRenderer"] as? [String: Any] else { continue }
            let panelId = pslr["panelIdentifier"] as? String ?? ""
            let headerTitle: String = {
                let header = pslr["header"] as? [String: Any]
                let thr = header?["engagementPanelTitleHeaderRenderer"] as? [String: Any]
                return (thr?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
            }()
            guard panelId.lowercased().contains("comment") || headerTitle.lowercased().contains("comment") else {
                continue
            }
            var found: String? = nil
            func findToken(_ obj: Any, depth: Int = 0) {
                guard found == nil else { return }
                guard depth < 50 else { return }
                if let dict = obj as? [String: Any] {
                    if let contItem = dict["continuationItemRenderer"] as? [String: Any],
                       let endpoint = contItem["continuationEndpoint"] as? [String: Any],
                       let cmd = endpoint["continuationCommand"] as? [String: Any],
                       let t = cmd["token"] as? String {
                        found = t
                        return
                    }
                    for v in dict.values { findToken(v, depth: depth + 1) }
                } else if let arr = obj as? [Any] {
                    for item in arr { findToken(item, depth: depth + 1) }
                }
            }
            findToken(pslr["content"] as Any)
            if let t = found { return t }
        }
        return nil
    }

    /// Parses `commentRenderer` objects from a comments continuation `/next` response.
    private func parseComments(from json: [String: Any]) -> [Comment] {
        var comments: [Comment] = []

        // New entity-based format (YouTube InnerTube v2):
        // frameworkUpdates.entityBatchUpdate.mutations[].payload.commentEntityPayload
        // The comment list in onResponseReceivedEndpoints now holds only `commentViewModel`
        // key-references; the actual data is in entity mutations.
        if let frameworkUpdates = json["frameworkUpdates"] as? [String: Any],
           let entityBatch = frameworkUpdates["entityBatchUpdate"] as? [String: Any],
           let mutations = entityBatch["mutations"] as? [[String: Any]] {
            for mutation in mutations {
                guard let payload = mutation["payload"] as? [String: Any],
                      let cep = payload["commentEntityPayload"] as? [String: Any] else { continue }
                let properties = cep["properties"] as? [String: Any]
                let author     = cep["author"] as? [String: Any]

                let id = properties?["commentId"] as? String ?? UUID().uuidString
                let authorName = author?["displayName"] as? String ?? ""
                let avatarURL = (author?["avatarThumbnailUrl"] as? String).flatMap { URL(string: $0) }
                let text = (properties?["content"] as? [String: Any])?["content"] as? String ?? ""
                let publishedTime = properties?["publishedTime"] as? String ?? ""
                let toolbarState = properties?["toolbarState"] as? [String: Any]
                let likeCount = toolbarState?["likeCountNotliked"] as? String ?? ""
                let isLiked = (toolbarState?["likeState"] as? String) == "LIKE_STATE_LIKED"
                comments.append(Comment(
                    id: id,
                    author: authorName,
                    authorAvatarURL: avatarURL,
                    text: text,
                    likeCount: likeCount,
                    publishedTime: publishedTime,
                    isLiked: isLiked
                ))
            }
            if !comments.isEmpty {
                tubeLog.notice("parseComments: entity format → \(comments.count, privacy: .public) comments")
                return comments
            }
        }

        // Legacy format: commentRenderer nested in the response tree.
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let cr = dict["commentRenderer"] as? [String: Any] {
                    let id = cr["commentId"] as? String ?? UUID().uuidString
                    let author = (cr["authorText"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let avatarURL = ((cr["authorThumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                        .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
                    let text = (cr["contentText"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let likeCount = (cr["voteCount"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let publishedTime = (cr["publishedTimeText"] as? [String: Any]).flatMap { extractText($0) } ?? ""
                    let isLiked = cr["isLiked"] as? Bool ?? false
                    comments.append(Comment(
                        id: id,
                        author: author,
                        authorAvatarURL: avatarURL,
                        text: text,
                        likeCount: likeCount,
                        publishedTime: publishedTime,
                        isLiked: isLiked
                    ))
                    return
                }
                for v in dict.values { walk(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(json)
        if !comments.isEmpty {
            tubeLog.notice("parseComments: legacy commentRenderer format → \(comments.count, privacy: .public) comments")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice("parseComments: 0 comments — top-level keys: \(topKeys, privacy: .public)")
        }
        return comments
    }

    // MARK: - Private: parseVideoRenderer passthrough
    // Social parsers (parseRelatedVideos) call parseVideoRenderer which lives in
    // InnerTubeAPI+VideoRenderers.swift. Because both files declare extensions on the
    // same actor, Swift resolves the call correctly at compile time.
}
