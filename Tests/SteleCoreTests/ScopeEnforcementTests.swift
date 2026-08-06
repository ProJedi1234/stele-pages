import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// What a valid credential is *allowed* to do, as distinct from whether it is valid at all.
///
/// The status code is the whole subject. Every case here presents a credential the server
/// accepts, so 401 would be a lie — and a costly one, because it would send an operator to
/// rotate a token that is working exactly as issued instead of to widen its scopes.
@Suite("Scope enforcement")
struct ScopeEnforcementTests {
    private static let page = ByteBuffer(string: "<h1>hi</h1>")

    private static func write(
        _ client: some TestClientProtocol,
        token: String,
        uri: String = "/\(ServerRoute.pages)",
        method: HTTPRequest.Method = .post
    ) async throws -> (status: HTTPResponse.Status, body: ByteBuffer) {
        try await client.execute(
            uri: uri,
            method: method,
            headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
            body: page
        ) { ($0.status, $0.body) }
    }

    /// The demotion, asserted on the route it changes. `STELE_UPLOAD_TOKEN` authenticates
    /// fine — it resolves to `Client.sharedToken` — and is refused anyway, because it
    /// carries `admin` and nothing else. This is the behaviour every deployed agent hits
    /// the moment this ships, so it should fail here first if it is ever reverted by
    /// accident.
    /// `DELETE` is in the list because it is the write whose refusal matters most: the
    /// shared token is the one credential an operator still types by hand, and the route it
    /// would reach past this gate is the only one that destroys a page.
    @Test("the admin-only shared token cannot publish", arguments: [
        ("/\(ServerRoute.pages)", HTTPRequest.Method.post),
        ("/\(ServerRoute.pages)/quiet-cedar-otter", HTTPRequest.Method.put),
        ("/\(ServerRoute.pages)/quiet-cedar-otter", HTTPRequest.Method.delete),
        ("/\(ServerRoute.pages)/quiet-cedar-otter?slug=renamed", HTTPRequest.Method.patch),
    ])
    func sharedTokenIsForbiddenOnWrites(uri: String, method: HTTPRequest.Method) async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "quiet-cedar-otter"), body: "<h1>original</h1>")

        try await TestFixture.makeApp(store: store).test(.router) { client in
            let response = try await Self.write(
                client, token: TestFixture.token, uri: uri, method: method
            )
            #expect(response.status == .forbidden)
            let message = try TestFixture.errorMessage(response.body)
            #expect(message.contains(ClientScope.publish.rawValue))
            #expect(message.contains(ClientScope.admin.rawValue))
        }

        // And it really was refused rather than half-applied: the seeded page is untouched.
        try await TestFixture.makeApp(store: store).test(.router) { client in
            try await client.execute(uri: "/quiet-cedar-otter", method: .get) { response in
                #expect(String(buffer: response.body) == "<h1>original</h1>")
            }
        }
    }

    /// The positive half of the same gate, and the half a mistake would break silently: a
    /// `publish` credential — the only kind an agent ever holds — is waved through on every
    /// write verb. A scope check that refused everything would pass every negative test in
    /// this file, so the accept path is worth pinning next to them rather than leaving it
    /// implied by the suites that happen to publish.
    @Test func aPublishOnlyCredentialIsAcceptedOnEveryWriteRoute() async throws {
        let store = InMemoryPageStore()
        await store.seed(slug: try Slug(custom: "quiet-cedar-otter"), body: "<h1>original</h1>")
        let clients = InMemoryClientStore(
            holding: TestFixture.publishToken, named: "claude-code", scopes: [.publish]
        )

        try await TestFixture.makeApp(store: store, clients: clients).test(.router) { client in
            let created = try await Self.write(client, token: TestFixture.publishToken)
            #expect(created.status == .created)

            let replaced = try await Self.write(
                client,
                token: TestFixture.publishToken,
                uri: "/\(ServerRoute.pages)/quiet-cedar-otter",
                method: .put
            )
            #expect(replaced.status == .ok)

            // And the write really landed, rather than a 200 over an untouched row.
            try await client.execute(uri: "/quiet-cedar-otter", method: .get) { response in
                #expect(String(buffer: response.body) == "<h1>hi</h1>")
            }

            // Last, because it takes the page away: the same credential is let through the
            // gate on the destructive verb too.
            let removed = try await Self.write(
                client,
                token: TestFixture.publishToken,
                uri: "/\(ServerRoute.pages)/quiet-cedar-otter",
                method: .delete
            )
            #expect(removed.status == .noContent)
        }
    }

    /// The mirror image, on a *stored* credential rather than on the synthesised
    /// `Client.sharedToken`: an `admin`-only row is refused on the write routes and accepted
    /// on the admin ones. The shared token takes the same pair of answers above, and it
    /// would keep taking them if the scope check only ever consulted `Client.sharedToken` —
    /// which is exactly the shortcut this rules out.
    @Test func anAdminOnlyStoredCredentialGetsTheOppositeAnswers() async throws {
        let clients = InMemoryClientStore(
            holding: "stele_pat_operator", named: "operator", scopes: [.admin]
        )

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            let published = try await Self.write(client, token: "stele_pat_operator")
            #expect(published.status == .forbidden)
            #expect(
                try TestFixture.errorMessage(published.body)
                    .contains(ClientScope.publish.rawValue)
            )

            try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .get,
                headers: [.authorization: "Bearer stele_pat_operator"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// The other direction, and the one the whole scheme exists for: a leaked agent
    /// credential cannot mint itself a second one. Without this, revoking the leaked token
    /// would achieve nothing, because the attacker would already be holding a different one.
    @Test("a publish-only credential cannot reach the admin routes", arguments: [
        ("/\(ServerRoute.admin)/\(ServerRoute.adminClients)", HTTPRequest.Method.post),
        ("/\(ServerRoute.admin)/\(ServerRoute.adminClients)", HTTPRequest.Method.get),
        ("/\(ServerRoute.admin)/\(ServerRoute.adminClients)/someone", HTTPRequest.Method.delete),
    ])
    func publishScopeIsForbiddenOnAdminRoutes(
        uri: String, method: HTTPRequest.Method
    ) async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: uri,
                method: method,
                headers: [
                    .authorization: "Bearer \(TestFixture.publishToken)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"name":"stolen"}"#)
            ) { response in
                #expect(response.status == .forbidden)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains(ClientScope.admin.rawValue))
            }
        }
    }

    /// 403 and 401 are two different instructions to whoever reads them, so the boundary
    /// between them is worth pinning directly: a bad credential is 401 even on a route the
    /// caller would not have been permitted to use anyway. Authentication answers first.
    @Test func anInvalidCredentialIs401EvenOnAnAdminRoute() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .get,
                headers: [.authorization: "Bearer stele_pat_never_issued"]
            ) { response in
                #expect(response.status == .unauthorized)
            }

            try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .get
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body).contains("Missing Authorization header"))
            }
        }
    }

    /// A credential carrying both scopes is refused by neither gate. Nothing in the design
    /// says the two are exclusive — the shared token is `admin`-only because that is what
    /// it is *for*, not because holding both is illegal — and a check written as "has
    /// exactly this scope" would pass every other test in this file.
    @Test func bothScopesOnOneCredentialSatisfyBothGates() async throws {
        let clients = InMemoryClientStore(
            holding: "stele_pat_operator", named: "operator", scopes: [.publish, .admin]
        )

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            let published = try await Self.write(client, token: "stele_pat_operator")
            #expect(published.status == .created)

            try await client.execute(
                uri: "/\(ServerRoute.admin)/\(ServerRoute.adminClients)",
                method: .get,
                headers: [.authorization: "Bearer stele_pat_operator"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    /// The middleware reads what the authenticating one wrote and nothing else, so a scope
    /// check with no credential in front of it must fail closed rather than wave the
    /// request through on a nil. Only reachable by misordering middleware, which is exactly
    /// why it is worth a test — the mistake compiles.
    @Test func aScopeCheckWithNoAuthenticationFailsClosed() async throws {
        let router = Router(context: SteleRequestContext.self)
        router.group("probe")
            .add(middleware: RequireScopeMiddleware(.admin))
            .get("") { _, _ -> String in "reached" }

        try await Application(router: router).test(.router) { client in
            try await client.execute(uri: "/probe", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(String(buffer: response.body) != "reached")
            }
        }
    }
}
