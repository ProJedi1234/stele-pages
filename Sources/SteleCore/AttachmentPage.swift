import Foundation

/// The viewer: what `GET /:slug` answers for a page whose body is bytes.
///
/// An attachment has two URLs and this is the one a person is given — the media rendered in
/// place, with its name, size, type and deadline, and a link to the bytes themselves. The
/// other URL, `/static/:slug`, is what an `<img src>` points at, and the split is the whole
/// reason a viewer can exist at all: a server with one URL per attachment has to choose
/// between showing a page and serving a file, and either choice is wrong half the time.
///
/// It is also the first page in this server to render a string a caller chose. Everything
/// else — slugs, content types, formatted dates — comes from a fixed vocabulary, which is
/// what `recentIndex`'s comment says and why there was no escaper until now. A filename is
/// free text: `validatedFilename` refuses the characters that would break a *header*, and
/// `<`, `>` and `&` are not among them, because they are perfectly ordinary in a filename
/// and harmless there. They are not harmless here.

/// The one HTML escaper in this server, for text a caller chose.
///
/// Ampersand first, or every entity this writes gets re-escaped by the substitutions after
/// it and `&lt;` reaches the reader as `&amp;lt;`.
///
/// Quotes are escaped along with the angle brackets even though the filename is only ever
/// placed in element content and in a `<meta content="…">`. The second of those is an
/// attribute, and an escaper that is safe in one context and not the other is one whose
/// correctness depends on where somebody pastes the call.
func htmlEscaped(_ raw: String) -> String {
    raw.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// A byte count as a person reads it: "812 bytes", "41.2 KB", "6.8 MB".
///
/// Decimal units rather than binary, because this number sits next to a video and is read
/// by whoever is deciding whether to click it — the same units their operating system's
/// file listing shows and their connection is measured in. The byte-exact figure is not
/// lost: it is what `Content-Length` carries on the response this page links to.
func formattedByteSize(_ bytes: Int) -> String {
    switch bytes {
    case ..<1_000: return "\(bytes) bytes"
    case ..<1_000_000: return String(format: "%.1f KB", Double(bytes) / 1_000)
    case ..<1_000_000_000: return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    default: return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// The viewer page for one attachment.
///
/// - Parameter now: injected so the relative times are testable without the wall clock, as
///   on the landing page.
func attachmentPage(
    slug: Slug,
    contentType: String,
    filename: String?,
    byteSize: Int,
    createdAt: Date,
    expiresAt: Date?,
    baseURL: String,
    now: Date = Date()
) -> String {
    let rawPath = "/\(ServerRoute.staticFiles)/\(slug.value)"
    let rawURL = "\(baseURL)\(rawPath)"
    // The filename when there is one, the slug otherwise. A slug is a poor title for a file
    // and a fine one for a page, which is exactly what this is when nobody named the upload.
    let title = filename.map(htmlEscaped) ?? slug.value
    let label = PageContentType.label(for: contentType) ?? "FILE"

    return """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(title)</title>
    <link rel="stylesheet" href="\(Stylesheet.path)">
    <link rel="icon" href="\(Favicon.path)">
    \(openGraphTags(title: title, contentType: contentType, rawURL: rawURL, slug: slug, baseURL: baseURL))
    </head>
    <body class="narrow">
    <h1>\(title)</h1>
    <p class="muted"><span class="badge">\(label)</span> \(formattedByteSize(byteSize)) &middot;
    published \(timeElement(createdAt, text: publishedLabel(createdAt, now: now))) &middot;
    expires \(expiresAt == nil ? "never" : timeElement(expiresAt!, text: expiryLabel(expiresAt, now: now)))</p>
    \(preview(contentType: contentType, rawPath: rawPath, title: title))
    <p><a href="\(rawPath)" \(downloadAttribute(filename: filename, title: title))>\(filename == nil ? "Download this file" : "Download \(title)")</a></p>
    <div class="card">
    <h3>Embedding it</h3>
    <p class="muted">This page is for reading. To put the file in a page of your own, link
    the bytes directly — that URL serves the file and nothing around it.</p>
    <pre><code>\(embedSnippet(contentType: contentType, rawURL: rawURL, title: title))</code></pre>
    </div>
    </body></html>
    """
}

/// The `download` attribute that makes the link's label true.
///
/// Without it this anchor is a plain navigation, and images and video are served
/// `Content-Disposition: inline` — so "Download screenshot.png" would *display* the
/// screenshot, which is what the reader was already looking at. The attribute is what turns
/// a navigation into a save, and it is same-origin here, which is the only case browsers
/// honour it in.
///
/// Named explicitly when there is a filename rather than left bare. A bare `download` takes
/// the name from `Content-Disposition` and falls back to the URL's last segment, which here
/// is the slug — so an attachment uploaded without a name would save as
/// `quiet-cedar-otter`, extensionless, opening in nothing. Stating it keeps the two paths
/// from depending on a header this page cannot see.
private func downloadAttribute(filename: String?, title: String) -> String {
    filename == nil ? "download" : "download=\"\(title)\""
}

/// The media itself, rendered the way its type wants to be rendered.
///
/// `controls` on the video and nothing else — no `autoplay`, no `loop`. An attachment is
/// often evidence somebody is about to watch deliberately, and a page that starts making
/// noise when it opens is a page nobody sends twice.
///
/// Anything that is neither image nor video gets no preview element at all rather than an
/// `<embed>` or an `<iframe>`. A PDF in an iframe on this origin is a document this server
/// did not write, rendering inside a page it did, and the download link below it does the
/// same job with none of that.
private func preview(contentType: String, rawPath: String, title: String) -> String {
    if contentType.hasPrefix("image/") {
        return #"<p><img src="\#(rawPath)" alt="\#(title)"></p>"#
    }
    if contentType.hasPrefix("video/") {
        return #"<p><video src="\#(rawPath)" controls></video></p>"#
    }
    return ""
}

/// What to paste into a page of your own.
///
/// The absolute URL, not the path: this snippet is copied into a page that may not be
/// served from here at all, and a root-relative `/static/…` in somebody else's document
/// points at their server.
private func embedSnippet(contentType: String, rawURL: String, title: String) -> String {
    if contentType.hasPrefix("image/") {
        return #"&lt;img src="\#(rawURL)" alt="\#(title)"&gt;"#
    }
    if contentType.hasPrefix("video/") {
        return #"&lt;video src="\#(rawURL)" controls&gt;&lt;/video&gt;"#
    }
    return #"&lt;a href="\#(rawURL)"&gt;\#(title)&lt;/a&gt;"#
}

/// OpenGraph tags, so a link pasted into a chat client unfurls into the thing it points at.
///
/// The only page in this server with a reason to carry them: sharing a screenshot's link is
/// the case this viewer exists for, and a preview is most of what the recipient wanted. The
/// landing page and a published page do not get them — one is a directory and the other is
/// a document whose contents this server did not write and cannot summarise.
///
/// `og:image` points at the raw bytes rather than at this page, which is the distinction the
/// two URLs exist for. A crawler asked to render a preview from an HTML document would get
/// the document.
private func openGraphTags(
    title: String, contentType: String, rawURL: String, slug: Slug, baseURL: String
) -> String {
    var tags = [
        #"<meta property="og:title" content="\#(title)">"#,
        #"<meta property="og:url" content="\#(baseURL)/\#(slug.value)">"#,
    ]
    if contentType.hasPrefix("image/") {
        tags.append(#"<meta property="og:type" content="website">"#)
        tags.append(#"<meta property="og:image" content="\#(rawURL)">"#)
        // Twitter reads its own vocabulary and falls back to a small thumbnail without
        // this, which for a screenshot is the one thing the preview is for.
        tags.append(#"<meta name="twitter:card" content="summary_large_image">"#)
    } else if contentType.hasPrefix("video/") {
        tags.append(#"<meta property="og:type" content="video.other">"#)
        tags.append(#"<meta property="og:video" content="\#(rawURL)">"#)
        tags.append(#"<meta property="og:video:type" content="\#(contentType)">"#)
    } else {
        tags.append(#"<meta property="og:type" content="website">"#)
    }
    return tags.joined(separator: "\n")
}
