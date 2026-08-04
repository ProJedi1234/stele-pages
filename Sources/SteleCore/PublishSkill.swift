/// The publish skill served at `GET /skill`: a SKILL.md that teaches an agent the whole
/// publish contract, from writing the page to reading the returned URL back out.
///
/// A Swift string rather than a SwiftPM resource, for the same reason `Stylesheet` is one:
/// the Dockerfile's runtime stage copies only the built executable out of the build stage,
/// and SwiftPM emits a resource bundle as a *sibling directory* of that executable which
/// `--static-swift-stdlib` does not embed. A `Bundle.module` lookup would pass `swift test`
/// on a dev machine and fail the moment it ran in production — the worst available failure
/// shape. (A top-level `Resources/` would also drop out of CI's `Sources/**` path filter.)
///
/// Not a page in Postgres either. It changes by deploy, not by upload, so storing it would
/// mean a deployment could run one version of the API while serving the documentation for
/// another — and `PageStore` stays the only file in this module that touches the database.
///
/// Rendered per-configuration, unlike `Stylesheet.css`, which is a constant: the deliverable
/// here is a *runnable* curl. A document that says `POST /pages` with no host is one the
/// agent has to guess at, and "fetch this deployment's `/skill` and follow it" is the entire
/// bootstrapping story. That is why `etag` is an instance property computed over the
/// rendering rather than a `static let` over a template — the tag has to be the tag of the
/// bytes this process actually serves.
///
/// Markdown, not an HTML rendering, because the consumer is an agent rather than a browser.
/// Said out loud so nobody "improves" it into a styled page later.
///
/// Maintenance: the prose is pinned to the code it documents by
/// `PublishSkillTests.componentTableMatchesTheStylesheet`, `.documentsOnlyDefinedClasses`,
/// `.listsEveryAllowedContentType` and `.exampleSlugsAreValid`. Those tests can only pin
/// what has a constant behind it; the rest of the prose is a human responsibility, and
/// changing the publish contract means changing this document in the same commit.
struct PublishSkill: Sendable {
    static let path = "/\(ServerRoute.skill)"

    /// Deliberately the same string `PageContentType.allowed["text/markdown"]` maps to, so
    /// the built-in document and an uploaded markdown page are indistinguishable in type. A
    /// test pins the two together.
    static let contentType = "text/markdown; charset=utf-8"

    let markdown: String
    let etag: String

    init(baseURL: String, maxPageBytes: Int) {
        let markdown = Self.render(baseURL: baseURL, maxPageBytes: maxPageBytes)
        self.markdown = markdown
        self.etag = strongETag(over: markdown.utf8)
    }

    /// A raw literal (`#"""…"""#`) because the document contains curl's `\` line
    /// continuations, and a plain literal would swallow them as escapes. Interpolation is
    /// therefore `\#(...)`.
    ///
    /// Every value with exactly one constant behind it is interpolated rather than typed
    /// out. That is a stronger accuracy mechanism than any test, because it removes the
    /// opportunity for drift instead of detecting it after the fact.
    private static func render(baseURL: String, maxPageBytes: Int) -> String {
        let reserved = Slug.reserved.sorted().map { "`\($0)`" }.joined(separator: ", ")
        let contentTypes = PageContentType.allowed.keys.sorted()
            .map { "`\($0)`" }.joined(separator: ", ")
        let tones = Stylesheet.toneClasses.map { "`\($0)`" }.joined(separator: ", ")

        return #"""
        ---
        name: publish-to-stele
        description: Publish a self-contained HTML page to this stele server and get a
          readable three-word URL back. Use when asked to publish, share, or put a page
          online at \#(baseURL).
        ---

        # Publishing a page to stele

        stele is a page server: you hand it one self-contained HTML file and it hands back a
        readable three-word URL like `\#(baseURL)/quiet-cedar-otter`. This document was
        served by the very deployment you are about to publish to, so every host, limit and
        reserved name below is that deployment's actual value rather than an example. There
        is no MCP server and no CLI — this skill wraps `curl`.

        ## Before you start

        - `STELE_UPLOAD_TOKEN` must be in the environment. Reads are open; writes are not.
          If it is unset, ask the user for it. Never invent one, and never write it into a
          page you publish.
        - Nothing else. No SDK, no build step, no dependencies.

        ## 1. Write one self-contained HTML file

        Each rule below is paired with the failure it prevents.

        - **One file.** There is no bundler and there are no sibling assets.
          `<script src="./app.js">` or `<img src="logo.png">` is a dead link the moment the
          page is published, because nothing else was uploaded alongside it.
        - **`<meta charset="utf-8">` in the `<head>`.** Pages are served as UTF-8; a page
          that does not declare it renders mojibake in some browsers.
        - **Valid UTF-8, non-empty, no NUL bytes.** Otherwise the upload is a `400`.
        - **Under \#(maxPageBytes) bytes.** Otherwise it is a `413`. Inline images blow past
          that fast — prefer an absolute `https://` image URL to a large `data:` URI.
        - **The only external subresource that is safe is this server's own stylesheet.**
          Everything else — your CSS, your JavaScript, your SVG — goes inline.

        A starter document worth copying:

        ```html
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Your title</title>
        <link rel="stylesheet" href="\#(Stylesheet.path)">
        </head>
        <body>
        <h1>Your title</h1>
        <p>Your first paragraph.</p>
        </body>
        </html>
        ```

        ## 2. Style it with the shared stylesheet

        ```html
        <link rel="stylesheet" href="\#(Stylesheet.path)">
        ```

        - Plain semantic HTML needs **no classes at all**. Headings, paragraphs, lists,
          links, `code`, `pre`, tables, blockquotes, images and rules are already styled.
        - Dark mode is automatic and follows the reader's system setting. Do not write your
          own `prefers-color-scheme` block; it will fight this one.
        - To retheme, override the custom properties rather than restating rules:
          `:root { --stele-accent: #7c3aed; }`.

        ### Component classes

        These are the opt-in extras, for the handful of shapes HTML has no element for. This
        table is the vocabulary — a class that is not in it does not exist on this server.

        | Class | Use it for | Markup |
        | --- | --- | --- |
        | `.card` | A bordered surface panel grouping a title and a few lines of content. | `<div class="card"><h3>Title</h3><p>Body text.</p></div>` |
        | `.grid` | A responsive row of cards that rewraps itself; there are no breakpoints to pick. | `<div class="grid"><div class="card">…</div><div class="card">…</div></div>` |
        | `.scroll` | Wrapping something too wide for the page — nearly always a table — so it scrolls in its own frame. | `<div class="scroll"><table>…</table></div>` |
        | `.callout` | A tinted aside for a note, a warning or a result, marked with an accent left border. | `<div class="callout warn"><p>Heads up.</p></div>` |
        | `.badge` | A small inline pill for a status, an HTTP method or a tag. | `<span class="badge">POST</span>` |
        | `.muted` | Secondary text: a subtitle, a caption, an aside. | `<p class="muted">Updated yesterday.</p>` |
        | `.narrow` | A body modifier for a short, centred message page: narrower measure, text sitting lower. | `<body class="narrow">` |
        | `.wide` | A body modifier for pages carrying tables, wide code blocks or galleries. | `<body class="wide">` |

        `.scroll` is the one worth reaching for on an otherwise plain page: a bare `<table>`
        can only shrink, never scroll, because it cannot be both page-width and wider than
        the page at once — the wrapper is the second box that makes scrolling possible.

        ### Tones

        `.callout` and `.badge` each take a second class: \#(tones). Write
        `<div class="callout warn">` or `<span class="badge ok">`. Nothing else takes a tone.

        ### `.narrow` / `.wide`

        Both go on the `<body>` element itself, not on a wrapper `<div>` — they change the
        page's measure, and the measure lives on `body`.

        ## 3. Publish it

        ```sh
        curl -X POST \#(baseURL)/pages \
          -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \
          -H "Content-Type: text/html" \
          --data-binary @page.html
        ```

        Success is a `201` with a JSON body:

        ```json
        {"slug":"quiet-cedar-otter","url":"\#(baseURL)/quiet-cedar-otter"}
        ```

        Read `url` out of that and report it to the user. That URL is the deliverable.

        ### Choosing your own slug

        Add `?slug=my-page` to the POST. A slug is lowercase letters, digits and single
        interior hyphens, \#(Slug.minLength)–\#(Slug.maxLength) characters long. Breaking
        those rules is a `400`; a name already taken is a `409` — pick a different one
        rather than retrying the same one.

        These names are reserved by the server and are rejected outright rather than
        accepted and then shadowed:

        \#(reserved)

        ### Replacing a page you already published

        ```sh
        curl -X PUT \#(baseURL)/pages/my-page \
          -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \
          -H "Content-Type: text/html" \
          --data-binary @page.html
        ```

        Returns `200`. It **never creates**: a `404` means nothing is published there yet, so
        use POST instead.

        One asymmetry to watch — omitting `Content-Type` on a PUT keeps the stored type,
        which is the opposite of POST, where an absent header means `text/html`.

        ## Pitfalls

        - **Use `--data-binary @file`, not `-d @file`.** `-d` strips newlines and sends
          `application/x-www-form-urlencoded`, which is a `415`.
        - **Send `Content-Type: text/html` explicitly.** It is the POST default, but a
          wrapper that helpfully sets `application/json` earns a `415`.
        - The accepted types are exactly these, and anything else is a `415`:
          \#(contentTypes)
        - Do not link stylesheets, fonts or scripts from other hosts.
        - Do not invent sub-paths. The API is exactly the routes in the table below.
        - A `503` means five random slugs collided in a row. Retry once, or pass `?slug=`.

        ## Status codes

        | Code | Means | Do |
        | --- | --- | --- |
        | `201` | Published. | Read `url` from the body and report it. |
        | `200` | Replaced (PUT). | Same URL as before. |
        | `400` | Bad slug, empty body, non-UTF-8, or a NUL byte. | Fix the input; the message says which. |
        | `401` | Missing or wrong bearer token. | Do not retry. Ask the user for the token. |
        | `404` | PUT to a slug that does not exist. | Publish it with POST instead. |
        | `409` | That slug is taken. | Choose another name. |
        | `413` | Page is over \#(maxPageBytes) bytes. | Drop inline images; link them instead. |
        | `415` | Content type not on the allowlist. | Send one of the accepted types. |
        | `503` | The server could not allocate a slug. | Retry once, or pass `?slug=`. |

        ## The whole API

        | Route | Auth | Behaviour |
        | --- | --- | --- |
        | `GET /` | none | Usage page |
        | `GET /healthz` | none | `ok` |
        | `GET /:slug` | none | The stored page, or a 404 page |
        | `GET \#(Stylesheet.path)` | none | The shared stylesheet |
        | `GET \#(PublishSkill.path)` | none | This document |
        | `POST /pages` | bearer | Stores the body, returns `{slug, url}` as `201` |
        | `PUT /pages/:slug` | bearer | Replaces a stored page, returns `{slug, url}` as `200` |

        ## Checklist before you publish

        One file · stylesheet linked · nothing fetched from another host · the stylesheet's
        rules not restated · no secrets in the markup · a valid slug if you chose one · the
        token read from the environment.

        ## What this is not

        - **Reads are unauthenticated and slugs are guessable.** Nothing private goes here.
        - **The stylesheet mutates in place.** A restyle reaches an already-published page on
          its next load, which is the point — but a page whose appearance must never change
          should carry its own inline `<style>` and link nothing.
        - **There is no listing endpoint.** Keep the URL you were handed; nothing else will
          give it back to you.
        """#
    }
}
