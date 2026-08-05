import Foundation
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
    static func makeApp(
        store: InMemoryPageStore = InMemoryPageStore(),
        clients: InMemoryClientStore = InMemoryClientStore(holding: publishToken),
        environment: [String: String] = [:]
    ) throws -> Application<RouterResponder<SteleRequestContext>> {
        Application(router: buildRouter(
            configuration: try configuration(environment: environment),
            store: store,
            clients: clients
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
