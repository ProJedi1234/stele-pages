import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// `pages.client_id` — who wrote the page.
///
/// The column has existed since migration 2 and, until this suite, nothing ever wrote it: a
/// schema that *looked* like it recorded provenance while every row published after the
/// migration was as anonymous as the ones that predate it. That failure is invisible from the
/// HTTP surface — attribution is never served — so it can only be caught by reading the write
/// back out, which is why `Page` carries `clientID` at all.
///
/// The suite drives the real routes against the in-memory store, so what is under test is the
/// threading: the authenticated credential on the context reaching the storage primitive with
/// the right value, including the nil that the synthesised shared-token credential has to
/// become.
@Suite("Attribution")
struct AttributionTests {
    static let page = ByteBuffer(string: "<h1>hi</h1>")

    static func headers(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "text/html"]
    }

    /// The straightforward half: a page published through `POST /pages` records the id of the
    /// credential that published it. Asserted against the *seeded* credential's id rather than
    /// a literal, so a fake that numbered its rows differently could not make this pass by
    /// coincidence.
    @Test func publishingRecordsTheCredentialThatWroteThePage() async throws {
        let store = InMemoryPageStore()
        let clients = InMemoryClientStore()
        let credential = await clients.seed(
            token: TestFixture.publishToken, name: "claude-code", scopes: [.publish]
        )

        try await TestFixture.makeApp(store: store, clients: clients).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=my-page",
                method: .post,
                headers: Self.headers(TestFixture.publishToken),
                body: Self.page
            ) { #expect($0.status == .created) }
        }

        let stored = try #require(await store.fetch(slug: try Slug(custom: "my-page")))
        #expect(stored.clientID == credential.id)
        // And not the sentinel that would be a dangling foreign key against real Postgres.
        #expect(stored.clientID != Client.sharedToken.id)
    }

    /// A generated slug takes the same path through `create`'s retry loop, and the loop is
    /// shared code every conformer runs — so an attribution threaded only through the
    /// requested-slug branch would leave every ordinary publish anonymous. The slug is read
    /// out of the response because nothing else knows what it is.
    @Test func aGeneratedSlugIsAttributedTheSameWay() async throws {
        let store = InMemoryPageStore()
        let clients = InMemoryClientStore()
        let credential = await clients.seed(token: TestFixture.publishToken, name: "claude-code")

        let slug = try await TestFixture.makeApp(store: store, clients: clients)
            .test(.router) { client -> String in
                try await client.execute(
                    uri: "/\(ServerRoute.pages)",
                    method: .post,
                    headers: Self.headers(TestFixture.publishToken),
                    body: Self.page
                ) { response in
                    #expect(response.status == .created)
                    let payload = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                    return try #require((payload as? [String: String])?["slug"])
                }
            }

        let stored = try #require(await store.fetch(slug: try Slug(custom: slug)))
        #expect(stored.clientID == credential.id)
    }

    /// Provenance follows the bytes. A `PUT` from a second credential re-attributes the page,
    /// because the column answers "who wrote what is being served" — and a page still credited
    /// to the credential that wrote the *previous* body is a record that reads as true and is
    /// not.
    @Test func updatingReattributesThePage() async throws {
        let store = InMemoryPageStore()
        let clients = InMemoryClientStore()
        let first = await clients.seed(token: TestFixture.publishToken, name: "first")
        let second = await clients.seed(token: "stele_pat_second", name: "second")

        try await TestFixture.makeApp(store: store, clients: clients).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=my-page",
                method: .post,
                headers: Self.headers(TestFixture.publishToken),
                body: Self.page
            ) { #expect($0.status == .created) }

            try await client.execute(
                uri: "/\(ServerRoute.pages)/my-page",
                method: .put,
                headers: Self.headers("stele_pat_second"),
                body: ByteBuffer(string: "<h1>replaced</h1>")
            ) { #expect($0.status == .ok) }
        }

        let stored = try #require(await store.fetch(slug: try Slug(custom: "my-page")))
        #expect(first.id != second.id)
        #expect(stored.clientID == second.id)
        #expect(stored.body == "<h1>replaced</h1>")
    }

    /// The one credential with nothing to attribute to. `Client.sharedToken` is synthesised
    /// rather than stored, so its `id` refers to no row and `pages.client_id` is a foreign
    /// key — writing the 0 would fail every publish against real Postgres, where the fake
    /// would happily keep it. Driven through the store rather than over HTTP because the
    /// shared token is `admin`-only and is refused by the write routes long before it reaches
    /// a store; the mapping still has to be right, because it is what would break first if
    /// that ever changed.
    @Test func theSharedTokenIsWrittenAsNoOwnerAtAll() async throws {
        #expect(Client.sharedToken.attributableID == nil)

        let store = InMemoryPageStore()
        let slug = try await store.create(
            requestedSlug: try Slug(custom: "orphan-page"),
            body: "<h1>hi</h1>",
            contentType: PageContentType.default,
            clientID: Client.sharedToken.attributableID,
            generator: SlugGenerator(wordCount: 3)
        )

        let stored = try #require(await store.fetch(slug: slug))
        #expect(stored.clientID == nil)

        // And an update by the same credential clears rather than preserves: the bytes it
        // just wrote have no honest owner either.
        _ = try await store.update(
            slug: slug, body: "<h1>replaced</h1>", contentType: nil, clientID: 7
        )
        #expect(try await store.fetch(slug: slug)?.clientID == 7)
        _ = try await store.update(
            slug: slug,
            body: "<h1>again</h1>",
            contentType: nil,
            clientID: Client.sharedToken.attributableID
        )
        #expect(try await store.fetch(slug: slug)?.clientID == nil)
    }

    /// Every stored credential attributes as itself; only the synthesised one is nil. Written
    /// as its own assertion because `attributableID` is the whole rule — one comparison, in
    /// one place, that both write routes depend on — and a version of it that returned nil for
    /// everything would pass no test above except by accident of the ids involved.
    @Test func onlyTheSynthesisedCredentialHasNoAttributableID() async throws {
        let clients = InMemoryClientStore()
        let credential = await clients.seed(token: TestFixture.publishToken, name: "claude-code")
        #expect(credential.attributableID == credential.id)
        #expect(credential.attributableID != nil)
        #expect(Client.sharedToken.attributableID == nil)
    }
}
