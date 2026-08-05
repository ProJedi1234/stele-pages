import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for the bearer-token gate on `POST /pages`.
///
/// Reads stay open by design, so every auth assertion here is about the upload route.
@Suite("Upload authentication")
struct UploadAuthTests {
    @Test func uploadWithoutAuthIs401() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [.contentType: "text/html"],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Missing Authorization header"))
            }
        }
    }

    @Test func uploadWithWrongTokenIs401() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(String(repeating: "w", count: 16))",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Invalid upload token"))
            }
        }
    }

    /// The right credential under the wrong scheme is still no credential — and it is
    /// the invalid-token branch that says so, not some unrelated 401.
    @Test func uploadWithWrongSchemeIs401() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Basic \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Invalid upload token"))
            }
        }
    }

    /// RFC 7235 auth schemes are case-insensitive, and the middleware compares them
    /// lowercased.
    @Test func bearerSchemeIsCaseInsensitive() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "bEaReR \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .created)
            }
        }
    }

    /// The happy path end to end: the JSON payload, the `Location` header, and a
    /// follow-up read that returns the bytes that were uploaded. Every field of the body is
    /// read, including the expiry this upload never asked for — the response has to be
    /// complete for a caller who reads it whole, not merely correct in the fields a test
    /// happens to look at.
    @Test func uploadWithCorrectTokenSucceeds() async throws {
        let uploaded = "<h1>hello stele</h1>"

        try await TestFixture.makeApp().test(.router) { client in
            let slug = try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: uploaded)
            ) { response -> String in
                #expect(response.status == .created)

                let payload = try TestFixture.writeResponse(response.body)
                let slug = try #require(payload["slug"] as? String)
                let url = try #require(payload["url"] as? String)
                #expect(!slug.isEmpty)
                #expect(url == "\(TestFixture.baseURL)/\(slug)")
                #expect(response.headers[.location] == url)
                // No `?ttl=`, so this page carries the default lifetime — non-nil is the
                // assertion, and `PageExpiryTests` is where the instant itself is pinned.
                #expect(try TestFixture.expiry(in: payload) != nil)
                return slug
            }

            try await client.execute(uri: "/\(slug)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == uploaded)
                #expect(response.headers[.contentType] == PageContentType.default)
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
            }
        }
    }
}
