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
/// here is a *runnable* sequence of commands. A document that says "log in to the server"
/// with no host is one the agent has to guess at, and "fetch this deployment's `/skill` and
/// follow it" is the entire bootstrapping story. That is why `etag` is an instance property
/// computed over the rendering rather than a `static let` over a template — the tag has to be
/// the tag of the bytes this process actually serves.
///
/// Markdown, not an HTML rendering, because the consumer is an agent rather than a browser.
/// Said out loud so nobody "improves" it into a styled page later.
///
/// **What this document is for has changed.** It used to teach an agent to hold
/// `STELE_UPLOAD_TOKEN` and run curl; it now teaches it to install the `stele` CLI and never
/// see a credential at all. Anything reintroducing a token into the agent's hands — an
/// environment variable, "ask the user for the token", a curl with an `Authorization` header
/// — undoes the point of the tool and is caught by
/// `PublishSkillTests.neverPutsTheCredentialInTheAgentsHands`.
///
/// Maintenance: the prose is pinned to the code it documents by
/// `PublishSkillTests.componentTableMatchesTheStylesheet`, `.documentsEverySyntaxTokenClass`,
/// `.documentsOnlyDefinedClasses`, `.listsEveryAllowedContentType`,
/// `.theRouteTableNamesExactlyTheScopesThatExist`, `.exampleSlugsAreValid`,
/// `.documentsTheInstallSequence` and `.mentionsExactlyTheMinimumCLIVersion`. Those tests can
/// only pin what has a constant behind it; the rest of the prose is a human responsibility,
/// and changing the publish contract means changing this document in the same commit.
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

    /// A raw literal (`#"""…"""#`) so that every shell line survives verbatim — a `\`
    /// continuation, a `\n` in a snippet — instead of being read as an escape on its way
    /// into the document. Interpolation is therefore `\#(...)`.
    ///
    /// Every value with exactly one constant behind it is interpolated rather than typed
    /// out. That is a stronger accuracy mechanism than any test, because it removes the
    /// opportunity for drift instead of detecting it after the fact — and it now reaches
    /// across repositories: the clone URL, the install commands, the two trap paths and
    /// `minimumCLIVersion` all come from `SteleCLI`, so the document cannot describe an
    /// installation this server does not expect. The deliberate exceptions are the
    /// component-class table and the syntax-token list: each row carries prose no list of
    /// names could generate, so the names are hand-typed and held set-equal to
    /// `Stylesheet.componentClasses` / `.syntaxTokenClasses` — in both directions — by
    /// `PublishSkillTests.componentTableMatchesTheStylesheet` and
    /// `.documentsEverySyntaxTokenClass`.
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
        reserved name below is that deployment's actual value rather than an example.

        ## Before you start

        Publishing goes through the `stele` command-line tool, and **the credential is
        never yours**. It lives in a file the tool reads and no command prints; you run
        `stele publish` and see a URL. So:

        - Do not ask the user for a token, do not read one out of a file, and do not put one
          in the environment. If a command needs a credential you do not have, the answer is
          always to ask the user to run `stele auth login` — never to obtain the secret
          yourself.
        - A token you never hold is a token you cannot leak into a page you publish, which
          is the failure this arrangement exists to make impossible.

        ## 1. Get the tool

        Assume nothing is installed, because on a fresh machine nothing is. Start by asking:

        ```sh
        stele auth status
        ```

        - It prints a host, a client name and its scopes — you are ready. Skip to step 2.
        - `command not found` — install it, below.
        - It runs but reports no credential — installed, not authenticated. Skip to
          *Authenticating*.

        ### Installing

        ```sh
        \#(SteleCLI.cloneCommand)
        \#(SteleCLI.installCommand)
        \#(SteleCLI.completionsCommand)   # optional, zsh only
        ```

        Two traps here, and both of them bite in a way that points somewhere else:

        - **`\#(SteleCLI.binaryDirectory)` must be on your `PATH`.** That is where the install
          writes the binary. If it is not on `PATH`, a *successful* install is followed by
          `stele: command not found`, which reads exactly like a failed one. Check `PATH`
          before you reinstall anything.
        - **A swiftly-managed toolchain needs
          `LD_LIBRARY_PATH=\#(SteleCLI.compatibilityLibraries)` in a non-interactive
          shell.** The user's shell profile exports it; the shell you are running commands
          in never reads that profile. Without it the build fails with a *linker* error that
          looks nothing like a missing environment variable, and you will lose the next ten
          minutes to the wrong hypothesis. If `\#(SteleCLI.installCommand)` fails while
          linking, retry it once as:

        ```sh
        LD_LIBRARY_PATH=\#(SteleCLI.compatibilityLibraries) \#(SteleCLI.installCommand)
        ```

        ### Authenticating

        This step is the user's, not yours:

        ```sh
        stele auth login --host \#(baseURL)
        ```

        **Ask them to run it; do not run it for them.** It prompts on a terminal for a
        secret — that is deliberate, because a token passed as an argument is visible in
        `ps` and lands in shell history, and shell history is something you read. Wait for
        them to confirm, then re-run `stele auth status` to check.

        ## 2. Write one self-contained HTML file

        Each rule below is paired with the failure it prevents.

        - **One file.** There is no bundler and there are no sibling assets.
          `<script src="./app.js">` or `<img src="logo.png">` is a dead link the moment the
          page is published, because nothing else was uploaded alongside it.
        - **`<meta charset="utf-8">` in the `<head>`.** Pages are served as UTF-8; a page
          that does not declare it renders mojibake in some browsers.
        - **Valid UTF-8, non-empty, no NUL bytes.** Otherwise the upload is a `400`.
        - **At most \#(maxPageBytes) bytes.** Over that is a `413`. Inline images blow past
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

        ## 3. Style it with the shared stylesheet

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

        `.callout` and `.badge` each take a second class, one of exactly these:

        \#(tones)

        Write `<div class="callout warn">` or `<span class="badge ok">`. Nothing else takes
        a tone.

        ### Highlighting code

        Plain `<pre><code>` already has its surface, border and horizontal scrollbar.
        Colour is yours to add: this server runs no highlighter and serves no JavaScript —
        **you are the highlighter**. Wrap tokens in spans as you write the snippet, using
        exactly these classes:

        - `tok-kw` — keywords and reserved words.
        - `tok-str` — string literals, quotes included.
        - `tok-num` — numeric literals.
        - `tok-fn` — function and method names, at definition and call sites alike.
        - `tok-type` — type names.
        - `tok-com` — comments; rendered muted and italic.

        ```html
        <pre><code><span class="tok-com">// Three attempts, then give up.</span>
        <span class="tok-kw">func</span> <span class="tok-fn">fetch</span>(attempts: <span class="tok-type">Int</span> = <span class="tok-num">3</span>) <span class="tok-kw">throws</span> -> <span class="tok-type">Data</span> {
          <span class="tok-kw">try</span> <span class="tok-fn">request</span>(<span class="tok-str">"GET"</span>, retries: attempts)
        }</code></pre>
        ```

        Leave punctuation, operators and plain identifiers unwrapped — the default text
        colour is theirs, and a snippet you only partially mark up degrades to plain code,
        not to a broken page. Any language works, because you are doing the parsing. The
        colours follow dark mode on their own; do not add `style` attributes or colour
        rules of your own to code.

        ### `.narrow` / `.wide`

        Both go on the `<body>` element itself, not on a wrapper `<div>` — they change the
        page's measure, and the measure lives on `body`.

        ## 4. Publish it

        ```sh
        stele publish page.html
        ```

        It prints the URL. **That URL is the deliverable** — report it to the user. If you
        would rather parse the answer than read it, every command takes `--json`, and this
        one prints the server's own response:

        ```json
        {"slug":"quiet-cedar-otter","url":"\#(baseURL)/quiet-cedar-otter"}
        ```

        ### Choosing your own slug

        ```sh
        stele publish page.html --slug my-page
        ```

        A slug is lowercase letters, digits and single interior hyphens, \#(Slug.minLength)–\#(Slug.maxLength)
        characters long. Breaking those rules fails with a `400`; a name already taken is a
        `409` — pick a different one rather than retrying the same one.

        These names are reserved by the server and are rejected outright rather than
        accepted and then shadowed:

        \#(reserved)

        ### Replacing a page you already published

        ```sh
        stele update my-page page.html
        ```

        `stele update <slug> <file>` **never creates**: a `404` means nothing is published
        at that name yet, so `stele publish page.html --slug my-page` is what you want
        instead. A successful update keeps the same URL.

        ### The commands, in full

        | Command | Who runs it | Does |
        | --- | --- | --- |
        | `stele auth status` | you | Host, client name, scopes. Never prints the token. |
        | `stele auth login` | **the user** | Prompts for the credential and stores it. Not yours to run. |
        | `stele publish <file> [--slug <name>]` | you | Publishes a page, prints its URL. |
        | `stele update <slug> <file>` | you | Replaces a page already published at that name. |
        | `stele skill` | you | Prints this document, fetched live from the server. |

        ## Pitfalls

        - The accepted types are exactly these, and anything else is a `415`:
          \#(contentTypes)
        - Do not link stylesheets, fonts or scripts from other hosts.
        - Do not call the API with `curl` and do not invent sub-paths. The routes are listed
          below for orientation, not as an invitation — reaching them directly means holding
          a credential, which is the one thing this arrangement is built to spare you.
        - A `503` means \#(PageStore.maxSlugAttempts) random slugs collided in a row. Retry once, or pass `--slug`.
        - A failure with no status at all is usually not the server: check `stele auth status`
          first, then that you are pointed at the right host.

        ## Status codes

        The tool exits non-zero and prints the server's status and message, so these are
        what a failed command tells you and what you react to.

        | Code | Means | Do |
        | --- | --- | --- |
        | `201` | Published. | Report the URL it printed. |
        | `200` | Replaced by `stele update`. | Same URL as before. |
        | `400` | Bad slug, empty file, non-UTF-8, or a NUL byte. | Fix the input; the message says which. |
        | `401` | The stored credential was rejected — expired, revoked, or never valid. | Do not retry. Ask the user to run `stele auth login`. |
        | `403` | The credential is valid but not allowed to publish. | Do not retry. Ask the user for one with the `\#(ClientScope.publish.rawValue)` scope. |
        | `404` | `stele update` against a name with no page at it. | Publish it instead, with `--slug`. |
        | `409` | That slug is taken. | Choose another name. |
        | `413` | Page is over \#(maxPageBytes) bytes. | Drop inline images; link them instead. |
        | `415` | Content type not on the allowlist. | Publish one of the accepted types. |
        | `426` | The installed tool is older than this deployment requires (`\#(minimumCLIVersion)`). | Run `\#(SteleCLI.installCommand)`, then retry once. |
        | `503` | The server could not allocate a slug. | Retry once, or pass `--slug`. |

        ## The whole API

        The tool talks to these so you do not have to.

        | Route | Auth | Behaviour |
        | --- | --- | --- |
        | `GET /` | none | Usage page |
        | `GET /\#(ServerRoute.healthz)` | none | `ok` |
        | `GET /:slug` | none | The stored page, or a 404 page |
        | `GET \#(Stylesheet.path)` | none | The shared stylesheet |
        | `GET \#(PublishSkill.path)` | none | This document |
        | `POST /\#(ServerRoute.pages)` | `\#(ClientScope.publish.rawValue)` | Stores the body, returns `{slug, url}` as `201` |
        | `PUT /\#(ServerRoute.pages)/:slug` | `\#(ClientScope.publish.rawValue)` | Replaces a stored page, returns `{slug, url}` as `200` |
        | `GET /\#(ServerRoute.admin)/\#(ServerRoute.adminWhoami)` | any credential | Reports the credential you hold — name, scopes, expiry. This is what `stele auth status` asks. |
        | `POST /\#(ServerRoute.admin)/\#(ServerRoute.adminClients)` | `\#(ClientScope.admin.rawValue)` | Mints a credential. The operator's route, not yours. |
        | `GET /\#(ServerRoute.admin)/\#(ServerRoute.adminClients)` | `\#(ClientScope.admin.rawValue)` | Lists credentials. The operator's route, not yours. |
        | `DELETE /\#(ServerRoute.admin)/\#(ServerRoute.adminClients)/:name` | `\#(ClientScope.admin.rawValue)` | Revokes one. The operator's route, not yours. |

        A credential carries scopes, and the one an agent is given carries
        `\#(ClientScope.publish.rawValue)` and nothing else. That is why a leaked publishing
        token cannot mint itself a second credential — and why `403`, not `401`, is what you
        get if you try. The one route under `/\#(ServerRoute.admin)` that asks for no scope at
        all is `\#(ServerRoute.adminWhoami)`: reporting which credential you are holding is
        exactly the question a publish-only credential needs answered.

        ## Checklist before you publish

        One file · stylesheet linked · nothing fetched from another host · the stylesheet's
        rules not restated · no secrets in the markup · a valid slug if you chose one ·
        `stele auth status` answering before you start.

        ## What this is not

        - **Reads are unauthenticated and slugs are guessable.** Nothing private goes here.
        - **The credential is not yours and never becomes yours.** No step of this document
          ends with you holding a token, and one that seems to is a step you have
          misunderstood.
        - **The stylesheet mutates in place.** A restyle reaches an already-published page on
          its next load, which is the point — but a page whose appearance must never change
          should carry its own inline `<style>` and link nothing.
        - **There is no listing endpoint.** Keep the URL you were handed; nothing else will
          give it back to you.
        """#
    }
}
