/// The shared stylesheet served at `GET /assets/stele.css`.
///
/// A Swift string rather than a SwiftPM resource: the Dockerfile's runtime stage copies
/// only the built executable out of the build stage, and SwiftPM emits a resource bundle
/// as a *sibling directory* of that executable which `--static-swift-stdlib` does not
/// embed. A `Bundle.module` lookup would therefore pass `swift test` on a dev machine and
/// trap the moment it ran in production — the worst possible failure shape. Compiled into
/// the binary, the sheet cannot be missing at runtime. (Moving it to a top-level
/// `Resources/` would also drop it out of CI's `Sources/**` path filter.)
///
/// Internal, not public, matching `notFoundPage()` / `landingPage(_:)`: the tests reach it
/// through `@testable import`, and nothing outside this module has a reason to hold the
/// bytes rather than the URL.
enum Stylesheet {
    static let fileName = "stele.css"

    /// Built from `ServerRoute.assets` so the route registration and the `<link href>` on
    /// every built-in page come from one string and cannot drift.
    static let path = "/\(ServerRoute.assets)/\(fileName)"

    /// Deliberately the same string `PageContentType.allowed["text/css"]` maps to, so the
    /// built-in sheet and a caller-uploaded stylesheet are indistinguishable in type. A
    /// test pins the two together.
    static let contentType = "text/css; charset=utf-8"

    /// The component classes this sheet defines. The source of truth for the publish skill
    /// (issue #4) and for the tests that assert each one has both a rule and a comment, so
    /// a class renamed in the CSS cannot quietly leave this list — or the skill — lying.
    static let componentClasses = ["card", "grid", "scroll", "callout", "badge", "muted", "narrow", "wide"]

    /// A raw literal because CSS legitimately contains backslashes (`content: "\201C"`,
    /// escaped selectors) and this string is fully static: raw removes an entire class of
    /// escaping bug at zero cost. Interpolation, if it were ever needed, is `\#(...)`.
    ///
    /// Served verbatim — no minification, no comment stripping. The comments are an
    /// acceptance criterion of issue #3 and the raw material issue #4 reads.
    static let css = #"""
    /* stele.css — the shared look for pages published on this server.
     *
     * Link it from the <head> of any page you publish:
     *
     *     <link rel="stylesheet" href="/assets/stele.css">
     *
     * Plain semantic HTML needs no classes at all: headings, paragraphs, lists, links,
     * code, tables and quotes are styled as they come. The classes below are opt-in extras
     * for the handful of shapes that HTML has no element for.
     *
     * Dark mode is automatic — it follows the reader's system setting, with no toggle and
     * no JavaScript, because published pages are static files.
     *
     * Retheme without forking: override any --stele-* custom property in your own page.
     *
     * This file mutates in place; there is no versioned path. Editing it restyles every
     * page that links it, which is the point — but it means a page that must never change
     * appearance should carry its own <style> instead of linking here.
     */

    /* ---------------------------------------------------------------------------
     * Tokens
     *
     * Custom properties are prefixed --stele-* because they inherit: a published page
     * that defines its own --fg or --accent would otherwise silently retint our
     * components from the outside. Component *class* names are unprefixed — matching is
     * not inheritance, so a collision takes a deliberate `.card` rule from the author,
     * and short names are what someone writing a page will actually type.
     * ------------------------------------------------------------------------ */

    :root {
      /* Tells the UA to theme scrollbars, form controls and the default canvas rather
         than leaving them light under a dark page. */
      color-scheme: light dark;

      --stele-bg: #fafaf9;
      --stele-fg: #1c1917;
      /* Kept at >= 4.5:1 on --stele-bg: .muted is secondary, not decorative. */
      --stele-muted: #57534e;
      --stele-surface: #f5f5f4;
      --stele-border: #e7e5e4;
      --stele-accent: #0f766e;

      /* A step away from --stele-surface rather than equal to it, which is what `code`
         used to be. A chip is drawn on whatever it sits on, and .card, thead, striped rows
         and the .callout fallback are all --stele-surface — so sharing that value made
         inline code vanish inside every one of them. */
      --stele-code-bg: #e7e5e4;

      /* One tone vocabulary shared by .callout and .badge, so a status reads the same
         whichever shape it is wearing.
         These are darker than the obvious mid-weight choice because .badge paints them as
         12px/600 *text* on a tint of themselves, which is the worst case in the file: it
         needs 4.5:1 against that tint, not against the canvas. The lighter shades cleared
         4.8:1 on the canvas and only ~4.1:1 where they are actually used. */
      --stele-tone-note: #1d4ed8;
      --stele-tone-ok: #166534;
      --stele-tone-warn: #92400e;
      --stele-tone-danger: #b91c1c;

      --stele-measure: 40rem;
      --stele-radius: .5rem;
    }

    /* The only dark-mode block in the file, and it reassigns tokens and nothing else.
       If a rule ever seems to belong in here, the value it changes belongs in a token
       instead — the whole point of the tokens is that a new component is dark-mode
       correct for free, without a second copy of itself to keep in step. */
    @media (prefers-color-scheme: dark) {
      :root {
        --stele-bg: #1c1917;
        --stele-fg: #e7e5e4;
        --stele-muted: #a8a29e;
        --stele-surface: #292524;
        --stele-border: #44403c;
        --stele-accent: #5eead4;
        --stele-code-bg: #44403c;

        --stele-tone-note: #93c5fd;
        --stele-tone-ok: #86efac;
        --stele-tone-warn: #fcd34d;
        --stele-tone-danger: #fca5a5;
      }
    }

    /* ---------------------------------------------------------------------------
     * Base elements — everything below applies to plain HTML, no classes required.
     * ------------------------------------------------------------------------ */

    *, *::before, *::after { box-sizing: border-box; }

    body {
      font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
      max-width: var(--stele-measure);
      margin: 12vh auto;
      padding: 0 1.5rem;
      /* Colour lives on body, not html, so the background propagates to the canvas and
         fills the area past the `auto` margins instead of framing the text in white. */
      color: var(--stele-fg);
      background: var(--stele-bg);
      text-wrap: pretty;
    }

    h1, h2, h3 { line-height: 1.25; margin: 2rem 0 .75rem; text-wrap: balance; }
    h1 { font-size: 1.9rem; margin-top: 0; }
    h2 { font-size: 1.4rem; }
    h3 { font-size: 1.15rem; }

    p, ul, ol, pre, table, blockquote { margin: 0 0 1rem; }
    ul, ol { padding-left: 1.5rem; }
    li { margin: .25rem 0; }

    a { color: var(--stele-accent); text-underline-offset: .15em; }

    /* :focus-visible rather than :focus, so a mouse click does not leave a ring behind
       while keyboard navigation still gets one. */
    :focus-visible { outline: 2px solid var(--stele-accent); outline-offset: 2px; }

    code {
      font-size: .9em;
      background: var(--stele-code-bg);
      padding: .15em .4em;
      border-radius: .25rem;
    }

    pre {
      background: var(--stele-surface);
      border: 1px solid var(--stele-border);
      border-radius: var(--stele-radius);
      padding: 1rem;
      /* A long command line scrolls its own block rather than widening the document and
         giving the whole page a horizontal scrollbar. */
      overflow-x: auto;
    }

    /* Inside a pre the block already provides the surface; a second one would draw a
       box around the code within the box. */
    pre code { background: none; padding: 0; font-size: inherit; }

    blockquote {
      margin-left: 0;
      padding-left: 1rem;
      border-left: 3px solid var(--stele-border);
      color: var(--stele-muted);
    }

    hr { border: 0; border-top: 1px solid var(--stele-border); margin: 2rem 0; }

    img, video, svg { max-width: 100%; height: auto; }

    /* `separate` rather than the `collapse` a bordered table usually reaches for: a
       collapsed table has no border box of its own for `border-radius` to round, so the
       corners are silently dropped. Separate borders keep them, and cost one extra rule —
       zeroing `border-spacing` — to sit as tightly as a collapsed one. */
    table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      border: 1px solid var(--stele-border);
      border-radius: var(--stele-radius);
      /* What actually rounds the corners: it clips the head's shading and the last row's
         stripe, which are square and would otherwise fill back over them. The cost is
         that a table too wide to compress clips instead of scrolling — cells wrap, so
         that only bites on unbreakable content. */
      overflow: hidden;
    }

    th, td { text-align: left; padding: .5rem .75rem; border-bottom: 1px solid var(--stele-border); }

    /* Shaded and set off by a heavier rule, so the head reads as a label strip rather than
       as the first row of data. */
    thead th { background: var(--stele-surface); border-bottom-width: 2px; font-weight: 600; }

    /* Alternating shading — what lets the eye carry a row across to the far column without
       losing its line. `even` so the first body row stays on the canvas colour and its
       stripe cannot be misread as a continuation of the head's. */
    tbody tr:nth-child(even) { background: var(--stele-surface); }

    /* The table's own border already draws the bottom edge; the last row's would sit just
       inside it as a second line. */
    tbody tr:last-child td { border-bottom: 0; }

    /* ---------------------------------------------------------------------------
     * Components — opt-in classes, one comment each describing purpose and markup.
     * ------------------------------------------------------------------------ */

    /* .card — a bordered surface panel for grouping a title and a few lines of content.
       <div class="card"><h3>Title</h3><p>Body text.</p></div> */
    .card {
      background: var(--stele-surface);
      border: 1px solid var(--stele-border);
      border-radius: var(--stele-radius);
      padding: 1rem 1.25rem;
    }
    /* The card supplies its own padding; a heading's or paragraph's outer margin on top
       of it would double the gap at the edges only. */
    .card > :first-child { margin-top: 0; }
    .card > :last-child { margin-bottom: 0; }

    /* .grid — a responsive row of cards that rewraps itself; there are no breakpoints to
       pick, because auto-fit decides the column count from the available width.
       <div class="grid"><div class="card">…</div><div class="card">…</div></div> */
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr));
      gap: 1rem;
      margin: 0 0 1rem;
    }

    /* .scroll — wraps something too wide for the page — nearly always a table — so it
       scrolls inside its own frame instead of squeezing every column into a ragged mess.
       <div class="scroll"><table>…</table></div> */
    .scroll {
      overflow-x: auto;
      border: 1px solid var(--stele-border);
      border-radius: var(--stele-radius);
      margin: 0 0 1rem;
    }
    /* A wrapper is unavoidable here, and it is worth knowing why before anyone tries to
       delete it. Scrolling needs two boxes: an outer one pinned to the page width, and an
       inner one free to be wider. A lone `<table>` cannot be both — give it
       `overflow-x: auto` and it is still shrink-to-fit, so it compresses to the available
       width and wraps rather than ever overflowing; force it wider and it pushes the whole
       document sideways instead of scrolling in place. */
    .scroll > table {
      /* Fills the frame when the content is narrow, and is free to exceed it when the
         cells cannot compress any further — which is exactly when scrolling should start. */
      min-width: 100%;
      /* The frame is the wrapper's now; the table's own would draw a second one just
         inside it, and its rounded corners would fight the wrapper's. */
      border: 0;
      border-radius: 0;
      margin: 0;
    }
    /* The actual cause of the mess this class exists to fix: `--stele-bg` in a cell breaks
       after each hyphen, so a column of identifiers collapses into stacked fragments long
       before the table gives up and scrolls. Holding code on one line raises the table's
       minimum width past the viewport, which is what hands the scroll to the wrapper.
       Scoped inside `.scroll` deliberately — code in ordinary prose has no scroll
       container to escape into, and would run off the page. */
    .scroll th code, .scroll td code { white-space: nowrap; }

    /* .callout — a tinted aside for a note, warning or result, marked with an accent
       left border. Add a tone class to recolour it: note (default), ok, warn, danger.
       <div class="callout warn"><p>Heads up.</p></div> */
    .callout {
      --stele-tone: var(--stele-tone-note);
      border-left: 3px solid var(--stele-tone);
      border-radius: 0 var(--stele-radius) var(--stele-radius) 0;
      padding: .75rem 1rem;
      margin: 0 0 1rem;
      /* The flat, universally supported background. It is guarded by the @supports block
         below rather than by a second declaration underneath it: the usual two-declaration
         fallback does not work here, because a declaration containing var() is assumed
         valid at parse time and only syntax-checked after the cascade has already thrown
         the earlier one away. On an engine without color-mix() that leaves `background`
         unset — transparent — not this surface. The feature query is what keeps it. */
      background: var(--stele-surface);
    }
    /* Literal colours in the condition on purpose: a var() inside it would make the query
       untestable at parse time for exactly the reason above, and always report support. */
    @supports (background: color-mix(in oklab, red, blue)) {
      .callout { background: color-mix(in oklab, var(--stele-tone) 10%, var(--stele-bg)); }
    }
    .callout > :first-child { margin-top: 0; }
    .callout > :last-child { margin-bottom: 0; }
    .callout.note { --stele-tone: var(--stele-tone-note); }
    .callout.ok { --stele-tone: var(--stele-tone-ok); }
    .callout.warn { --stele-tone: var(--stele-tone-warn); }
    .callout.danger { --stele-tone: var(--stele-tone-danger); }

    /* .badge — a small inline pill for a status, an HTTP method or a tag. Takes the same
       tone classes as .callout: note (default), ok, warn, danger.
       <span class="badge ok">POST</span> */
    .badge {
      --stele-tone: var(--stele-tone-note);
      display: inline-block;
      font-size: .75rem;
      font-weight: 600;
      line-height: 1.4;
      letter-spacing: .02em;
      padding: .1rem .5rem;
      border: 1px solid var(--stele-tone);
      border-radius: 999px;
      color: var(--stele-tone);
      /* Same arrangement as .callout, for the same reason: the flat background stands
         alone, and the tint is layered on only where the feature query says it will
         compute, so the pill still reads as a pill without color-mix(). */
      background: var(--stele-surface);
    }
    @supports (background: color-mix(in oklab, red, blue)) {
      .badge { background: color-mix(in oklab, var(--stele-tone) 12%, var(--stele-bg)); }
    }
    .badge.note { --stele-tone: var(--stele-tone-note); }
    .badge.ok { --stele-tone: var(--stele-tone-ok); }
    .badge.warn { --stele-tone: var(--stele-tone-warn); }
    .badge.danger { --stele-tone: var(--stele-tone-danger); }

    /* ---------------------------------------------------------------------------
     * Utilities
     *
     * The body modifiers come after the `body` rule deliberately: they win the shorthand
     * margin on specificity (0,1,0 beats 0,0,1), and `body { max-width: var(--stele-measure) }`
     * reads whatever they reassign the token to.
     * ------------------------------------------------------------------------ */

    /* .muted — secondary text: a subtitle, a caption, an aside.
       <p class="muted">Updated yesterday.</p> */
    .muted { color: var(--stele-muted); }

    /* .narrow — a body modifier for a short, centred message page; narrower measure, and
       the text sits lower so a single paragraph is not stranded at the top.
       <body class="narrow"> */
    body.narrow { --stele-measure: 32rem; margin-block-start: 20vh; }

    /* .wide — a body modifier for pages carrying tables, wide code blocks or galleries
       that a reading measure would squeeze.
       <body class="wide"> */
    body.wide { --stele-measure: 64rem; }
    """#
}

extension Stylesheet {
    /// A strong validator over the stylesheet bytes, so `no-cache` costs a conditional
    /// request rather than a download while still guaranteeing an edit reaches every page
    /// on its next load. That matters more than it looks: the 404 page links this sheet,
    /// and scanner traffic against the 404 surface is explicitly in this repo's threat
    /// model, so an unvalidated `no-cache` would turn every miss into a multi-KB download.
    ///
    /// Computed once, lazily, over a compile-time constant.
    static let etag: String = strongETag(over: css.utf8)
}
