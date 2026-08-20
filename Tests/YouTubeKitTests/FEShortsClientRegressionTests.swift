import Foundation
import Testing
@testable import YouTubeCore

// MARK: - FEShortsClientRegressionTests
//
// Regression tests for task #96: fetchShorts and fetchShortsMore must use the
// TVHTML5 client context, not the WEB client context, when making authenticated
// InnerTube browse requests.
//
// Root cause: the device-code OAuth token is bound to TVHTML5. When the WEB
// client body is sent with this token, YouTube returns HTTP 400. All other auth
// endpoints correctly use tvClientContext; fetchShorts and fetchShortsMore had
// a regression that switched them to webClientContext, causing Shorts to show
// no videos on cold launch.
//
// These tests intercept the outgoing URLRequest via URLProtocol and verify the
// JSON body contains `"clientName": "TVHTML5"` — not `"WEB"`.

// MARK: - URLProtocol helper

/// Intercepts the first outgoing POST request and captures its JSON body.
/// Returns HTTP 400 so the caller's network path fails fast.
private final class BodyCapturingURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        request.httpMethod == "POST"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession converts httpBody to httpBodyStream before handing the request
        // to URLProtocol; httpBody is always nil here.
        // Only capture the FIRST request — fetchShorts falls back to a second search
        // request when the primary browse fails, and we must not let it overwrite
        // the FEshorts browse body we already captured.
        if BodyCapturingURLProtocol.capturedBody == nil {
            if let stream = request.httpBodyStream {
                stream.open()
                var body = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer {
                    buffer.deallocate()
                    stream.close()
                }
                // Use read-until-zero rather than hasBytesAvailable; the latter
                // can return false prematurely for in-memory streams.
                while true {
                    let count = stream.read(buffer, maxLength: bufferSize)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                BodyCapturingURLProtocol.capturedBody = body
            } else if let bodyData = request.httpBody {
                // Fallback: some configurations pass the body directly in httpBody.
                BodyCapturingURLProtocol.capturedBody = bodyData
            }
        }

        // Reply with a minimal HTTP 400 response so the API call fails fast.
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

@Suite("FEshorts uses TV client — Regression #96", .serialized)
struct FEShortsClientRegressionTests {

    // MARK: - Helpers

    /// Returns an `InnerTubeAPI` wired to `BodyCapturingURLProtocol` via an ephemeral
    /// `URLSession`. This avoids polluting the global URLProtocol registry.
    private func makeTestAPI(authToken: String) -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingURLProtocol.self]
        let session = URLSession(configuration: config)
        return InnerTubeAPI(authToken: authToken, session: session)
    }

    // MARK: - fetchShorts

    /// `fetchShorts()` no longer issues an FEshorts browse at all.
    ///
    /// YouTube deprecated the FEshorts browseId (see the note in
    /// `InnerTubeAPI+Browse.swift`): every client — TV+auth, TV-category and WEB —
    /// started returning HTTP 400, while a home browse with the same token kept
    /// succeeding. The implementation now reaches the Shorts feed by searching
    /// "#shorts" with the short-duration filter, which goes out on the WEB client.
    ///
    /// This test asserted `clientName == "TVHTML5"` and was left behind when that
    /// rewrite landed, so it failed on every run. It now pins the behaviour that
    /// actually ships: the request is a `/search`, not an FEshorts `/browse`.
    /// `fetchShortsMore` below still uses the TV client for postTV continuations,
    /// which is why regression #96 is not simply obsolete.
    @Test("fetchShorts searches instead of browsing FEshorts")
    func fetchShortsUsesSearchNotFEshorts() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        // The call will throw (HTTP 400 from BodyCapturingURLProtocol), which is expected.
        _ = try? await api.fetchShorts()

        let bodyData = try #require(
            BodyCapturingURLProtocol.capturedBody,
            "URLProtocol should have captured the POST body"
        )
        let json = try #require(
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Request body must be valid JSON"
        )

        // A search body carries the query; an FEshorts browse would carry browseId.
        #expect(
            json["query"] as? String == "#shorts",
            "fetchShorts must reach Shorts via a #shorts search. Body keys: \(json.keys.sorted())"
        )
        #expect(
            json["browseId"] == nil,
            "fetchShorts must not send the deprecated FEshorts browseId — YouTube returns HTTP 400 for it."
        )
    }

    @Test("fetchShortsMore sends TVHTML5 clientName")
    func fetchShortsMoreSendsTVClient() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        _ = try? await api.fetchShortsMore(continuationToken: "test-continuation-token-12345")

        let bodyData = try #require(
            BodyCapturingURLProtocol.capturedBody,
            "URLProtocol should have captured the POST body"
        )
        let json = try #require(
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Request body must be valid JSON"
        )

        let context = json["context"] as? [String: Any]
        let clientDict = context?["client"] as? [String: Any]

        #expect(
            clientDict?["clientName"] as? String == "TVHTML5",
            """
            fetchShortsMore must use TVHTML5 client.
            Found clientName=\(String(describing: clientDict?["clientName"]))
            """
        )
        #expect(
            json["continuation"] as? String == "test-continuation-token-12345",
            "fetchShortsMore must forward the continuation token in the body"
        )
    }
}
