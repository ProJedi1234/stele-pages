import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for `GET /static/:slug`, the URL an `<img src>` or a `<video src>`
/// points at.
///
/// Range support is the reason most of this exists. Safari will not play a `<video>` whose
/// source answers a `Range` request with a `200` and the whole body — it probes with
/// `bytes=0-1` and gives up — so the `206` path is not an optimisation here, it is whether
/// video works at all.
@Suite("Serving attachments")
struct ServeAttachmentTests {
    /// Sixteen distinguishable bytes, so an off-by-one in a slice is visible in the
    /// assertion rather than hidden inside a run of identical filler.
    static let bytes: [UInt8] = Array(0x10...0x1F)

    static func seeded(
        contentType: String = "video/mp4",
        filename: String? = "clip.mp4",
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

    /// The whole file, with the headers an embedded resource needs.
    ///
    /// `Accept-Ranges` is on the unranged response deliberately: a player that cannot see
    /// it on the first request never sends a second one carrying a `Range`.
    @Test func servesTheBytesWithTheHeadersAnEmbedNeeds() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/static/\(slug.value)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(Array(buffer: response.body) == Self.bytes)
                #expect(response.headers[.contentType] == "video/mp4")
                #expect(response.headers[.acceptRanges] == "bytes")
                #expect(response.headers[.xContentTypeOptions] == "nosniff")
                // Mutable in place, exactly like a page: `PUT` replaces the bytes without
                // moving the URL, so a cache has to come back and ask.
                #expect(response.headers[.cacheControl] == "no-cache")
                #expect(response.headers[.eTag] != nil)
                // Video renders in place; the filename rides along for a reader who saves
                // it, because `amber-willow-heron` opens in nothing.
                #expect(response.headers[.contentDisposition] == #"inline; filename="clip.mp4""#)
            }
        }
    }

    /// A PDF is offered as a download rather than rendered, and carries its name.
    @Test func aNonRenderableTypeIsOfferedAsADownload() async throws {
        let (store, slug) = await Self.seeded(
            contentType: "application/pdf", filename: "report.pdf"
        )
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/static/\(slug.value)", method: .get) { response in
                #expect(
                    response.headers[.contentDisposition] == #"attachment; filename="report.pdf""#
                )
            }
        }
    }

    /// The probe Safari opens with, and the shape everything else is built on.
    @Test func aRangeRequestIsAnswered206WithAContentRange() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/static/\(slug.value)", method: .get, headers: [.range: "bytes=0-1"]
            ) { response in
                #expect(response.status == .partialContent)
                #expect(Array(buffer: response.body) == Array(Self.bytes[0...1]))
                // Inclusive end, and the total — both halves of what a player needs to know
                // how much is left.
                #expect(response.headers[.contentRange] == "bytes 0-1/16")
                #expect(response.headers[.acceptRanges] == "bytes")
            }
        }
    }

    /// Every range shape a client actually sends, including the two that cannot be resolved
    /// without knowing the size.
    ///
    /// `bytes=4-` is the one a player sends for "the rest of the file" and the one with no
    /// end to bind: it reaches the store as a range open at the top. `bytes=-4` needs the
    /// total before it means anything at all.
    @Test func everyRangeShapeResolvesToTheRightBytes() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            for (header, expected, contentRange) in [
                ("bytes=0-3", Array(Self.bytes[0...3]), "bytes 0-3/16"),
                ("bytes=4-", Array(Self.bytes[4...]), "bytes 4-15/16"),
                ("bytes=-4", Array(Self.bytes[12...]), "bytes 12-15/16"),
                ("bytes=15-15", Array(Self.bytes[15...15]), "bytes 15-15/16"),
                // Past the end at the top but not at the bottom: a client may ask for more
                // than exists and is answered with what does, rather than refused.
                ("bytes=8-999", Array(Self.bytes[8...]), "bytes 8-15/16"),
            ] as [(String, [UInt8], String)] {
                try await client.execute(
                    uri: "/static/\(slug.value)", method: .get, headers: [.range: header]
                ) { response in
                    #expect(response.status == .partialContent, "\(header)")
                    #expect(Array(buffer: response.body) == expected, "\(header)")
                    #expect(response.headers[.contentRange] == contentRange, "\(header)")
                }
            }
        }
    }

    /// A range starting at or past the end is the one case that earns a `416`, and the
    /// `Content-Range` on it is the bare total — which is how a client that guessed wrong
    /// learns what to ask for.
    @Test func aRangeStartingPastTheEndIs416() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(
                uri: "/static/\(slug.value)", method: .get, headers: [.range: "bytes=16-20"]
            ) { response in
                #expect(response.status == .rangeNotSatisfiable)
                #expect(response.headers[.contentRange] == "bytes */16")
            }
        }
    }

    /// A `Range` this server will not honour is ignored, not refused.
    ///
    /// RFC 9110 §14.2 permits exactly that, and it is the safer half of the permission: a
    /// `416` would deny a client the resource over a header it could simply not have sent.
    /// The multi-range case is here for a second reason — answering it means
    /// `multipart/byteranges`, a whole second body format for a request no media player
    /// makes.
    @Test func aRangeThisServerWillNotHonourFallsBackToTheWholeFile() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            for header in ["bytes=abc-def", "items=0-1", "bytes=5-2", "bytes=0-1,4-5", "bytes="] {
                try await client.execute(
                    uri: "/static/\(slug.value)", method: .get, headers: [.range: header]
                ) { response in
                    #expect(response.status == .ok, "\(header)")
                    #expect(Array(buffer: response.body) == Self.bytes, "\(header)")
                }
            }
        }
    }

    /// A `Range:` header carrying numbers no file could hold is answered, not crashed on.
    ///
    /// These are arithmetic tests wearing HTTP clothes. Every offset here reaches a `+ 1` or
    /// a subtraction on its way to `substring`, Swift traps on overflow rather than wrapping,
    /// and a trap inside a request handler takes the process and every in-flight request with
    /// it — from an unauthenticated `GET` over a header anyone can type. A crash in this test
    /// is a dead test *runner*, not a failed expectation, which is exactly the shape of the
    /// bug being guarded.
    ///
    /// The statuses are asserted as well as the survival, because the safe way to write this
    /// wrong is to refuse everything unusual: a `bytes=0-<huge>` is an ordinary request for
    /// the whole file, and answering it with a `416` would be a client denied a resource over
    /// a header it need not have sent.
    @Test func absurdRangeValuesAreAnsweredRatherThanTrappedOn() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            for (header, expected) in [
                // An end past anything addressable still means "to the end".
                ("bytes=0-\(Int.max)", HTTPResponse.Status.partialContent),
                ("bytes=4-\(Int.max)", .partialContent),
                // A suffix longer than the file is the whole file, per RFC 9110.
                ("bytes=-\(Int.max)", .partialContent),
                // A start past the end is the one case that is genuinely unsatisfiable.
                ("bytes=\(Int.max)-", .rangeNotSatisfiable),
                ("bytes=\(Int.max)-\(Int.max)", .rangeNotSatisfiable),
                ("bytes=\(Int.max - 1)-\(Int.max)", .rangeNotSatisfiable),
                // Digits past `Int` entirely: `Int(_:)` returns nil, so the header is
                // ignored and the whole representation is served.
                ("bytes=0-99999999999999999999999999", .ok),
                ("bytes=99999999999999999999999999-", .ok),
            ] as [(String, HTTPResponse.Status)] {
                try await client.execute(
                    uri: "/static/\(slug.value)", method: .get, headers: [.range: header]
                ) { response in
                    #expect(response.status == expected, "\(header)")
                }
            }
        }
    }

    /// The same header against a slug that does not exist, because the arithmetic runs
    /// before the store is ever asked.
    ///
    /// `resolved` is evaluated as the argument to `fetchBlob`, so the trap this guards did
    /// not need a published attachment to reach it — only a slug shaped like one. A fix that
    /// merely bounded things after the row was loaded would pass every test above and none
    /// of this one.
    @Test func absurdRangeValuesAreSurvivedEvenWithNoSuchPage() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            for header in ["bytes=0-\(Int.max)", "bytes=\(Int.max)-", "bytes=-\(Int.max)"] {
                try await client.execute(
                    uri: "/static/quiet-cedar-otter", method: .get, headers: [.range: header]
                ) { response in
                    #expect(response.status == .notFound, "\(header)")
                }
            }
        }
    }

    /// The ETag is the stored digest, and a matching `If-None-Match` gets a bodyless `304`.
    ///
    /// This is what makes an embedded image free to re-request on every page load: the
    /// bytes are mutable, so the response cannot be cached outright, but revalidating a
    /// video should not re-send it.
    @Test func aMatchingIfNoneMatchIs304() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let etag = try await client.execute(
                uri: "/static/\(slug.value)", method: .get
            ) { response -> String in
                let etag = try #require(response.headers[.eTag])
                #expect(etag == "\"\(PageStore.digest(of: Self.bytes))\"")
                return etag
            }

            try await client.execute(
                uri: "/static/\(slug.value)", method: .get, headers: [.ifNoneMatch: etag]
            ) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
                #expect(response.headers[.eTag] == etag)
            }

            // The weak spelling matches too, which is not pedantry: nginx rewrites a strong
            // ETag into `W/"…"` when it gzips, so exact comparison would re-send the whole
            // file on every conditional request from behind a proxy — invisibly, because a
            // `200` is still a correct answer.
            try await client.execute(
                uri: "/static/\(slug.value)", method: .get, headers: [.ifNoneMatch: "W/\(etag)"]
            ) { response in
                #expect(response.status == .notModified)
            }
        }
    }

    /// Replacing the bytes moves the ETag, which is what stops a revalidating cache serving
    /// the old ones forever.
    @Test func replacingTheBytesMovesTheETag() async throws {
        let (store, slug) = await Self.seeded(contentType: "image/png", filename: "shot.png")
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let before = try await client.execute(
                uri: "/static/\(slug.value)", method: .get
            ) { try #require($0.headers[.eTag]) }

            try await client.execute(
                uri: "/pages/\(slug.value)",
                method: .put,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "image/png",
                ],
                body: ByteBuffer(bytes: [0x99, 0x98, 0x97])
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/static/\(slug.value)", method: .get, headers: [.ifNoneMatch: before]
            ) { response in
                #expect(response.status == .ok)
                #expect(Array(buffer: response.body) == [0x99, 0x98, 0x97])
                #expect(response.headers[.eTag] != before)
            }
        }
    }

    /// An expired attachment stops serving bytes at the same instant it stops being a page.
    ///
    /// The failure this rules out is invisible from a browser: `GET /:slug` starts 404ing on
    /// the deadline while the embed URL keeps streaming, so the page is gone and the video
    /// in it is not.
    @Test func anExpiredAttachmentServesNothing() async throws {
        let (store, slug) = await Self.seeded(expiresAt: Date().addingTimeInterval(-1))
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/static/\(slug.value)", method: .get) { response in
                #expect(response.status == .notFound)
            }
            // Still physically stored, so the 404 came from the deadline rather than from a
            // sweep that had already run.
            #expect(await store.storedSlugs.contains(slug))
        }
    }

    /// Reads stay unauthenticated, like every other read on this server.
    @Test func servingBytesAsksForNoCredential() async throws {
        let (store, slug) = await Self.seeded()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/static/\(slug.value)", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
