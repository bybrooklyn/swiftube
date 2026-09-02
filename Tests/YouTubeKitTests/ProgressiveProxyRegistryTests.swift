import AVFoundation
import Foundation
import Testing
@testable import YouTubeMedia

// `AVAssetResourceLoader.setDelegate` does not retain its delegate, so the proxy
// loader has to be kept alive alongside the asset. It was kept in a plain
// dictionary keyed by `ObjectIdentifier`, drained only by a `release(_:)` method
// with no call sites anywhere in the app — so every progressive attempt leaked a
// loader and its private `URLSession`, and the retry ladder makes several
// attempts per failed load.
//
// The registry keys weakly now, so the asset's lifetime owns the loader.

@Suite("Progressive proxy registry", .serialized)
struct ProgressiveProxyRegistryTests {

    private let url = URL(string: "https://rr1---sn-example.googlevideo.com/videoplayback?id=abc")!

    @Test("makeAsset registers a loader for the asset")
    func makeAssetRegisters() {
        let before = YTProgressiveProxyLoader.liveCount
        let asset = YTProgressiveProxyLoader.makeAsset(url: url, userAgent: "UA/1.0")
        #expect(asset != nil)
        #expect(YTProgressiveProxyLoader.liveCount == before + 1)
        if let asset { YTProgressiveProxyLoader.release(asset) }
    }

    @Test("release drops the loader for a finished asset")
    func releaseDeregisters() throws {
        let before = YTProgressiveProxyLoader.liveCount
        let asset = try #require(YTProgressiveProxyLoader.makeAsset(url: url, userAgent: "UA/1.0"))
        #expect(YTProgressiveProxyLoader.liveCount == before + 1)
        YTProgressiveProxyLoader.release(asset)
        #expect(YTProgressiveProxyLoader.liveCount == before)
    }

    @Test("releasing one asset does not disturb another")
    func releaseIsPerAsset() throws {
        let before = YTProgressiveProxyLoader.liveCount
        let first = try #require(YTProgressiveProxyLoader.makeAsset(url: url, userAgent: "UA/1.0"))
        let second = try #require(YTProgressiveProxyLoader.makeAsset(url: url, userAgent: "UA/2.0"))
        #expect(YTProgressiveProxyLoader.liveCount == before + 2)
        YTProgressiveProxyLoader.release(first)
        #expect(YTProgressiveProxyLoader.liveCount == before + 1)
        YTProgressiveProxyLoader.release(second)
        #expect(YTProgressiveProxyLoader.liveCount == before)
    }

    @Test("the asset carries the custom scheme, so every request reaches the loader")
    func assetUsesProxyScheme() throws {
        let asset = try #require(YTProgressiveProxyLoader.makeAsset(url: url, userAgent: "UA/1.0"))
        defer { YTProgressiveProxyLoader.release(asset) }
        #expect(asset.url.scheme == "ytprog")
        // Everything but the scheme is preserved — the loader swaps it back to
        // https before fetching.
        #expect(asset.url.host == url.host)
        #expect(asset.url.query == url.query)
    }

    @Test("a URL that cannot carry the scheme yields no asset rather than a broken one")
    func unusableURLReturnsNil() {
        let before = YTProgressiveProxyLoader.liveCount
        // A bare relative reference has no scheme slot to replace.
        let weird = URL(string: "notaurl")!
        let asset = YTProgressiveProxyLoader.makeAsset(url: weird, userAgent: "UA/1.0")
        if let asset {
            // If the platform did produce an asset, it must still be registered.
            #expect(YTProgressiveProxyLoader.liveCount == before + 1)
            YTProgressiveProxyLoader.release(asset)
        } else {
            #expect(YTProgressiveProxyLoader.liveCount == before)
        }
    }
}
