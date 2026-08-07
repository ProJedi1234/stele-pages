import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for `PATCH /pages/:slug` — the verb that changes where a page lives and
/// how long it lives, and nothing else.
///
/// It exists because those were the two facts about a page that were fixed at publication: a
/// slug drawn at random could not be traded for a chosen one, and a deadline could not be
/// moved at all. Both are now amendable, and the verb is separate from `PUT` on purpose —
/// `PUT`'s refusal of `?ttl=` is still correct, because a *replacement* still cannot retime a
/// page.
///
/// Three properties carry most of the weight here. A rename is a **move**, so the old name
/// must both 404 and be claimable again — the second is observable only by claiming it, which
/// is what `theFreedNameIsClaimableAgain` does. An amendment must **preserve the page**:
/// body, content type and — where a rename is concerned — the deadline it was already
/// carrying. And the nil in `PageExpiry?` must keep meaning "no instruction": an absent
/// `?ttl=` on this verb must not resolve to the publish default, which is the one mistake
/// that would silently put a week's deadline on a page somebody made permanent.
@Suite("Amend page")
struct AmendPageTests {
    static let slugName = "quiet-cedar-otter"
    static let original = "<h1>original</h1>"

    /// A store holding one permanent HTML page at `slugName`.
    ///
    /// Permanent by default — `seed`'s own default — because it makes the deadline
    /// assertions sharper in both directions: a test that gives the page a deadline is
    /// watching a NULL become a date, and a test that renames it is watching a NULL survive
    /// a move rather than watching one date stay put.
    static func seededStore(
        contentType: String = PageContentType.default,
        expiresAt: Date? = nil
    ) async throws -> InMemoryPageStore {
        let store = InMemoryPageStore()
        await store.seed(
            slug: try Slug(custom: slugName),
            body: original,
            contentType: contentType,
            expiresAt: expiresAt
        )
        return store
    }

    /// `publishToken`, not `token`: this is a write and sits in the `publish`-scoped group,
    /// while the shared `STELE_UPLOAD_TOKEN` carries `admin` alone and earns a `403`.
    static var authorized: HTTPFields {
        [.authorization: "Bearer \(TestFixture.publishToken)"]
    }

    static func amend(
        _ client: some TestClientProtocol,
        slug: String = slugName,
        query: String,
        headers: HTTPFields = authorized
    ) async throws -> (status: HTTPResponse.Status, body: ByteBuffer) {
        try await client.execute(
            uri: "/\(ServerRoute.pages)/\(slug)?\(query)",
            method: .patch,
            headers: headers
        ) { ($0.status, $0.body) }
    }

    /// Asserts the page reads back at `slug` exactly as it was stored.
    static func expectPageServed(
        _ client: some TestClientProtocol,
        at slug: String,
        body: String = original,
        contentType: String = PageContentType.default
    ) async throws {
        try await client.execute(uri: "/\(slug)", method: .get) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == body)
            #expect(response.headers[.contentType] == contentType)
        }
    }

    /// Asserts a read of `slug` gets the uniform 404 page, byte for byte.
    ///
    /// Byte-equality with `notFoundPage()` rather than a status check, for the reason
    /// `DeletePageTests` uses the same helper: it proves the address rejoined every other
    /// miss instead of acquiring a distinguishable response of its own.
    static func expectNothingPublished(
        _ client: some TestClientProtocol,
        at slug: String
    ) async throws {
        try await client.execute(uri: "/\(slug)", method: .get) { response in
            #expect(response.status == .notFound)
            #expect(String(buffer: response.body) == notFoundPage())
        }
    }

    // MARK: - Authentication

    /// Asserted on this verb rather than inferred from the group's shape, exactly as the
    /// other three writes assert it: a route registered one line outside the group would
    /// compile, serve, and let anyone rename or retime any page on the server.
    @Test func amendWithoutAuthIs401() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await client.execute(
                uri: "/\(ServerRoute.pages)/\(Self.slugName)?slug=renamed",
                method: .patch
            ) { (status: $0.status, body: $0.body) }

            #expect(response.status == .unauthorized)
            #expect(String(buffer: response.body).contains("Missing Authorization header"))
            try await Self.expectPageServed(client, at: Self.slugName)
        }
    }

    // MARK: - Renaming

    /// The whole point of the rename, in one test: the page answers at its new name, the old
    /// name answers with the uniform 404, and the response body reports the address the
    /// caller should now use.
    @Test func renamingMovesThePageAndFreesTheOldName() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=q3-report")
            #expect(response.status == .ok)

            let payload = try TestFixture.writeResponse(response.body)
            #expect(payload["slug"] as? String == "q3-report")
            #expect(payload["url"] as? String == "\(TestFixture.baseURL)/q3-report")

            try await Self.expectPageServed(client, at: "q3-report")
            try await Self.expectNothingPublished(client, at: Self.slugName)
        }
    }

    /// The half a 404 cannot show. A rename is a hard move — no tombstone, no reservation —
    /// so the vacated name goes straight back into the pool, and the only way to observe the
    /// difference between "freed" and "merely hidden" is to claim it.
    ///
    /// This is the consequence a caller has to be warned about rather than a convenience:
    /// a link already handed out at the old name can later serve a stranger's page.
    @Test func theFreedNameIsClaimableAgain() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            #expect(try await Self.amend(client, query: "slug=q3-report").status == .ok)

            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=\(Self.slugName)",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>somebody else</h1>")
            ) { #expect($0.status == .created) }

            try await Self.expectPageServed(
                client, at: Self.slugName, body: "<h1>somebody else</h1>"
            )
            // And the renamed page is still where it was moved to, rather than having been
            // overwritten by the claim.
            try await Self.expectPageServed(client, at: "q3-report")
        }
    }

    /// A rename carries the page across intact. The content type is the sharp half: it is
    /// stored per page and never re-derived, so a move that rebuilt the row from defaults
    /// would answer a stylesheet as HTML and break every page linking it, behind a `200`.
    @Test func renamingPreservesTheBodyAndContentType() async throws {
        let store = try await Self.seededStore(contentType: "text/css; charset=utf-8")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            #expect(try await Self.amend(client, query: "slug=theme").status == .ok)

            try await Self.expectPageServed(
                client, at: "theme", contentType: "text/css; charset=utf-8"
            )
        }
    }

    /// A rename that changes no deadline must not invent one. The page here is permanent, and
    /// the failure this guards is the router reaching `PageLifetime(raw: nil)` — whose answer
    /// is seven days — for a request that said nothing about lifetimes at all.
    @Test func renamingAloneDoesNotTouchTheDeadline() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=q3-report")
            #expect(response.status == .ok)

            let payload = try TestFixture.writeResponse(response.body)
            #expect(try TestFixture.expiry(in: payload) == nil)
        }
    }

    /// The same guarantee for a page that has a real deadline: a move must report the stored
    /// instant back unchanged rather than restarting the clock. A rename that reset the
    /// deadline would be a way to extend any page indefinitely by moving it back and forth.
    @Test func renamingCarriesAnExistingDeadlineAcross() async throws {
        let deadline = Date().addingTimeInterval(3 * PageLifetime.secondsPerDay)
        let store = try await Self.seededStore(expiresAt: deadline)

        try await TestFixture.makeApp(store: store).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=q3-report")
            #expect(response.status == .ok)

            let reported = try #require(try TestFixture.expiry(in: TestFixture.writeResponse(response.body)))
            #expect(abs(reported.timeIntervalSince(deadline)) < 1)
        }
    }

    /// Renaming a page to the name it already has is a no-op that succeeds. An UPDATE setting
    /// a row's key to its own value violates no unique index, so this falls out of the SQL
    /// rather than needing a branch — and a store that reported it as a collision would turn
    /// a harmless retry into a `409` naming the caller's own page.
    @Test func renamingToTheCurrentNameIsANoOp() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=\(Self.slugName)")
            #expect(response.status == .ok)

            let payload = try TestFixture.writeResponse(response.body)
            #expect(payload["slug"] as? String == Self.slugName)
            try await Self.expectPageServed(client, at: Self.slugName)
        }
    }

    /// A taken name is a `409` and *both* pages survive. The second half matters more than
    /// the status: a rename that half-applied would destroy the page it collided with, which
    /// is the worst outcome this route can produce and the one no status code would report.
    @Test func renamingOntoATakenNameIs409AndChangesNothing() async throws {
        let store = try await Self.seededStore()
        await store.seed(slug: try Slug(custom: "occupied"), body: "<h1>theirs</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=occupied")
            #expect(response.status == .conflict)
            #expect(try TestFixture.errorMessage(response.body).contains("'occupied' is already taken"))

            try await Self.expectPageServed(client, at: Self.slugName)
            try await Self.expectPageServed(client, at: "occupied", body: "<h1>theirs</h1>")
        }
    }

    /// A name whose page died is claimable by the very request that frees it — the same
    /// reclaim-*before*-write ordering `create` uses, running here through the shared policy
    /// in `PageStoring`'s extension.
    ///
    /// Without it the caller gets a `409` naming a page they cannot fetch, replace or delete,
    /// with nothing they could do to clear it: every other verb calls that row absent.
    @Test func renamingOntoAnExpiredNameSucceeds() async throws {
        let store = try await Self.seededStore()
        await store.seed(
            slug: try Slug(custom: "yesterday"),
            body: "<h1>dead</h1>",
            expiresAt: Date().addingTimeInterval(-60)
        )

        try await TestFixture.makeApp(store: store).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=yesterday")
            #expect(response.status == .ok)

            try await Self.expectPageServed(client, at: "yesterday")
            try await Self.expectNothingPublished(client, at: Self.slugName)
        }
    }

    /// The new name goes through `Slug(custom:)`, so a rename cannot put anything in the
    /// table that a fresh publish would have refused. The reserved case is the one worth
    /// spelling out: `admin` would be shadowed by its own route the moment it was stored, so
    /// it has to be refused at write time rather than accepted and then unreachable.
    @Test(arguments: ["NO-CAPS", "trailing-", "double--hyphen", "ab", "admin", "under_score"])
    func anInvalidNewNameIs400(candidate: String) async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: "slug=\(candidate)")
            #expect(response.status == .badRequest, "\(candidate)")
            #expect(try TestFixture.errorMessage(response.body).contains("Invalid slug"))

            try await Self.expectPageServed(client, at: Self.slugName)
        }
    }

    // MARK: - Retiming

    /// The gap this verb was built for: a deadline that can be moved after publication.
    /// Measured from *now* rather than from `created_at` — `?ttl=30` means thirty more days,
    /// which is the only reading under which amending a page days after publishing it does
    /// what the caller asked.
    @Test func retimingSetsANewDeadlineFromNow() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let before = Date()
            let response = try await Self.amend(client, query: "\(PageLifetime.queryParameter)=30")
            #expect(response.status == .ok)

            let reported = try #require(
                try TestFixture.expiry(in: TestFixture.writeResponse(response.body))
            )
            let expected = before.addingTimeInterval(30 * PageLifetime.secondsPerDay)
            #expect(abs(reported.timeIntervalSince(expected)) < 5)
        }
    }

    /// The opt-out, after the fact. A page with a deadline becomes permanent, and `expires`
    /// comes back as an explicit JSON null — `TestFixture.expiry` fails on an *absent* key, so
    /// this also pins that the caller can tell "never expires" from "no opinion".
    @Test func retimingToNeverMakesAPagePermanent() async throws {
        let store = try await Self.seededStore(
            expiresAt: Date().addingTimeInterval(PageLifetime.secondsPerDay)
        )

        try await TestFixture.makeApp(store: store).test(.router) { client in
            let query = "\(PageLifetime.queryParameter)=\(PageLifetime.neverKeyword)"
            let response = try await Self.amend(client, query: query)
            #expect(response.status == .ok)
            #expect(try TestFixture.expiry(in: TestFixture.writeResponse(response.body)) == nil)
        }
    }

    /// And the other direction, which is the one a single nullable bind would have broken:
    /// giving a deadline back to a page that had none. A store that could only clear the
    /// column would pass every test above and silently ignore this.
    @Test func aPermanentPageCanBeGivenADeadline() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: "\(PageLifetime.queryParameter)=1")
            #expect(response.status == .ok)
            #expect(try TestFixture.expiry(in: TestFixture.writeResponse(response.body)) != nil)
        }
    }

    /// Retiming leaves the page where it is. The mirror of
    /// `renamingAloneDoesNotTouchTheDeadline`, and it guards the same class of bug from the
    /// other side: a `COALESCE` that fell through to a nil slug would move the page to
    /// nowhere.
    @Test func retimingAloneDoesNotMoveThePage() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: "\(PageLifetime.queryParameter)=5")
            #expect(response.status == .ok)
            #expect(try TestFixture.writeResponse(response.body)["slug"] as? String == Self.slugName)

            try await Self.expectPageServed(client, at: Self.slugName)
        }
    }

    /// The grammar is `PageLifetime`'s, unchanged — this verb parses the same parameter with
    /// the same parser, so nothing is silently rounded or defaulted here either. An empty
    /// value is in the list because `?ttl=` with nothing after it is a mistake that must be
    /// reported as one rather than read as "no opinion".
    @Test(arguments: ["0", "-1", "7.5", "", "forever", "\(PageLifetime.maxDays + 1)"])
    func anInvalidLifetimeIs400(candidate: String) async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(
                client, query: "\(PageLifetime.queryParameter)=\(candidate)"
            )
            #expect(response.status == .badRequest, "\(candidate)")
            #expect(
                try TestFixture.errorMessage(response.body)
                    .contains("Invalid \(PageLifetime.queryParameter)")
            )

            try await Self.expectPageServed(client, at: Self.slugName)
        }
    }

    // MARK: - Both at once

    /// One request, both changes, and the response reports both. Worth its own test because
    /// the two travel as separate binds into one statement: a store that applied whichever it
    /// looked at first would pass every single-change test above.
    @Test func aRenameAndARetimeApplyTogether() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let query = "slug=q3-report&\(PageLifetime.queryParameter)=\(PageLifetime.neverKeyword)"
            let response = try await Self.amend(
                client,
                slug: Self.slugName,
                query: query
            )
            #expect(response.status == .ok)

            let payload = try TestFixture.writeResponse(response.body)
            #expect(payload["slug"] as? String == "q3-report")
            #expect(try TestFixture.expiry(in: payload) == nil)

            try await Self.expectPageServed(client, at: "q3-report")
            try await Self.expectNothingPublished(client, at: Self.slugName)
        }
    }

    /// Both are validated before either is applied. A bad lifetime alongside a good rename
    /// must leave the page where it was rather than moving it and then failing — the caller
    /// would be told `400` while holding a URL that had quietly stopped working.
    @Test func aBadLifetimeRejectsTheWholeAmendment() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(
                client, query: "slug=q3-report&\(PageLifetime.queryParameter)=soon"
            )
            #expect(response.status == .badRequest)

            try await Self.expectPageServed(client, at: Self.slugName)
            try await Self.expectNothingPublished(client, at: "q3-report")
        }
    }

    // MARK: - Nothing to do, and nothing there

    /// An amendment that amends nothing is a `400`, not a `200` over an untouched page.
    /// The shape of this mistake is a misspelled parameter — `?tll=30`, `?name=x` — and a
    /// `200` would confirm it as having worked, which is the same silent-default failure the
    /// lifetime parser refuses everywhere else.
    @Test(arguments: ["", "tll=30", "name=q3-report", "expires=never"])
    func anAmendmentThatChangesNothingIs400(query: String) async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, query: query)
            #expect(response.status == .badRequest, "\(query)")
            #expect(try TestFixture.errorMessage(response.body).contains("Nothing to amend"))

            try await Self.expectPageServed(client, at: Self.slugName)
        }
    }

    /// An absent page is a `404`, distinguishable from every other failure — this caller is
    /// already behind the token, so there is nothing left for a precise error to leak.
    @Test func amendingAnAbsentPageIs404() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let response = try await Self.amend(
                client, slug: "amber-willow-heron", query: "slug=q3-report"
            )
            #expect(response.status == .notFound)
            #expect(try TestFixture.errorMessage(response.body).contains("No page exists"))
        }
    }

    /// An expired page cannot be amended back to life. `?ttl=never` on a page whose deadline
    /// has passed is the specific temptation — it looks like a rescue and would be a
    /// resurrection, contradicting the `GET`, `PUT` and `DELETE` that all already call that
    /// row gone.
    @Test(arguments: ["slug=q3-report", "\(PageLifetime.queryParameter)=\(PageLifetime.neverKeyword)"])
    func amendingAnExpiredPageIs404(query: String) async throws {
        let store = try await Self.seededStore(expiresAt: Date().addingTimeInterval(-60))

        try await TestFixture.makeApp(store: store).test(.router) { client in
            let response = try await Self.amend(client, query: query)
            #expect(response.status == .notFound, "\(query)")

            try await Self.expectNothingPublished(client, at: Self.slugName)
            try await Self.expectNothingPublished(client, at: "q3-report")
        }
    }

    /// The address being amended is validated too, and before the page is looked for. A
    /// nonsense path segment is a `400` about the slug rather than a `404` about a page that
    /// could never have existed under that name.
    @Test func anInvalidAddressIs400() async throws {
        try await TestFixture.makeApp(store: try await Self.seededStore()).test(.router) { client in
            let response = try await Self.amend(client, slug: "NO-CAPS", query: "slug=q3-report")
            #expect(response.status == .badRequest)
            #expect(try TestFixture.errorMessage(response.body).contains("Invalid slug"))
        }
    }

    // MARK: - The landing page's index

    /// A rename moves the page's entry in the recently-published list without moving its
    /// *position* in it. `created_at` is untouched, so the page stays exactly where its
    /// publication date puts it.
    ///
    /// This is the one interaction between the two newest features, and it is where the
    /// convenient implementation is wrong: rebuilding the row at its new name is the obvious
    /// way to write a rename, and it silently restamps `created_at` — so a renamed page jumps
    /// to the top of the index and claims to have been published just now. The store's SQL
    /// gets this right for free, since its `UPDATE` never names the column; the in-memory
    /// fake has to be *made* to get it right, which is what this pins.
    @Test func renamingRelabelsTheIndexWithoutReorderingIt() async throws {
        let store = InMemoryPageStore()
        // Not `slugName`: the landing page's own usage prose uses `quiet-cedar-otter` as its
        // worked example, so the "old name is gone" assertion below would match that instead
        // and fail on a page that had been renamed perfectly well.
        let source = "second-cedar-otter"
        // Seeded oldest-first, so the renamed page is deliberately not the newest: a rename
        // that restamped `created_at` would move it from the middle to the top, and only an
        // ordering assertion catches that. A test with one page could not.
        await store.seed(slug: try Slug(custom: "first-cedar-otter"), body: "<p>1</p>")
        await store.seed(slug: try Slug(custom: source), body: Self.original)
        await store.seed(slug: try Slug(custom: "third-cedar-otter"), body: "<p>3</p>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            #expect(try await Self.amend(client, slug: source, query: "slug=q3-report").status == .ok)

            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                let html = String(buffer: response.body)

                #expect(html.contains("<code>q3-report</code>"))
                #expect(!html.contains(source))

                // Still in the middle, where its publication date puts it — newest first.
                let newest = try #require(html.range(of: "third-cedar-otter"))
                let renamed = try #require(html.range(of: "q3-report"))
                let oldest = try #require(html.range(of: "first-cedar-otter"))
                #expect(newest.lowerBound < renamed.lowerBound)
                #expect(renamed.lowerBound < oldest.lowerBound)
            }
        }
    }

    // MARK: - Attribution

    /// An amendment does **not** re-attribute the page, which is the opposite of what `PUT`
    /// does and follows from the same rule: `client_id` records who wrote the bytes currently
    /// being served, and this verb writes no bytes. A page renamed by a second credential is
    /// still the work of the one that published it.
    ///
    /// Attribution is never served, so this reads the store directly — the same reason
    /// `AttributionTests` exists at all.
    @Test func amendingDoesNotReattributeThePage() async throws {
        let store = try await Self.seededStore()
        let clients = InMemoryClientStore()
        let publisher = await clients.seed(
            token: TestFixture.publishToken, name: "claude-code", scopes: [.publish]
        )
        let other = ClientCredential.prefix + "second-credential"
        _ = await clients.seed(token: other, name: "someone-else", scopes: [.publish])

        // Republished through the real route so the page carries a genuine attribution
        // rather than a seeded one.
        try await TestFixture.makeApp(store: store, clients: clients).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(Self.slugName)",
                method: .put,
                headers: [.authorization: "Bearer \(TestFixture.publishToken)", .contentType: "text/html"],
                body: ByteBuffer(string: Self.original)
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(Self.slugName)?slug=q3-report",
                method: .patch,
                headers: [.authorization: "Bearer \(other)"]
            ) { #expect($0.status == .ok) }
        }

        let moved = try #require(await store.fetch(slug: try Slug(custom: "q3-report")))
        #expect(moved.clientID == publisher.id)
    }
}
