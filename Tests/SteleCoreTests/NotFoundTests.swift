import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// The 404 surface. The interesting property is not that missing pages 404 — it is that
/// nothing about the response tells a scanner *why*, so walking the namespace is no
/// faster than guessing at it.
@Suite("Not found")
struct NotFoundTests {
    /// Three different reasons to fail — malformed, reserved-but-unrouted, and simply
    /// absent — have to be indistinguishable from outside. The store holds a real page
    /// throughout (asserted with a 200 below, so the seeding can't silently go inert),
    /// which makes "absent" mean absent rather than "the store is empty".
    @Test func all404sAreIdentical() async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "amber-willow-heron"), body: "<h1>here</h1>")

        // Malformed (too short), reserved but with no GET route, well-formed but never
        // published, a routed path whose only responder is POST, and the bare parent of
        // the stylesheet — `/pages` and `/assets` each need their own GET responder
        // because the trie matches the literal node without backtracking to `/:slug`.
        let paths = [
            "/x", "/admin", "/quiet-cedar-otter", "/\(ServerRoute.pages)",
            "/\(ServerRoute.assets)",
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

    /// `healthz` is in `Slug.reserved`, but reservation only keeps it out of the table —
    /// the route itself still has to answer, rather than being swallowed by `/:slug`.
    @Test func reservedRoutedPathsHitTheirRoutes() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.healthz)", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "ok")
            }
        }
    }

    /// The GET responder on `/pages` exists only to keep 404s uniform — it must not sit
    /// behind the upload group's bearer-token middleware, or an unauthenticated probe
    /// would get a 401 there and a 404 everywhere else, which is the same leak with a
    /// different status code.
    @Test func getPagesNeedsNoAuth() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.pages)", method: .get) { response in
                #expect(response.status == .notFound)
            }
        }
    }
}
