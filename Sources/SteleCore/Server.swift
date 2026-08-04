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

    /// Normalises a request `Content-Type` to its canonical stored form, or nil if it
    /// isn't something we're willing to serve back. An *absent* header never reaches
    /// this — the write handlers decide what absence means for their verb.
    static func normalize(_ raw: String) -> String? {
        let base = raw.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return allowed[base]
    }
}

struct PageLocationResponse: Encodable {
    let slug: String
    let url: String
}

/// First path segments the server claims for itself.
///
/// `buildRouter` builds its routes from these constants and a test asserts that
/// `Slug.reserved` covers `ServerRoute.names`, so a new route that forgets its
/// reservation fails the suite instead of silently shadowing a stored page.
public enum ServerRoute {
    public static let healthz = "healthz"
    public static let pages = "pages"

    public static let names: Set<String> = [healthz, pages]
}

/// Wires up the router. Split out from `buildApplication` so tests can exercise routes
/// without standing up a listening socket.
public func buildRouter(
    configuration: Configuration,
    store: some PageStoring
) -> Router<BasicRequestContext> {
    let generator = SlugGenerator(wordCount: configuration.slugWords)
    let router = Router()

    router.add(middleware: LogRequestsMiddleware(.info))

    router.get(RouterPath("/\(ServerRoute.healthz)")) { _, _ -> String in "ok" }

    router.get("/") { _, _ -> Response in
        htmlResponse(status: .ok, html: landingPage(baseURL: configuration.baseURL))
    }

    router.group(RouterPath(ServerRoute.pages))
        .add(middleware: BearerTokenMiddleware(token: configuration.uploadToken))
        .post("") { request, context -> Response in
            let (body, contentType) = try await readValidatedPage(
                request: request,
                configuration: configuration
            )

            // A caller-supplied slug is validated with exactly the same rules as a
            // generated one, so nothing enters the table that couldn't be served back.
            let requestedSlug = try request.uri.queryParameters["slug"]
                .map { try validatedSlug(String($0)) }

            let slug: Slug
            do {
                slug = try await store.create(
                    requestedSlug: requestedSlug,
                    body: body,
                    contentType: contentType ?? PageContentType.default,
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

            let (body, contentType) = try await readValidatedPage(
                request: request,
                configuration: configuration
            )

            // Update-only: an absent slug is a 404, never an implicit create. A PUT that
            // could create would hand the caller a way to claim names without going
            // through the generator's — and POST's — collision reporting.
            guard try await store.update(slug: slug, body: body, contentType: contentType) else {
                throw HTTPError(.notFound, message: "No page exists at \(slug.value).")
            }

            // No Location header: the resource is where the caller already addressed it.
            return try pageResponse(
                slug: slug,
                configuration: configuration,
                status: .ok,
                includeLocation: false
            )
        }

    // The trie matches the literal `pages` node for `GET /pages` and does not backtrack
    // to `/:slug`, so without this the framework's own plain-text 404 would leak out —
    // the one response that would distinguish a routed-but-methodless path from every
    // other miss. Registered outside the bearer-token group: a 404 must not demand auth,
    // or its 401 becomes the distinguishing signal instead.
    router.get(RouterPath("/\(ServerRoute.pages)")) { _, _ -> Response in
        htmlResponse(status: .notFound, html: notFoundPage())
    }

    router.get("/:slug") { _, context -> Response in
        guard let raw = context.parameters.get("slug"),
              let slug = try? Slug(custom: raw),
              let page = try await store.fetch(slug: slug)
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
            body: .init(byteBuffer: ByteBuffer(string: page.body))
        )
    }

    return router
}

/// Runs a raw path or query slug through the `Slug(custom:)` chokepoint, reporting a
/// rejection the same way for every write route.
private func validatedSlug(_ raw: String) throws -> Slug {
    do {
        return try Slug(custom: raw)
    } catch let error as SlugError {
        throw HTTPError(.badRequest, message: "Invalid slug: \(error).")
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
) async throws -> (body: String, contentType: String?) {
    let contentType: String?
    if let raw = request.headers[.contentType] {
        guard let normalized = PageContentType.normalize(raw) else {
            throw HTTPError(
                .unsupportedMediaType,
                message: """
                    Unsupported Content-Type. Allowed: \
                    \(PageContentType.allowed.keys.sorted().joined(separator: ", ")).
                    """
            )
        }
        contentType = normalized
    } else {
        contentType = nil
    }

    let buffer: ByteBuffer
    do {
        buffer = try await request.body.collect(upTo: configuration.maxPageBytes)
    } catch is NIOTooManyBytesError {
        // Only the size limit gets this message. Anything else — a dropped connection,
        // cancellation during shutdown — rethrows as itself, so a transport fault is
        // never reported as a too-large page.
        throw HTTPError(
            .contentTooLarge,
            message: "Page exceeds the \(configuration.maxPageBytes) byte limit."
        )
    }
    guard buffer.readableBytes > 0 else {
        throw HTTPError(.badRequest, message: "Request body is empty.")
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

    return (body, contentType)
}

/// The `{slug, url}` body both writes answer with. POST adds `Location` and a `201`; PUT
/// returns `200` without one, since the caller already knows the address.
private func pageResponse(
    slug: Slug,
    configuration: Configuration,
    status: HTTPResponse.Status,
    includeLocation: Bool
) throws -> Response {
    let payload = PageLocationResponse(
        slug: slug.value,
        url: "\(configuration.baseURL)/\(slug.value)"
    )
    let encoder = JSONEncoder()
    // Without this, Foundation emits "http:\/\/host\/slug". Legal JSON, but the URL is
    // the thing the caller reads off the terminal.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var body = ByteBuffer()
    body.writeBytes(try encoder.encode(payload))

    var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
    if includeLocation { headers[.location] = payload.url }

    return Response(status: status, headers: headers, body: .init(byteBuffer: body))
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
    let router = buildRouter(configuration: configuration, store: store)

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

func notFoundPage() -> String {
    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Not found</title>
    <style>
      body { font: 16px/1.6 system-ui, sans-serif; max-width: 32rem; margin: 20vh auto;
             padding: 0 1.5rem; color: #1c1917; background: #fafaf9; }
      code { background: #f5f5f4; padding: .15em .4em; border-radius: .25rem; }
      @media (prefers-color-scheme: dark) {
        body { color: #e7e5e4; background: #1c1917; }
        code { background: #292524; }
      }
    </style></head>
    <body><h1>Nothing here</h1>
    <p>No page is published at this address. Check the link, or publish one with
    <code>POST /pages</code>.</p></body></html>
    """
}

func landingPage(baseURL: String) -> String {
    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>stele</title>
    <style>
      body { font: 16px/1.6 system-ui, sans-serif; max-width: 40rem; margin: 12vh auto;
             padding: 0 1.5rem; color: #1c1917; background: #fafaf9; }
      pre { background: #f5f5f4; padding: 1rem; border-radius: .5rem; overflow-x: auto; }
      code { font-size: .9em; }
      @media (prefers-color-scheme: dark) {
        body { color: #e7e5e4; background: #1c1917; }
        pre { background: #292524; }
      }
    </style></head>
    <body>
    <h1>stele</h1>
    <p>Publish an HTML file, get a readable link back.</p>
    <pre><code>curl -X POST \(baseURL)/pages \\
      -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \\
      -H "Content-Type: text/html" \\
      --data-binary @index.html</code></pre>
    <p>Returns a slug like <code>quiet-cedar-otter</code>, served at
    <code>\(baseURL)/quiet-cedar-otter</code>. Add <code>?slug=my-page</code> to choose
    your own.</p>
    </body></html>
    """
}
