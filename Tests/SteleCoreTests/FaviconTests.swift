import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The site icon. Two paths serve one asset, and most of what is worth asserting is that
/// they cannot drift apart — the built-in pages link one of them and every browser asks
/// for the other by itself.
@Suite("Favicon")
struct FaviconTests {
    /// Both addresses, as literals. `/favicon.ico` in particular is not ours to rename: it
    /// is the path a browser requests without being told, so a change here is a change in
    /// what an uploaded page's tab shows, and has to be seen as one.
    static let uris = ["/assets/favicon.png", "/favicon.ico"]

    // MARK: - The bytes

    /// The one assertion that fails loudly if the base64 literal is corrupted. `bytes`
    /// decodes to empty rather than trapping, deliberately — which means a mangled literal
    /// would otherwise ship as a 200 with a zero-length body and an icon nobody notices is
    /// missing until they look at a tab. The dimensions come out of the IHDR chunk, whose
    /// layout is fixed by the PNG spec: 8-byte signature, 4-byte length, 4-byte type, then
    /// width and height as big-endian `UInt32`.
    @Test func theEmbeddedBytesAreARealPNG() throws {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Favicon.bytes.count > 1000)
        #expect(Array(Favicon.bytes.prefix(8)) == signature)
        #expect(Array(Favicon.bytes[12..<16]) == Array("IHDR".utf8))

        func dimension(at offset: Int) -> UInt32 {
            Favicon.bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        #expect(dimension(at: 16) == 64)
        #expect(dimension(at: 20) == 64)
    }

    // MARK: - The wire contract

    /// The type is `image/png` on both paths, including the one ending in `.ico`. That is
    /// not an oversight: browsers have accepted a PNG at `/favicon.ico` for years, the
    /// extension there is a convention about where to look rather than a claim about the
    /// format, and answering `image/x-icon` would be a lie about bytes that are demonstrably
    /// a PNG two assertions up.
    @Test(arguments: FaviconTests.uris)
    func servesTheIcon(uri: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: uri, method: .get) { response in
                #expect(response.status == .ok, "\(uri)")
                #expect(response.headers[.contentType] == "image/png", "\(uri)")
                #expect(response.headers[.cacheControl] == "no-cache", "\(uri)")
                #expect(Array(buffer: response.body) == Favicon.bytes, "\(uri)")
            }
        }
    }

    /// One asset, two addresses: a reader who has already fetched the icon from one must
    /// not be handed different bytes — or a different validator — by the other. Asserted
    /// across the pair rather than per path, because each of the tests above passes
    /// perfectly while the two routes serve two different things.
    @Test func bothPathsAreTheSameAssetAndTheSameValidator() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            var seen: [(etag: String, body: [UInt8])] = []
            for uri in Self.uris {
                let answer = try await client.execute(uri: uri, method: .get) { response in
                    (etag: try #require(response.headers[.eTag]), body: Array(buffer: response.body))
                }
                seen.append(answer)
            }
            #expect(seen[0].etag == seen[1].etag)
            #expect(seen[0].body == seen[1].body)
            #expect(!seen[0].body.isEmpty)
        }
    }

    /// A browser refetches the icon on every navigation, so `no-cache` without a working
    /// validator would re-send it with every 404 a scanner provokes. Same contract the
    /// stylesheet is held to, and it runs through the same shared helper — which is the
    /// reason to check it here rather than assume it.
    @Test(arguments: FaviconTests.uris)
    func revalidatesWithETag(uri: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let tag = try await client.execute(uri: uri, method: .get) { response in
                try #require(response.headers[.eTag])
            }

            try await client.execute(uri: uri, method: .get, headers: [.ifNoneMatch: tag]) { response in
                #expect(response.status == .notModified, "\(uri)")
                #expect(response.body.readableBytes == 0, "\(uri)")
                #expect(response.headers[.eTag] == tag, "\(uri)")
            }

            try await client.execute(
                uri: uri,
                method: .get,
                headers: [.ifNoneMatch: "\"bogus\""]
            ) { response in
                #expect(response.status == .ok, "\(uri)")
                #expect(Array(buffer: response.body) == Favicon.bytes, "\(uri)")
            }
        }
    }

    /// A subresource fetch carries no credential — the browser asking for `/favicon.ico`
    /// has none to offer and no way to be handed one. A 401 here would also be the icon
    /// route advertising itself as protected, which is what `/admin`'s stub exists to
    /// avoid. No headers at all is the assertion.
    @Test(arguments: FaviconTests.uris)
    func theIconNeedsNoAuth(uri: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: uri, method: .get) { response in
                #expect(response.status != .unauthorized, "\(uri)")
                #expect(response.status == .ok, "\(uri)")
            }
        }
    }

    // MARK: - Reservation and linkage

    /// The asset path is built from the route constant and the root path is the route
    /// constant, so renaming either moves the registration and the `<link>` together.
    /// Reservation is the other half, and `favicon.ico` needs it for the same reason
    /// `skill` does: `Slug.reserved` covering `ServerRoute.names` is what stops a published
    /// page shadowing a route — checked generically by `SlugTests`, and named here because
    /// this is the route that made the set hold a name with a dot in it.
    @Test func pathsAreBuiltFromTheRouteConstants() {
        #expect(Favicon.path == "/\(ServerRoute.assets)/\(Favicon.fileName)")
        #expect(Slug.reserved.contains(ServerRoute.favicon))
    }

    /// `/favicon.ico` is a terminal node that carries a value, like `/skill` and unlike
    /// `/assets` — so it resolves in the trie, needs no uniform-404 stub, and must stay out
    /// of `NotFoundTests.all404sAreIdentical`. Pinned as a 200 here so the instinctive fix
    /// of adding it to that list fails rather than quietly turning the icon into a 404.
    @Test func theRootPathIsAnEndpointRatherThanA404() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.favicon)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] != "text/html; charset=utf-8")
            }
        }
    }

    /// The built-in pages link the icon explicitly rather than relying on the root path,
    /// because the explicit link is what survives this server being mounted under a prefix
    /// — and because it is the same arrangement the stylesheet already has.
    @Test(arguments: [("/", HTTPResponse.Status.ok), ("/no-such-page", HTTPResponse.Status.notFound)])
    func builtInPagesLinkTheIcon(path: String, status: HTTPResponse.Status) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: path, method: .get) { response in
                #expect(response.status == status, "\(path)")
                #expect(String(buffer: response.body).contains("<link rel=\"icon\" href=\"\(Favicon.path)\">"), "\(path)")
            }
        }
    }

    /// The reservation at HTTP level: no write verb may hand out the icon's name. The read
    /// at the end is the real assertion — the rejections would mean nothing if the icon had
    /// been shadowed anyway.
    @Test func theIconsNameCannotBeClaimedAsASlug() async throws {
        let headers: HTTPFields = [
            .authorization: "Bearer \(TestFixture.publishToken)",
            .contentType: "text/html",
        ]

        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.pages)?slug=\(ServerRoute.favicon)",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "<h1>mine now</h1>")
            ) { response in
                #expect(response.status == .badRequest)
            }

            try await client.execute(
                uri: "/\(ServerRoute.pages)/\(ServerRoute.favicon)",
                method: .put,
                headers: headers,
                body: ByteBuffer(string: "<h1>mine now</h1>")
            ) { response in
                #expect(response.status == .badRequest)
            }

            try await client.execute(uri: "/\(ServerRoute.favicon)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(Array(buffer: response.body) == Favicon.bytes)
            }
        }
    }
}
