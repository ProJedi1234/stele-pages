import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The shared stylesheet at `GET /assets/stele.css`.
///
/// Two kinds of property are pinned here. The wire contract — the URI, the content type,
/// the caching headers — is what published pages link and what a cache negotiates
/// against, so those literals are written out longhand rather than read back off the
/// source. The rest is anti-drift: the built-in pages must actually use the sheet (and
/// have stopped carrying their own CSS), and the class list issue #4's publish skill will
/// read must keep matching what the sheet really defines.
@Suite("Shared stylesheet")
struct StylesheetTests {
    /// The published address, written out rather than interpolated from `Stylesheet.path`:
    /// every page that links the sheet hard-codes this string too, so a rename is a
    /// breaking change and has to be seen here as one.
    static let uri = "/assets/stele.css"

    // MARK: - The wire contract

    /// The whole point of the feature is a *stable* URL: pages published months apart link
    /// this one address, so the URI, the type and the bytes are asserted literally. The
    /// `no-cache` is not a performance oversight — the sheet mutates in place, so a cache
    /// must revalidate or a restyle would reach only new readers.
    @Test func servesTheStylesheet() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.status == .ok)
                // Hard-coded, not `Stylesheet.contentType`: a source-side rename must not
                // silently rename the promise as well.
                #expect(response.headers[.contentType] == "text/css; charset=utf-8")
                #expect(response.headers[.cacheControl] == "no-cache")
                #expect(String(buffer: response.body) == Stylesheet.css)
                // Guards the degenerate pass where the route serves an empty constant and
                // every comparison above holds vacuously.
                #expect(!Stylesheet.css.isEmpty)
            }
        }
    }

    /// Reads are open on this server by design, and the stylesheet is the read every other
    /// page depends on — a browser fetching a subresource has no token to offer. The
    /// missing `Authorization` header is the assertion, exactly as in
    /// `NotFoundTests.getPagesNeedsNoAuth`.
    @Test func stylesheetNeedsNoAuth() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            // No headers at all.
            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.status != .unauthorized)
                #expect(response.status == .ok)
            }
        }
    }

    /// `nosniff` is this repo's marker for bodies we did *not* write — stored pages, whose
    /// uploader chose the bytes. This one is compiled into the binary, so it is omitted for
    /// the same reason the landing page omits it. Pinned so the omission stays a decision
    /// rather than becoming an oversight someone "fixes" in either direction unknowingly.
    @Test func stylesheetCarriesNoNosniff() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.headers[.xContentTypeOptions] == nil)
            }
        }
    }

    /// An author who uploads their own stylesheet must get it served under exactly the type
    /// the built-in one uses; a divergence would mean the sheet a page links behaves
    /// differently depending on where it came from. Non-vacuous because
    /// `servesTheStylesheet` already pins the literal on the wire.
    @Test func contentTypeMatchesTheUploadAllowlist() {
        #expect(Stylesheet.contentType == PageContentType.allowed["text/css"])
    }

    /// The route registration and the `<link href>` on every built-in page are both built
    /// from these constants, so renaming the segment moves them together. Reservation is
    /// the other half: an `assets` slug would shadow the whole asset namespace.
    @Test func pathIsBuiltFromTheRouteConstant() {
        #expect(Stylesheet.path == "/\(ServerRoute.assets)/\(Stylesheet.fileName)")
        #expect(Slug.reserved.contains(ServerRoute.assets))
    }

    // MARK: - Dogfooding

    /// The issue's actual demand: the built-in pages *use* the shared sheet. The negative
    /// half is what enforces it — linking the stylesheet while keeping an inline `<style>`
    /// block would satisfy the letter of it and leave the duplication that motivated the
    /// issue in place.
    ///
    /// The needle carries the unescaped `<link …>` delimiters on purpose: the landing page
    /// also shows authors the tag to copy, as `&lt;link rel="stylesheet" …&gt;`, and a
    /// needle without them is satisfied by that escaped example even if the real `<head>`
    /// link is deleted.
    @Test(arguments: [("/", HTTPResponse.Status.ok), ("/no-such-page", HTTPResponse.Status.notFound)])
    func builtInPagesLinkTheStylesheet(path: String, status: HTTPResponse.Status) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: path, method: .get) { response in
                #expect(response.status == status, "\(path)")
                let body = String(buffer: response.body)
                #expect(body.contains("<link rel=\"stylesheet\" href=\"\(Stylesheet.path)\">"), "\(path)")
                #expect(!body.contains("<style"), "\(path)")
            }
        }
    }

    /// `componentClasses` is what issue #4's publish skill will hand an agent as the
    /// vocabulary to write against, so a name in it that the sheet does not define would
    /// teach the agent to emit markup that renders unstyled.
    ///
    /// The opening brace is load-bearing. Matching a bare `.card` also matches the `/* .card
    /// — … */` comment above the rule, so deleting the rule and keeping its comment left
    /// both this test and `stylesheetDocumentsItsComponents` green — the pair passing while
    /// the class no longer exists, which is the one thing they are here to prevent.
    @Test(arguments: Stylesheet.componentClasses)
    func stylesheetDefinesEveryDocumentedClass(name: String) {
        #expect(Stylesheet.css.contains(".\(name) {"), "\(name)")
    }

    /// Each component carrying its own comment is an acceptance criterion of the issue, and
    /// those comments are the raw material issue #4 reads. Asserted so a future
    /// "optimisation" that minifies or strips comments has to notice it is deleting the
    /// deliverable, not just whitespace.
    @Test(arguments: Stylesheet.componentClasses)
    func stylesheetDocumentsItsComponents(name: String) {
        #expect(Stylesheet.css.contains("/* .\(name)"), "\(name)")
    }

    /// The tone vocabulary the publish skill hands an agent, pinned the same way
    /// `stylesheetDefinesEveryDocumentedClass` pins the component names — and for the same
    /// reason: a tone the sheet does not define renders as valid, unstyled markup that no
    /// status assertion anywhere would catch.
    ///
    /// Both shapes are asserted because both are taught as taking a tone. The opening brace
    /// is load-bearing here too: `.callout.warn` on its own also matches the comment above
    /// the rule, so a deleted rule with a surviving comment would pass.
    @Test(arguments: Stylesheet.toneClasses)
    func stylesheetDefinesEveryToneClass(name: String) {
        #expect(Stylesheet.css.contains(".callout.\(name) {"), "\(name)")
        #expect(Stylesheet.css.contains(".badge.\(name) {"), "\(name)")
    }

    /// The drift guard that matters: a class renamed in the CSS leaves the built-in pages
    /// silently unstyled — still valid HTML, still a 200, just wrong-looking, which no
    /// status assertion anywhere would catch.
    @Test func builtInPagesOnlyUseDefinedClasses() {
        let used = TestFixture.classNames(in: landingPage(baseURL: TestFixture.baseURL))
            + TestFixture.classNames(in: notFoundPage())

        // Both halves of the non-vacuity check: pages that used no classes would pass the
        // loop below without exercising anything, and an empty `componentClasses` would
        // make the two parameterised tests above run zero cases.
        #expect(!used.isEmpty)
        #expect(!Stylesheet.componentClasses.isEmpty)

        for name in used {
            #expect(Stylesheet.componentClasses.contains(name), "\(name)")
        }
    }

    /// Both built-in pages carried their own `prefers-color-scheme` block before this
    /// stylesheet existed; dropping them must not have dropped dark mode with them.
    /// Deliberately coarse — it guards the issue's "keep dark-mode support" line, not any
    /// particular colour.
    @Test func stylesheetSupportsDarkMode() {
        #expect(Stylesheet.css.contains("@media (prefers-color-scheme: dark)"))
        // Without this the UA leaves scrollbars, form controls and the canvas light under
        // a dark page, which is the visible half of "supports dark mode".
        #expect(Stylesheet.css.contains("color-scheme: light dark"))
    }

    // MARK: - The 404 surface

    /// Registering `/assets/stele.css` creates a literal `assets` node, and the trie does
    /// not backtrack to `/:slug` when the final component lands on a node with no value —
    /// so without its own responder `/assets` would answer with the framework's plain 404,
    /// the one distinguishable response on the public read surface. Same trap `/pages`
    /// already walked into.
    @Test func assetsIndexServesTheUniform404() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.assets)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == "text/html; charset=utf-8")
                #expect(String(buffer: response.body) == notFoundPage())
            }
        }
    }

    /// A miss under `/assets` gets the framework's plain 404 rather than the uniform page,
    /// and that is fine: a two-segment path can never be a slug, so the response says
    /// nothing about the namespace a scanner is walking. Only the status is signal — and it
    /// must not be a 401, which would advertise `/assets` as a protected area.
    @Test func unknownAssetIs404() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.assets)/nope.css", method: .get) { response in
                #expect(response.status != .unauthorized)
                #expect(response.status == .notFound)
            }
        }
    }

    /// The reservation, at HTTP level rather than only in `Slug`: neither write verb may
    /// hand out `assets`, because a page stored there would sit in front of — or read as
    /// competing with — the server's own asset namespace. The read at the end is the real
    /// assertion; the rejections mean nothing if the sheet had been shadowed anyway.
    @Test func assetsCannotBeClaimedAsASlug() async throws {
        let headers: HTTPFields = [
            .authorization: "Bearer \(TestFixture.token)",
            .contentType: "text/html",
        ]

        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=\(ServerRoute.assets)",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "<h1>mine now</h1>")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("Invalid slug:"))
                #expect(message.contains("reserved"))
            }

            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(ServerRoute.assets)",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: "<h1>mine now</h1>")
            ) { response in
                #expect(response.status == .badRequest)
            }

            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == Stylesheet.css)
            }
        }
    }

    // MARK: - Revalidation

    /// `no-cache` without a validator would make every 404 — the surface scanners hammer —
    /// re-download a multi-KB sheet. The ETag turns that into a bodyless 304, so it has to
    /// be stable across requests (a per-process hash would validate nothing) and it has to
    /// actually be honoured, including refusing to honour one that doesn't match.
    @Test func revalidatesWithETag() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let first = try await client.execute(uri: Self.uri, method: .get) { response -> String in
                #expect(response.status == .ok)
                return try #require(response.headers[.eTag])
            }
            #expect(!first.isEmpty)

            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.headers[.eTag] == first)
            }

            try await client.execute(
                uri: Self.uri,
                method: .get,
                headers: [.ifNoneMatch: first]
            ) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
                // Repeated so a cache that already holds the body can keep validating
                // against it rather than falling back to a full fetch next time.
                #expect(response.headers[.eTag] == first)
            }

            try await client.execute(
                uri: Self.uri,
                method: .get,
                headers: [.ifNoneMatch: "\"bogus\""]
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == Stylesheet.css)
            }
        }
    }

    /// `If-None-Match` is a *list*, or `*`, compared weakly — RFC 9110 §13.1.2. Exact string
    /// equality passed the test above and still broke revalidation in front of a proxy:
    /// nginx's gzip module rewrites a strong `ETag` to `W/"…"`, so the browser sends back a
    /// weak tag, nothing matches, and the sheet is re-sent in full on every conditional
    /// request. The failure is silent from both ends — a 200 is always a legal answer — so
    /// the forms are pinned here rather than left to be noticed in a bandwidth graph.
    @Test(arguments: [
        ("W/\(Stylesheet.etag)", true),          // weakened by an intermediary
        ("\"other\", \(Stylesheet.etag)", true), // a list holding ours
        ("*", true),                             // any representation, and we have one
        ("\"other\"", false),
        ("W/\"other\"", false),
    ])
    func revalidationHandlesEveryIfNoneMatchForm(header: String, expectsNotModified: Bool) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: Self.uri,
                method: .get,
                headers: [.ifNoneMatch: header]
            ) { response in
                #expect(response.status == (expectsNotModified ? .notModified : .ok), "\(header)")
                #expect(
                    response.body.readableBytes == (expectsNotModified ? 0 : Stylesheet.css.utf8.count),
                    "\(header)"
                )
            }
        }
    }
}
