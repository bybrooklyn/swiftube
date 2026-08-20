import AVFoundation
import os
import YouTubeCore

// MARK: - SponsorBlock (thin wrapper — logic lives in SponsorBlockSkipManager)

extension PlaybackViewModel {

    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        sponsorBlockManager.checkSponsorSkip(at: time)
    }

    public func skipToastSegment() {
        sponsorBlockManager.skipToastSegment()
    }
}
