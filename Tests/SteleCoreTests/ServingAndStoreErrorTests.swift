import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for serving a stored page and for the store's failure paths.
///
/// The serving half pins what a reader gets back: the exact bytes, the content type the
/// page was stored under (not a re-sniffed one), and the `nosniff` header that keeps a
/// browser from second-guessing it. The error half pins the status codes a caller has to
/// distinguish — taken slug, exhausted keyspace, malformed slug, empty body, oversized
/// body — each of which is a different fix at the terminal.
@Suite("Serving and store errors")
struct ServingAndStoreErrorTests {
    /// A stored page comes back byte-for-byte, under its stored type, with the sniffing
    /// opt-out attached. Serving is driven by what the row says, not by a fixed HTML
    /// assumption — hence one argument per stored type, HTML and markdown alike.
    @Test(arguments: [
        ("quiet-cedar-otter", "<h1>hello</h1>\n<p>stored page</p>", PageContentType.default),
        ("brisk-maple-heron", "# heading\n\nbody text\n", "text/markdown; charset=utf-8"),
    ])
    func storedPageServedWithHeaders(name: String, body: String, contentType: String) async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: name)
        await store.seed(slug: slug, body: body, contentType: contentType)

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == body)
                #expect(response.headers[.contentType] == contentType)
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
            }
        }
    }

    /// Asking for a slug someone already holds is a conflict, not a silent overwrite —
    /// the existing page keeps its body.
    @Test func duplicateCustomSlugIs409() async throws {
        let store = InMemoryPageStore()
        let slug = try Slug(custom: "quiet-cedar-otter")
        let original = "<h1>original</h1>"
        await store.seed(slug: slug, body: original)

        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/pages?slug=\(slug.value)",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>replacement</h1>")
            ) { response in
                #expect(response.status == .conflict)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains(slug.value))
            }

            try await client.execute(uri: "/\(slug.value)", method: .get) { response in
                #expect(String(buffer: response.body) == original)
            }
        }
    }

    /// When the generator can't find a free slug the server says so with a retryable
    /// status: this is a capacity problem on our side, not a bad request.
    @Test func allocationExhaustionIs503() async throws {
        let app = try TestFixture.makeApp(store: InMemoryPageStore(failAllocation: true))
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>page</h1>")
            ) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }

    /// A caller-supplied slug goes through the same validation as a generated one. Three
    /// characters with an underscore is long enough to clear the length rule, so this
    /// pins the invalid-character rejection specifically.
    @Test func invalidQuerySlugIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages?slug=abc_def",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>page</h1>")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("Invalid slug:"))
            }
        }
    }

    /// An empty body is refused rather than published: a blank page at a permanent URL is
    /// almost always a truncated upload, not an intent.
    @Test func emptyBodyIs400() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("empty"))
            }
        }
    }

    /// The size limit is enforced, and only the size limit produces this message — the
    /// route rethrows every other collection failure as itself so a dropped connection is
    /// never reported as a too-large page.
    @Test func oversizedBodyIs413() async throws {
        let app = try TestFixture.makeApp(environment: ["STELE_MAX_PAGE_BYTES": "10"])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.token)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: String(repeating: "x", count: 64))
            ) { response in
                #expect(response.status == .contentTooLarge)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("10 byte limit"))
            }
        }
    }
}
