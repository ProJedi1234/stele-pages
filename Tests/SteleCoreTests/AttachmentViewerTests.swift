import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The viewer at `GET /:slug` for a page whose body is bytes.
///
/// What it must never become is a second way to get the bytes: the split between this page
/// and `/static/:slug` is what lets a link be shareable and an `<img src>` be embeddable at
/// the same time, and a viewer that answered with the file would collapse the two.
@Suite("Attachment viewer")
struct AttachmentViewerTests {
    static let bytes: [UInt8] = Array(repeating: 0xAB, count: 2_500)

    static func seeded(
        contentType: String = "image/png",
        filename: String? = "screenshot.png",
        expiresAt: Date? = nil
    ) async -> (InMemoryPageStore, Slug) {
        let store = InMemoryPageStore()
        let slug = Slug(unchecked: "amber-willow-heron")
        await store.seed(
            slug: slug,
            body: .blob(bytes: bytes, filename: filename),
            contentType: contentType,
            expiresAt: expiresAt
        )
        return (store, slug)
    }

    static func body(_ client: some TestClientProtocol, _ slug: Slug) async throws -> String {
        try await client.execute(uri: "/\(slug.value)", method: .get) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "text/html; charset=utf-8")
            return String(buffer: response.body)
        }
    }

    /// The page describes the attachment and points at the bytes; it does not contain them.
    @Test func theViewerDescribesTheAttachmentAndLinksTheBytes() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains("screenshot.png"))
            #expect(html.contains("<span class=\"badge\">PNG</span>"))
            #expect(html.contains("2.5 KB"))
            #expect(html.contains("/\(ServerRoute.staticFiles)/\(slug.value)"))
            // Rendered in place, which is what an image viewer is for.
            #expect(html.contains("<img src=\"/\(ServerRoute.staticFiles)/\(slug.value)\""))
        }
    }

    /// Video gets `controls` and nothing else — no autoplay, no loop.
    @Test func videoIsPlayableAndDoesNotStartOnItsOwn() async throws {
        let (store, slug) = await Self.seeded(contentType: "video/mp4", filename: "clip.mp4")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains("<video src=\"/\(ServerRoute.staticFiles)/\(slug.value)\" controls>"))
            #expect(html.contains("autoplay") == false)
            #expect(html.contains("loop") == false)
        }
    }

    /// A type that is neither image nor video gets a download link and no preview element.
    ///
    /// Specifically no `<iframe>` and no `<embed>`: a PDF rendered inside a page on this
    /// origin is a document this server did not write, framed by one it did.
    @Test func anUnpreviewableTypeIsOfferedAsADownloadAndNotFramed() async throws {
        let (store, slug) = await Self.seeded(
            contentType: "application/pdf", filename: "report.pdf"
        )
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains("Download report.pdf"))
            #expect(html.contains("<iframe") == false)
            #expect(html.contains("<embed") == false)
            #expect(html.contains("<img") == false)
        }
    }

    /// A filename is the first caller-controlled string this server renders into HTML, and
    /// it is escaped.
    ///
    /// `validatedFilename` refuses what would break a *header* — quotes, backslashes,
    /// control characters — and `<`, `>` and `&` are not on that list, because they are
    /// ordinary in a filename and harmless in a `Content-Disposition`. They are not harmless
    /// here, and this is the test that says so.
    @Test func aFilenameIsEscapedWhereverItIsRendered() async throws {
        let store = InMemoryPageStore()
        let slug = Slug(unchecked: "amber-willow-heron")
        await store.seed(
            slug: slug,
            body: .blob(bytes: Self.bytes, filename: "<script>alert(1)</script>&.png"),
            contentType: "image/png"
        )
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains("<script>alert(1)</script>") == false)
            #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;&amp;.png"))
            // The `og:title` is an *attribute*, so the same string has to survive being put
            // there too — an escaper that is safe in element content and not in an
            // attribute is one whose correctness depends on where it is called.
            #expect(html.contains(#"content="&lt;script&gt;"#))
        }
    }

    /// A page with no filename falls back to its slug rather than rendering an empty title.
    @Test func anUnnamedAttachmentIsTitledWithItsSlug() async throws {
        let (store, slug) = await Self.seeded(filename: nil)
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains("<title>\(slug.value)</title>"))
            #expect(html.contains("Download this file"))
        }
    }

    /// OpenGraph points a chat client at the *bytes*, not at this page.
    ///
    /// That is the distinction the two URLs exist for: a crawler asked to build a preview
    /// from an HTML document gets the document.
    @Test func openGraphPointsAtTheBytesRatherThanAtThePage() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            let base = TestFixture.baseURL
            #expect(html.contains(#"property="og:image" content="\#(base)/static/\#(slug.value)""#))
            #expect(html.contains(#"property="og:url" content="\#(base)/\#(slug.value)""#))
            #expect(html.contains(#"name="twitter:card" content="summary_large_image""#))
        }

        let (videoStore, videoSlug) = await Self.seeded(
            contentType: "video/mp4", filename: "clip.mp4"
        )
        try await TestFixture.makeApp(store: videoStore).test(.router) { client in
            let html = try await Self.body(client, videoSlug)
            #expect(html.contains(#"property="og:type" content="video.other""#))
            #expect(html.contains(#"property="og:video:type" content="video/mp4""#))
        }
    }

    /// The snippet a reader copies is absolute, because it is copied into somebody else's
    /// page — where `/static/…` points at their server.
    @Test func theEmbedSnippetIsAnAbsoluteURL() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains("&lt;img src=\"\(TestFixture.baseURL)/static/\(slug.value)\""))
        }
    }

    /// A text page still serves its own bytes here. The viewer is for attachments, and
    /// nothing about this route changed for the pages that already used it.
    @Test func aTextPageIsStillServedAsItself() async throws {
        let store = InMemoryPageStore()
        let slug = Slug(unchecked: "quiet-cedar-otter")
        await store.seed(slug: slug, body: "<h1>a page</h1>")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(String(buffer: response.body) == "<h1>a page</h1>")
            }
        }
    }

    /// An attachment appears in the landing index, badged, with no change to that page.
    ///
    /// Asserted rather than assumed because it is the clearest evidence the namespace stayed
    /// whole: `recent` reads `pages`, `PageSummary` has no idea attachments exist, and
    /// `PageContentType.label(for:)` derives the badge from the subtype — so the index
    /// listed these correctly before the viewer that renders them was written. A design that
    /// had split the table would have needed a second query and a merge here.
    @Test func anAttachmentIsListedOnTheLandingPageLikeAnyOtherPage() async throws {
        let (store, slug) = await Self.seeded(contentType: "video/mp4", filename: "clip.mp4")
        await store.seed(slug: Slug(unchecked: "quiet-cedar-otter"), body: "<h1>a page</h1>")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                let html = String(buffer: response.body)
                #expect(html.contains("<a href=\"/\(slug.value)\">"))
                #expect(html.contains("<span class=\"badge\">MP4</span>"))
                // The index links the viewer, not the bytes: a directory of links is read by
                // people, and one entry that starts a download when clicked is a surprise.
                #expect(html.contains("/\(ServerRoute.staticFiles)/\(slug.value)") == false)
                // The filename is not in the index. `PageSummary` has nowhere to put one,
                // which is what keeps that page free of caller-controlled text.
                #expect(html.contains("clip.mp4") == false)
            }
        }
    }

    /// The viewer is not cached, because everything on it can change without the URL moving.
    ///
    /// A `PUT` rewrites the size and the filename this page prints and a `PATCH` moves the
    /// deadline, so a heuristic cache would go on describing an attachment that no longer
    /// looks like that. The stored-page branch of this same route has carried `no-cache` for
    /// exactly that reason since long before attachments existed.
    @Test func theViewerIsRevalidatedLikeThePageBranchOfTheSameRoute() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.headers[.cacheControl] == "no-cache")
                // And deliberately *not* `nosniff`: this document is ours, and that header
                // is this repo's marker for bytes we did not write. The bytes at
                // `/static/:slug` — which we did not write — do carry it.
                #expect(response.headers[.xContentTypeOptions] == nil)
            }
        }
    }

    /// The download link actually downloads.
    ///
    /// Images and video are served `Content-Disposition: inline`, so without the `download`
    /// attribute this anchor displays the file the reader is already looking at, and the
    /// label is a promise the markup does not keep. The name is stated rather than left to
    /// the header, so an unnamed attachment does not save as an extensionless slug.
    @Test func theDownloadLinkAsksTheBrowserToSave() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let html = try await Self.body(client, slug)
            #expect(html.contains(#"download="screenshot.png""#))
        }

        let (unnamed, unnamedSlug) = await Self.seeded(filename: nil)
        try await TestFixture.makeApp(store: unnamed).test(.router) { client in
            let html = try await Self.body(client, unnamedSlug)
            #expect(html.contains("download>"))
        }
    }

    /// An expired attachment gets the uniform 404, like every other dead page.
    @Test func anExpiredAttachmentGetsTheUniform404() async throws {
        let (store, slug) = await Self.seeded(expiresAt: Date().addingTimeInterval(-1))
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body) == notFoundPage())
            }
        }
    }
}
