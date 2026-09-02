import Foundation
import Testing
@testable import YouTubeCore

// The three WebView-HLS maps — manifest URL, BotGuard pot= token, and the
// preWarm flag — deliberately survive `consume()` so a re-play skips the 5–9 s
// extraction. But they sat outside LRU eviction entirely: `store` never called
// `touch`, and `touch`'s eviction body never removed from them. Entries expired
// only if something happened to read that same id again, so the maps grew by one
// per video ever seen for the life of the process. The pot= map had no TTL at
// all, and none of the three were cleared on sign-out — so BotGuard tokens minted
// for one account outlived it.
//
// These run against their own cache instance rather than `.shared`, which is what
// makes asserting on eviction and sign-out possible at all.

@Suite("WebView-HLS cache bounds")
struct WKHLSCacheBoundsTests {

    private func url(_ id: String) -> URL {
        URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/\(id)/index.m3u8")!
    }

    @Test("a stored manifest URL is readable back")
    func storeAndRead() async {
        let cache = VideoPreloadCache()
        await cache.store(wkHLSManifestURL: url("aaa"), for: "aaa")
        #expect(await cache.cachedWKHLSURL(for: "aaa") == url("aaa"))
    }

    @Test("the manifest map is bounded — old entries fall out")
    func manifestMapIsBounded() async {
        let cache = VideoPreloadCache()
        let overflow = VideoPreloadCache.maxVideoEntries + 5
        for index in 0..<overflow {
            await cache.store(wkHLSManifestURL: url("v\(index)"), for: "v\(index)")
        }
        // The first ids stored are the least recently touched, so they go first.
        #expect(await cache.cachedWKHLSURL(for: "v0") == nil)
        // …and the most recent survive.
        #expect(await cache.cachedWKHLSURL(for: "v\(overflow - 1)") != nil)
    }

    @Test("the pot= token map is bounded alongside the manifest map")
    func poTokenMapIsBounded() async {
        let cache = VideoPreloadCache()
        let overflow = VideoPreloadCache.maxVideoEntries + 5
        for index in 0..<overflow {
            await cache.store(wkHLSPoToken: "tok\(index)", for: "p\(index)")
        }
        #expect(await cache.cachedPoToken(for: "p0") == nil)
        #expect(await cache.cachedPoToken(for: "p\(overflow - 1)") == "tok\(overflow - 1)")
    }

    @Test("signing out drops the manifest URL")
    func signOutDropsManifest() async {
        let cache = VideoPreloadCache()
        await cache.store(wkHLSManifestURL: url("bbb"), for: "bbb")
        #expect(await cache.cachedWKHLSURL(for: "bbb") != nil)
        await cache.evictAuthSensitiveData()
        #expect(await cache.cachedWKHLSURL(for: "bbb") == nil)
    }

    @Test("signing out drops the BotGuard token minted for the old account")
    func signOutDropsPoToken() async {
        let cache = VideoPreloadCache()
        await cache.store(wkHLSPoToken: "secret", for: "ccc")
        #expect(await cache.cachedPoToken(for: "ccc") == "secret")
        await cache.evictAuthSensitiveData()
        #expect(await cache.cachedPoToken(for: "ccc") == nil)
    }

    @Test("signing out drops the preWarm flag with everything else")
    func signOutDropsPreWarmFlag() async {
        let cache = VideoPreloadCache()
        await cache.store(wkHLSManifestURL: url("ddd"), for: "ddd", isPreWarm: true)
        #expect(await cache.cachedWKHLSIsPreWarm(for: "ddd"))
        await cache.evictAuthSensitiveData()
        #expect(await cache.cachedWKHLSIsPreWarm(for: "ddd") == false)
    }

    @Test("two cache instances do not share state")
    func instancesAreIsolated() async {
        let one = VideoPreloadCache()
        let two = VideoPreloadCache()
        await one.store(wkHLSManifestURL: url("eee"), for: "eee")
        #expect(await one.cachedWKHLSURL(for: "eee") != nil)
        #expect(await two.cachedWKHLSURL(for: "eee") == nil)
    }
}
