import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The health probe and the landing page. Both run through `buildRouter` in `.router` mode,
/// so there is no socket and no database — only the routing, the status, the headers we
/// promise, and the index the landing page now renders out of the in-memory fake.
@Suite("Health and landing")
struct HealthAndLandingTests {
    @Test func healthzReturnsOK() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.healthz)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    /// The landing page interpolates the configured base URL into its curl example, so
    /// this pins that flow-through as well as the content type. It deliberately does not
    /// carry `nosniff`: that header is for stored pages, whose bodies we didn't write.
    @Test func landingPageIsHTML() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(String(buffer: response.body)
                    .contains("\(TestFixture.baseURL)/\(ServerRoute.pages)"))
                #expect(response.headers[.xContentTypeOptions] == nil)
            }
        }
    }

    /// The skill is only discoverable if something points at it — a human reading the
    /// landing page is how an agent gets told to fetch it in the first place. The href is
    /// written longhand rather than interpolated from `PublishSkill.path`, for the same
    /// reason `StylesheetTests` writes its URI out: a rename is a breaking change to a
    /// published address and has to be visible here as one.
    @Test func landingPageLinksTheSkill() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("href=\"/skill\""))
            }
        }
    }

    /// The index lists live pages, newest first, and links each one at its own address.
    ///
    /// The ordering assertion is on the *positions* of the slugs in the rendered document
    /// rather than on a parse of the table, because the order is the only thing being
    /// checked and any parser here would be a second implementation of the renderer.
    @Test func theIndexListsLivePagesNewestFirst() async throws {
        let store = InMemoryPageStore()
        // Seeded in publication order: the fake stamps each one a tick later than the last.
        await store.seed(slug: try Slug(custom: "first-cedar-otter"), body: "<p>1</p>")
        await store.seed(slug: try Slug(custom: "second-cedar-otter"), body: "<p>2</p>")
        await store.seed(slug: try Slug(custom: "third-cedar-otter"), body: "<p>3</p>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                let html = String(buffer: response.body)

                #expect(html.contains("<a href=\"/third-cedar-otter\">"))
                #expect(html.contains("<code>third-cedar-otter</code>"))

                let third = try #require(html.range(of: "third-cedar-otter"))
                let second = try #require(html.range(of: "second-cedar-otter"))
                let first = try #require(html.range(of: "first-cedar-otter"))
                #expect(third.lowerBound < second.lowerBound)
                #expect(second.lowerBound < first.lowerBound)
            }
        }
    }

    /// The assertion this whole feature has to earn: an expired page is absent from the index.
    ///
    /// It is not a tidiness rule. Every other 404 on the read surface is byte-identical
    /// precisely so a scanner cannot learn that a name *used to* be a page — and an index that
    /// listed expired rows would publish exactly that, in a table, sorted. The live page is
    /// seeded alongside so a renderer that dropped the index entirely cannot pass this.
    @Test func theIndexHidesExpiredPages() async throws {
        let store = InMemoryPageStore()
        await store.seed(
            slug: try Slug(custom: "gone-cedar-otter"),
            body: "<p>gone</p>",
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        await store.seed(slug: try Slug(custom: "here-cedar-otter"), body: "<p>here</p>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let html = String(buffer: response.body)
                #expect(html.contains("here-cedar-otter"))
                #expect(!html.contains("gone-cedar-otter"))
            }
        }
    }

    /// A permanent page reads "never" as plain text, and a page with a deadline gets a
    /// `<time>` carrying the exact instant behind the coarse label.
    ///
    /// The negative half is the point: "never" must not be wrapped in a `<time>`, because the
    /// only `datetime` such an element could carry is a fabricated far-future instant, and
    /// every machine reading the attribute rather than the text would be told a lie.
    @Test func lifetimesAreReportedInTheIndex() async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "forever-cedar-otter"), body: "<p>x</p>")
        await store.seed(
            slug: try Slug(custom: "fleeting-cedar-otter"),
            body: "<p>y</p>",
            expiresAt: Date().addingTimeInterval(6 * 24 * 60 * 60)
        )

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let html = String(buffer: response.body)
                #expect(html.contains(">never</td>") || html.contains("\">never<"))
                #expect(html.contains("in 5d") || html.contains("in 6d"))
                // The exact instant survives the coarse label, in a machine-readable form.
                #expect(html.contains("<time datetime=\""))
            }
        }
    }

    /// A non-HTML page is badged with its subtype; an HTML one is not.
    @Test func theIndexBadgesNonHTMLPages() async throws {
        let store = InMemoryPageStore()
        await store.seed(
            slug: try Slug(custom: "sheet-cedar-otter"),
            body: "p{}",
            contentType: "text/css; charset=utf-8"
        )
        await store.seed(slug: try Slug(custom: "plain-cedar-otter"), body: "<p>x</p>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let html = String(buffer: response.body)
                #expect(html.contains("<span class=\"badge\">CSS</span>"))
                #expect(!html.contains("<span class=\"badge\">HTML</span>"))
            }
        }
    }

    /// An empty server says so, and says it differently from a broken one.
    @Test func anEmptyServerSaysNothingIsPublished() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Nothing published yet."))
            }
        }
    }

    /// A store that cannot be read degrades the index and keeps the page.
    ///
    /// The status matters as much as the copy: the rest of this document is how-to-publish
    /// documentation that is still true while Postgres is down, and answering `500` would
    /// withhold a working answer because an unrelated table could not be listed. The "nothing
    /// published" wording is asserted *absent* — an empty list is a fact about the server, and
    /// a server that cannot see its own table does not have that fact.
    @Test func anUnreadableStoreDegradesTheIndexRatherThanThePage() async throws {
        let store = InMemoryPageStore(failRecent: true)

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                let html = String(buffer: response.body)
                #expect(html.contains("The index is unavailable right now."))
                #expect(!html.contains("Nothing published yet."))
                // The documentation the page exists for is still there.
                #expect(html.contains("\(TestFixture.baseURL)/\(ServerRoute.pages)"))
            }
        }
    }

    /// The index stops at `recentPageCount`, and stops at the *newest* that many.
    @Test func theIndexIsCappedAtTheNewestPages() async throws {
        let store = InMemoryPageStore()
        for index in 0..<(recentPageCount + 5) {
            await store.seed(slug: try Slug(custom: "page-\(index)-otter"), body: "<p>x</p>")
        }

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let html = String(buffer: response.body)
                // The five oldest are off the end; the newest is on it.
                #expect(!html.contains("\"/page-0-otter\""))
                #expect(!html.contains("\"/page-4-otter\""))
                #expect(html.contains("\"/page-5-otter\""))
                #expect(html.contains("\"/page-\(recentPageCount + 4)-otter\""))
            }
        }
    }

    // The index's markup is held to `Stylesheet.componentClasses` by
    // `StylesheetTests.builtInPagesOnlyUseDefinedClasses`, which renders all three of its
    // states directly. It is not repeated here: two copies of a drift detector is its own
    // drift, and that one covers the states an HTTP test cannot easily arrange.
}
