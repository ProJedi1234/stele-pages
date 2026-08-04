import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The document exactly as the fixture's application renders it, hoisted to file scope so
/// the parameterised cases below can read it in their argument lists. Its byte limit is the
/// configuration default, which is what `TestFixture.configuration` leaves unset — so this
/// value and the one the router serves are the same rendering, not two that resemble each
/// other.
private let skillDocument = PublishSkill(baseURL: TestFixture.baseURL, maxPageBytes: 1024 * 1024)

/// The publish skill at `GET /skill`.
///
/// Two kinds of property are pinned here, as in `StylesheetTests`. The wire contract — the
/// URI, the type, the caching headers — is what an agent bootstraps against, so those
/// literals are written longhand rather than read back off the source. Everything else is
/// anti-drift, and it is the point of the suite: a skill that teaches a class the stylesheet
/// no longer defines, a content type the server no longer accepts, or a slug the server
/// would reject is worse than no skill, because every one of those failures is a `200` from
/// this route and a confused agent somewhere else.
@Suite("Publish skill")
struct PublishSkillTests {
    /// The published address, written out rather than interpolated from `PublishSkill.path`:
    /// "fetch this deployment's `/skill`" is the whole bootstrapping story, so a rename is a
    /// breaking change and has to be seen here as one.
    static let uri = "/skill"

    /// The backtick-quoted tokens on a line, in order — the only markup this suite parses,
    /// because the document uses backticks for every value it means literally.
    static func backtickedTokens(in line: some StringProtocol) -> [String] {
        line.split(separator: "`", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset.isMultiple(of: 2) == false }
            .map { String($0.element) }
    }

    // MARK: - The wire contract

    /// The route serves the rendering, not a template: the body equality is against a
    /// `PublishSkill` built with the fixture's own base URL, so a route that rendered with a
    /// default host would fail here rather than ship a curl pointed at the wrong server.
    @Test func servesTheSkill() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.status == .ok)
                // Hard-coded, not `PublishSkill.contentType`: a source-side rename must not
                // silently rename the promise as well.
                #expect(response.headers[.contentType] == "text/markdown; charset=utf-8")
                #expect(response.headers[.cacheControl] == "no-cache")
                #expect(String(buffer: response.body) == skillDocument.markdown)
                // Anti-vacuity: an empty or stub document would satisfy every equality
                // above and every `contains` below would then be the only thing failing.
                #expect(!skillDocument.markdown.isEmpty)
                #expect(skillDocument.markdown.count > 1_000)
            }
        }
    }

    /// An author who uploads their own markdown must get it served under exactly the type
    /// the built-in document uses; a divergence would mean markdown behaves differently
    /// depending on where it came from. Non-vacuous because `servesTheSkill` pins the
    /// literal on the wire.
    @Test func contentTypeMatchesTheUploadAllowlist() {
        #expect(PublishSkill.contentType == PageContentType.allowed["text/markdown"])
    }

    /// The route registration and the landing page's link are both built from this constant,
    /// so renaming the segment moves them together. Reservation is the other half: a `skill`
    /// slug would be permanently shadowed by this route.
    @Test func pathIsBuiltFromTheRouteConstant() {
        #expect(PublishSkill.path == "/\(ServerRoute.skill)")
        #expect(Slug.reserved.contains(ServerRoute.skill))
    }

    /// The document exists to bootstrap an agent that has nothing yet — including, quite
    /// possibly, the token. Demanding auth to read the instructions for obtaining auth is
    /// the deadlock this pins shut. Reads are open on this server anyway.
    @Test func skillNeedsNoAuth() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            // No headers at all.
            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.status != .unauthorized)
                #expect(response.status == .ok)
            }
        }
    }

    /// `nosniff` is this repo's marker for bodies we did *not* write. This one is compiled
    /// into the binary, so it is omitted exactly as the stylesheet and the landing page omit
    /// it. Pinned so the omission stays a decision rather than becoming an oversight.
    @Test func skillCarriesNoNosniff() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.headers[.xContentTypeOptions] == nil)
            }
        }
    }

    // MARK: - Revalidation

    /// `no-cache` without a validator would re-send the whole document on every check. The
    /// ETag turns that into a bodyless 304, so it has to be stable across requests — a
    /// per-process hash would validate nothing — and it has to be honoured, including
    /// refusing to honour one that does not match.
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
                #expect(String(buffer: response.body) == skillDocument.markdown)
            }
        }
    }

    /// `If-None-Match` is a *list*, or `*`, compared weakly — RFC 9110 §13.1.2. The forms are
    /// pinned per route rather than once for `ifNoneMatchHits`, because the bug this guards
    /// is a route that compares the header itself instead of calling the shared helper, and
    /// a helper-level test would not see that.
    @Test(arguments: [
        ("W/\(skillDocument.etag)", true),          // weakened by an intermediary
        ("\"other\", \(skillDocument.etag)", true), // a list holding ours
        ("*", true),                                // any representation, and we have one
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
                    response.body.readableBytes
                        == (expectsNotModified ? 0 : skillDocument.markdown.utf8.count),
                    "\(header)"
                )
            }
        }
    }

    /// The tag has to be a tag *of this rendering*. Two deployments differ only in the values
    /// interpolated into the document, so a validator computed over the template — or copied
    /// from the stylesheet — would hand a cache the wrong host and never revalidate it away.
    /// Every other assertion in this suite passes with a copy-pasted ETag; this one does not.
    @Test func etagIsBoundToTheRendering() {
        let again = PublishSkill(baseURL: TestFixture.baseURL, maxPageBytes: 1024 * 1024)
        #expect(again.etag == skillDocument.etag)

        let elsewhere = PublishSkill(baseURL: "https://other.example", maxPageBytes: 1024 * 1024)
        #expect(elsewhere.etag != skillDocument.etag)

        #expect(skillDocument.etag != Stylesheet.etag)
    }

    // MARK: - Content accuracy

    /// The vocabulary the agent writes against. A component the sheet defines and the skill
    /// never mentions is a feature the agent cannot use.
    @Test(arguments: Stylesheet.componentClasses)
    func documentsEveryComponentClass(name: String) {
        #expect(skillDocument.markdown.contains(".\(name)"), "\(name)")
    }

    /// Set equality, parsed out of the component table's own class column, because presence
    /// only catches one direction. The direction it misses is the worse one: a class deleted
    /// from the CSS but still taught here produces markup that is valid, serves a `200`, and
    /// renders unstyled — a failure no status assertion anywhere can see.
    @Test func componentTableMatchesTheStylesheet() {
        let documented = skillDocument.markdown.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| `.") else { return nil }
            let rest = line.dropFirst("| `.".count)
            guard let end = rest.firstIndex(of: "`") else { return nil }
            return String(rest[..<end])
        }

        #expect(!documented.isEmpty)
        #expect(Set(documented) == Set(Stylesheet.componentClasses))
    }

    /// Every class the document's own snippets use has to exist. The snippets are what an
    /// agent copies verbatim, so a typo here ships as unstyled markup on somebody's page.
    /// Tone modifiers are legal in a snippet even though they are not `componentClasses` —
    /// that list is what the built-in pages are held to, and this document teaches more.
    @Test func documentsOnlyDefinedClasses() {
        let used = TestFixture.classNames(in: skillDocument.markdown)
        let defined = Set(Stylesheet.componentClasses).union(Stylesheet.toneClasses)

        #expect(!used.isEmpty)
        for name in used {
            #expect(defined.contains(name), "\(name)")
        }
    }

    /// The tones are taught as a second class on `.callout` and `.badge`, so they drift the
    /// same way the component names do. `StylesheetTests.stylesheetDefinesEveryToneClass` is
    /// the other half: this asserts the document teaches them, that asserts the sheet has
    /// them.
    @Test(arguments: Stylesheet.toneClasses)
    func documentsEveryToneClass(name: String) {
        #expect(skillDocument.markdown.contains(name), "\(name)")
    }

    /// An agent that sends a type the server rejects gets a `415` with no idea why, so the
    /// list has to be exact in both directions — a type missing from the document is a
    /// capability lost, and one listed but no longer accepted is a guaranteed failed publish.
    @Test(arguments: PageContentType.allowed.keys.sorted())
    func listsEveryAllowedContentType(type: String) throws {
        #expect(skillDocument.markdown.contains(type), "\(type)")

        // The one line that carries the whole list, identified by the type least likely to
        // appear in a curl example. Set equality over it catches the reverse direction.
        let line = try #require(
            skillDocument.markdown.split(separator: "\n").first { $0.contains("text/plain") }
        )
        #expect(Set(Self.backtickedTokens(in: line)) == Set(PageContentType.allowed.keys))
    }

    /// The single line an agent copies into every page it writes. Interpolated from
    /// `Stylesheet.path`, so this asserts the interpolation happened rather than that
    /// somebody typed the path out and got it right today.
    @Test func documentsTheStylesheetLink() {
        #expect(
            skillDocument.markdown
                .contains("<link rel=\"stylesheet\" href=\"\(Stylesheet.path)\">")
        )
    }

    /// The single failure that breaks "publish on the first try": a curl pointed at a host
    /// the agent cannot reach. The negative half matters as much — a placeholder left in the
    /// literal would still satisfy the positive half, because the real host appears elsewhere
    /// in the document.
    @Test func curlTargetsTheConfiguredHost() {
        #expect(skillDocument.markdown.contains("\(TestFixture.baseURL)/\(ServerRoute.pages)"))
        #expect(skillDocument.markdown.contains("--data-binary"))
        #expect(!skillDocument.markdown.contains("localhost"))
        #expect(!skillDocument.markdown.contains("example.com"))
    }

    /// Rendered with a byte limit no default could produce, so a stale literal in the
    /// document — rather than the interpolation — fails here. The default rendering is
    /// checked too: without it, a document that mentioned every plausible number would pass.
    @Test func documentsTheConfiguredSizeLimit() {
        let unusual = PublishSkill(baseURL: TestFixture.baseURL, maxPageBytes: 424_242)
        #expect(unusual.markdown.contains("424242"))
        #expect(!skillDocument.markdown.contains("424242"))
        #expect(skillDocument.markdown.contains("\(1024 * 1024)"))
    }

    /// An agent choosing its own slug needs the actual bounds, not "short". Interpolated from
    /// `Slug`, so widening the range in one place cannot leave the document narrow.
    @Test func documentsTheSlugGrammar() {
        #expect(skillDocument.markdown.contains("\(Slug.minLength)"))
        #expect(skillDocument.markdown.contains("\(Slug.maxLength)"))
    }

    /// Every example name the document offers, run through the same chokepoint the server
    /// would run it through. A skill that teaches an example the server rejects is worse than
    /// no skill: the agent's first act on the first try is a `400`.
    @Test func exampleSlugsAreValid() throws {
        var examples: [String] = []
        for marker in ["?slug=", "/\(ServerRoute.pages)/"] {
            var remainder = Substring(skillDocument.markdown)
            while let found = remainder.range(of: marker) {
                let tail = remainder[found.upperBound...]
                let name = tail.prefix { !" \n`\"\\".contains($0) }
                examples.append(String(name))
                remainder = tail
            }
        }

        for example in examples {
            // A bare marker with nothing after it (`?slug=` used as a noun) names no slug,
            // and `:slug` is the route table's placeholder rather than an example.
            guard !example.isEmpty, !example.hasPrefix(":") else { continue }
            #expect(throws: Never.self, "\(example)") { try Slug(custom: example) }
        }

        // The scan really found something — otherwise the loop above is a no-op that passes.
        #expect(examples.contains("my-page"))
    }

    /// An agent handed a status it was never told about has no recovery path and will either
    /// retry a permanent failure or report success it did not get.
    @Test(arguments: ["400", "401", "404", "409", "413", "415", "503"])
    func documentsEveryFailureStatus(code: String) {
        #expect(skillDocument.markdown.contains(code), "\(code)")
    }

    /// The field names the agent reads its answer out of. Worth pinning because the README
    /// shows `url` first while `PageLocationResponse` encodes `slug` first — the document has
    /// to show what the encoder actually emits, not what reads better in prose.
    @Test func documentsTheResponseShape() {
        #expect(skillDocument.markdown.contains("\"slug\""))
        #expect(skillDocument.markdown.contains("\"url\""))
    }

    /// The asymmetry an agent updating a page will otherwise get wrong: absence of
    /// `Content-Type` means "text/html" to POST and "leave it alone" to PUT. Prose-level, but
    /// silently re-typing a stored stylesheet to HTML behind a `200` is the failure.
    @Test func documentsThePutDifference() {
        #expect(
            skillDocument.markdown
                .contains("omitting `Content-Type` on a PUT keeps the stored type")
        )
    }

    /// It is a SKILL.md, and the frontmatter is what an agent runtime reads to decide whether
    /// this document applies at all. Without it the file is just prose.
    @Test func hasFrontmatter() {
        #expect(skillDocument.markdown.hasPrefix("---\n"))
        #expect(skillDocument.markdown.contains("\nname: "))
        #expect(skillDocument.markdown.contains("\ndescription: "))
    }

    // MARK: - The 404 surface

    /// The reservation at HTTP level rather than only in `Slug`: neither write verb may hand
    /// out `skill`, because a page stored there would be shadowed by this route the moment it
    /// was published. The read at the end is the real assertion — the rejections mean nothing
    /// if the document had been shadowed anyway.
    @Test func skillCannotBeClaimedAsASlug() async throws {
        let headers: HTTPFields = [
            .authorization: "Bearer \(TestFixture.token)",
            .contentType: "text/html",
        ]

        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=\(ServerRoute.skill)",
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
                uri: "/\(ServerRoute.pages)/\(ServerRoute.skill)",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: "<h1>mine now</h1>")
            ) { response in
                #expect(response.status == .badRequest)
            }

            try await client.execute(uri: Self.uri, method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == skillDocument.markdown)
            }
        }
    }

    /// A miss under `/skill` gets the framework's plain 404 rather than the uniform page, and
    /// that is fine: a two-segment path can never be a slug, so the response says nothing
    /// about the namespace a scanner is walking — the same reasoning as `unknownAssetIs404`.
    /// Only the status is signal, and it must not be a 401, which would advertise `/skill` as
    /// a protected area.
    @Test func unknownSkillChildIs404() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.skill)/nope", method: .get) { response in
                #expect(response.status != .unauthorized)
                #expect(response.status == .notFound)
            }
        }
    }
}
