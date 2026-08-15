import Foundation

/// The landing page: what this server is, and what has lately been published to it.
///
/// Split out of `Server.swift` when it stopped being a string constant. It now reads the
/// store, so it has an index to render, an empty state, a degraded state, and a small
/// vocabulary of relative times — none of which belong in the file that wires up routes.
///
/// It is also the server's own showcase for the shared stylesheet: whatever it demonstrates
/// here is what an author can copy. It uses only names listed in
/// `Stylesheet.componentClasses`, and only their bare forms — the tone modifiers
/// (`.badge.ok`, `.callout.warn`, …) are real CSS but not part of that list, so reaching for
/// one here would fail the drift test that keeps the list honest. The index is deliberately
/// a plain `<table>`: the sheet styles tables with no classes at all, so the most prominent
/// thing on the page is a demonstration that plain semantic HTML is already enough.

/// How many pages the index shows.
///
/// A landing page, not a paginated archive: twenty is about a screen, and there is no "next"
/// link because a second page of results would be an enumeration API with a slower interface
/// rather than a different feature. Anyone who needs the whole table has the database.
let recentPageCount = 20

/// The landing page.
///
/// - Parameter recent: the newest live pages, or **nil** when the store could not be read.
///   The distinction matters and is why this is not just an empty array: an empty index means
///   "nothing has been published", which is a true and useful thing to say, whereas a
///   database that is down knows nothing about how many pages exist. Rendering the second as
///   the first would put "no pages published yet" in front of a reader looking at a server
///   holding hundreds.
/// - Parameter now: injected so the relative times are testable without the wall clock.
///
/// The `\(baseURL)/pages` adjacency is asserted by a test. Do not reformat it or break the
/// interpolation away from the path.
func landingPage(baseURL: String, recent: [PageSummary]?, now: Date = Date()) -> String {
    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>stele</title>
    <link rel="stylesheet" href="\(Stylesheet.path)">
    <link rel="icon" href="\(Favicon.path)"></head>
    <body>
    <h1>stele</h1>
    <p class="muted">Publish an HTML file, get a readable link back.</p>
    \(recentIndex(recent, now: now))
    <h2>Publishing</h2>
    <pre><code>stele publish index.html</code></pre>
    <p>The <code>stele</code> CLI holds the credential so the thing running it never has to.
    Underneath, that is a <code>POST</code> to <code>\(baseURL)/pages</code> with a bearer
    token — reachable with curl if you already hold one.</p>
    <p>Returns a slug like <code>quiet-cedar-otter</code>, served at
    <code>\(baseURL)/quiet-cedar-otter</code>. Add <code>?slug=my-page</code> to choose
    your own.</p>
    <p>A page expires \(PageLifetime.defaultDays) days after it is published unless you say
    otherwise. Add <code>?\(PageLifetime.queryParameter)=30</code> for a different number of
    days, or <code>?\(PageLifetime.queryParameter)=\(PageLifetime.neverKeyword)</code> to
    keep it for good.</p>
    <div class="grid">
    <div class="card"><h3><span class="badge">POST</span> /pages</h3>
    <p>Publish a page and get a fresh slug back, or ask for one with
    <code>?slug=</code>. Choose how long it lives with
    <code>?\(PageLifetime.queryParameter)=</code>.</p></div>
    <div class="card"><h3><span class="badge">PUT</span> /pages/:slug</h3>
    <p>Replace the page already published at a slug. Never creates one.</p></div>
    <div class="card"><h3><span class="badge">PATCH</span> /pages/:slug</h3>
    <p>Move a page to a new name with <code>?slug=</code>, or give it a new deadline with
    <code>?\(PageLifetime.queryParameter)=</code>. Its contents are left alone, and the old
    name goes back in the pool.</p></div>
    <div class="card"><h3><span class="badge">DELETE</span> /pages/:slug</h3>
    <p>Remove the page at a slug for good. The name goes back in the pool.</p></div>
    </div>
    <div class="callout">
    <p>Pages you publish can share this server's look. Link the stylesheet from your
    <code>&lt;head&gt;</code>:
    <code>&lt;link rel="stylesheet" href="\(Stylesheet.path)"&gt;</code> — plain HTML needs
    no classes, and dark mode follows the reader's system setting.</p>
    <p>Publishing from an agent? <a href="\(PublishSkill.path)"><code>\(PublishSkill.path)</code></a>
    is a skill document that teaches the whole contract — installing the CLI, the page
    rules and the component classes — served by this server, so it cannot drift from it.</p>
    </div>
    </body></html>
    """
}

/// The index itself: a heading and either a table, an empty state, or a note that the store
/// could not be read.
///
/// Every page listed here is one anybody could already have found by scanning — the README
/// is explicit that an 11.8M keyspace is enumerable by a script, and that slugs are pretty
/// rather than secret. What this changes is the cost, from a scan to a page load, so it is
/// worth being clear about what it does *not* change: expired pages never appear, because
/// `recent` carries the same deadline predicate every read does, so the one thing the uniform
/// 404 protects — that a name *used to* be a page — is still not on offer here.
private func recentIndex(_ recent: [PageSummary]?, now: Date) -> String {
    guard let recent else {
        // Degraded, not fatal. The rest of this page is documentation that is still true and
        // still worth serving while the database is unreachable, and a reader who came for
        // "how do I publish" should get an answer rather than a 500. The handler logs the
        // underlying error; this line is what the reader is owed.
        return """
            <h2>Recently published</h2>
            <p class="muted">The index is unavailable right now.</p>
            """
    }

    guard !recent.isEmpty else {
        return """
            <h2>Recently published</h2>
            <p class="muted">Nothing published yet.</p>
            """
    }

    // No HTML escaping anywhere in this table, and that is a property of the inputs rather
    // than an omission. A `Slug` has passed `Slug(custom:)`, which permits lowercase ASCII
    // letters, digits and hyphens and nothing else — no `<`, no `&`, no quote. The content
    // type is one of `PageContentType.allowed`'s values. The dates are formatted here. The
    // page body, which is the one piece of caller-controlled text in the system, is not read
    // by `recent` and has nowhere in `PageSummary` to live. If a column is ever added that
    // carries free text — a title, a description — it needs an escaper, and this comment is
    // the reason there isn't one yet.
    let rows = recent.map { page in
        let label = PageContentType.label(for: page.contentType)
        let badge = label.map { " <span class=\"badge\">\($0)</span>" } ?? ""
        return """
            <tr><td><a href="/\(page.slug.value)"><code>\(page.slug.value)</code></a>\(badge)</td>\
            <td>\(timeElement(page.createdAt, text: publishedLabel(page.createdAt, now: now)))</td>\
            <td class="muted">\(expiresCell(page.expiresAt, now: now))</td></tr>
            """
    }

    // `.scroll` around the table: on a phone the slug column cannot compress past a
    // hyphenated three-word name without breaking it into stacked fragments, which is the
    // exact mess that class exists to fix — it also holds `code` in these cells on one line.
    return """
        <h2>Recently published</h2>
        <div class="scroll">
        <table>
        <thead><tr><th>Page</th><th>Published</th><th>Expires</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        </div>
        """
}

/// The expiry cell: a `<time>` for a real deadline, plain text for a page that has none.
///
/// "never" is not a time and must not be marked up as one — a `<time>` element with no
/// parseable `datetime` is invalid, and one carrying a made-up far-future instant would be a
/// lie told to every machine that reads the attribute rather than the text.
private func expiresCell(_ expiresAt: Date?, now: Date) -> String {
    guard let expiresAt else { return "never" }
    return timeElement(expiresAt, text: expiryLabel(expiresAt, now: now))
}

/// Wraps a coarse label in a `<time>` carrying the exact instant.
///
/// The visible text is deliberately imprecise — "2h ago" is what a list of links wants — and
/// the precision it drops has to go somewhere, or the page is the only place this information
/// exists and it is now approximate. `datetime` is the machine-readable copy; `title` is the
/// same string, so hovering a row recovers the exact moment without a round trip.
private func timeElement(_ instant: Date, text: String) -> String {
    let iso = instant.formatted(.iso8601)
    return "<time datetime=\"\(iso)\" title=\"\(iso)\">\(text)</time>"
}

/// "just now", "9m ago", "2h ago", "6d ago".
private func publishedLabel(_ createdAt: Date, now: Date) -> String {
    let elapsed = now.timeIntervalSince(createdAt)
    // Also the clock-skew branch: a `created_at` stamped by a database whose clock runs ahead
    // of this process gives a negative interval, and "just now" is the right thing to say
    // about it. "in 3s ago" is not.
    guard elapsed >= 60 else { return "just now" }
    return "\(coarse(elapsed)) ago"
}

/// "in 6d", "in 3h", or "any moment" for a page inside its last minute.
private func expiryLabel(_ expiresAt: Date?, now: Date) -> String {
    guard let expiresAt else { return "never" }
    let remaining = expiresAt.timeIntervalSince(now)
    // `recent` only returns pages whose deadline is still ahead, but it is the *database's*
    // `now()` that decided that and this is a later moment on a different clock. A page can
    // therefore arrive here with a deadline that has just passed, and "in -1s" would be the
    // reading of that. This says the honest thing for both.
    guard remaining >= 60 else { return "any moment" }
    return "in \(coarse(remaining))"
}

/// An interval as a single whole unit: minutes, then hours, then days, then years.
///
/// Truncating rather than rounding, so a label never claims more time than has actually
/// passed — "1h" at eighty-nine minutes is imprecise, "2h" at ninety-one would be wrong in
/// the direction that matters for an expiry. Weeks and months are skipped on purpose: a
/// month is not a fixed number of days, and a list that mixed "5w" and "1mo" would be
/// comparing two units that overlap.
private func coarse(_ seconds: TimeInterval) -> String {
    let whole = Int(seconds)
    switch whole {
    case ..<3_600: return "\(whole / 60)m"
    case ..<86_400: return "\(whole / 3_600)h"
    case ..<31_536_000: return "\(whole / 86_400)d"
    default: return "\(whole / 31_536_000)y"
    }
}
