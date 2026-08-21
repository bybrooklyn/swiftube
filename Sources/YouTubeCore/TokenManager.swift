import Foundation

// MARK: - TokenManager
//
// Actor that owns all Keychain storage for OAuth tokens.
//
// AuthService creates and holds a TokenManager, reading initial token state
// via `initialSnapshot` (nonisolated — safe from synchronous init).
// Consumers that want to react to future token changes subscribe to `updates`.
//
// Conservative scope (task #62): AuthService delegates Keychain I/O here but
// still maintains its own @Observable stored vars for UI binding. The
// AsyncStream is available for future consumer migration but not yet consumed
// by InnerTubeAPI / VideoPreloadCache.

public actor TokenManager {

    // MARK: - Types

    public enum Update: Sendable {
        case refreshed(token: String?, expiresAt: Date?)
        case signedOut
    }

    public struct Snapshot: Sendable {
        public let accessToken: String?
        public let refreshToken: String?
        public let tokenExpiry: Date?
        public let accountName: String?
        public let accountAvatarURL: URL?
        /// YouTube.com SAPISID cookie for WEB_CREATOR SAPISIDHASH auth.
        public let sapisid: String?
    }

    // MARK: - State

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var accountName: String?
    private var accountAvatarURL: URL?
    private var sapisid: String?

    private let service: String

    // MARK: - Stream

    private var continuation: AsyncStream<Update>.Continuation?

    /// Subscribe to receive future token updates without polling AuthService.
    /// `nonisolated let` — accessible without `await`, safe cross-actor.
    public nonisolated let updates: AsyncStream<Update>

    // MARK: - Initial snapshot

    /// Snapshot of Keychain values at init time.
    /// `nonisolated let` — AuthService.init() reads this without `await`.
    public nonisolated let initialSnapshot: Snapshot

    // MARK: - Init

    public init(keychainService: String = "com.smarttube.auth") {
        service = keychainService

        var cont: AsyncStream<Update>.Continuation!
        let stream = AsyncStream<Update> { cont = $0 }
        updates = stream
        continuation = cont

        let snap = Snapshot(
            accessToken:     Self.kcGet(service: keychainService, key: "st_access_token"),
            refreshToken:    Self.kcGet(service: keychainService, key: "st_refresh_token"),
            tokenExpiry: {
                guard let s = Self.kcGet(service: keychainService, key: "st_token_expiry")
                else { return nil }
                return ISO8601DateFormatter().date(from: s)
            }(),
            accountName:     Self.kcGet(service: keychainService, key: "st_account_name"),
            accountAvatarURL: Self.kcGet(service: keychainService, key: "st_avatar_url")
                                .flatMap(URL.init(string:)),
            sapisid:         Self.kcGet(service: keychainService, key: "st_sapisid")
        )
        initialSnapshot  = snap
        accessToken      = snap.accessToken
        refreshToken     = snap.refreshToken
        tokenExpiry      = snap.tokenExpiry
        accountName      = snap.accountName
        accountAvatarURL = snap.accountAvatarURL
        sapisid          = snap.sapisid
    }

    // MARK: - Reads

    public func currentAccessToken() -> String?  { accessToken }
    public func currentRefreshToken() -> String? { refreshToken }
    public func currentTokenExpiry() -> Date?    { tokenExpiry }
    public func currentAccountName() -> String?  { accountName }
    public func currentAvatarURL() -> URL?       { accountAvatarURL }
    public func isSignedIn() -> Bool             { accessToken != nil }

    // MARK: - Mutations

    public func setToken(
        access: String?,
        refresh: String?,
        expiry: Date?,
        accountName: String?,
        avatarURL: URL?
    ) {
        self.accessToken      = access
        self.refreshToken     = refresh
        self.tokenExpiry      = expiry
        self.accountName      = accountName
        self.accountAvatarURL = avatarURL
        persistToKeychain()
        continuation?.yield(.refreshed(token: access, expiresAt: expiry))
    }

    /// Persists the SAPISID cookie to Keychain so it survives app restarts and
    /// is available on the next launch without requiring a fresh cookie exchange.
    public func setSAPISID(_ value: String?) {
        sapisid = value
        Self.kcSet(service: service, key: "st_sapisid", value: value)
    }

    public func clearToken() {
        accessToken      = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        sapisid          = nil
        deleteFromKeychain()
        continuation?.yield(.signedOut)
    }

    // MARK: - Private Keychain I/O

    private func persistToKeychain() {
        let fmt = ISO8601DateFormatter()
        Self.kcSet(service: service, key: "st_access_token",  value: accessToken)
        Self.kcSet(service: service, key: "st_refresh_token", value: refreshToken)
        Self.kcSet(service: service, key: "st_token_expiry",  value: tokenExpiry.map { fmt.string(from: $0) })
        Self.kcSet(service: service, key: "st_account_name",  value: accountName)
        Self.kcSet(service: service, key: "st_avatar_url",    value: accountAvatarURL?.absoluteString)
    }

    private func deleteFromKeychain() {
        for key in ["st_access_token", "st_refresh_token", "st_token_expiry",
                    "st_account_name", "st_avatar_url", "st_sapisid"] {
            Self.kcDelete(service: service, key: key)
        }
    }

    // MARK: - Storage
    //
    // A 0600 JSON file under Application Support, deliberately **not** the
    // macOS Keychain.
    //
    // Keychain items are scoped to the signing identity that created them, and
    // this app is signed locally — every rebuild that changes the signature
    // makes macOS treat it as a different app and put up a "YouTube wants to
    // use your login keychain" password prompt. During development that is
    // constant, and a modal SecurityAgent panel blocks the app before its
    // window even appears. A local, personal client is not worth that, so the
    // tokens live in a file the user owns instead.
    //
    // The tradeoff is explicit: file permissions rather than Keychain
    // encryption. Anything with read access to the home directory can read the
    // OAuth token, exactly as it could read a browser's cookie jar.

    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("SwifTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("credentials.json")
    }()

    /// The whole store, read fresh each time. It is a handful of short strings
    /// and is touched only at sign-in, sign-out and launch.
    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }

    private static func save(_ values: [String: String]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        // `.atomic` only. `.completeFileProtection` is an iOS data-protection
        // class; asking for it on macOS makes the write fail, and `try?` would
        // swallow that silently — leaving an empty credentials file and a user
        // who appears signed in until the next launch.
        try? data.write(to: storeURL, options: [.atomic])
        // Owner-only, in case the file predates this attribute.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: storeURL.path)
    }

    private static func kcGet(service: String, key: String) -> String? {
        load()[key]
    }

    private static func kcSet(service: String, key: String, value: String?) {
        var values = load()
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
        save(values)
    }

    private static func kcDelete(service: String, key: String) {
        kcSet(service: service, key: key, value: nil)
    }
}
