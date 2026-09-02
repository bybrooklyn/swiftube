import Foundation

// MARK: - AuthError

public enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case tokenExchangeFailed
    case notSignedIn
    case configurationError
    case deviceCodeRequestFailed
    case authorizationPending
    case slowDown
    case deviceCodeExpired
    /// An in-flight token exchange/refresh was abandoned because the auth
    /// session changed underneath it (sign-out, new sign-in attempt). The
    /// response must not be applied or persisted — persisting it resurrected
    /// credentials the user had just cleared.
    case superseded

    public var errorDescription: String? {
        switch self {
        case .cancelled:              return "Sign-in was cancelled"
        case .missingCode:            return "OAuth code was missing from callback"
        case .tokenExchangeFailed:    return "Failed to exchange code for tokens"
        case .notSignedIn:            return "You are not signed in"
        case .configurationError:     return "OAuth credentials could not be obtained"
        case .deviceCodeRequestFailed:return "Could not start sign-in. Check your internet connection."
        case .authorizationPending:   return "Waiting for authorisation…"
        case .slowDown:               return "Too many requests — slowing down"
        case .deviceCodeExpired:      return "The sign-in code expired. Please try again."
        case .superseded:             return "Sign-in state changed; the pending token was discarded"
        }
    }
}
