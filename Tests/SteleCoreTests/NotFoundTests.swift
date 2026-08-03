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

        // Malformed (too short), reserved but with no GET route, and well-formed but
        // never published.
        let paths = ["/x", "/admin", "/quiet-cedar-otter"]
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
        #expect(bodies[0] == bodies[1])
        #expect(bodies[1] == bodies[2])
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

    /// KNOWN INVARIANT EXCEPTION — documenting current behaviour, not endorsing it.
    ///
    /// `/pages` has a POST responder, so Hummingbird's trie matches the literal `pages`
    /// node and stops; it does not backtrack to `/:slug`. The result is the framework's
    /// own 404 rather than `notFoundPage()`, which makes `GET /pages` distinguishable
    /// from every other 404 — the one crack in the uniformity above. Flagged for a
    /// decision in the PR; routing is deliberately left alone in this change.
    @Test func getPagesReturnsFrameworkDefault404() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.pages)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body) != notFoundPage())
            }
        }
    }
}
