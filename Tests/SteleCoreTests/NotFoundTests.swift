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
        // deadline, and five bare segments whose real endpoints are elsewhere: `/pages`
        // (its responders are POST and the `:slug` child), `/assets` (the stylesheet),
        // `/admin` (the client routes), `/auth` (the two GitHub sign-in routes, two segments
        // further down) and `/static` (attachment bytes, one segment down). Each of those
        // five needs its own GET responder, because the trie matches the literal node and
        // does not backtrack to `/:slug`.
        //
        // `/skill` and `/favicon.ico` are deliberately absent, even though this list
        // otherwise mirrors `ServerRoute.names`: each answers with its own content, not a
        // 404, so neither has a uniform-404 responder to compare. Adding either is the
        // instinctive "fix" and is wrong — `PublishSkillTests.servesTheSkill` and
        // `FaviconTests.theRootPathIsAnEndpointRatherThanA404` cover those paths.
        let paths = [
            "/x", "/quiet-cedar-otter", "/brisk-maple-compass", "/\(ServerRoute.pages)",
            "/\(ServerRoute.assets)", "/\(ServerRoute.admin)", "/\(ServerRoute.auth)",
            "/\(ServerRoute.staticFiles)",
            // A slug under `/static` that is a *text* page, which is a miss on this path
            // for the same reason an absent one is: it names no bytes. It answers the same
            // page as the rest, so a scanner cannot use this route to learn which slugs
            // exist as pages either.
            "/\(ServerRoute.staticFiles)/amber-willow-heron",
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

    /// The GET responders on `/pages`, `/admin` and `/auth` exist only to keep 404s uniform
    /// — they must not sit behind a group's bearer-token middleware, or an unauthenticated
    /// probe would get a 401 there and a 404 everywhere else, which is the same leak with a
    /// different status code. `/admin` is the one where it would matter most: a 401 on the
    /// bare segment advertises where the credential-minting routes live. `/auth` is in no
    /// group at all — the route beneath it is the authentication — so its stub is the case
    /// where the mistake would be *adding* a guard rather than inheriting one.
    @Test("a bare routed segment answers 404 without asking for a credential", arguments: [
        ServerRoute.pages, ServerRoute.admin, ServerRoute.auth,
    ])
    func bareSegmentsNeedNoAuth(segment: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(segment)", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    /// The same leak one segment deeper. Every write verb hangs a parameter node under the
    /// literal `pages`, and an unauthenticated `GET /pages/<anything>` must not answer 401:
    /// a status reachable only under `pages` tells a scanner it has found the write
    /// namespace, which is the read surface's uniformity defeated by a status code rather
    /// than by a body. It answers 404 — the framework's plain envelope rather than the
    /// uniform page, which is fine here, because a two-segment path can never be a slug and
    /// only the status is signal.
    ///
    /// This lives here rather than in the suite for any one verb because it is a property
    /// of the node, not of POST, PUT or DELETE: it was asserted identically in two write
    /// suites until DELETE would have made it three, and a copy per verb is a count that
    /// grows while the property stays one.
    @Test func noAuthLeaksUnderPages() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.pages)/foo", method: .get) { response in
                #expect(response.status != .unauthorized)
                #expect(response.status == .notFound)
            }
        }
    }

    /// The same property under `/auth`, two and three segments down, and the reason neither
    /// depth gets a uniform-404 stub of its own.
    ///
    /// The stub exists on `/auth` because that segment is ambiguous with `/:slug` — the trie
    /// matches the literal node and does not backtrack, so without a responder a scanner
    /// would get the framework's plain-text envelope there and the uniform page everywhere
    /// else. Nothing deeper is ambiguous with anything: a two- or three-segment path can
    /// never be a slug, so the envelope carries no signal a scanner could use. What *would*
    /// be signal is a `401` or a `426`, which is what registering either sign-in route inside
    /// a group would produce — a status reachable only under `/auth/github` says "something
    /// lives here", which is the leak the bare stub exists to prevent, arriving one segment
    /// deeper.
    ///
    /// Both are `POST`-only, so a `GET` is a miss on the method rather than on the path; the
    /// assertion is deliberately about what the status is *not*.
    @Test(
        "no auth leaks under the sign-in routes",
        arguments: [
            "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)",
            "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)/\(ServerRoute.authDevice)",
            "/\(ServerRoute.auth)/\(ServerRoute.authGitHub)/\(ServerRoute.authExchange)",
        ]
    )
    func noAuthLeaksUnderTheSignInRoutes(path: String) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: path, method: .get) { response in
                #expect(response.status != .unauthorized, "\(path)")
                #expect(response.status != .upgradeRequired, "\(path)")
                #expect(response.status != .ok, "\(path)")
            }
        }
    }
}
