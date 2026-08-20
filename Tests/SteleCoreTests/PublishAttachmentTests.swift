import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for publishing an attachment — a page whose body is bytes.
///
/// The write verbs are the ones that already existed: an attachment is a `POST /pages` with
/// a binary `Content-Type`, and `PUT`, `PATCH` and `DELETE` reach it at its slug exactly as
/// they reach a page. That is the design being defended here as much as any single
/// assertion — a suite that had to test a parallel route family would be evidence the
/// namespace had been split after all.
@Suite("Publishing attachments")
struct PublishAttachmentTests {
    /// A PNG header followed by bytes that are not valid UTF-8 in either direction.
    ///
    /// Deliberately not text. Half of what these tests assert is that the UTF-8 and NUL
    /// checks a page body goes through are *not* applied here, and a payload that happened
    /// to decode would pass those assertions without exercising anything.
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        + [0xFF, 0xFE, 0x00, 0xC0, 0x80, 0x41]

    static func publish(
        client: some TestClientProtocol,
        uri: String = "/pages",
        contentType: String = "image/png",
        bytes: [UInt8] = png
    ) async throws -> String {
        try await client.execute(
            uri: uri,
            method: .post,
            headers: [
                .authorization: "Bearer \(TestFixture.publishToken)",
                .contentType: contentType,
            ],
            body: ByteBuffer(bytes: bytes)
        ) { response in
            #expect(response.status == .created)
            let payload = try TestFixture.writeResponse(response.body)
            return try #require(payload["slug"] as? String)
        }
    }

    /// The bytes arrive intact, the type is stored, and none of the text checks ran.
    ///
    /// Read back through the store rather than over HTTP, because the route that serves
    /// bytes is the next layer. What this pins is that the upload path put the right thing
    /// in the right column — the half a serving test would take for granted.
    @Test func anAttachmentIsStoredAsBytesWithItsType() async throws {
        let store = InMemoryPageStore()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let slug = try await Self.publish(client: client)

            let page = try #require(await store.fetch(slug: Slug(unchecked: slug)))
            #expect(page.contentType == "image/png")
            let attachment = try #require(page.content.attachment)
            #expect(attachment.byteSize == Self.png.count)
            #expect(attachment.digest == PageStore.digest(of: Self.png))
            #expect(attachment.filename == nil)

            let slice = try #require(
                await store.fetchBlob(slug: Slug(unchecked: slug), range: nil)
            )
            #expect(slice.bytes == Self.png)
        }
    }

    /// Every accepted binary type reaches the store as bytes, and is stored under the
    /// canonical spelling rather than the one the caller sent.
    ///
    /// Driven from `allowedAttachments` rather than a list retyped here, so a type added to
    /// that table is covered by this test the moment it is added — and a type added with a
    /// `charset` parameter, which none of these may carry, fails it.
    @Test func everyAllowedAttachmentTypeIsStoredAsBytes() async throws {
        for (sent, stored) in PageContentType.allowedAttachments {
            let store = InMemoryPageStore()
            try await TestFixture.makeApp(store: store).test(.router) { client in
                let slug = try await Self.publish(
                    client: client, contentType: "\(sent); charset=utf-8"
                )
                let page = try #require(await store.fetch(slug: Slug(unchecked: slug)))
                #expect(page.contentType == stored)
                #expect(page.content.attachment != nil)
                #expect(stored.contains("charset") == false)
            }
        }
    }

    /// Bytes that would be refused as a page are stored without complaint as an attachment.
    ///
    /// Both checks in one test on purpose: they are the same claim about the same branch,
    /// and a NUL byte in a PNG is not an edge case but the fourth byte of a great many
    /// real ones.
    @Test func attachmentsSkipTheUTF8AndNULChecks() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            // Byte-for-byte what `ServingAndStoreErrorTests` sends to earn a 400 as a page.
            _ = try await Self.publish(client: client, bytes: [0xFF, 0xFE, 0xFD])
            _ = try await Self.publish(client: client, bytes: [0x61, 0x00, 0x62])
        }
    }

    /// A filename is stored, and it is the caller's rather than the slug's.
    @Test func anAttachmentRemembersTheFilenameItArrivedWith() async throws {
        let store = InMemoryPageStore()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let slug = try await Self.publish(
                client: client, uri: "/pages?filename=evidence%20clip.mp4",
                contentType: "video/mp4"
            )
            let page = try #require(await store.fetch(slug: Slug(unchecked: slug)))
            #expect(page.content.attachment?.filename == "evidence clip.mp4")
        }
    }

    /// The characters that would let a filename escape the header it ends up in are
    /// refused, one message each, before anything is stored.
    ///
    /// `Content-Disposition` is a structured header, so a quote closes the quoted string
    /// early and a CR or LF ends the header outright. This is the one caller-supplied
    /// string in the server that reaches a response header, and it gets the treatment
    /// `Slug(custom:)` gives the one that reaches a path.
    @Test func aFilenameThatCouldBreakAHeaderIsRefused() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            for raw in ["a%22b.png", "a%5Cb.png", "../secret.png", "a%0D%0Ab.png", "a%00b.png", ""] {
                try await client.execute(
                    uri: "/pages?filename=\(raw)",
                    method: .post,
                    headers: [
                        .authorization: "Bearer \(TestFixture.publishToken)",
                        .contentType: "image/png",
                    ],
                    body: ByteBuffer(bytes: Self.png)
                ) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }
    }

    /// Asking for a filename on a text page is a `400`, not a silently dropped parameter.
    ///
    /// The same reading `PUT`'s refusal of `?ttl=` gets, and for the same reason: a caller
    /// who sent it believes the page will download under that name, and a `201` would be
    /// the server agreeing.
    @Test func aFilenameOnATextPageIsRefusedRatherThanIgnored() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/pages?filename=page.html",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .badRequest)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains(filenameQueryParameter))
            }
        }
    }

    /// The two limits are separate, and each applies to its own kind.
    ///
    /// The interesting half is the first: bytes well past `maxPageBytes` publish happily as
    /// an attachment, which is what says the limits did not get crossed over. A single
    /// shared limit would pass a test that only checked the refusal.
    @Test func theAttachmentLimitIsItsOwnAndAppliesToBytesOnly() async throws {
        let environment = [
            "STELE_MAX_PAGE_BYTES": "64",
            "STELE_MAX_ATTACHMENT_BYTES": "4096",
        ]
        try await TestFixture.makeApp(environment: environment).test(.router) { client in
            _ = try await Self.publish(
                client: client, bytes: [UInt8](repeating: 0xAB, count: 1024)
            )

            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "image/png",
                ],
                body: ByteBuffer(bytes: [UInt8](repeating: 0xAB, count: 8192))
            ) { response in
                #expect(response.status == .contentTooLarge)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains("4096"))
                // Named as an attachment, not as a page. The two limits are different
                // numbers, so a caller told the wrong one goes looking for the wrong knob.
                #expect(message.lowercased().contains("attachment"))
            }
        }
    }

    /// A `PUT` replaces an attachment's bytes at the same slug, which is what keeps an
    /// embed URL pointing at something after the evidence is re-recorded.
    @Test func replacingAnAttachmentKeepsItsAddress() async throws {
        let store = InMemoryPageStore()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let slug = try await Self.publish(client: client)
            let replacement: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0x11, 0x22]

            try await client.execute(
                uri: "/pages/\(slug)",
                method: .put,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "image/png",
                ],
                body: ByteBuffer(bytes: replacement)
            ) { response in
                #expect(response.status == .ok)
            }

            let slice = try #require(
                await store.fetchBlob(slug: Slug(unchecked: slug), range: nil)
            )
            #expect(slice.bytes == replacement)
        }
    }

    /// Replacing across kinds re-types the page rather than leaving the old type on the new
    /// bytes.
    ///
    /// The failure this rules out is quiet: with a plain `COALESCE` the page becomes text
    /// and keeps `image/png`, so HTML is served under an image type behind a `200`.
    /// `nosniff` stops that being dangerous and nothing stops it being wrong, and the
    /// caller — who sent no `Content-Type`, which is how the case arises at all — has no
    /// signal.
    @Test func replacingAnAttachmentWithATypelessTextBodyRetypesThePage() async throws {
        let store = InMemoryPageStore()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let slug = try await Self.publish(client: client)

            try await client.execute(
                uri: "/pages/\(slug)",
                method: .put,
                headers: [.authorization: "Bearer \(TestFixture.publishToken)"],
                body: ByteBuffer(string: "<h1>now a page</h1>")
            ) { response in
                #expect(response.status == .ok)
            }

            let page = try #require(await store.fetch(slug: Slug(unchecked: slug)))
            #expect(page.content.text == "<h1>now a page</h1>")
            #expect(page.contentType == PageContentType.default)
            #expect(try await store.fetchBlob(slug: Slug(unchecked: slug), range: nil) == nil)
        }
    }

    /// A replacement of like with like still preserves the stored type, which is the half
    /// the CASE above must not have broken.
    @Test func replacingATextPageWithoutATypeStillPreservesTheStoredOne() async throws {
        let store = InMemoryPageStore()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let slug = Slug(unchecked: "amber-willow-heron")
            await store.seed(slug: slug, body: "body { color: red }", contentType: "text/css; charset=utf-8")

            try await client.execute(
                uri: "/pages/\(slug.value)",
                method: .put,
                headers: [.authorization: "Bearer \(TestFixture.publishToken)"],
                body: ByteBuffer(string: "body { color: blue }")
            ) { response in
                #expect(response.status == .ok)
            }

            #expect(try await store.fetch(slug: slug)?.contentType == "text/css; charset=utf-8")
        }
    }

    /// An attachment renames, retimes and deletes through the verbs that already existed.
    ///
    /// This is the payoff of keeping one namespace, so it is asserted rather than assumed:
    /// none of these three routes learned what an attachment is, and all three work on one.
    @Test func theExistingVerbsReachAnAttachment() async throws {
        let store = InMemoryPageStore()
        try await TestFixture.makeApp(store: store).test(.router) { client in
            let slug = try await Self.publish(client: client)

            try await client.execute(
                uri: "/pages/\(slug)?slug=moved-cedar-otter&ttl=never",
                method: .patch,
                headers: [.authorization: "Bearer \(TestFixture.publishToken)"]
            ) { response in
                #expect(response.status == .ok)
            }

            // The bytes followed the rename, which in Postgres is the foreign key's
            // ON UPDATE CASCADE and here is the fake imitating it.
            let moved = Slug(unchecked: "moved-cedar-otter")
            #expect(try await store.fetchBlob(slug: moved, range: nil)?.bytes == Self.png)
            #expect(try await store.fetch(slug: moved)?.expiresAt == nil)

            try await client.execute(
                uri: "/pages/moved-cedar-otter",
                method: .delete,
                headers: [.authorization: "Bearer \(TestFixture.publishToken)"]
            ) { response in
                #expect(response.status == .noContent)
            }
            #expect(try await store.fetchBlob(slug: moved, range: nil) == nil)
            #expect(await store.storedSlugs.isEmpty)
        }
    }
}
