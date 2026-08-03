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
    /// isn't something we're willing to serve back.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return `default` }
        let base = raw.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        return allowed[base]
    }
}

struct CreatedPageResponse: Encodable {
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
            guard let contentType = PageContentType.normalize(request.headers[.contentType]) else {
                throw HTTPError(
                    .unsupportedMediaType,
                    message: """
                        Unsupported Content-Type. Allowed: \
                        \(PageContentType.allowed.keys.sorted().joined(separator: ", ")).
                        """
                )
            }

            let buffer: ByteBuffer
            do {
                buffer = try await request.body.collect(upTo: configuration.maxPageBytes)
            } catch is NIOTooManyBytesError {
                // Only the size limit gets this message. Anything else — a dropped
                // connection, cancellation during shutdown — rethrows as itself, so a
                // transport fault is never reported as a too-large page.
                throw HTTPError(
                    .contentTooLarge,
                    message: "Page exceeds the \(configuration.maxPageBytes) byte limit."
                )
            }
            guard buffer.readableBytes > 0 else {
                throw HTTPError(.badRequest, message: "Request body is empty.")
            }
            guard let body = buffer.getString(at: 0, length: buffer.readableBytes) else {
                throw HTTPError(.badRequest, message: "Request body is not valid UTF-8.")
            }

            // A caller-supplied slug is validated with exactly the same rules as a
            // generated one, so nothing enters the table that couldn't be served back.
            var requestedSlug: Slug?
            if let raw = request.uri.queryParameters["slug"].map(String.init) {
                do {
                    requestedSlug = try Slug(custom: raw)
                } catch let error as SlugError {
                    throw HTTPError(.badRequest, message: "Invalid slug: \(error).")
                }
            }

            let slug: Slug
            do {
                slug = try await store.create(
                    requestedSlug: requestedSlug,
                    body: body,
                    contentType: contentType,
                    generator: generator
                )
            } catch PageStoreError.slugTaken(let taken) {
                throw HTTPError(.conflict, message: "The slug '\(taken)' is already taken.")
            } catch PageStoreError.couldNotAllocateSlug(let attempts) {
                context.logger.error("slug allocation exhausted", metadata: ["attempts": "\(attempts)"])
                throw HTTPError(.serviceUnavailable, message: "Could not allocate a slug.")
            }

            let payload = CreatedPageResponse(
                slug: slug.value,
                url: "\(configuration.baseURL)/\(slug.value)"
            )
            let encoder = JSONEncoder()
            // Without this, Foundation emits "http:\/\/host\/slug". Legal JSON, but the
            // URL is the thing the caller reads off the terminal.
            encoder.outputFormatting = [.withoutEscapingSlashes]
            var body_ = ByteBuffer()
            body_.writeBytes(try encoder.encode(payload))
            return Response(
                status: .created,
                headers: [
                    .contentType: "application/json; charset=utf-8",
                    .location: payload.url,
                ],
                body: .init(byteBuffer: body_)
            )
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
            ],
            body: .init(byteBuffer: ByteBuffer(string: page.body))
        )
    }

    return router
}

/// Builds the full application: Postgres client, schema bootstrap, and HTTP server.
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
