import Foundation
import Testing
@testable import YouTubeMedia
@testable import YouTubeCore

// State invariants around the retry ladder and the history stack that need no
// network: the probe path with an unknown method fails synchronously, which
// makes `exhaustiveRetry` a fast, deterministic call.

@MainActor
@Suite("Playback retry and history state")
struct PlaybackRetryStateTests {

    private func video(_ id: String) -> Video { Video(id: id, title: id, channelTitle: "Ch") }

    @Test("exhaustiveRetryTask is released when the ladder finishes")
    func retryTaskReleased() async {
        StreamMethodProbeSupport.forcedStreamMethod = "no-such-method"
        defer { StreamMethodProbeSupport.forcedStreamMethod = nil }

        let vm = PlaybackViewModel()
        let v = video("v1")
        vm.exhaustiveRetryTask = Task { await vm.exhaustiveRetry(video: v, originalError: nil) }
        await vm.exhaustiveRetryTask?.value
        #expect(vm.exhaustiveRetryTask == nil, "a finished ladder must clear its own handle")
        #expect(vm.error != nil)
        #expect(vm.isLoading == false)
    }

    @Test("a cancelled ladder does not clear the task that replaced it")
    func cancelledRetryLeavesReplacement() async {
        StreamMethodProbeSupport.forcedStreamMethod = "no-such-method"
        defer { StreamMethodProbeSupport.forcedStreamMethod = nil }

        let vm = PlaybackViewModel()
        let v = video("v1")
        let first = Task { await vm.exhaustiveRetry(video: v, originalError: nil) }
        first.cancel()
        let replacement: Task<Void, Never> = Task { try? await Task.sleep(for: .seconds(30)) }
        vm.exhaustiveRetryTask = replacement
        await first.value
        #expect(vm.exhaustiveRetryTask != nil, "the cancelled run must not nil out its successor")
        replacement.cancel()
        vm.exhaustiveRetryTask = nil
    }

    @Test("Previous walks back through history instead of ping-ponging")
    func previousWalksBack() {
        let vm = PlaybackViewModel()
        vm.history = [video("a"), video("b")]
        vm.currentVideo = video("c")
        vm.hasPrevious = true

        vm.playPrevious()
        #expect(vm.currentVideo?.id == "b")
        #expect(vm.history.map(\.id) == ["a"], "the video being left must not be pushed back")
        #expect(vm.hasPrevious)

        vm.playPrevious()
        #expect(vm.currentVideo?.id == "a")
        #expect(vm.history.isEmpty)
        #expect(!vm.hasPrevious)

        // An ordinary load still records where it came from.
        vm.load(video: video("d"))
        #expect(vm.history.map(\.id) == ["a"])
        vm.stop()
    }
}
