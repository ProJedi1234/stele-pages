import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The one fixture every HTTP-level suite builds its application from, so the boundary
/// values it pins — the token length, the base URL, the parse-only database URL — are
/// asserted in exactly one place instead of drifting per file.
enum TestFixture {
    /// The shared `STELE_UPLOAD_TOKEN`, at exactly the minimum accepted length so the
    /// fixture pins that boundary rather than drifting past it.
    ///
    /// This is the **admin** credential now, not the publishing one: it resolves to
    /// `Client.sharedToken`, which carries `admin` and nothing else, so a write route
    /// answers it with a 403. Suites that mean to publish want `publishToken` below; this
    /// one is for the admin routes and for the auth failures that never get as far as a
    /// scope check.
    static let token = String(repeating: "t", count: 16)

    /// The per-client credential every write suite publishes with, seeded into the default
    /// client store by `makeApp`.
    ///
    /// Carries `ClientCredential.prefix` because a token that did not would still work —
    /// nothing checks the prefix on the way in — and this way the fixture exercises the
    /// shape a real `POST /admin/clients` hands out.
    static let publishToken = ClientCredential.prefix + "fixture-publish-credential"

    /// A base URL that could not be a default, so an assertion on it proves the
    /// configured value reached the response rather than a hard-coded one.
    static let baseURL = "https://stele.example"

    /// The smallest environment that builds a `Configuration`. The `DATABASE_URL` only
    /// has to parse — nothing here constructs a `PostgresClient`, which only
    /// `buildApplication` does. `environment` lets a single test vary one setting (the
    /// byte limit) without a second fixture that could drift from this one.
    static func configuration(environment extra: [String: String] = [:]) throws -> Configuration {
        var environment = [
            "STELE_UPLOAD_TOKEN": token,
            "DATABASE_URL": "postgres://stele:secret@localhost:5432/stele",
            "STELE_BASE_URL": baseURL,
        ]
        for (key, value) in extra { environment[key] = value }
        return try Configuration(environment: environment)
    }

    /// Each test gets its own application and its own fakes — swift-testing runs tests in
    /// parallel, so nothing is shared.
    ///
    /// The default `clients` store holds exactly one credential — `publishToken`, scoped
    /// `publish` — because that is now the only kind of credential that can write a page.
    /// A suite testing the admin routes, or the shared token's own behaviour, passes its
    /// own store or authenticates with `token`.
    ///
    /// The default `github` identifies no token at all, so every suite that does not opt in
    /// gets a sign-in route that refuses everything. That is deliberate rather than merely
    /// convenient: nothing in this package may reach the network, and a fake that answered
    /// *something* by default would let a test pass while proving nothing about which
    /// identity it had arranged.
    ///
    /// It is the one parameter here taken as `some …`, where the two stores are concrete.
    /// GitHub is the dependency with a second fake worth building — the one that throws,
    /// standing in for an outage — and a concrete parameter would push the suite that needs
    /// it into building its own application beside this one, which is how two fixtures
    /// start disagreeing about what the default deployment looks like.
    static func makeApp(
        store: InMemoryPageStore = InMemoryPageStore(),
        clients: InMemoryClientStore = InMemoryClientStore(holding: publishToken),
        github: some GitHubIdentifying = InMemoryGitHub(),
        environment: [String: String] = [:]
    ) throws -> Application<RouterResponder<SteleRequestContext>> {
        Application(router: buildRouter(
            configuration: try configuration(environment: environment),
            store: store,
            clients: clients,
            github: github
        ))
    }

    /// Every whitespace-separated name inside a `class="…"` attribute of `html`.
    ///
    /// Hand-scanned rather than regex-matched so the tests pull in nothing beyond the
    /// stdlib, and deliberately naive: the inputs are the built-in pages and the snippets in
    /// the publish skill, and a parser clever enough to handle arbitrary HTML would be the
    /// thing under test instead. The scan stops at a line break as well as at the closing
    /// quote — an attribute value never spans one, so this costs nothing on real markup,
    /// and it keeps a `class="` in the skill's *prose* with no closing quote on its line
    /// from silently swallowing the rest of the document into garbage names. Lives here
    /// rather than in one suite because two of them now need it, and two copies of a drift
    /// detector is its own drift.
    static func classNames(in html: String) -> [String] {
        let attribute = "class=\""
        var names: [String] = []
        var index = html.startIndex
        while index < html.endIndex {
            guard html[index...].hasPrefix(attribute) else {
                index = html.index(after: index)
                continue
            }
            let start = html.index(index, offsetBy: attribute.count)
            var end = start
            while end < html.endIndex, html[end] != "\"", html[end] != "\n" {
                end = html.index(after: end)
            }
            names.append(contentsOf: html[start..<end].split(separator: " ").map(String.init))
            index = end
        }
        return names
    }

    /// Pulls the message out of Hummingbird's JSON error envelope.
    ///
    /// Read as JSON rather than substring-matched on the raw body: the encoder escapes
    /// slashes, so the wire bytes can read `text\/html` and a plain `contains` would miss.
    static func errorMessage(_ body: ByteBuffer) throws -> String {
        let payload = try JSONSerialization.jsonObject(with: Data(buffer: body))
        return try #require((payload as? [String: [String: String]])?["error"]?["message"])
    }

    /// A write route's JSON body, decoded loosely rather than through a mirror of
    /// `PageLocationResponse` — the wire shape is what these tests are about.
    ///
    /// `[String: Any]`, not `[String: String]`, which is what this started as: `expires` is
    /// JSON `null` for a permanent page, and a `[String: String]` cast fails outright on the
    /// `NSNull` that produces. That failure would land in whichever test happened to publish
    /// a permanent page, nowhere near the reason.
    static func writeResponse(_ body: ByteBuffer) throws -> [String: Any] {
        let payload = try JSONSerialization.jsonObject(with: Data(buffer: body))
        return try #require(payload as? [String: Any])
    }

    /// The `expires` field of a write response, as an instant, or nil for a permanent page.
    ///
    /// An *absent* key fails rather than reading as nil, and that distinction is the point:
    /// absence would mean the server had no opinion about the page's lifetime, and it always
    /// has one. Only an explicit JSON null says "this page never expires".
    static func expiry(in payload: [String: Any]) throws -> Date? {
        let raw = try #require(payload["expires"], "the response must carry an `expires` key")
        if raw is NSNull { return nil }
        let text = try #require(raw as? String, "`expires` must be a string or null")
        return try Date(text, strategy: .iso8601)
    }
}

/// Everything a caller probing for valid credentials can observe about a refusal, reduced
/// to something `==` can compare in one go.
///
/// Deliberately the *whole* response rather than a chosen subset: the point of the type is
/// that a future header — a `WWW-Authenticate` that names the failure, a `Retry-After` on
/// one branch only — is included in the comparison without anyone remembering to add it.
/// Headers are canonicalised and sorted because their order is not part of the message and
/// nothing observable depends on it.
///
/// It lives here rather than in `ClientAuthTests`, where it began, because two surfaces now
/// have the same property to defend: the bearer routes collapse unknown, revoked and expired
/// credentials into one 401, and `POST /auth/github/exchange` collapses a rejected GitHub
/// token, a non-owner and an unconfigured allowlist into another. Two copies of a drift
/// detector is its own kind of drift — the copy that stops comparing headers is the one
/// nobody notices.
struct Rejection: Equatable, Sendable {
    let status: HTTPResponse.Status
    let headers: [String]
    let body: [UInt8]

    init(_ response: TestResponse) {
        self.status = response.status
        self.headers = response.headers
            .map { "\($0.name.canonicalName): \($0.value)" }
            .sorted()
        self.body = Array(buffer: response.body)
    }
}

/// Reading a text page's body in an assertion, without the `case .text(let body) = …`
/// dance at every site.
///
/// Test-only on purpose. Production code pattern-matches `PageContent`, because the branch
/// it is skipping is the attachment one and an accessor returning nil there would let a
/// handler silently serve an empty body for a page it does not know how to render.
extension PageContent {
    /// Whether two contents are both text or both attachments, which is what the store's
    /// `CASE WHEN kind = …` asks of a replacement.
    func isSameKind(as other: PageContent) -> Bool {
        switch (self, other) {
        case (.text, .text), (.attachment, .attachment): true
        default: false
        }
    }

    var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    /// The counterpart, for asserting on an attachment's metadata.
    var attachment: (byteSize: Int, digest: String, filename: String?)? {
        guard case .attachment(let byteSize, let digest, let filename) = self else {
            return nil
        }
        return (byteSize, digest, filename)
    }
}
