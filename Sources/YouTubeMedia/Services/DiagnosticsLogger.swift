import Foundation
import os
import YouTubeCore

/// Structured logging for the media stack.
///
/// Upstream (SmartTubeIOS) forwarded these entries to Firebase Crashlytics as
/// breadcrumbs. This build has no Firebase dependency — a TV app installed from
/// a local build has nobody to report crashes to — so everything lands in
/// `os.Logger` instead, where `log stream --predicate 'subsystem == "…"'` can
/// read it. The API surface is kept identical to upstream's `DiagnosticsLogger`
/// so the ~19 call sites across the playback pipeline read the same, and so
/// upstream fixes touching those lines still cherry-pick cleanly.
struct DiagnosticsLogger: Sendable {

    /// Short identifier (8 hex chars) generated once per app session.
    /// Displayed in the Stats for Nerds overlay so a session's logs can be
    /// correlated when describing an issue.
    static let sessionReportID: String = {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return String(raw.prefix(8)).uppercased()
    }()

    private let logger: Logger
    private let category: String

    init(subsystem: String = appSubsystem, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    // Each body evaluates the autoclosure into a local before interpolating.
    // os.Logger's interpolation is itself an *escaping* autoclosure, and an
    // escaping autoclosure may not capture a non-escaping parameter.
    func notice(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
    }

    func debug(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
    }

    func recordNonFatal(_ error: Error, userInfo: [String: String] = [:]) {
        let nsError = error as NSError
        var msg = "[\(category)] \(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
        if !userInfo.isEmpty {
            let pairs = userInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            msg += " {" + pairs.joined(separator: " ") + "}"
        }
        logger.error("\(msg, privacy: .public)")
    }

    // MARK: - Session context

    private static let context = Logger(subsystem: appSubsystem, category: "Context")

    static func setVideoContext(id: String, title: String) {
        context.notice("[Video] active id=\(id, privacy: .public) title=\(title.prefix(60), privacy: .public)")
    }

    static func setIntendedVideo(id: String, title: String) {
        context.notice("[Video] intended id=\(id, privacy: .public) title=\(title.prefix(60), privacy: .public)")
    }

    // MARK: - Diagnostics

    static func sendDiagnosticReport() {
        context.notice("[Diagnostic] user-triggered report \(sessionReportID, privacy: .public)")
    }

    /// Logged when time-to-first-frame exceeds 4 seconds, tagged with the stream
    /// type and elapsed ms so slow loads can be correlated with the fallback path
    /// that produced them.
    static func recordSlowVideoLoad(
        videoId: String,
        elapsedMs: Int,
        streamType: String,
        hasError: Bool,
        errorDescription: String? = nil
    ) {
        var msg = "[SlowLoad] videoId=\(videoId) ttff=\(elapsedMs)ms stream=\(streamType) hasError=\(hasError)"
        if let desc = errorDescription { msg += " err=\(desc)" }
        context.error("\(msg, privacy: .public)")
    }

    static func sendAutoPlaybackDiagnostic() {
        context.error("[AutoDiagnostic] Playback failure — see preceding breadcrumbs.")
    }

    /// Logged when the video that reached `readyToPlay` is not the video the user
    /// asked for. Upstream tracked this as a distinct issue class because it was a
    /// recurring regression; keeping the log line keeps it greppable here too.
    static func sendWrongVideoReport(
        intendedId: String,
        intendedTitle: String,
        activeId: String,
        activeTitle: String
    ) {
        let msg = "[WrongVideo] intended=\(intendedId) (\(intendedTitle.prefix(60))) active=\(activeId) (\(activeTitle.prefix(60)))"
        Logger(subsystem: appSubsystem, category: "WrongVideo").error("\(msg, privacy: .public)")
    }
}
