import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The 404 surface. The interesting property is not that missing pages 404 — it is that
/// nothing about the response tells a scanner *why*, so walking the namespace is no
/// faster than guessing at it.
@Suite("Not found")
struct NotFoundTests {
    /// Four different reasons to fail — malformed, reserved-but-unrouted, simply absent,
    /// and expired — have to be indistinguishable from outside. The store holds a real page
    /// throughout (asserted with a 200 below, so the seeding can't silently go inert),
    /// which makes "absent" mean absent rather than "the store is empty".
    ///
    /// Expiry is the newest member and the one with the most to leak: a page that once
    /// existed answering differently from one that never did would tell a scanner it had
    /// found a real slug, and hand it the publication history of the namespace for free.
    /// The expired page is seeded and never reclaimed, which is the state a real server sits
    /// in between uploads.
    @Test func all404sAreIdentical() async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "amber-willow-heron"), body: "<h1>here</h1>")
        await store.seed(
            slug: try Slug(custom: "brisk-maple-compass"),
            body: "<h1>expired</h1>",
            expiresAt: Date().addingTimeInterval(-1)
        )

        // Malformed (too short), well-formed but never published, published but past its
        // deadline, and three bare segments whose real endpoints are elsewhere: `/pages`
        // (its responders are POST and the `:slug` child), `/assets` (the stylesheet) and
        // `/admin` (the client routes). Each of those three needs its own GET responder,
        // because the trie matches the literal node and does not backtrack to `/:slug`.
        //
        // `/skill` is deliberately absent, even though this list otherwise mirrors
        // `ServerRoute.names`: it answers with the publish document, not a 404, so it has
        // no uniform-404 responder to compare. Adding it here is the instinctive "fix" and
        // is wrong — `PublishSkillTests.servesTheSkill` is what covers that path.
        let paths = [
            "/x", "/quiet-cedar-otter", "/brisk-maple-compass", "/\(ServerRoute.pages)",
            "/\(ServerRoute.assets)", "/\(ServerRoute.admin)",
        ]
        // Collected inside the test closure and returned out of it: the closure is
        // `@Sendable`, so it cannot mutate a captured local.
        let bodies = try await TestFixture.makeApp(store: store).test(.router) { client -> [[UInt8]] in
            // The seeded page really is servable — otherwise the "absent" case would be
            // vacuously testing an empty store.
            try await client.execute(uri: "/amber-willow-heron", method: .get) { response in
                #expect(response.status == .ok)
            }

            var collected: [[UInt8]] = []
            for path in paths {
                let bytes = try await client.execute(uri: path, method: .get) { response -> [UInt8] in
                    #expect(response.status == .notFound, "\(path)")
                    #expect(response.headers[.contentType] == "text/html; charset=utf-8", "\(path)")
                    return Array(buffer: response.body)
                }
                collected.append(bytes)
            }
            return collected
        }

        #expect(bodies.count == paths.count)
        // Byte-identical, not merely "both a 404 page": any divergence at all is a signal.
        for pair in bodies.indices.dropFirst() {
            #expect(bodies[pair - 1] == bodies[pair], "\(paths[pair - 1]) vs \(paths[pair])")
        }
        // And identical to the page we mean to serve — three copies of some *other*
        // uniform body (the framework default, an empty body) would still be a bug.
        #expect(bodies[0] == Array(notFoundPage().utf8))
    }

    /// `healthz` and `skill` are in `Slug.reserved`, but reservation only keeps them out of
    /// the table — the routes themselves still have to answer, rather than being swallowed
    /// by `/:slug` and turned into the uniform 404 along with everything else.
    @Test func reservedRoutedPathsHitTheirRoutes() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.healthz)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }

            try await client.execute(uri: "/\(ServerRoute.skill)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.body.readableBytes > 0)
            }
        }
    }

    /// The GET responders on `/pages` and `/admin` exist only to keep 404s uniform — they
    /// must not sit behind their group's bearer-token middleware, or an unauthenticated
    /// probe would get a 401 there and a 404 everywhere else, which is the same leak with a
    /// different status code. `/admin` is the one where it would matter most: a 401 on the
    /// bare segment advertises where the credential-minting routes live.
    @Test("a bare routed segment answers 404 without asking for a credential", arguments: [
        ServerRoute.pages, ServerRoute.admin,
    ])
    func bareSegmentsNeedNoAuth(segment: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(segment)", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
