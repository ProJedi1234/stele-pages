import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for `DELETE /pages/:slug`.
///
/// The route unpublishes a page, and the deletion is hard — no tombstone, no reservation.
/// Two properties carry the weight. The slug goes straight back in the pool, which is
/// observable only by claiming it again, so `deletedSlugIsClaimableAgain` pins that the
/// POST path really does treat a deleted name as free rather than 409ing on it. That the
/// *store* frees it is a claim about SQL and not about this seam — the fake's `removeValue`
/// makes it true by construction — and is asserted in
/// `PageStoreDatabaseTests.deleteReportsWhetherARowWasRemoved`. And the failures
/// are *distinguishable*, like PUT's and unlike the public read surface: a repeat delete is
/// a 404 rather than a soothing 204, because everything here is already behind the upload
/// token and a script that deleted a typo would otherwise be told it had succeeded.
@Suite("Delete page")
struct DeletePageTests {
    static let slugName = "quiet-cedar-otter"
    static let original = "<h1>original</h1>"

    /// A store holding one HTML page at `slugName`, which every deletion test starts from
    /// and every rejection test asserts is still readable afterwards.
    static func seededStore() async throws -> InMemoryPageStore {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: slugName), body: original)
        return store
    }

    /// `contentType` defaults to absent because DELETE carries no payload — only the test
    /// that pins the header being ignored has any reason to send one.
    static func authorized(contentType: String? = nil) -> HTTPFields {
        var headers: HTTPFields = [.authorization: "Bearer \(TestFixture.token)"]
        if let contentType { headers[.contentType] = contentType }
        return headers
    }

    /// Asserts the seeded page still reads back as it was stored — `nosniff` included,
    /// this repo's marker for bodies it did not write, since a rejected delete must leave
    /// the page served exactly as it was rather than merely still present.
    static func expectOriginalIntact(_ client: some TestClientProtocol) async throws {
        try await client.execute(uri: "/\(slugName)", method: .get) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == original)
            #expect(response.headers[.contentType] == PageContentType.default)
            #expect(response.headers[.xContentTypeOptions] == "nosniff")
        }
    }

    /// Asserts a read of `slug` gets the uniform 404 page, byte for byte.
    ///
    /// This — not the delete's own status — is what proves a row is gone rather than merely
    /// reported gone, and byte-equality with `notFoundPage()` is what proves the address
    /// rejoined every other miss instead of acquiring a page of its own.
    static func expectNothingPublished(
        _ client: some TestClientProtocol,
        at slug: String
    ) async throws {
        try await client.execute(uri: "/\(slug)", method: .get) { response in
            #expect(response.status == .notFound)
            #expect(response.headers[.contentType] == "text/html; charset=utf-8")
            #expect(String(buffer: response.body) == notFoundPage())
        }
    }

    // MARK: - Authentication

    /// Deletion is registered inside the same token group as POST and PUT, so the
    /// middleware answers before the handler exists. Asserted per verb rather than trusted
    /// from the group's shape: a route added one line outside the group would compile,
    /// serve, and let anyone empty the table.
    @Test func deleteWithoutAuthIs401() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(uri: "/pages/\(Self.slugName)", method: .delete) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Missing Authorization header"))
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    @Test func deleteWithWrongTokenIs401() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .delete,
                headers: [.authorization: "Bearer \(String(repeating: "w", count: 16))"]
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Invalid upload token"))
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    /// Auth runs before slug validation: an anonymous caller learns nothing about which
    /// addresses are even well-formed, because the middleware answers first.
    @Test func unauthenticatedMalformedSlugIs401NotBadRequest() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/pages/abc_def", method: .delete) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - Slug validation

    /// The path slug goes through the same `Slug(custom:)` chokepoint as POST's and PUT's,
    /// and reports the same way. Three characters with an underscore clears the length
    /// rule, so this pins the character rejection specifically.
    @Test func malformedSlugIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages/abc_def",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("Invalid slug:"))
            }
        }
    }

    /// A reserved name is refused as a bad slug rather than 404ing as an absent page.
    /// The distinction matters more here than anywhere else: a 404 would read as "that
    /// page is already gone" about an address the server serves itself.
    @Test func reservedSlugIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages/\(ServerRoute.healthz)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("reserved"))
            }
        }
    }

    // MARK: - Success

    /// The happy path end to end: a 204 with nothing in it, and a read that has rejoined
    /// the uniform 404.
    ///
    /// The empty body and absent `Location` are asserted rather than assumed — POST and PUT
    /// both answer with `{slug, url}`, and the url in that payload would point at what is
    /// now a 404, so a success response that grew one would be handing the caller a dead
    /// link as confirmation.
    ///
    /// `Content-Length` is asserted absent, not zero. RFC 9112 §6.2 forbids the header on a
    /// 204, and Hummingbird adds it unprompted — an empty `ResponseBody` reports a length of
    /// 0 rather than nil — so the handler strips it back off. Nothing about the response is
    /// visibly different if that line is deleted, which is the whole reason this assertion
    /// exists: near every client accepts the malformed form, and the intermediaries that do
    /// not would reject a delete the server had already performed.
    @Test func deleteRemovesThePageAndReturnsNoContent() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .noContent)
                #expect(response.body.readableBytes == 0)
                #expect(response.headers[.location] == nil)
                #expect(response.headers[.contentLength] == nil)
            }

            try await Self.expectNothingPublished(client, at: Self.slugName)
        }
    }

    /// The header the allowlist would reject on a write is simply irrelevant here, and so
    /// is a body far past the configured limit: DELETE stores nothing, so it never calls
    /// `readValidatedPage`. Pinned because the obvious tidy-up — routing all three writes
    /// through the shared reader — would start 415ing and 413ing callers over bytes this
    /// route was never going to look at.
    @Test func deleteIgnoresContentTypeAndBody() async throws {
        let app = try TestFixture.makeApp(
            store: try await Self.seededStore(),
            environment: ["STELE_MAX_PAGE_BYTES": "10"]
        )
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .delete,
                headers: Self.authorized(contentType: "application/json"),
                body: ByteBuffer(string: String(repeating: "x", count: 64))
            ) { response in
                #expect(response.status == .noContent)
            }

            try await Self.expectNothingPublished(client, at: Self.slugName)
        }
    }

    /// The whole observable consequence of the deletion being hard: the name is free again,
    /// so a POST asking for it is a 201 and not the 409 a taken slug earns.
    ///
    /// If this ever becomes a 409, something between the handler and the seam started
    /// keeping the name spent, and every other test in this file would still pass: a soft
    /// delete answers 204 and reads back as a 404 exactly like a hard one. The same shape
    /// of regression a layer down — a `deleted_at` column that `ON CONFLICT DO NOTHING`
    /// then bounces off — is invisible to a fake whose `removeValue` frees the key
    /// regardless, and is caught in `PageStoreDatabaseTests` instead.
    @Test func deletedSlugIsClaimableAgain() async throws {
        let republished = "<h1>second tenant</h1>"

        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/pages?slug=\(Self.slugName)",
                method: .post,
                headers: Self.authorized(contentType: "text/html"),
                body: ByteBuffer(string: republished)
            ) { response in
                #expect(response.status == .created)
                let payload = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: String]
                )
                #expect(payload["slug"] == Self.slugName)
            }

            try await client.execute(uri: "/\(Self.slugName)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == republished)
            }
        }
    }

    // MARK: - Absent pages

    /// Not idempotent, deliberately, and mirroring PUT: the second delete is a 404 with the
    /// same message shape rather than a second 204.
    ///
    /// Idempotence is the conventional choice and is wrong here for the reason every
    /// distinguishable failure behind this token is right — the caller is already
    /// authenticated, so there is no namespace left to leak, and "204" in answer to a
    /// mistyped slug would report success at work that never happened.
    @Test func deletingTwiceIs404TheSecondTime() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/pages/\(Self.slugName)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .notFound)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message == "No page exists at \(Self.slugName).")
            }
        }
    }

    /// A well-formed slug nobody ever published is the same 404 — and the seeded page is
    /// still there afterwards, which is the assertion that would catch a 404 path that had
    /// nonetheless removed a row, whether the wrong one or by matching too loosely.
    @Test func absentSlugIs404AndTouchesNothingElse() async throws {
        let missing = "amber-willow-heron"

        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/pages/\(missing)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .notFound)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message == "No page exists at \(missing).")
            }

            try await Self.expectOriginalIntact(client)
        }
    }

    // MARK: - Trie edges

    /// `DELETE /pages` with no slug segment resolves the literal node, finds no responder
    /// for the method, and gets the framework's 404 — the same answer `PUT /pages` gets.
    /// Pinned because the alternative readings are both live: a collection-level DELETE
    /// that empties the table, or a 401 from a group that started matching the bare
    /// segment. Either would have to come and change this line.
    ///
    /// The neighbouring edge — that an unauthenticated `GET /pages/<anything>` stays a 404
    /// rather than becoming a 401 — is a property of the node itself rather than of any one
    /// verb hung off it, and lives in `NotFoundTests.noAuthLeaksUnderPages`.
    @Test func deletePagesWithoutSlugHasNoResponder() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .delete,
                headers: Self.authorized()
            ) { response in
                #expect(response.status == .notFound)
            }

            try await Self.expectOriginalIntact(client)
        }
    }
}
