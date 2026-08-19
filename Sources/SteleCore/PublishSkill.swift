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
/// **What the document owes the CLI, and how that went wrong.** `--ttl` shipped in the
/// client and this document went on saying "`stele publish` does not expose this yet" — so
/// an agent asked for a permanent page refused, citing a limitation that had stopped
/// existing, in prose confident enough to read as policy rather than staleness. Nothing in a
/// build of this package can see the other repository, which is the whole difficulty; what
/// closed it is naming the client's surface in `SteleCLI` and interpolating it, so the
/// document has one place to be wrong instead of six and a test can hold it to that place.
/// `SteleCLI.flags` and `SteleCLI.exits` exist for that and for nothing else.
///
/// Maintenance: the prose is pinned to the code it documents by
/// `PublishSkillTests.componentTableMatchesTheStylesheet`, `.documentsEverySyntaxTokenClass`,
/// `.documentsOnlyDefinedClasses`, `.listsEveryAllowedContentType`,
/// `.theRouteTableNamesExactlyTheScopesThatExist`, `.exampleSlugsAreValid`,
/// `.documentsTheInstallSequence`, `.mentionsExactlyTheMinimumCLIVersion`,
/// `.documentsEveryCommandTheAgentNeeds`, `.documentsEveryFlagTheAgentCanUse`,
/// `.theExitTableMatchesTheClientsExitCodes`, `.documentsTheDefaultLifetime`,
/// `.documentsTheLifetimeGrammar`, `.theBadRequestRowNamesTheLifetime`,
/// `.documentsTheAmendRoute`, `.documentsTheDeleteRoute` and
/// `.doesNotClaimALifetimeIsUnchangeable`. Those tests can
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

    init(baseURL: String, maxPageBytes: Int, maxAttachmentBytes: Int) {
        let markdown = Self.render(
            baseURL: baseURL, maxPageBytes: maxPageBytes, maxAttachmentBytes: maxAttachmentBytes
        )
        self.markdown = markdown
        self.etag = strongETag(over: markdown.utf8)
    }

    /// A raw literal (`#"""…"""#`) so that every shell line survives verbatim — a `\`
    /// continuation, a `\n` in a snippet — instead of being read as an escape on its way
    /// into the document. Interpolation is therefore `\#(...)`.
    ///
    /// Every value with exactly one constant behind it is interpolated rather than typed
    /// out — the base URL, the byte limit, the stylesheet path, the slug bounds, the
    /// reserved names, the accepted content types, and the whole lifetime vocabulary
    /// (`PageLifetime.queryParameter`, `.neverKeyword`, `.defaultDays`, `.maxDays`). That is
    /// a stronger accuracy mechanism than any test, because it removes the opportunity for
    /// drift instead of detecting it after the fact — and it now reaches across
    /// repositories: the clone URL, the install commands, the two trap paths and
    /// `minimumCLIVersion` all come from `SteleCLI`, so the document cannot describe an
    /// installation this server does not expect. The deliberate exceptions are the
    /// component-class table and the syntax-token list: each row carries prose no list of
    /// names could generate, so the names are hand-typed and held set-equal to
    /// `Stylesheet.componentClasses` / `.syntaxTokenClasses` — in both directions — by
    /// `PublishSkillTests.componentTableMatchesTheStylesheet` and
    /// `.documentsEverySyntaxTokenClass`.
    private static func render(
        baseURL: String, maxPageBytes: Int, maxAttachmentBytes: Int
    ) -> String {
        let reserved = Slug.reserved.sorted().map { "`\($0)`" }.joined(separator: ", ")
        let contentTypes = PageContentType.everyAllowedType
            .map { "`\($0)`" }.joined(separator: ", ")
        let attachmentTypes = PageContentType.allowedAttachments.keys.sorted()
            .map { "`\($0)`" }.joined(separator: ", ")
        let tones = Stylesheet.toneClasses.map { "`\($0)`" }.joined(separator: ", ")
        let exits = SteleCLI.exits
            .map { "| `\($0.code)` | \($0.meaning) | \($0.remedy) |" }
            .joined(separator: "\n")

        return #"""
        ---
        name: publish-to-stele
        description: Publish a self-contained HTML page to this stele server and get a
          readable three-word URL back. Pages expire after \#(PageLifetime.defaultDays) days
          unless published with `\#(PageLifetime.queryParameter)=\#(PageLifetime.neverKeyword)`.
          Use when asked to publish, share, or put a page online at \#(baseURL), when asked
          to replace or update a page already there, and when asked to delete or unpublish
          one.
        ---

        # Publishing a page to stele

        stele is a page server: you hand it one self-contained HTML file and it hands back a
        readable three-word URL like `\#(baseURL)/quiet-cedar-otter`. This document was
        served by the very deployment you are about to publish to, so every host, limit,
        lifetime and reserved name below is that deployment's actual value rather than an
        example.

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
        - It exits `2` and says there is no stored credential — installed, but not
          authenticated. Skip to *Authenticating*.
        - It prints the stored credential, says it could not reach the server, and exits `9`
          — the credential is fine and the address is not. Fix that before anything else.

        It asks the server rather than reading the file, which is the point: a credential
        revoked yesterday still looks perfectly healthy on disk.

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
          page is published, because nothing else was uploaded alongside it. Images and video
          are not stuck outside, though — publish each one first with `stele attach` and put
          the URL it prints in the `src`. See "Attachments" below.
        - **`<meta charset="utf-8">` in the `<head>`.** Pages are served as UTF-8; a page
          that does not declare it renders mojibake in some browsers.
        - **Valid UTF-8, non-empty, no NUL bytes.** Otherwise the upload is a `400`.
        - **At most \#(maxPageBytes) bytes.** Over that is a `413`. Inline images blow past
          that fast — `stele attach` is what they are for, and a `data:` URI is what to avoid.
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

        That command takes the default lifetime — \#(PageLifetime.defaultDays) days — and the
        page stops being served when it runs out. Read "How long the page lives" below before
        you run it; `\#(SteleCLI.ttlFlag)` is how you choose something else. A deadline can be
        moved afterwards, with `stele amend`, but the link you hand back is only as good as the
        date you chose here — so choose it now rather than planning to fix it.

        The URL goes to stdout and nothing else does, so `url=$(stele publish page.html)`
        captures it cleanly; the page's deadline is printed under it on stderr. **That URL is
        the deliverable** — report it to the user. If you would rather parse the answer than
        read it, every command takes `\#(SteleCLI.jsonFlag)`:

        ```json
        {"slug":"quiet-cedar-otter","url":"\#(baseURL)/quiet-cedar-otter","expires":"2030-01-08T09:41:00Z"}
        ```

        `expires` is that instant for a page with a deadline, and JSON `null` for one that
        never expires. The key is always there, so read it rather than reading permanence
        into its absence. Parse by key rather than by position — the server's own body makes
        no promise about the order of the three.

        Report `expires` alongside the URL — either the date the link dies, or that it is
        permanent — because the user cannot look it up later and nothing will remind them.

        ### How long the page lives

        **Pages are temporary unless you say otherwise.** A page published with no lifetime
        expires \#(PageLifetime.defaultDays) days after it is published, and then serves the
        ordinary 404 exactly as if it had never existed.

        `stele publish` takes the lifetime as `\#(SteleCLI.ttlFlag)`:

        ```sh
        stele publish page.html \#(SteleCLI.ttlFlag) \#(PageLifetime.neverKeyword)
        ```

        | Flag | Means |
        | --- | --- |
        | omitted | the server's default: \#(PageLifetime.defaultDays) days |
        | `\#(SteleCLI.ttlFlag) 30` | 30 days. `30d` says the same thing, and `2w` means fourteen |
        | `\#(SteleCLI.ttlFlag) \#(PageLifetime.neverKeyword)` | kept until somebody deletes it |

        A page's deadline is stored to the day, so anything finer is refused rather than
        rounded to a lifetime you did not ask for: `12h` is an error, not half a day. Ask for
        the lifetime the user actually wants. `stele amend \#(SteleCLI.ttlFlag)` can move it
        later, but only for as long as the page is still alive — a deadline that has already
        passed cannot be extended, only republished at a new name — so this is a choice to
        make rather than one to inherit from an example, and a user expecting a permanent link
        needs to hear if they did not get one.

        Underneath, the server reads the lifetime as a query parameter on the write, and that
        is where the bounds live:

        | Query | Means |
        | --- | --- |
        | omitted | \#(PageLifetime.defaultDays) days |
        | `?\#(PageLifetime.queryParameter)=30` | 30 days; any whole number from 1 to \#(PageLifetime.maxDays) |
        | `?\#(PageLifetime.queryParameter)=\#(PageLifetime.neverKeyword)` | never expires |

        Anything else — `0`, a negative, `7.5`, an empty value, a number past
        \#(PageLifetime.maxDays) — is a `400`. Nothing is ever silently rounded or defaulted, so
        a rejected value means the page was not published at all rather than published with a
        lifetime nobody chose. You do not send that parameter yourself; `\#(SteleCLI.ttlFlag)`
        is how it gets there.

        That table is the rule **when a page is being published**. On
        `PATCH /\#(ServerRoute.pages)/:slug` — which is what `stele amend` runs — the first row
        does not apply: an omitted `?\#(PageLifetime.queryParameter)=` there means *leave the
        deadline exactly as it is*, not \#(PageLifetime.defaultDays) days. The other two rows
        mean what they say on both verbs. That difference is why renaming a page with
        `\#(SteleCLI.slugFlag)` alone does not re-date it, and it is the thing to be careful
        about when reporting what an amendment did — on a permanent page the two readings
        differ by the page's whole future.

        The other difference is where the clock starts. A lifetime given to `stele amend` is
        counted from the moment you run it, not from when the page was published, so
        `\#(SteleCLI.ttlFlag) 30` on a three-week-old page grants thirty fresh days rather than
        the nine that were left. It is a new lease, not an adjustment to the old one.

        The expiry belongs to the page, not to its current contents: **replacing a page does
        not extend it**, which is why `stele update` has no `\#(SteleCLI.ttlFlag)` and the
        server refuses that query parameter on a `PUT` with a `400` rather than accepting it
        and moving nothing. A deadline is a property of the page, and rewriting the page's
        contents is not a reason to move it. Moving a deadline is a separate act with its own
        command — see "Renaming a page, and changing its deadline".

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

        A name freed by an expiry becomes claimable again — expired pages leave nothing
        behind — so a `409` today may not be a `409` next week.

        ### Replacing a page you already published

        ```sh
        stele update my-page page.html
        ```

        Reports the page's unchanged `expires` in the same body a publish answers with: an
        update does not move a deadline. Report the value it prints rather than the one the
        original publish printed — those agree today, and would stop agreeing the moment
        anything retimed the page.

        `stele update <slug> <file>` **never creates**: exit `7` means nothing is published
        at that name yet — or that it has expired — so `stele publish page.html --slug my-page`
        is what you want instead. A successful update keeps the same URL.

        ### Renaming a page, and changing its deadline

        ```sh
        stele amend my-page \#(SteleCLI.slugFlag) better-name
        stele amend my-page \#(SteleCLI.ttlFlag) \#(PageLifetime.neverKeyword)
        ```

        `stele amend` changes a page's name, its deadline, or both in one command, and nothing
        else. It sends no file: the contents, the content type and the record of who published
        them come through untouched. It prints the page's URL *after* the amendment, which is
        not necessarily the one you passed in — report that one, and never assemble the new URL
        yourself from the name you asked for.

        Omitting `\#(SteleCLI.ttlFlag)` leaves the existing deadline exactly where it is. This
        is the one place the flag does not mean what it means on `stele publish`, where
        omitting it takes the default — so a rename with no `\#(SteleCLI.ttlFlag)` does not
        quietly put \#(PageLifetime.defaultDays) days on a page somebody published to keep.

        It never creates and never revives. Exit `7` means there is no live page at that name,
        and a page that has already expired counts as none — so `\#(SteleCLI.ttlFlag)
        \#(PageLifetime.neverKeyword)` cannot bring one back, and republishing at a new name is
        the only answer for a page that missed its date.

        Exit `5` means another live page holds the name you asked for. Dropping
        `\#(SteleCLI.slugFlag)` is not an escape here the way it is on a publish: there it asks
        for a generated name, here it asks for no rename at all.

        **Renaming is the harsher tool, and usually not what the user needs.** The move is
        hard: the old name is released the instant it commits, with no redirect and nothing
        left behind, so a link already in somebody's hands starts serving the ordinary 404 and
        the name goes back into the pool for the next page — anybody's — to claim. So the
        question to ask before renaming is not whether a better name would be nicer, it is who
        already has the old one. A URL that has not left your terminal renames freely, and that
        is what this is for. A URL already sitting in somebody's inbox is a different matter —
        `stele update` gives them new contents at the name they already have, which is what the
        request usually means.

        If `stele amend` comes back saying it does not recognise the command, the installed
        client predates it: run `\#(SteleCLI.installCommand)` and try once more. That is a
        different failure from every exit code in the table below, and the only one whose fix
        is reinstalling rather than rewording.

        ### Deleting a page

        ```sh
        stele delete my-page
        ```

        `stele delete` takes a page down immediately and prints nothing on stdout — every
        other command prints a URL because there is a page to point at, and here there is
        not. The confirmation goes to stderr, and `\#(SteleCLI.jsonFlag)` prints the slug you
        asked about rather than a location. Do not report a link afterwards; there isn't one.

        **The name goes back into the pool.** Deletion is permanent — there is no undo. The
        row is removed outright rather than tombstoned, so the slug is claimable again the
        moment the delete commits, by anybody's next page or by this server's own generator.
        A URL you already handed out may later resolve to a different page.
        Republishing the same file afterwards is a new page rather than the old one back.

        Two things are worth putting to the user before you run it, because neither is
        recoverable afterwards.

        **You never have to delete a page to make it expire.** A page with a deadline retires
        itself on the date you already reported, and every page has one unless somebody asked
        for `\#(SteleCLI.ttlFlag) \#(PageLifetime.neverKeyword)` — so "take it down
        eventually" needs nothing from anybody.

        **And replacing is usually what the request means.** `stele update` rewrites a page
        without ever releasing its name, so a link already in someone's hands keeps pointing
        at something the user chose. Deleting is the harsher tool; it is for when the *name*
        is the thing being given up.

        Exit `7` means there was no live page at that name — nothing was ever published there,
        or it has already expired, which counts as none. Nothing was removed and nothing needs
        to be. It is an error rather than a `0` on purpose, so a typo'd slug is something you
        can notice instead of a success you report.

        As with `stele amend`, a client that answers that it does not recognise the command is
        an install predating it: run `\#(SteleCLI.installCommand)` and try once more.

        ## Attachments: images, video and files

        Images and video are published on their own and linked from a page, rather than
        bundled into one. Publish the image first, then put the URL you get back into the
        page's `src`:

        ```sh
        src=$(stele attach screenshot.png)
        # then, in the page you are writing:
        # <img src="$src">
        ```

        `stele attach` prints **the URL of the bytes**, which is the one you embed. That is
        what makes it the value on stdout: a page-writing agent needs it far more often than
        it needs anything else about the upload.

        Every attachment has a second URL, and the difference matters:

        | URL | Serves | Use it for |
        | --- | --- | --- |
        | `\#(baseURL)/\#(ServerRoute.staticFiles)/quiet-cedar-otter` | the file itself, nothing around it | `<img src>`, `<video src>`, a download link |
        | `\#(baseURL)/quiet-cedar-otter` | a page *about* the file — it rendered, with its name, size and deadline | sharing the link with a person |

        Put the first in a page and the second in a chat message. Getting them the wrong way
        round is the mistake worth avoiding: an `<img>` pointed at the viewer renders nothing,
        because the viewer is an HTML document.

        The attachment types are exactly these, and anything else is a `415`:
        \#(attachmentTypes)

        At most \#(maxAttachmentBytes) bytes, which is a different and much larger limit than
        the one on a page. Over it is a `413`.

        ### Flags

        ```sh
        stele attach clip.mp4 \#(SteleCLI.ttlFlag) never
        stele attach diagram.png \#(SteleCLI.filenameFlag) architecture.png
        ```

        `\#(SteleCLI.slugFlag)` and `\#(SteleCLI.ttlFlag)` mean exactly what they mean on
        `stele publish`, including the default: an attachment you say nothing about expires in
        \#(PageLifetime.defaultDays) days.

        `\#(SteleCLI.filenameFlag)` sets the name a browser saves the file under. It defaults
        to the name of the file you uploaded, and is worth setting when that name is a
        temporary one — a slug is a name for a URL, and a download called
        `quiet-cedar-otter` opens in nothing.

        ### Give an attachment the lifetime of the page that embeds it

        This is the one thing to get right, and nothing will warn you. A page and the images
        inside it are separate publications with separate deadlines, so:

        ```sh
        url=$(stele attach chart.png \#(SteleCLI.ttlFlag) never)   # matching the page below
        # …write the page using $url…
        stele publish report.html \#(SteleCLI.ttlFlag) never
        ```

        A permanent page whose screenshots were published with the default becomes a page full
        of broken images a week later, and no request fails at the time. **Ask for the same
        lifetime on both**, and when the user asks for a permanent page, that includes
        everything in it.

        The other verbs reach an attachment exactly as they reach a page, at its slug:
        `stele update` replaces the bytes without moving the URL, `stele amend` renames or
        retimes it, `stele delete` takes it down. Replacing is the one to reach for when the
        evidence changes — every page already embedding it keeps working.

        ### The commands, in full

        | Command | Who runs it | Does |
        | --- | --- | --- |
        | `stele auth status` | you | Host, client name, scopes, expiry, and whether the server still accepts it. Never prints the token. |
        | `stele auth login` | **the user** | Prompts for the credential and stores it. Not yours to run. |
        | `stele auth logout` | **the user** | Forgets the stored credential for a host. Not yours to run either. |
        | `stele publish <file> [\#(SteleCLI.slugFlag) <name>] [\#(SteleCLI.ttlFlag) <days>] [\#(SteleCLI.contentTypeFlag) <type>]` | you | Publishes a page, prints its URL. |
        | `stele update <slug> <file> [\#(SteleCLI.contentTypeFlag) <type>]` | you | Replaces a page already published at that name. |
        | `stele amend <slug> [\#(SteleCLI.slugFlag) <name>] [\#(SteleCLI.ttlFlag) <days>]` | you | Renames a page, moves its deadline, or both. Sends no file and changes no contents. |
        | `stele delete <slug>` | you | Takes the page down and frees its name. Prints no URL, because there is no page left. |
        | `stele attach <file> [\#(SteleCLI.slugFlag) <name>] [\#(SteleCLI.ttlFlag) <days>] [\#(SteleCLI.filenameFlag) <name>]` | you | Publishes an image, video or file. Prints the URL of the bytes — the one you embed. |
        | `stele skill` | you | Prints this document, fetched live from the server. |
        | `stele admin clients` (`create`, `list`, `revoke`) | **an operator** | Mints, lists and revokes credentials. Needs the `\#(ClientScope.admin.rawValue)` scope, which yours does not have. |

        Every one of them also takes `\#(SteleCLI.hostFlag) <url>`, needed only when the
        credential file holds more than one deployment, and `\#(SteleCLI.jsonFlag)`.

        `\#(SteleCLI.contentTypeFlag)` is rarely worth reaching for: the type is inferred from
        the file's extension, which is the whole reason a `415` is not something you have to
        think about. Override it when the extension is lying, not otherwise.

        ## Pitfalls

        - The accepted types are exactly these, and anything else is a `415`:
          \#(contentTypes)
        - Do not link stylesheets, fonts or scripts from other hosts.
        - Do not call the API with `curl` and do not invent sub-paths. The routes are listed
          below for orientation, not as an invitation — reaching them directly means holding
          a credential, which is the one thing this arrangement is built to spare you.
        - A `503` means \#(PageStore.maxSlugAttempts) random slugs collided in a row. Retry once, or pass `--slug`.
        - A failure with no status at all — exit `9` — is usually not the server being down:
          check `stele auth status` first, then that you are pointed at the right host.
        - **A successful publish is not a promise the page will still be there.** The default
          is \#(PageLifetime.defaultDays) days, not forever. `stele amend \#(SteleCLI.ttlFlag)`
          can move that date while the page is alive, but nothing recovers one that has already
          passed. Tell the user which they got.

        ## What a failure looks like

        Every command prints one sentence saying what to do, and exits. **Branch on the exit
        code.** It is the stable half of that answer — the message is prose, and the server's
        status number is usually not in it at all. Two of the likeliest outcomes never reach a
        server and so have no status behind them: no usable credential on this machine, and a
        host that did not answer.

        These are the codes, and what each one asks you to do next:

        | Exit | Means | Do |
        | --- | --- | --- |
        \#(exits)

        The statuses underneath are what those messages are written from. You will not often
        act on one directly, but they are what the server means:

        | Code | Means | Do |
        | --- | --- | --- |
        | `201` | Published. | Report the URL it printed, with its `expires`. |
        | `200` | Replaced by `stele update`, or amended by `stele amend`. | Report the URL the command printed. |
        | `204` | Deleted by `stele delete`. | The page and its name are both gone. Report that, not a URL. |
        | `400` | Bad slug, bad `\#(PageLifetime.queryParameter)`, empty file, non-UTF-8, or a NUL byte. | Fix the input; the message says which. |
        | `401` | The stored credential was rejected — expired, revoked, or never valid. | Do not retry. Ask the user to run `stele auth login`. |
        | `403` | The credential is valid but not allowed to publish. | Do not retry. Ask the user for one with the `\#(ClientScope.publish.rawValue)` scope. |
        | `404` | `stele update`, `stele amend` or `stele delete` against a name with no live page at it — including an expired one. | Publish it instead, with `--slug`. Nothing to do if you were deleting it. |
        | `409` | That slug is taken. | Choose another name. |
        | `413` | Page is over \#(maxPageBytes) bytes, or an attachment is over \#(maxAttachmentBytes). | Publish images with `stele attach` and link them, rather than inlining them. |
        | `415` | Content type not on the allowlist. | Publish one of the accepted types. |
        | `426` | The installed tool is older than this deployment requires (`\#(minimumCLIVersion)`). | Run `\#(SteleCLI.installCommand)`, then retry once. |
        | `503` | The server could not allocate a slug. | Retry once, or pass `--slug`. |

        ## The routes the tool uses

        The tool talks to these so you do not have to.

        | Route | Auth | Behaviour |
        | --- | --- | --- |
        | `GET /` | none | Usage page, and a public index of recently published pages |
        | `GET /\#(ServerRoute.healthz)` | none | `ok` |
        | `GET /:slug` | none | The stored page — or, for an attachment, a page about it — or a 404 page if it is absent or expired |
        | `GET /\#(ServerRoute.staticFiles)/:slug` | none | An attachment's bytes, with the type it was stored as. Supports `Range`, so video seeks |
        | `GET \#(Stylesheet.path)` | none | The shared stylesheet |
        | `GET \#(PublishSkill.path)` | none | This document |
        | `POST /\#(ServerRoute.pages)` | `\#(ClientScope.publish.rawValue)` | Stores the body, takes `?slug=` and `?\#(PageLifetime.queryParameter)=`, returns `{slug, url, expires}` as `201` |
        | `PUT /\#(ServerRoute.pages)/:slug` | `\#(ClientScope.publish.rawValue)` | Replaces a stored page, returns `{slug, url, expires}` as `200` |
        | `PATCH /\#(ServerRoute.pages)/:slug` | `\#(ClientScope.publish.rawValue)` | Renames a page with `?slug=` and retimes it with `?\#(PageLifetime.queryParameter)=`, leaving its contents alone; returns `{slug, url, expires}` as `200`. This is what `stele amend` runs — see "Renaming a page, and changing its deadline". |
        | `DELETE /\#(ServerRoute.pages)/:slug` | `\#(ClientScope.publish.rawValue)` | Removes a stored page and frees the slug, returns `204` with no body. This is what `stele delete` runs — see "Deleting a page". |
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
        `stele auth status` answering before you start · the page's deadline reported to the
        user alongside its URL.

        ## What this is not

        - **Reads are unauthenticated and slugs are guessable.** Nothing private goes here.
        - **Every page you publish is listed publicly.** `GET /` shows the most recently
          published live pages by name, so a page is discoverable the moment it exists — not
          only by someone who already has the link. There is no unlisted option. If the user
          would not want the page's *name* on a public index, do not publish it here.
        - **The credential is not yours and never becomes yours.** No step of this document
          ends with you holding a token, and one that seems to is a step you have
          misunderstood.
        - **This is not permanent hosting.** A URL you hand to a user stops working on its
          expiry date, and the user then gets the same "nothing here" page a wrong address gets
          — no explanation, nothing to retry. Say the deadline out loud when you report the URL.
        - **The stylesheet mutates in place.** A restyle reaches an already-published page on
          its next load, which is the point — but a page whose appearance must never change
          should carry its own inline `<style>` and link nothing.
        - **There is no listing endpoint.** Keep the URL you were handed; nothing else will
          give it back to you.
        - **A URL is not a permanent address.** Deleting and renaming both retire the page
          rather than the name, so a link you published can be occupied by somebody else's
          page afterwards. Both are yours to cause — `stele delete` and
          `stele amend \#(SteleCLI.slugFlag)` — so neither is a thing to do to a link that has
          already left your hands. When one has, `stele update` replaces the page without
          moving it.
        """#
    }
}
