import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// Expiry at the HTTP level: what `?ttl=` accepts, what the response says about it, and
/// what a reader gets once a page's deadline has passed.
///
/// The two enforcement layers are tested separately here because they fail separately. A
/// read is correct the moment the deadline passes, whether or not anything has cleaned up;
/// reclamation is about disk and about returning names to the pool, and happens only when
/// somebody uploads. Conflating them is how a suite ends up proving neither.
@Suite("Page expiry")
struct PageExpiryTests {
    /// `publishToken`, not `token`. The shared `STELE_UPLOAD_TOKEN` carries `admin` and
    /// nothing else since per-client credentials landed, so it answers `403` on `/pages` —
    /// every write suite authenticates with the publish-scoped fixture instead.
    static func authorized() -> HTTPFields {
        [.authorization: "Bearer \(TestFixture.publishToken)", .contentType: "text/html"]
    }

    /// POSTs a page and hands back the whole decoded JSON body.
    static func publish(
        client: some TestClientProtocol,
        query: String = "",
        body: String = "<h1>page</h1>"
    ) async throws -> [String: Any] {
        try await client.execute(
            uri: "/\(ServerRoute.pages)\(query)",
            method: .post,
            headers: authorized(),
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .created)
            return try TestFixture.writeResponse(response.body)
        }
    }

    /// Tolerance for an instant the server computed from its own clock. A minute is loose
    /// enough that a slow CI machine and the format's one-second truncation cannot fail it,
    /// and tight enough that every wrong answer worth catching — hours mistaken for days in
    /// the arithmetic, the reference date taken from the epoch, an off-by-one in the day
    /// count — is far outside it. What the tolerance cannot catch is a wrong value for
    /// `secondsPerDay` itself, because the expectations below are derived from that constant
    /// and move with it; `PageLifetimeTests.aDayIsEightySixThousandFourHundredSeconds` is
    /// the one place that pins it to a literal.
    static let tolerance: TimeInterval = 60

    static func expectInstant(_ actual: Date?, roughly expected: Date, _ label: Comment) throws {
        let actual = try #require(actual, label)
        #expect(abs(actual.timeIntervalSince(expected)) < tolerance, label)
    }

    // MARK: - The lifetime a page gets

    /// An upload that says nothing about its lifetime gets one anyway. This is the whole
    /// ephemeral-by-default decision on the wire, and the assertion is against the constant
    /// rather than a literal seven, so the two can never disagree.
    @Test func uploadWithNoTTLExpiresAfterTheDefaultLifetime() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let payload = try await Self.publish(client: client)
            try Self.expectInstant(
                try TestFixture.expiry(in: payload),
                roughly: Date().addingTimeInterval(
                    Double(PageLifetime.defaultDays) * PageLifetime.secondsPerDay
                ),
                "default lifetime"
            )
        }
    }

    /// A day count is honoured as days. The arguments are chosen rather than sampled: `1` is
    /// the value furthest from the default, so a server that ignored `?ttl=` entirely and
    /// reported its own default would fail here rather than pass by coincidence; `30` is an
    /// ordinary two-digit answer, which is what catches a parser that only ever read one
    /// character; and `maxDays` is the ceiling, where the day arithmetic stops being ordinary
    /// and a lifetime a century out is the one most likely to land somewhere strange.
    @Test(arguments: [1, 30, PageLifetime.maxDays])
    func ttlInDaysSetsTheExpiry(days: Int) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let payload = try await Self.publish(
                client: client, query: "?\(PageLifetime.queryParameter)=\(days)"
            )
            try Self.expectInstant(
                try TestFixture.expiry(in: payload),
                roughly: Date().addingTimeInterval(Double(days) * PageLifetime.secondsPerDay),
                "\(days) days"
            )
        }
    }

    /// The opt-out, and the one response shape a synthesised `Encodable` would get wrong:
    /// `expires` must be present and JSON `null`, not missing. An absent key would read as
    /// "this server has no opinion about lifetimes" to a caller who has no other way to ask.
    @Test func ttlNeverReportsAnExplicitNull() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let raw = try await client.execute(
                uri: "/\(ServerRoute.pages)?\(PageLifetime.queryParameter)=\(PageLifetime.neverKeyword)",
                method: .post,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>forever</h1>")
            ) { response -> String in
                #expect(response.status == .created)
                return String(buffer: response.body)
            }

            // The bytes, not the decoded object: `[String: Any]` cannot tell an explicit
            // null from a key that was never written, and the difference is the assertion.
            #expect(raw.contains("\"expires\":null"))
        }
    }

    /// Every malformed value is a `400` and publishes nothing. Silently defaulting any of
    /// these would hand back a `201` and a link the caller never asked for, dying on a date
    /// they never chose.
    ///
    /// `%20` is here for the shape `?ttl=` followed by whitespace; whether the query decoder
    /// hands the router a space or the literal three characters, neither is a lifetime and
    /// both must be refused — which is exactly why the parser neither trims nor tolerates.
    @Test(arguments: ["0", "-1", "7.5", "7d", "abc", "", "%20", "36501", "Never"])
    func malformedTTLIs400(raw: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?\(PageLifetime.queryParameter)=\(raw)",
                method: .post,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>page</h1>")
            ) { response in
                #expect(response.status == .badRequest, "\(raw)")
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("Invalid \(PageLifetime.queryParameter):"), "\(raw)")
                // The refusal names a way forward. A caller at a terminal has nothing else.
                #expect(message.contains(PageLifetime.neverKeyword), "\(raw)")
            }
        }
    }

    /// A bare `?ttl` with no `=` at all. It arrives as an empty value rather than as an
    /// absent parameter, so it must be refused like the other empty forms — a caller who
    /// typed half a lifetime did not mean the default.
    @Test func bareTTLWithNoValueIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?\(PageLifetime.queryParameter)",
                method: .post,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>page</h1>")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    /// The lifetime POST reports is the lifetime POST *stored*.
    ///
    /// Every other assertion here about a newly published page reads `expires` off the `201`,
    /// and the handler builds that field from the same value it hands to `create` — so the
    /// response only ever echoes the parse. Drop the expiry anywhere along
    /// `create` → `insert` → row and every page becomes permanent, nothing is ever reclaimed,
    /// and this suite still passes while the `201` cheerfully reports a deadline nobody
    /// recorded.
    ///
    /// PUT is what closes that loop without adding fake-only surface: it reports the deadline
    /// the *store* handed back and never recomputes one, so a matching instant on the second
    /// request can only have come out of storage.
    @Test(arguments: [
        ("", PageLifetime.defaultDays),
        ("?\(PageLifetime.queryParameter)=1", 1),
    ])
    func theReportedLifetimeIsTheStoredOne(query: String, days: Int) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let created = try await Self.publish(client: client, query: query)
            let slug = try #require(created["slug"] as? String)
            let expected = Date().addingTimeInterval(Double(days) * PageLifetime.secondsPerDay)

            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(slug)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .ok, "\(query)")
                let payload = try TestFixture.writeResponse(response.body)
                try Self.expectInstant(
                    try TestFixture.expiry(in: payload), roughly: expected, "stored \(query)"
                )
            }
        }
    }

    /// A `?ttl=` on PUT is refused, not ignored. A replacement cannot move a deadline, so a
    /// `200` for `?ttl=never` would leave the caller believing they had just made the page
    /// permanent with nothing to tell them otherwise — the same silent default the POST parser
    /// exists to prevent, and worse here because the value is well-formed.
    ///
    /// `30` is in the arguments precisely because it is *valid*: a handler that only rejected
    /// unparseable lifetimes would still swallow the ones a caller actually means.
    ///
    /// The message has to name `PATCH`, and that half is newer than the refusal. This error
    /// used to end "publish again with POST to change it", which was true when a deadline was
    /// fixed at publication and became false the moment `PATCH` shipped — a refusal that
    /// sends a caller to the wrong verb is worse than one that just says no, because they
    /// will follow it. It is the same drift the `--ttl` incident was, in the one place a
    /// caller reads at the terminal.
    @Test(arguments: [PageLifetime.neverKeyword, "30", "banana", ""])
    func ttlOnUpdateIs400(raw: String) async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<h1>original</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(slug.value)?\(PageLifetime.queryParameter)=\(raw)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .badRequest, "\(raw)")
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains(PageLifetime.queryParameter), "\(raw)")
                #expect(message.contains("PATCH /\(ServerRoute.pages)/:slug"), "\(raw)")
                #expect(!message.contains("POST"), "\(raw)")
            }

            // And it wrote nothing on the way to saying so.
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .ok, "\(raw)")
                #expect(String(buffer: response.body) == "<h1>original</h1>", "\(raw)")
            }
        }
    }

    // MARK: - Reading an expired page

    /// The correctness half. A page past its deadline is gone from the read surface
    /// immediately — not when something next gets around to deleting it — and the seeded row
    /// is still physically present, which is what makes this a test of the *read* rather
    /// than of cleanup that happened to have run.
    @Test func anExpiredPageIsNotServed() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(
            slug: slug,
            body: "<h1>gone</h1>",
            expiresAt: Date().addingTimeInterval(-1)
        )

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body) == notFoundPage())
            }
        }

        #expect(await store.storedSlugs.contains(slug))
    }

    /// A page whose deadline is still ahead of it is served normally. Without this the test
    /// above would pass against a store that had simply stopped serving anything with an
    /// expiry at all.
    @Test func aPageInsideItsLifetimeIsStillServed() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "amber-willow-heron")
        let body = "<h1>still here</h1>"
        await store.seed(
            slug: slug,
            body: body,
            expiresAt: Date().addingTimeInterval(PageLifetime.secondsPerDay)
        )

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == body)
            }
        }
    }

    /// A page that is published and then read back inside its own lifetime, through the real
    /// routes and nothing seeded. The default lifetime is a week, so this would only fail if
    /// the expiry were being written or compared in the wrong unit entirely — which is the
    /// mistake that makes every *other* test in this suite pass while the server serves
    /// nothing.
    @Test func aFreshlyPublishedPageIsReadable() async throws {
        let uploaded = "<h1>just published</h1>"

        try await TestFixture.makeApp().test(.router) { client in
            let payload = try await Self.publish(client: client, body: uploaded)
            let slug = try #require(payload["slug"] as? String)

            try await client.execute(uri: "/\(slug)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == uploaded)
            }
        }
    }

    // MARK: - Reclamation

    /// The reclamation half, and the reason the delete runs *before* the insert rather than
    /// after it: the freed name has to be claimable by the very upload that freed it.
    ///
    /// Asserted on `storedSlugs` as well as through the API, because every other observation
    /// this store offers already hides expired rows — a store that reclaimed nothing at all
    /// would satisfy an HTTP-only version of this test right up until the `?slug=` claim.
    @Test func anUploadDeletesExpiredRowsAndFreesTheirSlugs() async throws {
        let store = InMemoryPageStore()
        let dead = try Slug(custom: "quiet-cedar-otter")
        let alive = try Slug(custom: "amber-willow-heron")
        await store.seed(slug: dead, body: "<h1>dead</h1>", expiresAt: Date().addingTimeInterval(-1))
        await store.seed(slug: alive, body: "<h1>alive</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            // The claim would be a 409 against the expired row if the delete ran after the
            // insert, or not at all.
            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=\(dead.value)",
                method: .post,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>reclaimed</h1>")
            ) { response in
                #expect(response.status == .created)
            }

            try await client.execute(uri: "/\(dead.value)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "<h1>reclaimed</h1>")
            }

            // The live page was never in scope for the delete.
            try await client.execute(uri: "/\(alive.value)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "<h1>alive</h1>")
            }
        }

        #expect(await store.storedSlugs == [dead, alive])
    }

    /// The delete is not selective about which expired rows it takes: an upload sweeps every
    /// one, not merely the slug it happened to want. Cleanup that only reclaimed the name
    /// under contention would leave a table that only ever grows.
    @Test func anUploadSweepsEveryExpiredRowNotJustTheOneItNeeds() async throws {
        let store = InMemoryPageStore()
        let past = Date().addingTimeInterval(-1)
        for name in ["quiet-cedar-otter", "amber-willow-heron", "brisk-maple-compass"] {
            await store.seed(slug: try Slug(custom: name), body: "<h1>dead</h1>", expiresAt: past)
        }

        try await TestFixture.makeApp(store: store).test(.router) { client in
            _ = try await Self.publish(client: client)
        }

        // Only the page just published survives — every seeded row is gone.
        #expect(await store.storedSlugs.count == 1)
    }

    // MARK: - Replacement

    /// A PUT reports the stored deadline and does not move it. If replacing a page extended
    /// its life, a link's lifetime would depend on how often somebody happened to edit it,
    /// and "expires in a week" would mean nothing.
    @Test func updateReportsTheStoredExpiryWithoutChangingIt() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        let deadline = Date(timeIntervalSince1970: 4_000_000_000)
        await store.seed(slug: slug, body: "<h1>original</h1>", expiresAt: deadline)

        try await TestFixture.makeApp(store: store).test(.router) { client in
            for _ in 0..<2 {
                try await client.execute(
                    uri: "/\(ServerRoute.pages)/\(slug.value)",
                    method: .put,
                    headers: Self.authorized(),
                    body: ByteBuffer(string: "<h1>replacement</h1>")
                ) { response in
                    #expect(response.status == .ok)
                    let payload = try TestFixture.writeResponse(response.body)
                    // Equal to the seeded instant, and equal again on the second pass: a
                    // deadline that crept forward by one lifetime per edit would still match
                    // "some date in the future" on either pass alone.
                    #expect(try TestFixture.expiry(in: payload) == deadline)
                }
            }
        }
    }

    /// A permanent page's replacement reports `null` rather than omitting the key — the same
    /// contract POST holds to, pinned separately because PUT builds its response from what
    /// the store reported rather than from a lifetime it parsed.
    @Test func updateOfAPermanentPageReportsNull() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<h1>original</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(slug.value)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("\"expires\":null"))
            }
        }
    }

    /// A PUT to an expired-but-unreclaimed page is a `404`, exactly as a GET of it is, and
    /// leaves the dead row alone rather than resurrecting it with a new body. The write
    /// surface and the read surface have to agree about which pages exist, or a page could
    /// be edited and still be unreadable.
    @Test func updateOfAnExpiredPageIs404AndWritesNothing() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        await store.seed(
            slug: slug,
            body: "<h1>dead</h1>",
            expiresAt: Date().addingTimeInterval(-1)
        )

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(slug.value)",
                method: .put,
                headers: Self.authorized(),
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .notFound)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message == "No page exists at \(slug.value).")
            }

            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
