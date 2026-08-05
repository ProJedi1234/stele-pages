import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for `PUT /pages/:slug`.
///
/// The route replaces a stored page in place. Two properties carry most of the weight:
/// it is update-only — an absent slug is a 404 and never an implicit create, which is
/// what keeps name-claiming going through POST's collision reporting — and its failures
/// are *distinguishable*, unlike the public read surface, because everything here is
/// already behind the upload token so there is no namespace left to leak.
///
/// The body checks (415/413/400) are the shared ones POST already exercises; they are
/// asserted here only where the ordering against slug validation is the point, or where
/// a rejection has to leave the stored page untouched.
@Suite("Update page")
struct UpdatePageTests {
    static let slugName = "quiet-cedar-otter"
    static let original = "<h1>original</h1>"

    /// A store holding one HTML page at `slugName`, which every replacement test starts
    /// from and every rejection test asserts is still intact afterwards.
    static func seededStore(contentType: String = PageContentType.default) async throws -> InMemoryPageStore {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: slugName), body: original, contentType: contentType)
        return store
    }

    static func authorized(contentType: String? = "text/html") -> HTTPFields {
        var headers: HTTPFields = [.authorization: "Bearer \(TestFixture.token)"]
        if let contentType { headers[.contentType] = contentType }
        return headers
    }

    /// Asserts the seeded page still reads back as it was stored.
    static func expectOriginalIntact(
        _ client: some TestClientProtocol,
        contentType: String = PageContentType.default
    ) async throws {
        try await client.execute(uri: "/\(slugName)", method: .get) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == original)
            #expect(response.headers[.contentType] == contentType)
            #expect(response.headers[.xContentTypeOptions] == "nosniff")
        }
    }

    // MARK: - Authentication

    @Test func updateWithoutAuthIs401() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: [.contentType: "text/html"],
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Missing Authorization header"))
            }
        }
    }

    @Test func updateWithWrongTokenIs401() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: [
                    .authorization: "Bearer \(String(repeating: "w", count: 16))",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Invalid upload token"))
            }
        }
    }

    /// Auth runs before slug validation: an anonymous caller learns nothing about which
    /// addresses are even well-formed, because the middleware answers first.
    @Test func unauthenticatedMalformedSlugIs401NotBadRequest() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages/abc_def",
                method: .put,
                headers: [.contentType: "text/html"],
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - Slug validation

    /// The path slug goes through the same `Slug(custom:)` chokepoint as POST's query
    /// slug, and reports the same way. Three characters with an underscore clears the
    /// length rule, so this pins the character rejection specifically.
    @Test func malformedSlugIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages/abc_def",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("Invalid slug:"))
            }
        }
    }

    /// A reserved name is refused as a bad slug rather than 404ing as an absent page:
    /// behind the token, telling the caller their address can never exist is the useful
    /// answer.
    @Test func reservedSlugIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages/\(ServerRoute.healthz)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("reserved"))
            }
        }
    }

    /// Pins the deliberate divergence from POST: the slug is checked before the body is
    /// looked at, so a request that is wrong in both ways reports the address, not the
    /// payload.
    @Test func malformedSlugBeatsUnsupportedContentType() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages/abc_def",
                method: .put,
                headers: Self.authorized(contentType: "application/json"),
                body: ByteBuffer(string: #"{"hello":"world"}"#)
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("Invalid slug:"))
            }
        }
    }

    // MARK: - Update-only

    /// A well-formed but unpublished slug is a 404, and — the actual point — the follow-up
    /// read still gets the uniform 404 page, proving the PUT created nothing.
    @Test func absentSlugIs404AndCreatesNothing() async throws {
        let missing = "amber-willow-heron"

        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(missing)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .notFound)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message == "No page exists at \(missing).")
            }

            try await client.execute(uri: "/\(missing)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(String(buffer: response.body) == notFoundPage())
            }
        }
    }

    // MARK: - Body validation

    /// The allowlist applies to replacements too — otherwise a page could be re-typed into
    /// something we never agreed to serve. The refusal names what would work, and the
    /// stored page is untouched.
    @Test func disallowedContentTypeIs415AndLeavesPageIntact() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(contentType: "application/json"),
                body: ByteBuffer(string: #"{"hello":"world"}"#)
            ) { response in
                #expect(response.status == .unsupportedMediaType)
                let message = try TestFixture.errorMessage(response.body)
                for allowed in PageContentType.allowed.keys {
                    #expect(message.contains(allowed))
                }
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    @Test func oversizedBodyIs413AndLeavesPageIntact() async throws {
        let app = try TestFixture.makeApp(
            store: try await Self.seededStore(),
            environment: ["STELE_MAX_PAGE_BYTES": "10"]
        )
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: String(repeating: "x", count: 64))
            ) { response in
                #expect(response.status == .contentTooLarge)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("10 byte limit"))
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    /// An empty or non-text replacement is refused rather than blanking a live page —
    /// the failure mode a truncated upload would otherwise have.
    @Test func emptyAndNonUTF8BodiesAre400AndLeavePageIntact() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("empty"))
            }

            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(bytes: [0xFF, 0xFE, 0xFD])
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("UTF-8"))
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    // MARK: - Success

    /// The happy path end to end: a 200 rather than POST's 201, the same `{slug, url}`
    /// body, no `Location` (the caller already addressed the resource), and a read that
    /// returns the new bytes under the new type.
    @Test func updateReplacesBodyAndContentType() async throws {
        let replacement = "# replaced\n\nnew body\n"

        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(contentType: "text/markdown"),
                body: ByteBuffer(string: replacement)
            ) { response in
                // Not `.created`: nothing came into existence here.
                #expect(response.status == .ok)

                // Decoded loosely rather than through a mirror of `PageLocationResponse`:
                // the wire shape is what this test is about.
                let payload = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: String]
                )
                #expect(payload["slug"] == Self.slugName)
                #expect(payload["url"] == "\(TestFixture.baseURL)/\(Self.slugName)")
                #expect(response.headers[.location] == nil)
            }

            try await client.execute(uri: "/\(Self.slugName)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == replacement)
                #expect(response.headers[.contentType] == "text/markdown; charset=utf-8")
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
            }
        }
    }

    /// A replacement with no `Content-Type` keeps the stored type — the caller expressed
    /// no opinion, and defaulting to HTML here would silently re-type a stylesheet into
    /// something browsers refuse under `nosniff`, behind a 200. Seeded as markdown so
    /// inheritance is distinguishable from POST's HTML default.
    @Test func updateWithoutContentTypePreservesStoredType() async throws {
        let store = try await Self.seededStore(contentType: "text/markdown; charset=utf-8")
        let replacement = "# replaced"

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(contentType: nil),
                body: ByteBuffer(string: replacement)
            ) { response in
                #expect(response.status == .ok)
            }

            try await client.execute(uri: "/\(Self.slugName)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == replacement)
                #expect(response.headers[.contentType] == "text/markdown; charset=utf-8")
            }
        }
    }

    /// NUL is well-formed UTF-8 that Postgres `text` cannot store; without an explicit
    /// check it would surface as a database error and a 500. The fake accepts NUL
    /// happily, so this pins the router-level guard, not the store.
    @Test func nulByteInBodyIs400() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(bytes: [0x61, 0x00, 0x62])
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("NUL"))
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    // MARK: - Trie edges

    /// `PUT /pages` with no slug segment has no
    /// responder at all. Pinned so a future routing change that starts answering it —
    /// with an upsert, or with a 401 that distinguishes the path — has to say so here.
    ///
    /// The neighbouring edge — that an unauthenticated `GET /pages/<anything>` stays a 404
    /// rather than becoming a 401 — is a property of the node itself rather than of any one
    /// verb hung off it, and lives in `NotFoundTests.noAuthLeaksUnderPages`.
    @Test func putPagesWithoutSlugHasNoResponder() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
