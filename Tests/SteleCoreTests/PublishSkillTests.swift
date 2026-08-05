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
private let skillDocument = PublishSkill(
    baseURL: TestFixture.baseURL,
    maxPageBytes: Configuration.defaultMaxPageBytes
)

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

    /// The first non-blank line after the one containing `anchor`: how the suite finds a
    /// list the document renders on a line of its own. Anchored to the sentence that
    /// introduces the list — a structural relationship — rather than to a token from the
    /// list itself, which is a coincidence of today's prose that a new mention anywhere
    /// earlier in the document would silently re-point.
    static func line(after anchor: String, in markdown: String) throws -> Substring {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        let index = try #require(lines.firstIndex { $0.contains(anchor) }, "\(anchor)")
        return try #require(
            lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }

    /// The rows of the table that follows `anchor`, each split into its `|`-delimited cells,
    /// with the header and the `| --- |` rule dropped.
    ///
    /// Anchored to the sentence that introduces a table rather than to anything inside it, for
    /// the same reason `line(after:in:)` is — and scoped to *one* table because this document
    /// has five, several of whose rows are indistinguishable from each other line by line.
    static func tableRows(after anchor: String, in markdown: String) throws -> [[Substring]] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        let index = try #require(lines.firstIndex { $0.contains(anchor) }, "\(anchor)")
        let rows = lines[(index + 1)...]
            .drop { !$0.hasPrefix("|") }
            .prefix { $0.hasPrefix("|") }
            .dropFirst(2)
        return rows.map { $0.split(separator: "|", omittingEmptySubsequences: false) }
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
        let again = PublishSkill(
            baseURL: TestFixture.baseURL, maxPageBytes: Configuration.defaultMaxPageBytes
        )
        #expect(again.etag == skillDocument.etag)

        let elsewhere = PublishSkill(
            baseURL: "https://other.example", maxPageBytes: Configuration.defaultMaxPageBytes
        )
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
    /// Tone modifiers and syntax tokens are legal in a snippet even though they are not
    /// `componentClasses` — that list is what the built-in pages are held to, and this
    /// document teaches more.
    @Test func documentsOnlyDefinedClasses() {
        let used = TestFixture.classNames(in: skillDocument.markdown)
        let defined = Set(Stylesheet.componentClasses)
            .union(Stylesheet.toneClasses)
            .union(Stylesheet.syntaxTokenClasses)

        #expect(!used.isEmpty)
        for name in used {
            #expect(defined.contains(name), "\(name)")
        }
    }

    /// The tones are taught as a second class on `.callout` and `.badge`, so they drift the
    /// same way the component names do. `StylesheetTests.stylesheetDefinesEveryToneClass` is
    /// the other half: this asserts the document teaches them, that asserts the sheet has
    /// them.
    ///
    /// Backticked, and set-equal against the one line that carries the whole list, for the
    /// same reason `listsEveryAllowedContentType` is: the tone names are ordinary English
    /// words, so a bare `contains` for `note`, `ok` or `warn` passes on unrelated prose
    /// elsewhere in the document, and set equality is also what catches the reverse
    /// direction — a tone dropped from the sheet but still taught here. One unparameterised
    /// test, not one per tone: the assertion reads the whole list at once, so per-tone
    /// arguments would just re-run it identically and report one drift as four failures.
    @Test func documentsEveryToneClass() throws {
        let line = try Self.line(after: "one of exactly these:", in: skillDocument.markdown)
        #expect(Set(Self.backtickedTokens(in: line)) == Set(Stylesheet.toneClasses))
    }

    /// The syntax-token list is the skill's second hand-typed vocabulary, and it drifts
    /// exactly the way the component table does: each row carries prose no list of names
    /// could generate, so the names cannot be interpolated and set equality in both
    /// directions stands in for it. The direction presence alone would miss is the worse
    /// one here too — a token class deleted from the sheet but still taught produces
    /// markup that is valid, serves a `200`, and renders uncoloured. Parsed off the list's
    /// own rows rather than an anchor line, because unlike the tones the list *is* the
    /// rendering — there is no one-line summary elsewhere to read it from.
    @Test func documentsEverySyntaxTokenClass() {
        let documented = skillDocument.markdown.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- `tok-") else { return nil }
            return Self.backtickedTokens(in: line).first
        }

        #expect(!documented.isEmpty)
        #expect(Set(documented) == Set(Stylesheet.syntaxTokenClasses))
    }

    /// The example the token list teaches by is what an agent will pattern-match against,
    /// so it must demonstrate the whole vocabulary — a token class the snippet never shows
    /// is one the agent has seen named but never used, which is how a plausible-looking
    /// `tok-string` gets invented. `documentsOnlyDefinedClasses` already holds the snippet
    /// to defined classes; this is the other direction.
    @Test(arguments: Stylesheet.syntaxTokenClasses)
    func codeExampleUsesEverySyntaxToken(name: String) {
        #expect(skillDocument.markdown.contains("class=\"\(name)\""), "\(name)")
    }

    /// An agent that sends a type the server rejects gets a `415` with no idea why, so the
    /// list has to be exact in both directions — a type missing from the document is a
    /// capability lost, and one listed but no longer accepted is a guaranteed failed
    /// publish. Set equality over the one line that carries the whole list checks both at
    /// once, which is also why this is one test rather than one per type.
    @Test func listsEveryAllowedContentType() throws {
        let line = try Self.line(
            after: "accepted types are exactly these", in: skillDocument.markdown
        )
        #expect(Set(Self.backtickedTokens(in: line)) == Set(PageContentType.allowed.keys))
    }

    /// The scope vocabulary, held set-equal to `ClientScope` off the route table's own auth
    /// column — the third hand-checkable list in this document, after the tones and the
    /// content types, and pinned the same way for the same reason.
    ///
    /// Both directions matter and they fail differently. A scope this build enforces but the
    /// table never names leaves an agent staring at a `403` with no idea what to ask the user
    /// for; a scope named here that no longer exists sends them to ask for a credential the
    /// server cannot mint. The un-backticked `none` and `any credential` are deliberately not
    /// scopes and must stay outside the backticks, which is what keeps this equality exact.
    @Test func theRouteTableNamesExactlyTheScopesThatExist() throws {
        let rows = try Self.tableRows(
            after: "The tool talks to these so you do not have to.", in: skillDocument.markdown
        )
        // The read surface, the two writes, whoami and the three admin routes.
        #expect(rows.count >= 9)

        let auth = rows.flatMap { row -> [String] in
            guard row.count > 2 else { return [] }
            return Self.backtickedTokens(in: row[2])
        }
        #expect(!auth.isEmpty)
        #expect(Set(auth) == Set(ClientScope.allCases.map(\.rawValue)))
    }

    /// The two places outside that table where a scope is named in prose, and both are places
    /// an agent has to act on: the `403` row says which scope to ask the user for, and the
    /// paragraph under the table says which one it already has. Interpolated from
    /// `ClientScope`, so a rename cannot leave either sentence naming a scope the server has
    /// never heard of.
    @Test func namesThePublishScopeWhereARefusalHasToBeActedOn() {
        #expect(
            skillDocument.markdown.contains("with the `\(ClientScope.publish.rawValue)` scope")
        )
        #expect(
            skillDocument.markdown.contains("`\(ClientScope.publish.rawValue)` and nothing else")
        )
    }

    /// `stele auth status` — the first command the document tells an agent to run — is a
    /// `GET /admin/whoami`, and it is the one route under `/admin` that any credential may
    /// reach. A document that listed the admin routes without it would describe a segment
    /// that is entirely off limits to its reader, which is both wrong and the reason an agent
    /// would not bother running the check.
    @Test func documentsTheWhoamiRoute() {
        #expect(
            skillDocument.markdown
                .contains("/\(ServerRoute.admin)/\(ServerRoute.adminWhoami)")
        )
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

    /// The single failure that breaks "publish on the first try": an agent authenticated
    /// against a host it cannot reach, or against the wrong one. `stele auth login --host`
    /// is where this deployment's address has to arrive, because it is the only command in
    /// the document that names a host at all — every later command reads it back out of the
    /// credential file.
    ///
    /// The negative half matters as much — a placeholder left in the literal would still
    /// satisfy the positive half, because the real host appears elsewhere in the document.
    @Test func authenticatesAgainstTheConfiguredHost() {
        #expect(skillDocument.markdown.contains("stele auth login --host \(TestFixture.baseURL)"))
        #expect(!skillDocument.markdown.contains("localhost"))
        // The default an unset `STELE_BASE_URL` resolves to — the placeholder most likely
        // to actually ship, so its absence is the half of this test that earns its keep.
        #expect(!skillDocument.markdown.contains("127.0.0.1"))
        #expect(!skillDocument.markdown.contains("example.com"))
    }

    // MARK: - The CLI

    /// The install sequence, pinned to the constants it is interpolated from.
    ///
    /// This is the part of the document that describes a *different repository*, which is
    /// the new opportunity for it to lie: nothing in a `swift build` of this package would
    /// notice a clone URL that had moved or a make target that had been renamed. Holding
    /// the prose to `SteleCLI` is what keeps the two repos' story single-sourced — the
    /// server states these facts in one place and the document quotes it.
    @Test(arguments: [
        SteleCLI.cloneCommand,
        SteleCLI.installCommand,
        SteleCLI.completionsCommand,
        SteleCLI.binaryDirectory,
        SteleCLI.compatibilityLibraries,
    ])
    func documentsTheInstallSequence(fragment: String) {
        #expect(skillDocument.markdown.contains(fragment), "\(fragment)")
    }

    /// The document has to assume nothing is installed, so it needs the check that decides
    /// whether to install at all, and the two commands the agent runs afterwards. A skill
    /// that named only `stele publish` would leave an agent on a fresh machine with a
    /// `command not found` and no instruction covering it.
    @Test(arguments: [
        "stele auth status", "stele auth login", "stele auth logout", "stele publish",
        "stele update", "stele skill", "stele admin clients",
    ])
    func documentsEveryCommandTheAgentNeeds(command: String) {
        #expect(skillDocument.markdown.contains(command), "\(command)")
    }

    /// Every flag the client accepts has to be named, because a flag an agent has not been
    /// told about is a capability it does not have.
    ///
    /// This is the test the document needed and did not have. `--ttl` shipped in the client
    /// while the prose still read "`stele publish` does not expose this yet", so an agent
    /// asked for a permanent page refused — citing a limitation that had stopped existing,
    /// in a sentence confident enough to be read as policy. Nothing here can see the other
    /// repository, so this cannot prove the flags exist; what it proves is that the set this
    /// package believes in and the set the document teaches are the same set, which is the
    /// half that was actually broken.
    @Test(arguments: SteleCLI.flags)
    func documentsEveryFlagTheAgentCanUse(flag: String) {
        #expect(skillDocument.markdown.contains(flag), "\(flag)")
    }

    /// The exit table, held to `SteleCLI.exits` row for row and in order.
    ///
    /// The exit code is what an agent branches on — the CLI says so itself — and the
    /// document used to answer "what does a failure look like?" with HTTP statuses the
    /// caller never sees: the client rewrites the message in its own words and, outside one
    /// case, never prints the number. So an agent was told to match on strings that do not
    /// arrive, while `2` (no credential here) and `9` (nothing answered) had no row at all
    /// because neither has a status behind it.
    ///
    /// Order is asserted, not just membership: the table is read top to bottom by something
    /// deciding what to do, and a code that drifted out of sequence would read as a
    /// severity ranking that is not there.
    @Test func theExitTableMatchesTheClientsExitCodes() throws {
        let rows = try Self.tableRows(
            after: "These are the codes, and what each one asks you to do next:",
            in: skillDocument.markdown
        )
        let documented = rows.compactMap { row -> Int32? in
            guard row.count > 1 else { return nil }
            return Self.backtickedTokens(in: row[1]).first.flatMap { Int32($0) }
        }

        #expect(documented == SteleCLI.exits.map(\.code))
        // The success case earns a row too: an agent that only ever sees failures documented
        // has been told what to do about every outcome except the one it usually gets.
        #expect(documented.first == 0)
    }

    /// The two exits with no HTTP status behind them, which is exactly why the old
    /// status-only table could not carry them. `2` is decided before a request is built and
    /// `9` is a request that never got an answer — and they are between them the most likely
    /// way a fresh machine fails, so an agent without a row for either invents one.
    @Test(arguments: ["`2`", "`9`"])
    func documentsTheFailuresThatNeverReachTheServer(code: String) {
        #expect(skillDocument.markdown.contains(code), "\(code)")
    }

    /// The one version string in the document, and it is the server's.
    ///
    /// Set equality over *every* dotted-numeric token the prose contains, rather than a
    /// `contains` for the current value: a `contains` passes happily alongside a second,
    /// stale version left behind in a sentence somewhere, which is exactly the drift this
    /// guards — the document would then tell an agent to reinstall until it reached a build
    /// number this deployment never asked for. Parsed with the same initialiser the gate
    /// parses a `User-Agent` with, so "what counts as a version" cannot differ between the
    /// document and the middleware.
    @Test func mentionsExactlyTheMinimumCLIVersion() {
        let punctuation = CharacterSet(charactersIn: "`(),.;:|*")
        let versions = skillDocument.markdown
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: punctuation) }
            .compactMap { CLIVersion(parsing: $0) }

        #expect(Set(versions) == [minimumCLIVersion])
    }

    /// The whole point of the rewrite, asserted negatively because that is the only way a
    /// custody boundary can be asserted: the document must contain no way for the agent to
    /// come into possession of a credential.
    ///
    /// Every string below was in the previous version of this document. A well-meaning
    /// "helpful" edit that restores any of them — an env var to export, a header to send, a
    /// curl to run — hands the token back to the model, in the same context window as a page
    /// it is about to publish at a guessable URL. That is the failure the CLI exists to make
    /// impossible, and it would otherwise reappear silently, because a document that teaches
    /// both routes still works.
    @Test(arguments: [
        "STELE_UPLOAD_TOKEN", "Authorization", "Bearer", "--data-binary", "curl -X",
        "ask the user for it",
    ])
    func neverPutsTheCredentialInTheAgentsHands(fragment: String) {
        #expect(!skillDocument.markdown.contains(fragment), "\(fragment)")
    }

    /// `stele auth login` prompts on a TTY for a secret. An agent that runs it either hangs
    /// on a prompt it cannot answer or, worse, decides to source the value from somewhere —
    /// so the document has to say whose step it is, in words, and not merely list the
    /// command. Prose-level, like `documentsThatUpdateNeverCreates`.
    @Test func handsAuthenticationToTheUser() {
        #expect(skillDocument.markdown.contains("Ask them to run it; do not run it for them."))
    }

    /// Rendered with a byte limit no default could produce, so a stale literal in the
    /// document — rather than the interpolation — fails here. The default rendering is
    /// checked too: without it, a document that mentioned every plausible number would pass.
    @Test func documentsTheConfiguredSizeLimit() {
        let unusual = PublishSkill(baseURL: TestFixture.baseURL, maxPageBytes: 424_242)
        #expect(unusual.markdown.contains("424242"))
        #expect(!skillDocument.markdown.contains("424242"))
        #expect(skillDocument.markdown.contains("\(Configuration.defaultMaxPageBytes)"))
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
        // The three places a name can follow: the flag that requests one, the update
        // command's first argument, and the route table's path. `?slug=` is gone with the
        // curl it belonged to — the flag replaced it.
        var examples: [String] = []
        for marker in ["--slug ", "stele update ", "/\(ServerRoute.pages)/"] {
            var remainder = Substring(skillDocument.markdown)
            while let found = remainder.range(of: marker) {
                let tail = remainder[found.upperBound...]
                // `&`, `?` and `#` end a slug as surely as whitespace does: the document
                // teaches `?slug=my-page&ttl=never`, and without them the "example" this
                // scan extracts is the whole query string — a name `Slug(custom:)` rejects,
                // failing this test for a document that is entirely correct.
                let name = tail.prefix { !" \n`\"\\&?#".contains($0) }
                examples.append(String(name))
                remainder = tail
            }
        }

        for example in examples {
            // A bare marker with nothing after it (`--slug` used as a noun) names no slug;
            // `:slug` is the route table's placeholder, and `<slug>` is a synopsis line's.
            // Neither placeholder spelling is an example, and neither could be — no slug
            // may contain `:` or `<`.
            guard !example.isEmpty, !example.hasPrefix(":"), !example.hasPrefix("<")
            else { continue }
            #expect(throws: Never.self, "\(example)") { try Slug(custom: example) }
        }

        // The scan really found something — otherwise the loop above is a no-op that passes.
        #expect(examples.contains("my-page"))
    }

    /// An agent handed a status it was never told about has no recovery path and will either
    /// retry a permanent failure or report success it did not get.
    ///
    /// `403` and `426` are the two the credential split added. Both are recoverable and
    /// neither is retryable as-is, which is precisely the combination an agent gets wrong
    /// when it has not been told: a `403` is a credential without the `publish` scope and a
    /// `426` is an install that has fallen behind the deployment.
    @Test(arguments: ["400", "401", "403", "404", "409", "413", "415", "426", "503"])
    func documentsEveryFailureStatus(code: String) {
        #expect(skillDocument.markdown.contains(code), "\(code)")
    }

    /// The delete verb has to appear in the route table and must not appear as something to
    /// run, and those two halves are one fact rather than two.
    ///
    /// The route table is where an agent looks to decide whether a verb exists at all; the
    /// document tells it not to invent sub-paths, so a verb missing from that table is a
    /// capability it will not use. But `stele` ships no delete command, so the only way to
    /// act on that row is to reach past the tool for a credential — which is precisely what
    /// `neverPutsTheCredentialInTheAgentsHands` exists to forbid. A row that named the verb
    /// and stopped there would be an invitation to go find a way, so the document says the
    /// gap out loud in the same breath, exactly as it does for `?ttl=`. When the CLI grows a
    /// delete command, this test is the one to come back to.
    ///
    /// `204` is asserted *absent* for the same reason, and it is why the status is missing
    /// from `documentsEveryFailureStatus`' arguments too — that table is what a command
    /// tells you, and no command can earn a `204` today. The assertion is anchored on the
    /// row shape rather than the bare digits, which would collide with any byte limit that
    /// happened to contain them.
    @Test func documentsTheDeleteRoute() {
        let markdown = skillDocument.markdown
        #expect(
            markdown.contains(
                "| `DELETE /\(ServerRoute.pages)/:slug` | `\(ClientScope.publish.rawValue)` |"
            )
        )
        #expect(markdown.contains("**`stele` has no delete command**"))
        #expect(!markdown.contains("| `204` |"))
    }

    /// The consequence no status code can carry, pinned as exact sentences the way
    /// `documentsThePutDifference` is. A delete here frees the name rather than retiring it,
    /// so a page taken down is a URL that may one day serve a stranger's page — and it is
    /// the *agent*, not the server, that has to decide the user meant that. That the CLI
    /// cannot delete today makes this more worth keeping, not less: it is the argument the
    /// agent relays to a user asking for the capability, and the argument it will need at
    /// hand on the day a `stele delete` arrives. An edit that compressed this section into
    /// "removes the page" would still pass every other assertion in this suite while
    /// dropping the only part that changes what a caller does.
    @Test func documentsThatDeletionIsPermanent() {
        #expect(skillDocument.markdown.contains("Deletion is permanent — there is no undo."))
        #expect(
            skillDocument.markdown
                .contains("A URL you already handed out may later resolve to a different page.")
        )
    }

    /// The one place the two features can mislead each other. An agent that has been told
    /// pages expire, and separately that DELETE removes pages, has every reason to invent a
    /// tidy-up pass that deletes what it published — which earns a `404` per page, because
    /// an expired page is already gone. The document says so in as many words; this pins
    /// that it keeps saying so.
    @Test func documentsThatExpiryNeedsNoDelete() {
        #expect(
            skillDocument.markdown
                .contains("You never have to delete a page to make it expire.")
        )
    }

    /// `400` is now four different mistakes, and a malformed lifetime is the one an agent
    /// will actually make — it is the only `400` you can earn while sending a perfectly good
    /// page. `documentsEveryFailureStatus` cannot see this: `contains("400")` stays true
    /// however incomplete the row's enumeration becomes.
    @Test func theBadRequestRowNamesTheLifetime() throws {
        let row = try #require(
            skillDocument.markdown.split(separator: "\n").first { $0.hasPrefix("| `400`") }
        )
        #expect(row.contains(PageLifetime.queryParameter))
    }

    /// The field names the agent reads its answer out of. Worth pinning because the README
    /// shows `url` first while `PageLocationResponse` encodes `slug` first — the document has
    /// to show what the encoder actually emits, not what reads better in prose.
    ///
    /// `expires` is here for a sharper reason than the other two: it is the only field whose
    /// value can be JSON `null`, so an agent that never learned the key exists will report a
    /// permanent-looking URL for a page with a week to live.
    @Test func documentsTheResponseShape() {
        #expect(skillDocument.markdown.contains("\"slug\""))
        #expect(skillDocument.markdown.contains("\"url\""))
        #expect(skillDocument.markdown.contains("\"expires\""))
    }

    /// The default lifetime, pinned to the constant through the table row that states it.
    ///
    /// Unlike `documentsTheConfiguredSizeLimit` there is no negative half available: the
    /// default is a compile-time constant rather than an init parameter, so there is no
    /// "render with an unusual value" rendering to contrast against. What this test does
    /// catch is the drift that matters — a `7` typed into the prose in place of the
    /// interpolation would pass today and fail the moment the constant moved, which is
    /// exactly when a stale document would otherwise start teaching a wrong lifetime.
    ///
    /// Anchored on the table row rather than a sentence because the row is one line and
    /// structural; a prose phrase would break on any rewording that left the fact intact.
    @Test func documentsTheDefaultLifetime() {
        #expect(skillDocument.markdown.contains("| omitted | \(PageLifetime.defaultDays) days |"))
    }

    /// The rest of the `?ttl=` vocabulary: the parameter's name, the opt-out spelling, and
    /// the upper bound. All three are constants the parser reads, so a document that taught
    /// `forever`, or `lifetime=`, or a bound the server does not enforce would be a `200`
    /// from this route and a `400` for the agent that followed it — the worst shape of
    /// wrong, because nothing on either side reports a problem with the document.
    @Test func documentsTheLifetimeGrammar() {
        let markdown = skillDocument.markdown
        #expect(markdown.contains("?\(PageLifetime.queryParameter)="))
        #expect(
            markdown.contains("\(PageLifetime.queryParameter)=\(PageLifetime.neverKeyword)")
        )
        #expect(markdown.contains("\(PageLifetime.maxDays)"))
    }

    /// The asymmetry an agent updating a page will otherwise get wrong: `stele update`
    /// addresses a page that already exists and refuses to create one, so an agent that
    /// reaches for it to publish gets a `404` and no page. Prose-level, and it replaces the
    /// `Content-Type` asymmetry this test used to pin — that one was about headers the
    /// agent no longer sends, and a document that still explained it would be teaching the
    /// mechanics of a request the reader never makes.
    @Test func documentsThatUpdateNeverCreates() {
        #expect(skillDocument.markdown.contains("`stele update <slug> <file>` **never creates**"))
    }

    /// It is a SKILL.md, and the frontmatter is what an agent runtime reads to decide whether
    /// this document applies at all. Without it the file is just prose.
    @Test func hasFrontmatter() {
        #expect(skillDocument.markdown.hasPrefix("---\n"))
        #expect(skillDocument.markdown.contains("\nname: "))
        #expect(skillDocument.markdown.contains("\ndescription: "))
    }

    /// The `description` is the whole activation surface — a runtime reads it to decide
    /// whether to open this document, and reads nothing else. So the triggers have to name
    /// every capability the body teaches, or a section is unreachable in exactly the
    /// situation it was written for: an agent told to unpublish the page it put here
    /// matches nothing, never loads the skill, and either refuses or invents a route, which
    /// is the sub-path invention the Pitfalls section exists to prevent. `hasFrontmatter`
    /// only asserts the line exists; this asserts it still names all three write verbs, and
    /// the search is scoped to the frontmatter because the words appear all over the body.
    ///
    /// One test over all three rather than one per verb: what this pins is that the trigger
    /// list and the body stayed the same size, and that is a single fact. `replace` earned
    /// its place here the slow way — it shipped with `PUT` and went unnamed until `DELETE`
    /// made the omission a pattern, which is the argument for asserting the whole set at
    /// once instead of the verb most recently added.
    @Test func frontmatterTriggersOnEveryWriteVerb() throws {
        let close = try #require(skillDocument.markdown.range(of: "\n---\n"))
        let frontmatter = skillDocument.markdown[..<close.lowerBound]
        for trigger in ["publish", "replace", "update", "delete", "unpublish"] {
            #expect(frontmatter.contains(trigger), "\(trigger)")
        }
    }

    // MARK: - The 404 surface

    /// The reservation at HTTP level rather than only in `Slug`: neither write verb may hand
    /// out `skill`, because a page stored there would be shadowed by this route the moment it
    /// was published. The read at the end is the real assertion — the rejections mean nothing
    /// if the document had been shadowed anyway.
    @Test func skillCannotBeClaimedAsASlug() async throws {
        let headers: HTTPFields = [
            .authorization: "Bearer \(TestFixture.publishToken)",
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
