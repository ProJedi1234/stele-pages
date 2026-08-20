import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import PostgresNIO

/// Content types a page may be stored and served as.
///
/// An allowlist rather than "echo whatever the client sent" — this is a page server,
/// not a general file host, and reflecting an arbitrary `Content-Type` back out is how
/// an upload endpoint turns into a way to serve executables from your domain.
public enum PageContentType {
    public static let `default` = "text/html; charset=utf-8"

    static let allowed: [String: String] = [
        "text/html": "text/html; charset=utf-8",
        "text/plain": "text/plain; charset=utf-8",
        "text/css": "text/css; charset=utf-8",
        "text/markdown": "text/markdown; charset=utf-8",
    ]

    /// Types stored as bytes rather than as text — the attachment half of the allowlist.
    ///
    /// A separate table rather than more rows in `allowed`, because membership *is* the
    /// decision: which of these two dictionaries a request's type appears in determines
    /// whether its body is validated as UTF-8, which byte limit applies, and which column
    /// it lands in. One table with a flag beside each row would put that decision in a
    /// field somebody can forget to read.
    ///
    /// No `charset` on any of them: these are not text, and a charset parameter on a PNG is
    /// a claim about an encoding it does not have. The value is the same string as the key
    /// for that reason, which is not an invitation to collapse the two — the canonical form
    /// of a *text* type differs from its key, and this table is read by the same code.
    ///
    /// SVG is deliberately absent and should stay absent. It is the one image format that
    /// executes script when navigated to directly, and the viewer's whole job is to be a
    /// page you navigate to. That the server already hosts uploaded HTML is not an argument
    /// for adding it: HTML arrives from a caller who knows they are publishing a document,
    /// while an `<img>` is the shape nobody inspects.
    static let allowedAttachments: [String: String] = [
        "image/png": "image/png",
        "image/jpeg": "image/jpeg",
        "image/gif": "image/gif",
        "image/webp": "image/webp",
        "video/mp4": "video/mp4",
        "video/webm": "video/webm",
        "application/pdf": "application/pdf",
    ]

    /// Every type this server will store, in one sorted list, for the message a `415` is
    /// answered with. Derived rather than typed out, so a type added to either table shows
    /// up in the refusal that names them.
    static var everyAllowedType: [String] {
        (Array(allowed.keys) + Array(allowedAttachments.keys)).sorted()
    }

    /// Normalises a request `Content-Type` to its canonical stored form, or nil if it
    /// isn't something we're willing to serve back. An *absent* header never reaches
    /// this — the write handlers decide what absence means for their verb.
    static func normalize(_ raw: String) -> String? {
        allowed[base(of: raw)]
    }

    /// Resolves a request `Content-Type` to its canonical stored form *and* to the kind of
    /// body that type implies, or nil if it is not something we are willing to serve back.
    ///
    /// One lookup answering both questions, because they are the same question asked twice:
    /// a type is stored as bytes precisely when it is in the attachment table. A caller that
    /// normalised first and then asked "is this binary?" would be free to disagree with
    /// itself, and the disagreement — text validated as UTF-8 and then written to the blob
    /// column, or the reverse — is one no test would think to write.
    static func resolve(_ raw: String) -> (stored: String, kind: PageKind)? {
        let base = base(of: raw)
        if let text = allowed[base] { return (text, .text) }
        if let attachment = allowedAttachments[base] { return (attachment, .blob) }
        return nil
    }

    /// The type and subtype, lowercased, with any parameters dropped.
    private static func base(of raw: String) -> String {
        raw.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
    }

    /// A short tag for a stored content type — "CSS", "PLAIN", "MARKDOWN" — or nil for HTML,
    /// which is what a page is unless it says otherwise and so is worth no ink.
    ///
    /// Derived from the subtype rather than looked up in a second table keyed by the same
    /// strings `allowed` is. A table would be a list of every content type this server
    /// serves, sitting next to the list of every content type this server serves, and adding
    /// a type would silently produce a page in the index labelled with nothing. There is
    /// nothing here to keep in agreement with anything.
    static func label(for stored: String) -> String? {
        let base = stored.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        guard base != "text/html" else { return nil }
        // The subtype, which is the part that distinguishes these from each other — every
        // allowed type is `text/…`, so the type half would be the same word on every badge.
        guard let subtype = base.split(separator: "/").last, !subtype.isEmpty else { return nil }
        return subtype.uppercased()
    }
}

/// The JSON body every write route that returns one answers with — POST, PUT and PATCH.
/// `DELETE` is the exception and answers `204` with nothing.
///
/// The document at `GET /skill` shows a sample of this body, but the sample cannot promise
/// a key *order*: `JSONEncoder` emits a keyed container's members in an unspecified order,
/// and three consecutive uploads really do come back ordered three different ways. What the
/// skill promises instead — and what the encoding below actually guarantees — is that all
/// three keys are always present. Anything reading this body must read it by key.
struct PageLocationResponse: Encodable {
    let slug: String
    let url: String
    /// The page's deadline as an RFC 3339 instant in UTC, or nil for a page that never
    /// expires.
    let expires: String?

    enum CodingKeys: String, CodingKey {
        case slug, url, expires
    }

    /// Hand-written rather than synthesised for one reason, in one line. The synthesised
    /// `Encodable` calls `encodeIfPresent` for an optional property, which *omits the key
    /// entirely* when it is nil — so a permanent page would answer `{"slug":…,"url":…}`,
    /// and a caller reading `expires` could not tell "this page never expires" from "this
    /// server has no opinion about lifetimes". An explicit null says the first thing.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(url, forKey: .url)
        if let expires {
            try container.encode(expires, forKey: .expires)
        } else {
            try container.encodeNil(forKey: .expires)
        }
    }
}

/// The `POST /admin/clients` request body.
///
/// Only `name` is required. `scopes` defaults to `[publish]`, which is what an agent
/// credential wants and all it should get; `expiresIn` is a count of **seconds from now**,
/// and its absence means a credential that does not expire. Seconds rather than a duration
/// string because this is a machine contract — `stele admin clients create --expires-in 30d`
/// is the CLI's job to parse, and a server that also accepted `30d` would be a second
/// grammar to keep in agreement with the first.
struct CreateClientRequest: Decodable {
    let name: String
    let scopes: [String]?
    let expiresIn: Int?
}

/// The `POST /auth/github/exchange` request body: a GitHub access token, and nothing else.
///
/// Nothing else, deliberately. The name of the credential to mint comes from the login
/// GitHub reports rather than from the caller, so an owner cannot sign in as a name of their
/// choosing and quietly take over a hand-minted credential; the scopes are fixed at
/// `publish`; and the expiry is fixed at none. Every field this body might plausibly have
/// grown is a field an unauthenticated caller would get to influence.
///
/// `accessToken` in camelCase, matching `CreateClientRequest` rather than GitHub's
/// snake_case `access_token`. This body is stele's contract with its own client — the GitHub
/// token happens to be its payload, and borrowing GitHub's spelling for it would be the
/// beginning of a wire format that looks like a proxy for theirs.
struct GitHubExchangeRequest: Decodable {
    let accessToken: String
}

/// One credential as the admin API reports it.
///
/// There is no `token` field and no `tokenHash` field, and neither is an omission this type
/// could quietly lose: `Client` does not carry the token at all, and the digest is dropped
/// here so that even a future `Client` that gained one could not reach a response body
/// through this struct. `id` is dropped too — the name is the handle every admin route
/// addresses, so exposing a second identifier would only invite the CLI to key on it.
///
/// `Encodable` is synthesized, and stays that way: `JSONEncoder` omits a nil `Optional`
/// rather than writing a null, so absence is this type's whole vocabulary for "never
/// happened" — never used, never expires, not revoked, not minted by a GitHub account. A
/// hand-written `encode(to:)` emitting explicit nulls would change every one of those wire
/// shapes at once, for the sake of one field.
struct ClientResponse: Encodable {
    let name: String
    let scopes: [String]
    let createdAt: Date
    let lastUsedAt: Date?
    let expiresAt: Date?
    let revokedAt: Date?
    /// Which GitHub account minted this, for the credentials that were minted that way.
    /// Reported rather than withheld because it is the only thing distinguishing a
    /// credential the operator issued from one somebody signed in for, and the listing is
    /// where that question is asked. It is not a secret: an owner's login is public on
    /// GitHub, and this route is already behind `admin` or behind the credential itself.
    let githubLogin: String?

    init(_ client: Client) {
        self.name = client.name
        self.scopes = client.scopes
        self.createdAt = client.createdAt
        self.lastUsedAt = client.lastUsedAt
        self.expiresAt = client.expiresAt
        self.revokedAt = client.revokedAt
        self.githubLogin = client.githubLogin
    }
}

/// `GET /admin/clients`. An object rather than a bare top-level array: a JSON array cannot
/// grow a sibling field, so the day this needs a cursor or a total every parser breaks.
struct ClientListResponse: Encodable {
    let clients: [ClientResponse]
}

/// `POST /admin/clients`, and the only response in this server that carries a secret.
///
/// The token is returned exactly once, here, because it is stored only as a digest — the
/// server cannot produce it a second time, and a caller that drops it has to mint a
/// replacement. Nested rather than flattened alongside the credential's metadata so the
/// field that must never be logged, cached or echoed is visibly a thing apart, and so the
/// CLI can decode `client` with the same type it decodes a listing with.
struct CreatedClientResponse: Encodable {
    let token: String
    let client: ClientResponse
}

/// First path segments the server claims for itself.
///
/// `buildRouter` builds its routes from these constants and a test asserts that
/// `Slug.reserved` covers `ServerRoute.names`, so a new route that forgets its
/// reservation fails the suite instead of silently shadowing a stored page.
public enum ServerRoute {
    public static let healthz = "healthz"
    public static let pages = "pages"
    /// Only the first segment. The stylesheet's full path lives on `Stylesheet.path`,
    /// because `names` is exactly the set `Slug.reserved` has to cover and `stele.css` is
    /// not a first segment — nor a slug anyone could claim — so putting it here would make
    /// this set mean two different things at once.
    public static let assets = "assets"
    /// The publish skill an agent downloads to learn how to write for this server.
    /// Named here before any handler exists: the name only stops being claimable as a
    /// slug once it is in this set and in `Slug.reserved`, and a page that claimed
    /// `skill` before the route landed would be shadowed the day it did.
    public static let skill = "skill"
    /// Credential management. Like `assets`, only the first segment: the endpoints all sit
    /// underneath it, and `admin` itself answers with the uniform 404. Already in
    /// `Slug.reserved` long before this route existed, which is exactly what that
    /// forward-looking list is for.
    public static let admin = "admin"
    /// Signing in. Like `assets` and `admin`, only the first segment: the exchange endpoint
    /// sits two levels beneath it and `auth` itself answers the uniform 404. It is the one
    /// first segment whose children are reached by callers holding no stele credential at
    /// all — which is what the routes under it are for.
    ///
    /// Unlike `admin` and `skill`, this name had no head start: it was absent from
    /// `Slug.reserved` until the route landed, so `POST /pages?slug=auth` was a legal
    /// publish on any server running an earlier build. One such page is now shadowed by the
    /// stub below *and* unaddressable — `PUT`, `PATCH` and `DELETE` all pass through
    /// `validatedSlug`, which answers `400` for a reserved name — so it sits there until it
    /// expires, or forever if it was published `ttl=never`. The window to clear it is before
    /// this build is deployed, which is the whole reason `Slug.reserved` is a
    /// forward-looking list and not a description of the routes that exist.
    public static let auth = "auth"

    /// The site icon, at the root, where a browser looks for it without being told. Unlike
    /// every other name here it carries an extension, because that is the path browsers
    /// request by convention — and it is a first segment, so it belongs in `names` and in
    /// `Slug.reserved` like the rest. It is also the one route here that exists for pages
    /// this server did not write: an uploaded page links no icon of ours, so this is the
    /// only way its tab gets one.
    public static let favicon = "favicon.ico"

    /// Raw attachment bytes, at `/static/:slug`. Only the first segment, like `assets` and
    /// `admin`: the bytes live one level beneath it and `static` itself answers the uniform
    /// 404.
    ///
    /// Already in `Slug.reserved` long before this route existed, which is exactly what
    /// that forward-looking list is for — unlike `auth`, this name was never claimable, so
    /// no deployment can be carrying a page it now shadows.
    ///
    /// The bytes get their own segment rather than a query parameter on `/:slug` because
    /// the two are different resources: one is a page you look at and one is a file you
    /// embed. A `?raw=1` would make the distinction something a caller can forget, and the
    /// URL in an `<img src>` is the one nobody re-reads.
    public static let staticFiles = "static"

    public static let names: Set<String> = [
        healthz, pages, assets, skill, admin, auth, favicon, staticFiles,
    ]

    /// The one collection under `/admin`, as its *second* segment. Kept out of `names` for
    /// the same reason `stele.css` is: that set is exactly what `Slug.reserved` has to
    /// cover, and a second-segment name is not claimable as a slug — putting it there would
    /// make the set mean two different things at once.
    public static let adminClients = "clients"

    /// "Which credential am I holding?", also a second segment under `/admin` and kept out
    /// of `names` for the same reason.
    ///
    /// It lives under `admin` because that segment is already reserved and already carries
    /// everything about credentials — but it is emphatically **not** an `admin`-scoped
    /// route. See the route's own registration in `buildRouter`.
    public static let adminWhoami = "whoami"

    /// The identity provider, as the *second* segment under `/auth`, and out of `names` for
    /// the same reason `adminClients` is. Named rather than folded into a single
    /// `"github/exchange"` constant because it is the extension point: a second provider is
    /// a sibling here, and a single string would hide that the path has a shape.
    public static let authGitHub = "github"

    /// The token exchange itself, the third segment: hand over a GitHub access token,
    /// receive a stele credential.
    public static let authExchange = "exchange"
}

/// Wires up the router. Split out from `buildApplication` so tests can exercise routes
/// without standing up a listening socket.
///
/// Both stores arrive as existentials-by-generics (`some …Storing`) rather than as the
/// concrete Postgres types, which is what lets the HTTP suite run the real routing, auth
/// and status codes against in-memory fakes with no database anywhere. `github` is the same
/// arrangement for the one dependency that is neither ours nor a database: the sign-in route
/// has to be exercisable — refusals included, especially the refusals — without a socket to
/// `api.github.com`.
///
/// None of the three is defaulted. A default here would be a production dependency chosen by
/// omission at whichever call site forgot to pass one, and there are only two call sites —
/// `buildApplication` and the test fixture — each with an opinion worth stating out loud.
public func buildRouter(
    configuration: Configuration,
    store: some PageStoring,
    clients: some ClientStoring,
    github: some GitHubIdentifying
) -> Router<SteleRequestContext> {
    let generator = SlugGenerator(wordCount: configuration.slugWords)
    // Explicit context type: the routes carry the authenticated `Client` on it, and the
    // default `BasicRequestContext` has nowhere to put one.
    let router = Router(context: SteleRequestContext.self)

    router.add(middleware: LogRequestsMiddleware(.info))

    router.get(RouterPath("/\(ServerRoute.healthz)")) { _, _ -> String in "ok" }

    // The one read on the public surface that touches the store without being addressed at a
    // slug. Unauthenticated like every other read, which is a decision and not an inherited
    // default: it publishes the live half of the namespace to anyone who loads the root URL.
    // The README argues that out — slugs are already guessable by a script, and the index
    // shows only pages that are still being served, so it costs a scanner time rather than
    // telling it anything a scan would not.
    router.get("/") { _, context -> Response in
        // A store that cannot be read degrades the index rather than the page. Everything
        // else here is documentation — how to publish, what the lifetimes are, where the
        // skill lives — and all of it is still true and still worth serving while Postgres is
        // down. A 500 would replace a working answer to "how do I use this" with nothing.
        //
        // The error is logged rather than swallowed: this is the one branch where the page
        // looks fine and the server is not, so the signal has to come from somewhere.
        let recent: [PageSummary]?
        do {
            recent = try await store.recent(limit: recentPageCount)
        } catch {
            context.logger.error(
                "could not read the recent-pages index",
                metadata: ["error": "\(error)"]
            )
            recent = nil
        }

        return htmlResponse(
            status: .ok,
            html: landingPage(baseURL: configuration.baseURL, recent: recent)
        )
    }

    router.group(RouterPath(ServerRoute.pages))
        .add(middleware: BearerTokenMiddleware(
            clients: clients,
            sharedToken: configuration.uploadToken
        ))
        // Both write verbs, one scope. `publish` is what an agent credential carries and
        // all it carries, which is the property that makes revocation work: a leaked
        // publishing token can deface pages — bad, bounded, and recoverable from a
        // re-publish — but it cannot mint itself a second credential and revoke yours.
        //
        // The shared `STELE_UPLOAD_TOKEN` is `admin`-only and therefore fails here. That is
        // the demotion, not an oversight: it stopped being the publish credential when it
        // became the one that mints them.
        .add(middleware: RequireScopeMiddleware(.publish))
        // Last in the chain: a client too old to write is still told about its credential
        // first, because a `426` sends it to reinstall a CLI that would have failed
        // authentication anyway. A caller that does not identify itself as the CLI passes
        // straight through — curl is still a supported way to publish.
        .add(middleware: MinimumCLIVersionMiddleware())
        .post("") { request, context -> Response in
            let (body, contentType) = try await readValidatedPage(
                request: request,
                configuration: configuration
            )

            // A caller-supplied slug is validated with exactly the same rules as a
            // generated one, so nothing enters the table that couldn't be served back.
            let requestedSlug = try request.uri.queryParameters["slug"]
                .map { try validatedSlug(String($0)) }

            // The lifetime is checked here, with the slug and after the body, rather than
            // first. POST already decided once that its *optional* query parameters come
            // after the body — the opposite of PUT, whose slug is the address being written
            // to and so is worth rejecting before a megabyte streams at it. `?ttl=` is an
            // optional query parameter of exactly that kind, so it inherits that decision
            // instead of making POST's precedence two decisions to keep straight.
            let lifetime = try validatedLifetime(
                request.uri.queryParameters[Substring(PageLifetime.queryParameter)]
            )

            let slug: Slug
            do {
                slug = try await store.create(
                    requestedSlug: requestedSlug,
                    body: body,
                    contentType: contentType ?? PageContentType.default,
                    expiresAt: lifetime.expiresAt,
                    // Who wrote it, recorded at the moment it is written. The optional
                    // chain cannot actually produce nil — this route is behind
                    // `BearerTokenMiddleware`, which sets `client` or throws — but
                    // `attributableID` can, and that nil is the shared token's: see
                    // `Client.attributableID`.
                    clientID: context.client?.attributableID,
                    generator: generator,
                    logger: context.logger
                )
            } catch PageStoreError.slugTaken(let taken) {
                throw HTTPError(.conflict, message: "The slug '\(taken)' is already taken.")
            } catch PageStoreError.couldNotAllocateSlug(let attempts) {
                context.logger.error("slug allocation exhausted", metadata: ["attempts": "\(attempts)"])
                throw HTTPError(.serviceUnavailable, message: "Could not allocate a slug.")
            }

            return try pageResponse(
                slug: slug,
                expiresAt: lifetime.expiresAt,
                configuration: configuration,
                status: .created,
                includeLocation: true
            )
        }
        // Unlike POST, the slug is validated before the body is read: POST's slug is an
        // optional query parameter, whereas here it is the address being written to, and
        // rejecting a nonsense address before streaming a megabyte to it is the cheaper
        // order. Precedence is auth, then slug, then the body checks.
        .put(":slug") { request, context -> Response in
            let slug = try validatedSlug(context.parameters.require("slug"))

            // Refused, not ignored. A replacement cannot move a deadline (see below), so
            // there is nothing this verb could do with the value — but accepting and
            // discarding it would be exactly the silent default the POST parser exists to
            // prevent: `?ttl=never` here would answer `200`, and a caller who believed they
            // had just made the page permanent would have no signal at all. Checked with the
            // slug, before the body, for the same reason the slug is: a request that cannot
            // succeed should not first stream a megabyte.
            guard request.uri.queryParameters[Substring(PageLifetime.queryParameter)] == nil
            else {
                throw HTTPError(
                    .badRequest,
                    message: """
                        PUT does not take ?\(PageLifetime.queryParameter)=. A replacement \
                        cannot move a deadline; use PATCH \
                        /\(ServerRoute.pages)/:slug?\(PageLifetime.queryParameter)= to \
                        change it.
                        """
                )
            }

            let (body, contentType) = try await readValidatedPage(
                request: request,
                configuration: configuration
            )

            // Update-only: an absent slug is a 404, never an implicit create. A PUT that
            // could create would hand the caller a way to claim names without going
            // through the generator's — and POST's — collision reporting.
            //
            // A replacement reports the stored deadline and does not move it — the expiry
            // belongs to the page, not to its current body — so the value reported below is
            // the one the store handed back, never one recomputed here. That is why a
            // `?ttl=` on this verb was rejected above rather than applied.
            //
            // Attribution is the one thing a replacement *does* move: the column records who
            // last wrote the page, so this re-attributes it rather than leaving the original
            // publisher credited for content they did not write.
            let expiresAt: Date?
            switch try await store.update(
                slug: slug,
                body: body,
                contentType: contentType,
                clientID: context.client?.attributableID
            ) {
            case .replaced(let stored):
                expiresAt = stored
            case .noSuchPage:
                // An expired page that has not been reclaimed yet arrives here too, so this
                // verb and `GET /:slug` agree about which pages exist.
                throw HTTPError(.notFound, message: "No page exists at \(slug.value).")
            }

            // No Location header: the resource is where the caller already addressed it.
            return try pageResponse(
                slug: slug,
                expiresAt: expiresAt,
                configuration: configuration,
                status: .ok,
                includeLocation: false
            )
        }
        // Everything about a page except its contents: where it lives and how long it lives.
        // A separate verb rather than query parameters bolted onto PUT, because the two
        // operations are independent — extending a deadline should not require re-uploading a
        // megabyte, and replacing a body should not be a chance to silently move a deadline.
        // That is also why PUT's refusal of `?ttl=` stays exactly as it was: it is still true
        // that *a replacement* cannot retime a page, and this verb is not a replacement.
        //
        // Reads no body, like DELETE and for the same reason: there is nothing here to store,
        // so the content-type allowlist has nothing to apply to and `handleHTTP` drains
        // whatever a caller sends anyway.
        .patch(":slug") { request, context -> Response in
            let slug = try validatedSlug(context.parameters.require("slug"))

            let requestedSlug = request.uri.queryParameters["slug"]
            let requestedTTL = request.uri.queryParameters[Substring(PageLifetime.queryParameter)]

            // An amendment that amends nothing is a `400`, not a `200` over an untouched
            // page. The caller reached for this verb because they wanted something changed,
            // and the shape of that mistake is a forgotten or misspelled parameter — which a
            // success would confirm as having worked.
            guard requestedSlug != nil || requestedTTL != nil else {
                throw HTTPError(
                    .badRequest,
                    message: """
                        Nothing to amend. Pass ?slug= to rename the page, \
                        ?\(PageLifetime.queryParameter)= to change how long it lives, or both.
                        """
                )
            }

            // Validated with `Slug(custom:)` exactly as POST's `?slug=` is, so a rename
            // cannot put a name into the table that a fresh publish would have refused —
            // including a reserved one, which would otherwise be shadowed by its own route.
            let newSlug = try requestedSlug.map { try validatedSlug(String($0)) }

            // The one place in the server where an absent `?ttl=` must *not* mean the
            // default. `PageLifetime(raw: nil)` resolves to `defaultDays`, which is the right
            // answer for a page being published and precisely the wrong one here: a caller
            // renaming a permanent page would have it silently given a week to live. So the
            // parser is only reached when the parameter is actually present, and its absence
            // becomes a nil instruction rather than a parsed value.
            let newExpiry: PageExpiry?
            if let requestedTTL {
                newExpiry = PageExpiry(try validatedLifetime(requestedTTL))
            } else {
                newExpiry = nil
            }

            switch try await store.amend(
                slug: slug,
                newSlug: newSlug,
                newExpiry: newExpiry,
                logger: context.logger
            ) {
            case .amended(let resulting, let expiresAt):
                // The resulting slug, never the requested one: only the store knows whether
                // a rename was asked for, and answering with `newSlug ?? slug` here would be
                // a second place deciding that.
                //
                // No Location header even when the page moved. PUT sets none because the
                // caller already knows the address; here they do not, but the body's `url`
                // is where every client already reads it from, and a `Location` on a `200`
                // means something looser than "it is over there" — the one client that
                // followed it and the one that read `url` would disagree about nothing,
                // which is not worth two ways to learn one fact.
                return try pageResponse(
                    slug: resulting,
                    expiresAt: expiresAt,
                    configuration: configuration,
                    status: .ok,
                    includeLocation: false
                )
            case .noSuchPage:
                // Expired-but-unreclaimed arrives here too, so this verb agrees with GET,
                // PUT and DELETE about which pages exist.
                throw HTTPError(.notFound, message: "No page exists at \(slug.value).")
            case .slugTaken(let taken):
                // The same message POST answers a claimed `?slug=` with, because it is the
                // same fact and the same remedy: pick another name.
                throw HTTPError(.conflict, message: "The slug '\(taken)' is already taken.")
            }
        }
        // The one write that never reads a body. DELETE carries no payload, so
        // `readValidatedPage` is deliberately not called and the content-type allowlist has
        // nothing to apply to — sending `Content-Type: image/png` here is not an error,
        // because nothing is being stored to serve back. Leaving the body unread is safe
        // for the connection too: `handleHTTP` drains whatever body parts remain before it
        // reads the next request head, so a caller who sends bytes anyway does not wedge a
        // keep-alive connection. Ordering is PUT's — auth, then the slug, then the store.
        .delete(":slug") { _, context -> Response in
            let slug = try validatedSlug(context.parameters.require("slug"))

            // An absent slug is a 404, not an idempotent 204, mirroring PUT: the caller is
            // already past the upload token, so there is nothing left for a distinguishing
            // failure to leak to, and a script that deleted a typo'd slug would otherwise
            // be told it succeeded at work it never did.
            guard try await store.delete(slug: slug) else {
                throw HTTPError(.notFound, message: "No page exists at \(slug.value).")
            }

            // 204 with no body, rather than POST and PUT's `{slug, url}`. The url in that
            // payload would point at what is now a 404 — a link handed back by a
            // success response that leads nowhere is worse than saying nothing, and
            // there is no resource left to describe.
            var response = Response(status: .noContent)
            // And 204 means *no content*, not zero-length content: RFC 9112 §6.2 forbids
            // `Content-Length` on this status outright. `Response.init` adds one anyway —
            // an empty `ResponseBody` reports a length of 0 rather than nil, and the
            // initialiser writes whatever length the body reports — so the header is
            // removed here rather than never set. Nearly every client tolerates the
            // spec-violating form, which is exactly why it would have survived unnoticed;
            // the ones that don't are intermediaries, and a proxy that rejects a delete
            // the server actually performed is a failure with no signal at either end.
            response.headers[.contentLength] = nil
            return response
        }

    // The trie matches the literal `pages` node for `GET /pages` and does not backtrack
    // to `/:slug`, so without this the framework's own plain-text 404 would leak out —
    // the one response that would distinguish a routed-but-methodless path from every
    // other miss. Registered outside the bearer-token group: a 404 must not demand auth,
    // or its 401 becomes the distinguishing signal instead.
    router.get(RouterPath("/\(ServerRoute.pages)")) { _, _ -> Response in
        htmlResponse(status: .notFound, html: notFoundPage())
    }

    // "Who am I?", and the one route under `/admin` that is **not** `admin`-scoped.
    //
    // Its own group, carrying `BearerTokenMiddleware` and nothing else, because the caller
    // that runs this most is a publish-only agent: `stele auth status` is the first command
    // the skill tells one to run, and `stele auth login` checks a credential here before
    // writing it to disk. Adding it to the scoped group below would answer both with a 403 —
    // the credential works perfectly, and the one command that exists to say so would be the
    // one that denies it.
    //
    // No `MinimumCLIVersionMiddleware` either, deliberately. The gate is on the routes where
    // an old decoder loses something it cannot get back (a `201`'s one-time token) or writes
    // under a contract it may not speak. This route only reports, and it is what an agent
    // reaches for when something has already gone wrong — a diagnostic that refuses to
    // answer until you reinstall is a diagnostic that cannot tell you your credential is
    // fine. The `426` still arrives on the first write, where it is actionable.
    //
    // What it returns is `ClientResponse`, the same type the admin listing uses, so the
    // credential's name, scopes and expiry are reported by the one struct in this file that
    // is built to hold no token and no digest. There is nothing here that could grow one.
    router.group(RouterPath(ServerRoute.admin))
        .add(middleware: BearerTokenMiddleware(
            clients: clients,
            sharedToken: configuration.uploadToken
        ))
        .get(RouterPath(ServerRoute.adminWhoami)) { _, context -> Response in
            guard let client = context.client else {
                // Unreachable behind the middleware above, which either sets `client` or
                // throws. Fails closed and says so in the log for the same reason
                // `RequireScopeMiddleware` does: the mistake that gets here is a wiring
                // one, and it compiles.
                context.logger.error(
                    "whoami ran with no authenticated client; check the middleware order"
                )
                throw HTTPError(.unauthorized, message: "Missing Authorization header.")
            }
            return try jsonResponse(status: .ok, payload: ClientResponse(client))
        }

    // Credential management. Behind the same bearer middleware as the write routes and then
    // behind `admin`, which no agent credential carries — the whole point of having scopes
    // at all is that a compromised publisher cannot reach these three routes.
    //
    // Errors here are deliberately distinguishable (400 for a bad name, 404 for an unknown
    // one, 409 for a duplicate), which the README permits and this caller needs: they are
    // already behind an admin credential, so there is nothing left to leak to them.
    router.group(RouterPath(ServerRoute.admin))
        .add(middleware: BearerTokenMiddleware(
            clients: clients,
            sharedToken: configuration.uploadToken
        ))
        .add(middleware: RequireScopeMiddleware(.admin))
        // Gated on the same minimum as the write routes, listing included. A client too old
        // to mint a credential is also too old to be trusted to *display* one — the token
        // in a `201` here is shown exactly once, and a stale decoder that drops the field
        // loses it for good.
        .add(middleware: MinimumCLIVersionMiddleware())
        .post(RouterPath(ServerRoute.adminClients)) { request, context -> Response in
            let payload = try await readCreateClientRequest(request: request)
            let name = try validatedClientName(payload.name)
            let scopes = try validatedScopes(payload.scopes)
            let expiresAt = try validatedExpiry(payload.expiresIn)

            let created: (client: Client, token: String)
            do {
                created = try await clients.create(
                    name: name, scopes: scopes, expiresAt: expiresAt
                )
            } catch ClientStoreError.nameTaken(let taken) {
                // "still live", because a revoked one does not hold the name — rotating a
                // credential is revoke-then-mint under the same name, and the operator who
                // hits this needs to know which half they skipped.
                throw HTTPError(
                    .conflict,
                    message: """
                        A client named '\(taken)' is still live. Revoke it first to \
                        reissue that name.
                        """
                )
            }

            // Named, never quoted: the token is in scope on the line above and must not
            // reach a log, which is the one place a secret survives longest and is read
            // by the most people.
            context.logger.info(
                "minted a client credential",
                metadata: [
                    "client": "\(created.client.name)",
                    "scopes": "\(created.client.scopes.joined(separator: ","))",
                ]
            )

            return try jsonResponse(
                status: .created,
                payload: CreatedClientResponse(
                    token: created.token,
                    client: ClientResponse(created.client)
                )
            )
        }
        .get(RouterPath(ServerRoute.adminClients)) { _, _ -> Response in
            try jsonResponse(
                status: .ok,
                payload: ClientListResponse(
                    clients: try await clients.allClients().map(ClientResponse.init)
                )
            )
        }
        // `DELETE` rather than a `POST …/revoke`: revocation is the only kind of deletion
        // this table has. The row stays — a credential's history is what an incident is
        // reconstructed from — so what is deleted is the credential's ability to
        // authenticate, which is what the caller meant.
        .delete(RouterPath("\(ServerRoute.adminClients)/:name")) { _, context -> Response in
            let name = try validatedClientName(context.parameters.require("name"))
            // Idempotent in the way that matters: revoking twice returns the same
            // `revokedAt` rather than moving it — see `ClientStore.revoke`. An unknown name
            // is still a 404, because a typo the operator cannot see is how a credential
            // they believe is revoked stays live.
            guard let revoked = try await clients.revoke(name: name) else {
                throw HTTPError(.notFound, message: "No client named '\(name)' exists.")
            }
            context.logger.info("revoked a client credential", metadata: ["client": "\(name)"])
            return try jsonResponse(status: .ok, payload: ClientResponse(revoked))
        }

    // The same trie trap as `/pages` and `/assets`, and the same fix: adding the literal
    // `admin` node means `GET /admin` matches it rather than falling through to `/:slug`,
    // and `Trie.resolve` does not backtrack when the final component lands on a node with
    // no value. Registered *outside* the group above on purpose — a 404 must not demand
    // auth, or the 401 it would answer with becomes the one response that says "something
    // lives here", which is a worse leak on this path than on any other.
    router.get(RouterPath("/\(ServerRoute.admin)")) { _, _ -> Response in
        htmlResponse(status: .notFound, html: notFoundPage())
    }

    // Signing in with GitHub, and the first route in this server that is neither a public
    // read nor behind a credential. It **is** the authentication, which is why it sits in no
    // group at all: the caller is here precisely because they hold no stele token yet, and
    // what they present instead is a GitHub access token they obtained from GitHub directly.
    // A `BearerTokenMiddleware` in front of this would demand the thing it exists to issue.
    //
    // No `RequireScopeMiddleware` either, and not as an oversight: a scope is a fact about a
    // stele credential, and there is none on this request to have facts about. The credential
    // this route *hands out* carries `publish` and only `publish` — a sign-in produces an
    // agent's credential, never an operator's, so what an owner walks away with can neither
    // mint nor revoke.
    //
    // The route itself is a different question, and the honest answer is that it revokes:
    // whatever live credential holds the login's name, whoever minted it and whatever scopes
    // it carries. That is the rotation below, and its sharp edge is that `POST
    // /admin/clients` and this route share one namespace — an operator who hand-mints
    // `projedi1234` has named it after somebody's GitHub login, and that person's next
    // sign-in retires it. See the README, and
    // `GitHubExchangeTests.aSignInRetiresAHandMintedCredentialUnderTheLoginsName`.
    //
    // And no `MinimumCLIVersionMiddleware`, which is the one omission that looks like a
    // mistake. The gate is deliberately registered *after* authentication everywhere else so
    // it never answers an unauthenticated prober; here there is no authentication for it to
    // sit after. It would also be gating the bootstrap on the thing being bootstrapped — a
    // user whose CLI is too old would be told to upgrade by the one route that could have
    // given them the credential everything else needs.
    router.post(RouterPath(
        "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)/\(ServerRoute.authExchange)"
    )) { request, context -> Response in
        let payload = try await readGitHubExchangeRequest(request: request)

        // One `guard`, one `throw`, and every refusal reaches it. Five different facts —
        // GitHub rejected the token, the login is not an owner, this deployment has no
        // owners, the token was empty, the token held bytes no `Authorization` header can
        // carry — collapsed to one nil inside `owner(presenting:allowedBy:)` before they got
        // here, so there is no shape in this handler that could accidentally be branched on.
        // Every one of them belongs on that side of the seam rather than in a guard here: a
        // second `throw` site is a second thing to keep byte-identical with the first, and
        // the whole property being defended is that a caller cannot tell these apart.
        guard let login = try await github.owner(
            presenting: payload.accessToken,
            allowedBy: configuration.githubOwners,
            logger: context.logger
        )
        else { throw githubExchangeRejected }

        // Past the allowlist, so this caller is an owner and a distinguishing error is
        // licensed by exactly the rule the admin routes run on — there is nothing left to
        // leak to them. In practice the `400` is unreachable: GitHub logins are ASCII
        // letters, digits and hyphens and at most 39 characters, which is a subset of what
        // `Client.validated(name:)` accepts once lowercased. It goes through the chokepoint
        // anyway, because "GitHub could never send that" is an assumption about somebody
        // else's system and the cost of checking is one function call.
        let name = try validatedClientName(login.lowercased())

        // Signing in twice is a rotation, not a conflict. The live credential under this
        // name is revoked and a fresh one minted under the same name, so the answer to "I
        // lost my token" or "I am on a new machine" is to sign in again — which is the only
        // recovery there can be, since the old plaintext exists nowhere.
        //
        // `revoke(name:)` resolves by name and by nothing else, so this retires an
        // `admin`-scoped credential an operator happened to name after this login just as
        // readily as the one the last sign-in left. That is the namespace the two minting
        // routes share, argued out at the registration above.
        //
        // The nil this discards is the first-ever sign-in (no such name), and its
        // already-revoked answer is `COALESCE` keeping the original timestamp; neither is a
        // fact the caller needs, because the call means "make this name free", not "tell me
        // what was there". The retired row stays in `clients` with its `revoked_at` set,
        // which is the audit trail — and this rides the live-only name index that migration
        // 4 added for precisely this rotation path.
        _ = try await clients.revoke(name: name)

        let created: (client: Client, token: String)
        do {
            // `login`, not `name`: the credential is *addressed* by the folded spelling
            // because a URL path segment has no uppercase in its alphabet, and it is
            // *attributed* to the canonical one GitHub reports, because that is the spelling
            // the owner would recognise. Recording the fold instead would throw away the only
            // half of the identity that is not already the name.
            created = try await clients.create(
                name: name, scopes: [.publish], expiresAt: nil, githubLogin: login
            )
        } catch ClientStoreError.nameTaken {
            // Two sign-ins for one login, interleaved: both revoked, one minted, and this
            // one found the name live again. Post-authentication, so it may say so, and the
            // remedy is genuinely "try that again" — a second attempt now finds the name
            // held by a live row it will revoke itself.
            throw HTTPError(
                .conflict,
                message: """
                    Another sign-in for '\(name)' is in flight. Retry: the credential this \
                    one would have replaced now exists.
                    """
            )
        }

        // The token is in scope on the line above and is named here rather than quoted. The
        // login is not a secret; the credential it just bought is.
        context.logger.info(
            "minted a client credential via github",
            metadata: ["client": "\(created.client.name)", "login": "\(login)"]
        )

        return try jsonResponse(
            status: .created,
            payload: CreatedClientResponse(
                token: created.token,
                client: ClientResponse(created.client)
            )
        )
    }

    // The same trie trap as `/pages`, `/assets` and `/admin`: registering the exchange above
    // creates the literal `auth` node, so `GET /auth` matches it, finds no value, and does
    // **not** backtrack to `/:slug`. Without this it would answer the framework's own
    // plain-text 404 — the one distinguishable response on the public read surface. Outside
    // every group, like the others, and here that is not merely convention: a 401 on this
    // segment would advertise that signing in is a thing this deployment does.
    //
    // `GET /auth/github` needs no stub of its own and deliberately does not get one. A
    // two-segment path can never be a slug, so the framework's envelope there tells a
    // scanner nothing the uniform page would not — the same reasoning `/pages/foo` already
    // runs on.
    router.get(RouterPath("/\(ServerRoute.auth)")) { _, _ -> Response in
        htmlResponse(status: .notFound, html: notFoundPage())
    }

    // The stylesheet ships with the binary, so it is served from a constant rather than
    // the store: it is code, and it changes by deploy, not by upload. Unauthenticated like
    // every other read — it is linked as a subresource by every published page.
    router.get(RouterPath(Stylesheet.path)) { request, _ -> Response in
        shippedDocumentResponse(
            ifNoneMatch: request.headers[.ifNoneMatch],
            etag: Stylesheet.etag,
            contentType: Stylesheet.contentType,
            body: ByteBuffer(string: Stylesheet.css)
        )
    }

    // The site icon, on the same terms as the stylesheet: it ships with the binary and
    // changes by deploy. Served from two paths for one reason each — `/assets/favicon.png`
    // is what the built-in pages link, and `/favicon.ico` is what a browser asks for when
    // nothing links anything, which is every page an uploader wrote. Same bytes, same
    // `image/png` content type: the `.ico` in that path is a convention about where to
    // look, not a claim about the format, and browsers have taken PNGs there for years.
    for iconPath in [Favicon.path, "/\(ServerRoute.favicon)"] {
        router.get(RouterPath(iconPath)) { request, _ -> Response in
            shippedDocumentResponse(
                ifNoneMatch: request.headers[.ifNoneMatch],
                etag: Favicon.etag,
                contentType: Favicon.contentType,
                body: ByteBuffer(bytes: Favicon.bytes)
            )
        }
    }

    // Rendered once here rather than per request: it interpolates this deployment's own base
    // URL and byte limit, so it is configuration-shaped rather than a compile-time constant —
    // but it is fixed for the life of the process, and so is its ETag. Unauthenticated for the
    // same reason every other read is, and because an agent bootstrapping from this document
    // has no token yet: the token is for writing.
    //
    // No bare-segment 404 stub, unlike `/pages` and `/assets`: `/skill` is a terminal node
    // that carries its own value, so the trie resolves it. It therefore must NOT appear in
    // `NotFoundTests.all404sAreIdentical`.
    let skill = PublishSkill(baseURL: configuration.baseURL, maxPageBytes: configuration.maxPageBytes)

    router.get(RouterPath(PublishSkill.path)) { request, _ -> Response in
        shippedDocumentResponse(
            ifNoneMatch: request.headers[.ifNoneMatch],
            etag: skill.etag,
            contentType: PublishSkill.contentType,
            body: ByteBuffer(string: skill.markdown)
        )
    }

    // Same trap as `GET /pages`: adding the literal `assets` node means `/assets` matches
    // it instead of falling through to `/:slug`, and `Trie.resolve` does not backtrack to a
    // sibling when the final component lands on a node with no value. Without this,
    // `/assets` answers with the framework's own 404 while every other miss answers with
    // the page — the one distinguishable response on the public read surface. Outside any
    // auth group, for the same reason `/pages`' guard is.
    router.get(RouterPath("/\(ServerRoute.assets)")) { _, _ -> Response in
        htmlResponse(status: .notFound, html: notFoundPage())
    }

    // Raw attachment bytes: what an `<img src>` or a `<video src>` points at, and the one
    // read in this server that can answer a `206`.
    //
    // Unauthenticated like every other read, and a miss answers the same uniform 404 page
    // `GET /:slug` does — absent, expired, malformed and "that slug is a text page" are one
    // response here for the reason they are one there. A text page is a miss rather than a
    // redirect to itself: this path means "the bytes of an attachment", and a page has none
    // in that sense.
    router.get(RouterPath("/\(ServerRoute.staticFiles)/:slug")) { request, context -> Response in
        guard let raw = context.parameters.get("slug"),
              let slug = try? Slug(custom: raw)
        else { return htmlResponse(status: .notFound, html: notFoundPage()) }

        let requested = RequestedRange.parse(request.headers[.range])

        // A suffix range is the one shape that cannot be resolved without the total, so it
        // costs a first read to learn it. An empty range is that read: `substring(… for 0)`
        // returns no bytes and the row still reports `byte_size`, so this is a metadata
        // query spelled in the vocabulary the seam already has rather than a second
        // primitive that would exist for one branch.
        let totalSize: Int
        if case .suffix = requested {
            guard let probe = try await store.fetchBlob(slug: slug, range: 0..<0) else {
                return htmlResponse(status: .notFound, html: notFoundPage())
            }
            totalSize = probe.totalSize
        } else {
            // Every other shape resolves without knowing the size. An explicit end needs
            // nothing, and `bytes=N-` resolves to a range open at the top — which is how
            // `fetchBlob` is told to read to the end, so this is a real value rather than a
            // placeholder standing in for one.
            totalSize = Int.max
        }

        guard let slice = try await store.fetchBlob(
            slug: slug, range: requested.resolved(totalSize: totalSize)
        ) else {
            return htmlResponse(status: .notFound, html: notFoundPage())
        }

        // The digest quoted into an entity-tag. Strong, because it identifies the bytes
        // exactly — it came from them — and revalidation is what makes an embedded image
        // free to re-request on every page load without re-sending it.
        let etag = "\"\(slice.digest)\""
        if ifNoneMatchHits(request.headers[.ifNoneMatch], etag: etag) {
            return Response(
                status: .notModified,
                headers: [.eTag: etag, .cacheControl: "no-cache", .acceptRanges: "bytes"]
            )
        }

        var headers: HTTPFields = [
            .contentType: slice.contentType,
            // These bytes are somebody else's, which is this repo's rule for where the
            // header goes. It matters more here than on a stored page: the allowlist is
            // what says a `.png` is a PNG, and a browser that sniffed its way to something
            // else would be running it on this origin.
            .xContentTypeOptions: "nosniff",
            // Mutable in place, exactly like a page — `PUT` replaces the bytes and the URL
            // does not move — so a cache must always come back and ask. The ETag is what
            // makes the ask a bodyless round trip rather than a re-download of a video.
            .cacheControl: "no-cache",
            .eTag: etag,
            // Advertised on every response, not only on a `206`. A player that cannot see
            // this on the first request does not send a second one with a `Range`.
            .acceptRanges: "bytes",
        ]
        if let disposition = attachmentDisposition(
            contentType: slice.contentType, filename: slice.filename
        ) {
            headers[.contentDisposition] = disposition
        }

        guard let range = requested.resolved(totalSize: slice.totalSize) else {
            return Response(
                status: .ok, headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: slice.bytes))
            )
        }

        // A range starting at or past the end is the one a `416` exists for, and the
        // `Content-Range` on it is the bare total — which is how a client that guessed
        // wrong learns the size to ask again with. `fetchBlob` reports the real total for
        // exactly this branch rather than clamping the range into something satisfiable,
        // which would answer a request nobody made.
        guard range.lowerBound < slice.totalSize else {
            var refused: HTTPFields = [
                .contentRange: "bytes */\(slice.totalSize)",
                .acceptRanges: "bytes",
            ]
            refused[.contentType] = nil
            return Response(status: .rangeNotSatisfiable, headers: refused)
        }

        // Inclusive end, and computed from what came back rather than from what was asked
        // for: the store clamps a range that overruns the file, and a `Content-Range`
        // describing the request instead of the response is how a player ends up waiting
        // for bytes that were never sent.
        let end = range.lowerBound + slice.bytes.count - 1
        headers[.contentRange] = "bytes \(range.lowerBound)-\(end)/\(slice.totalSize)"
        return Response(
            status: .partialContent, headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: slice.bytes))
        )
    }

    // The same trie trap as `/pages`, `/assets`, `/admin` and `/auth`: registering the
    // route above creates the literal `static` node, so `GET /static` matches it, finds no
    // value, and does not backtrack to `/:slug`. Outside any group, like the others.
    router.get(RouterPath("/\(ServerRoute.staticFiles)")) { _, _ -> Response in
        htmlResponse(status: .notFound, html: notFoundPage())
    }

    router.get("/:slug") { _, context -> Response in
        guard let raw = context.parameters.get("slug"),
              let slug = try? Slug(custom: raw),
              let page = try await store.fetch(slug: slug),
              // An attachment has no presentation yet — the viewer that renders one is the
              // next layer. Until it lands this falls through to the same uniform 404 an
              // absent slug gets, which is the right placeholder precisely because it is
              // indistinguishable: nothing here leaks that a row exists.
              case .text(let body) = page.content
        else {
            // Anything that isn't a live page gets the same 404, whether the slug was
            // malformed, reserved, or simply absent. Distinguishing them would let a
            // scanner map the namespace faster than guessing.
            return htmlResponse(status: .notFound, html: notFoundPage())
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: page.contentType,
                // Stops a browser content-sniffing a stored page into something we
                // didn't agree to serve it as.
                .xContentTypeOptions: "nosniff",
                // Pages are mutable (PUT replaces them in place) and carry no validator,
                // so without this a cache may heuristically keep serving pre-update
                // bytes with nothing for the caller to bust it with.
                .cacheControl: "no-cache",
            ],
            body: .init(byteBuffer: ByteBuffer(string: body))
        )
    }

    return router
}

/// The one response shape for documents that ship with the binary — today the stylesheet,
/// the publish skill and the site icon. All mutate in place across deploys (which is the feature: an
/// edit reaches every page, or every agent, at once), so a cache must always come back and
/// ask; `no-cache` forces that, and the strong ETag makes the ask a bodyless round trip
/// rather than a re-download. No `nosniff`, because these bytes are ours — that header is
/// this repo's marker for bodies we did *not* write. Shared so a conditional-GET fix (a
/// 304 header, `Vary`, HEAD) cannot land on one route and silently miss the other.
private func shippedDocumentResponse(
    ifNoneMatch: String?,
    etag: String,
    contentType: String,
    body: ByteBuffer
) -> Response {
    if ifNoneMatchHits(ifNoneMatch, etag: etag) {
        return Response(status: .notModified, headers: [.eTag: etag, .cacheControl: "no-cache"])
    }

    return Response(
        status: .ok,
        headers: [.contentType: contentType, .eTag: etag, .cacheControl: "no-cache"],
        body: .init(byteBuffer: body)
    )
}

/// Whether an `If-None-Match` header says the caller already holds `etag`.
///
/// Not string equality, which is what this started as. RFC 9110 §13.1.2 defines the header
/// as a *list* of entity-tags or `*`, compared with the **weak** function — `W/"abc"` and
/// `"abc"` match. Exact equality looks safe when the server only ever emits one strong tag,
/// but it fails the moment anything sits in front: nginx's gzip module rewrites a strong
/// `ETag` into `W/"…"`, so the browser revalidates with a weak tag, nothing matches, and
/// every conditional request re-sends the whole sheet — precisely the download the ETag was
/// added to avoid, and invisible from both ends because a 200 is still a correct answer.
private func ifNoneMatchHits(_ rawHeader: String?, etag: String) -> Bool {
    guard let rawHeader else { return false }
    let header = rawHeader.trimmingCharacters(in: .whitespaces)
    // `*` means "any current representation", and serving this route means we have one.
    if header == "*" { return true }
    return header.split(separator: ",").contains { candidate in
        let tag = candidate.trimmingCharacters(in: .whitespaces)
        // Weak comparison: the weakness prefix is stripped before the opaque tags are
        // compared. Only the candidate can carry one — ours is always strong.
        return tag == etag || (tag.hasPrefix("W/") && String(tag.dropFirst(2)) == etag)
    }
}

/// Runs a raw path or query slug through the `Slug(custom:)` chokepoint, reporting a
/// rejection the same way for every write route.
private func validatedSlug(_ raw: String) throws -> Slug {
    do {
        return try Slug(custom: raw)
    } catch {
        // Untyped `catch`, for the same reason as `validatedClientName` below:
        // `Slug(custom:)` is `throws(SlugError)`, so the binding is already that type and
        // an `as` pattern would only earn an always-true warning.
        throw HTTPError(.badRequest, message: "Invalid slug: \(error).")
    }
}

/// Runs a credential name through `Client.validated(name:)`, on the way in *and* on the way
/// back out.
///
/// `DELETE` validates the path segment it was handed rather than trusting that it must be
/// fine because a valid name was required to create the row. The two routes have to agree
/// on the alphabet or a name that `POST` accepted would address nothing here — running both
/// through one function is what makes disagreeing impossible.
private func validatedClientName(_ raw: String) throws -> String {
    do {
        return try Client.validated(name: raw)
    } catch {
        // Untyped `catch`: `validated(name:)` throws `ClientNameError` and nothing else, so
        // the binding is already that type and an `as` pattern would only earn an
        // always-true warning.
        throw HTTPError(.badRequest, message: "Invalid client name: \(error).")
    }
}

/// Resolves the requested scopes, defaulting to the one an agent credential should have.
///
/// An unrecognised scope is a 400 rather than a stored string that grants nothing. `Client`
/// tolerates unknown scopes on the *read* path deliberately — a row written by a newer
/// build must not fail the lookup — but writing one here would mint a credential that
/// silently cannot do the thing the operator asked for, and they would not find out until
/// the agent's first publish failed.
private func validatedScopes(_ raw: [String]?) throws -> [ClientScope] {
    let allowed = ClientScope.allCases.map(\.rawValue).sorted().joined(separator: ", ")
    guard let raw else { return [.publish] }
    guard !raw.isEmpty else {
        throw HTTPError(
            .badRequest,
            message: """
                A credential with no scopes could do nothing. Omit "scopes" for the \
                default (\(ClientScope.publish.rawValue)), or name some of: \(allowed).
                """
        )
    }
    let parsed = try raw.map { candidate in
        guard let scope = ClientScope(rawValue: candidate) else {
            throw HTTPError(
                .badRequest,
                message: "Unknown scope '\(candidate)'. Allowed: \(allowed)."
            )
        }
        return scope
    }
    // Stable dedupe: `["publish", "publish"]` is a typo, not a request for something
    // different, and storing it would make every listing of that credential read oddly.
    var seen: Set<ClientScope> = []
    return parsed.filter { seen.insert($0).inserted }
}

/// The furthest ahead `expiresIn` may reach. A century is far past any credential anyone
/// means to issue, and "no expiry at all" is already spelled by omitting the field — so
/// nothing legitimate lives between here and the top of `Int`.
///
/// The bound is a safety limit, not a policy one. A `timestamptz` is microseconds in an
/// `Int64`, and PostgresNIO's `Date` encoder converts to that with a plain `Int64(_:)` over
/// a `Double`: a date past roughly the year 294000 does not fail to bind, it **traps**, and
/// a trap in a request handler takes the process and every in-flight request with it. That
/// is reachable from one JSON field, so the field is bounded here rather than trusted to be
/// sensible.
let maxExpiresInSeconds = 100 * 365 * 24 * 60 * 60

/// Turns `expiresIn` seconds into the absolute instant stored in `expires_at`.
///
/// Absolute rather than relative in the database, so a credential's death is a fact rather
/// than something derived from a `created_at` that a restore or a timezone could move.
///
/// - Parameter moment: injectable so the arithmetic is testable without the wall clock.
private func validatedExpiry(_ seconds: Int?, from moment: Date = Date()) throws -> Date? {
    guard let seconds else { return nil }
    guard seconds > 0 else {
        throw HTTPError(
            .badRequest,
            message: """
                "expiresIn" is a number of seconds from now and must be positive. \
                Omit it for a credential that does not expire.
                """
        )
    }
    guard seconds <= maxExpiresInSeconds else {
        throw HTTPError(
            .badRequest,
            message: """
                "expiresIn" is at most \(maxExpiresInSeconds) seconds (a century). \
                Omit it for a credential that does not expire.
                """
        )
    }
    return moment.addingTimeInterval(TimeInterval(seconds))
}

/// The largest `POST /admin/clients` body worth reading.
///
/// Its own constant rather than `configuration.maxPageBytes`: that limit is about how big a
/// *page* an operator wants to allow and is tuned for that, whereas this body is a
/// three-field JSON object and anything near a megabyte of it is a mistake or an attack.
private let maxAdminRequestBytes = 16 * 1024

/// Reads and decodes the `POST /admin/clients` body.
///
/// Decoded by hand rather than through the context's request decoder so the failure is one
/// message that names the shape expected. `DecodingError`'s own text is written for a
/// programmer holding the type, and this one is read by an operator at a terminal who has
/// mistyped a field name.
private func readCreateClientRequest(request: Request) async throws -> CreateClientRequest {
    let buffer: ByteBuffer
    do {
        buffer = try await request.body.collect(upTo: maxAdminRequestBytes)
    } catch is NIOTooManyBytesError {
        throw HTTPError(
            .contentTooLarge,
            message: "Request body exceeds the \(maxAdminRequestBytes) byte limit."
        )
    }
    do {
        // `Data(buffer.readableBytesView)` rather than `Data(buffer:)`, which lives in
        // NIOFoundationCompat — a module this target does not declare a dependency on and
        // gets only transitively.
        return try JSONDecoder().decode(
            CreateClientRequest.self, from: Data(buffer.readableBytesView)
        )
    } catch {
        throw HTTPError(
            .badRequest,
            message: """
                Expected a JSON object: {"name": "…", "scopes": ["…"], "expiresIn": <seconds>}. \
                Only "name" is required.
                """
        )
    }
}

/// Reads and decodes the `POST /auth/github/exchange` body.
///
/// A sibling of `readCreateClientRequest` and hand-decoded for the same reason: the failure
/// is one message naming the shape expected, rather than `DecodingError`'s text, which is
/// written for a programmer holding the type.
///
/// This 400 is the one thing on this route that is *not* the uniform 401, and that is the
/// same distinction `BearerTokenMiddleware` draws between a missing `Authorization` header
/// and a rejected one: a caller who sent no credential at all has learned nothing about
/// which credentials exist. What they get told is what the body should look like, which is
/// public API, and being told it is what turns a mistyped field name into a fixable mistake
/// instead of an indistinguishable refusal.
private func readGitHubExchangeRequest(request: Request) async throws -> GitHubExchangeRequest {
    let buffer: ByteBuffer
    do {
        // The same 16 KiB cap the admin body uses. A GitHub token is a few dozen bytes and
        // this object holds one field; the limit is about what an unauthenticated route is
        // willing to buffer, and this is the most unauthenticated route there is.
        buffer = try await request.body.collect(upTo: maxAdminRequestBytes)
    } catch is NIOTooManyBytesError {
        throw HTTPError(
            .contentTooLarge,
            message: "Request body exceeds the \(maxAdminRequestBytes) byte limit."
        )
    }
    do {
        return try JSONDecoder().decode(
            GitHubExchangeRequest.self, from: Data(buffer.readableBytesView)
        )
    } catch {
        throw HTTPError(
            .badRequest,
            message: #"Expected a JSON object: {"accessToken": "…"}."#
        )
    }
}

/// The one answer every refused sign-in gets, defined once for the same reason
/// `BearerTokenMiddleware.rejected` is.
///
/// "GitHub rejected that token", "that is a real GitHub account and not an owner of this
/// deployment" and "this deployment has no owners configured" are three facts, and a caller
/// learns none of them. The second is the dangerous one: an endpoint that distinguished it
/// would be an oracle for who owns the deployment — anyone holding a GitHub token of their
/// own could walk it and read the allowlist off the status codes, and the allowlist is a
/// list of people whose accounts are worth attacking.
///
/// A computed property with one call site is not ceremony here. The property being defended
/// is that every refusal is byte-identical *including its headers*, which survives exactly
/// as long as there is one place that constructs it; the version of this route with a
/// `throw HTTPError(.unauthorized, …)` at each refusing branch passes every test the day it
/// is written and drifts the first time somebody improves one message.
private var githubExchangeRejected: HTTPError {
    HTTPError(.unauthorized, message: "GitHub sign-in was refused.")
}

/// Resolves the `?ttl=` query parameter into an expiry, reporting a rejection the way every
/// other write-side validation failure is reported.
///
/// Takes the raw `Substring?` straight off the query rather than a `String`, because the
/// difference between the two nil-ish inputs is the whole point: an *absent* parameter means
/// "no opinion" and gets the default lifetime, while `?ttl=` with nothing after it arrives
/// as `""` and is a mistake. Collapsing them — with `?? ""`, or by trimming — would publish
/// a week-long page for somebody who thought they had asked for something else, which is
/// exactly the silent defaulting this parameter exists to prevent.
private func validatedLifetime(_ raw: Substring?) throws -> PageLifetime {
    do {
        return try PageLifetime(raw: raw.map(String.init))
        // A bare `catch`, where `validatedSlug` above writes `catch let error as SlugError`
        // for the same shape — and not as a style preference. The `as` form crashes the
        // 6.3.3 compiler in SILGen ("Found ownership error") on this error type. The bare
        // form is equivalent, because `PageLifetime.init` uses typed throws and `error` is
        // therefore already a `PageLifetimeError`. Revisit when the toolchain moves; there
        // is nothing here worth keeping but the workaround.
    } catch {
        throw HTTPError(
            .badRequest, message: "Invalid \(PageLifetime.queryParameter): \(error)."
        )
    }
}

/// The request checks every write shares: an allowed content type, and a body that fits,
/// isn't empty, and is text. Shared by POST and PUT so the two cannot drift into
/// accepting different things into the same table.
///
/// `contentType` is nil when the request carried no `Content-Type` header at all — the
/// caller expressed no opinion. What that means differs by verb: POST picks the HTML
/// default (a new page has no prior type), PUT preserves the stored one (silently
/// re-typing a stylesheet to HTML would break every page linking it, behind a 200).
private func readValidatedPage(
    request: Request,
    configuration: Configuration
) async throws -> (body: PageBody, contentType: String?) {
    let contentType: String?
    let kind: PageKind
    if let raw = request.headers[.contentType] {
        guard let resolved = PageContentType.resolve(raw) else {
            throw HTTPError(
                .unsupportedMediaType,
                message: """
                    Unsupported Content-Type. Allowed: \
                    \(PageContentType.everyAllowedType.joined(separator: ", ")).
                    """
            )
        }
        contentType = resolved.stored
        kind = resolved.kind
    } else {
        // No header means text, and it has to: the type is what says a body is bytes, so
        // deciding that from the bytes themselves would be content sniffing — the exact
        // guess `nosniff` is sent on every stored page to prevent a browser making. An
        // attachment therefore names its type or is not one, and a PNG PUT with no header
        // fails the UTF-8 check below rather than being stored as an unreadable page.
        contentType = nil
        kind = .text
    }

    // The filename belongs to an attachment and to nothing else, so asking for one on a
    // text write is refused rather than dropped — the same reading `PUT`'s `?ttl=` gets. A
    // caller who sent it believes the page will download under that name, and a `200` would
    // confirm it.
    let requestedFilename = request.uri.queryParameters[Substring(filenameQueryParameter)]
    guard kind == .blob || requestedFilename == nil else {
        throw HTTPError(
            .badRequest,
            message: """
                ?\(filenameQueryParameter)= applies to an attachment. This request's \
                Content-Type is a text type, which is stored as a page rather than as a file.
                """
        )
    }
    let filename = try requestedFilename.map { try validatedFilename(String($0)) }

    // The limit follows the kind, because the two answer different questions: one is how
    // much HTML an operator will host, the other how much of a screen recording. Checked
    // before the body is read rather than after, which is what `collect(upTo:)` gives —
    // a request over the limit is refused as it streams instead of after it has all
    // arrived.
    let limit = kind == .blob ? configuration.maxAttachmentBytes : configuration.maxPageBytes
    let buffer: ByteBuffer
    do {
        buffer = try await request.body.collect(upTo: limit)
    } catch is NIOTooManyBytesError {
        // Only the size limit gets this message. Anything else — a dropped connection,
        // cancellation during shutdown — rethrows as itself, so a transport fault is
        // never reported as a too-large page.
        throw HTTPError(
            .contentTooLarge,
            message: kind == .blob
                ? "Attachment exceeds the \(limit) byte limit."
                : "Page exceeds the \(limit) byte limit."
        )
    }
    guard buffer.readableBytes > 0 else {
        throw HTTPError(.badRequest, message: "Request body is empty.")
    }

    // Bytes are stored as they arrived. None of the three checks below applies to them:
    // an attachment is not required to be UTF-8, a NUL is ordinary in a PNG, and `bytea`
    // holds every byte a `text` column cannot.
    if kind == .blob {
        return (.blob(bytes: Array(buffer.readableBytesView), filename: filename), contentType)
    }
    // A validating decode straight out of the buffer, not `ByteBuffer.getString`: that
    // one is `String?` but never actually returns nil — it decodes with
    // `String(decoding:)`, which substitutes U+FFFD for invalid bytes and would store
    // mojibake at a permanent URL instead of telling the caller their upload wasn't text.
    guard let body = buffer.withUnsafeReadableBytes({
        String(validating: $0, as: Unicode.UTF8.self)
    }) else {
        throw HTTPError(.badRequest, message: "Request body is not valid UTF-8.")
    }
    // Valid UTF-8, but Postgres `text` cannot hold it — without this check a NUL
    // surfaces as a database error and a 500 instead of a complaint about the body.
    guard !body.contains("\0") else {
        throw HTTPError(.badRequest, message: "Request body contains a NUL byte.")
    }

    return (.text(body), contentType)
}

/// The query parameter naming an attachment's original filename.
let filenameQueryParameter = "filename"

/// The longest filename worth storing. Generous next to anything a real file is called,
/// and short enough that the header it ends up in stays a header.
private let maxFilenameLength = 255

/// Validates `?filename=`, which is the one caller-supplied string in this server that is
/// echoed back into a response *header* rather than into a path or a body.
///
/// That is what the checks are for. `Content-Disposition` is a structured header, so a
/// filename carrying a quote or a backslash can close the quoted string early and a CR or
/// LF can end the header outright — the classic response-splitting shape. A slug goes
/// through `Slug(custom:)` for the same kind of reason; this is that chokepoint for the
/// other string a caller gets to choose.
///
/// Path separators go too, and not because of this server: the name is a hint to whichever
/// browser saves the file, and `../../.bashrc` is a hint worth refusing to pass on.
private func validatedFilename(_ raw: String) throws -> String {
    guard !raw.isEmpty else {
        throw HTTPError(
            .badRequest,
            message: "?\(filenameQueryParameter)= is empty. Omit it, or name the file."
        )
    }
    guard raw.count <= maxFilenameLength else {
        throw HTTPError(
            .badRequest,
            message: """
                ?\(filenameQueryParameter)= is at most \(maxFilenameLength) characters.
                """
        )
    }
    // Explicit rather than a regular expression, so the message can name the character the
    // caller actually sent — which is the difference between a fixable mistake and a
    // refusal they have to guess at.
    let forbidden: Set<Character> = ["\"", "\\", "/", "\r", "\n", "\0"]
    if let offender = raw.first(where: { forbidden.contains($0) || $0.isASCII && $0.asciiValue! < 0x20 }) {
        throw HTTPError(
            .badRequest,
            message: """
                ?\(filenameQueryParameter)= contains \(offender.debugDescription), which \
                cannot appear in a filename this server hands to a browser.
                """
        )
    }
    return raw
}

/// The one JSON response every API route answers with, so the two encoder settings below
/// cannot end up applying to one route and not another.
private func jsonResponse(
    status: HTTPResponse.Status,
    headers extra: HTTPFields = [:],
    payload: some Encodable
) throws -> Response {
    let encoder = JSONEncoder()
    // Without this, Foundation emits "http:\/\/host\/slug". Legal JSON, but the URL is
    // the thing the caller reads off the terminal.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    // RFC 3339, not Foundation's default of seconds-since-2001 as a bare double — which is
    // unreadable at a terminal, and is silently wrong in every language whose epoch is 1970.
    encoder.dateEncodingStrategy = .iso8601
    var body = ByteBuffer()
    body.writeBytes(try encoder.encode(payload))

    var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
    for field in extra { headers[field.name] = field.value }

    return Response(status: status, headers: headers, body: .init(byteBuffer: body))
}

/// The `{slug, url, expires}` body the three body-returning writes answer with. POST adds
/// `Location` and a `201`; PUT and PATCH return `200` without one — PUT because the caller
/// already knows the address, PATCH because the body's `url` is where a caller reads a moved
/// page's new one. (DELETE answers `204` and no body at all.)
///
/// `expiresAt` is undefaulted deliberately, and the case for that got stronger as the call
/// sites multiplied: all three get the value from a different place — POST from the lifetime
/// it just parsed, PUT from what the store reported for a deadline it did not touch, PATCH
/// from what the store reported for one it may well have — so a default would let any of them
/// silently answer "permanent" for a page that is not.
private func pageResponse(
    slug: Slug,
    expiresAt: Date?,
    configuration: Configuration,
    status: HTTPResponse.Status,
    includeLocation: Bool
) throws -> Response {
    let payload = PageLocationResponse(
        slug: slug.value,
        url: "\(configuration.baseURL)/\(slug.value)",
        // RFC 3339 in UTC, formatted here rather than left to the encoder's
        // `dateEncodingStrategy`, whose default is a Cocoa reference-date `Double` — a
        // number no other language's JSON client would recognise as a time. A format
        // *style* rather than an `ISO8601DateFormatter`, which is a non-`Sendable` class
        // that could not be hoisted to a constant under strict concurrency anyway.
        expires: expiresAt.map { $0.formatted(.iso8601) }
    )
    var extra: HTTPFields = [:]
    if includeLocation { extra[.location] = payload.url }

    return try jsonResponse(status: status, headers: extra, payload: payload)
}

/// Builds the full application: Postgres client, schema migrations, and HTTP server.
public func buildApplication(
    configuration: Configuration,
    logger: Logger
) async throws -> some ApplicationProtocol {
    let postgresClient = PostgresClient(
        configuration: configuration.database,
        backgroundLogger: logger
    )
    let store = PageStore(client: postgresClient, logger: logger)
    // Two stores over one connection pool. They are separate types because they answer to
    // separate seams — `PageStore` is still the only file that touches the `pages` table —
    // and one migration list, owned by `PageStore`, creates the schema for both.
    let clients = ClientStore(client: postgresClient, logger: logger)
    // The only place a real `GitHubAPI` is constructed. It holds nothing — no connection
    // pool, no lifetime — because it makes its requests through `HTTPClient.shared`, so
    // unlike `postgresClient` there is no service to register and nothing to shut down.
    let router = buildRouter(
        configuration: configuration,
        store: store,
        clients: clients,
        github: GitHubAPI()
    )

    var app = Application(
        router: router,
        configuration: .init(
            address: .hostname(configuration.host, port: configuration.port),
            serverName: "stele"
        ),
        logger: logger
    )
    // Registering the client as a service hands its connection-pool lifetime to the
    // same graceful-shutdown path as the HTTP server, so neither outlives the other.
    app.addServices(postgresClient)
    app.beforeServerStarts {
        logger.info("connecting to postgres", metadata: ["target": "\(configuration.databaseDescription)"])
        // Migrating here, before the server binds, is what keeps "there is no migrate
        // step" true. It also relies on the client's `run()` loop already executing so a
        // connection can be leased — it is, because `addServices` above starts it
        // concurrently, which is the same precondition every query in `PageStore` has.
        try await store.migrate()
        logger.info(
            "schema ready",
            metadata: [
                "slug_words": "\(configuration.slugWords)",
                "keyspace": "\(SlugGenerator(wordCount: configuration.slugWords).keyspace)",
            ]
        )
        // The one place an operator is told whether sign-in works, and it has to be here
        // because every other channel is closed by design: an unconfigured allowlist
        // refuses with the same bytes as a rejected token, deliberately, so a deployment
        // that forgot `STELE_GITHUB_OWNERS` would otherwise present as one where nobody
        // has tried to sign in yet. Whether, and not who: this line goes wherever the logs
        // go, and the allowlist is the set of people who may publish here.
        logger.info(
            "github sign-in",
            metadata: ["configured": "\(!configuration.githubOwners.isEmpty)"]
        )
    }
    return app
}

func htmlResponse(status: HTTPResponse.Status, html: String) -> Response {
    Response(
        status: status,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: .init(byteBuffer: ByteBuffer(string: html))
    )
}

/// The one 404 body every miss on the public read surface answers with.
///
/// It has to stay a compile-time constant — no echoed path, no nonce, no timestamp. The
/// byte-identity across malformed, reserved and absent slugs is the whole point, and a
/// single per-request detail would hand a scanner the distinction back. Interpolating
/// `Stylesheet.path` is safe precisely because it is a constant.
///
/// Deliberately plain: base typography plus the `.narrow` body modifier, which restates
/// the geometry this page used to carry inline.
func notFoundPage() -> String {
    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Not found</title>
    <link rel="stylesheet" href="\(Stylesheet.path)">
    <link rel="icon" href="\(Favicon.path)"></head>
    <body class="narrow"><h1>Nothing here</h1>
    <p>No page is published at this address. Check the link, or publish one with
    <code>POST /pages</code>.</p></body></html>
    """
}

// The landing page moved to `LandingPage.swift` when it stopped being a string constant and
// started reading the store.
