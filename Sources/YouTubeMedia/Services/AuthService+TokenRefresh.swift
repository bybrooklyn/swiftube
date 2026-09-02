import Foundation
import YouTubeCore

extension AuthService {

    // MARK: - Token refresh

    /// Refreshes the access token, coalescing concurrent callers onto one request.
    ///
    /// `validAccessToken()`, `refreshIfNeeded()` and the proactive timer can all
    /// decide to refresh at the same moment — an expired token at launch does
    /// exactly that, from the feed, the cookie fetch and the user-info fetch.
    /// Each used to POST /token on its own. Google may rotate the refresh token
    /// on use, so the losers of that race could persist a token the server had
    /// just invalidated. One request in flight at a time; everyone else awaits it.
    func refreshAccessToken(refreshToken: String, creds: YouTubeClientCredentials) async throws {
        if let inFlight = refreshInFlight {
            return try await inFlight.value
        }
        let task = Task { try await performRefresh(refreshToken: refreshToken, creds: creds) }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        try await task.value
    }

    private func performRefresh(refreshToken: String, creds: YouTubeClientCredentials) async throws {
        let epoch = authEpoch
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "refresh_token": refreshToken,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "refresh_token",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)

        // The session may have been torn down while this request was in flight
        // (signOut / clearSession / a fresh beginSignIn). Applying the response
        // now would set isSignedIn back to true and persist tokens the user
        // just cleared — the save Task lands on TokenManager after the clear.
        guard epoch == authEpoch else {
            authLog.notice("refreshAccessToken: auth epoch changed mid-flight — discarding response")
            throw AuthError.superseded
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Detect permanent refresh-token failures (revoked, expired, invalid credentials).
        // Google returns HTTP 400/401 with {"error":"invalid_grant"} or "invalid_client".
        // These are unrecoverable — sign out so the user isn't stuck with stale tokens.
        if (statusCode == 400 || statusCode == 401),
           let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauthError = errJson["error"] as? String,
           ["invalid_grant", "invalid_client", "unauthorized_client"].contains(oauthError) {
            authLog.error("refreshAccessToken: permanent failure (\(oauthError)) — signing out")
            signOut()
            throw AuthError.tokenExchangeFailed
        }

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.tokenExchangeFailed }

        accessToken = json["access_token"] as? String
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
        scheduleProactiveRefresh()
    }
}
