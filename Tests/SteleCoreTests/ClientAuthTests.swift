import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for authenticating a *per-client* credential, alongside the shared
/// token `UploadAuthTests` covers.
///
/// Two shapes of application appear here. The write routes run through the real
/// `TestFixture.makeApp`, because 201-versus-401 is the behaviour a caller actually sees.
/// The attribution tests build a one-route probe router instead: `context.client` is not
/// observable from any route this server serves yet, and a probe that mounts the real
/// middleware is a smaller lie than a temporary endpoint that echoes a credential.
@Suite("Per-client authentication")
struct ClientAuthTests {
    /// A router with nothing on it but the middleware under test and a route that reports
    /// what the middleware put on the context.
    private func probeApp(
        clients: some ClientStoring,
        sharedToken: String = TestFixture.token
    ) -> Application<RouterResponder<SteleRequestContext>> {
        let router = Router(context: SteleRequestContext.self)
        router.group("probe")
            .add(middleware: BearerTokenMiddleware(clients: clients, sharedToken: sharedToken))
            .get("") { _, context -> String in
                guard let client = context.client else { return "none" }
                return "\(client.name):\(client.scopes.joined(separator: ","))"
            }
        return Application(router: router)
    }

    private func get(
        _ app: Application<RouterResponder<SteleRequestContext>>,
        token: String
    ) async throws -> (status: HTTPResponse.Status, body: String) {
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/probe",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { ($0.status, String(buffer: $0.body)) }
        }
    }

    @Test func aClientTokenIsResolvedOntoTheContext() async throws {
        let clients = InMemoryClientStore()
        await clients.seed(token: "stele_pat_agent", name: "claude-code", scopes: [.publish])

        let response = try await get(probeApp(clients: clients), token: "stele_pat_agent")
        #expect(response.status == .ok)
        #expect(response.body == "claude-code:publish")
    }

    /// The legacy path, which every deployed agent is still on. It resolves to a
    /// credential like any other so nothing downstream has to ask which door a request
    /// came through — and that credential is `admin`, because the shared token is becoming
    /// the operator's root credential rather than staying an agent's.
    @Test func theSharedTokenResolvesToTheSynthesisedAdminCredential() async throws {
        let clients = InMemoryClientStore()

        let response = try await get(probeApp(clients: clients), token: TestFixture.token)
        #expect(response.status == .ok)
        #expect(response.body == "shared-upload-token:admin")
        #expect(Client.sharedToken.has(.admin))
        // 0 is not a value `bigserial` issues, so this credential can never be mistaken
        // for a row — nothing may write it to `pages.client_id`.
        #expect(Client.sharedToken.id == 0)
    }

    /// A successful per-client request stamps `last_used_at`; the shared token has no row
    /// to stamp and must not pretend otherwise.
    @Test func onlyAStoredCredentialRecordsAUse() async throws {
        let clients = InMemoryClientStore()
        let seeded = await clients.seed(token: "stele_pat_agent")

        _ = try await get(probeApp(clients: clients), token: "stele_pat_agent")
        #expect(await clients.recordedUses == [seeded.id])

        _ = try await get(probeApp(clients: clients), token: TestFixture.token)
        #expect(await clients.recordedUses == [seeded.id])
    }

    /// The stamp is bookkeeping on an already-authorised request. A store that cannot
    /// write it must not be able to turn a valid credential into a 401.
    @Test func aFailedUseStampDoesNotFailTheRequest() async throws {
        let response = try await get(
            probeApp(clients: UnwritableClientStore()),
            token: "stele_pat_agent"
        )
        #expect(response.status == .ok)
        #expect(response.body == "unwritable:publish")
    }

    /// The property this whole design rests on: unknown, revoked and expired credentials
    /// are one answer, byte for byte. A caller probing for valid tokens is not behind the
    /// token, so learning that a token *used to* work would tell them their guess was
    /// structurally right.
    ///
    /// The comparison is whole-response — status, every header, and the body bytes —
    /// rather than three separate "is it a 401?" checks, because a shared status is the
    /// part that was never in doubt. What would actually leak is a `content-length` two
    /// bytes apart, a header one branch sets and another does not, or a message that names
    /// the credential state; each of those is invisible to a status-only assertion and each
    /// hands a scanner the same distinction the 401 was meant to withhold.
    @Test func unknownRevokedAndExpiredAreOneIdentical401() async throws {
        let clients = InMemoryClientStore()
        await clients.seed(token: "stele_pat_revoked", name: "revoked", revokedAt: Date())
        await clients.seed(
            token: "stele_pat_expired",
            name: "expired",
            expiresAt: Date().addingTimeInterval(-60)
        )

        let tokens = ["stele_pat_unknown", "stele_pat_revoked", "stele_pat_expired"]
        // Collected inside the closure and returned out of it: the closure is `@Sendable`
        // and cannot mutate a captured local.
        let rejections = try await TestFixture.makeApp(clients: clients)
            .test(.router) { client -> [Rejection] in
                var collected: [Rejection] = []
                for token in tokens {
                    let rejection = try await client.execute(
                        uri: "/\(ServerRoute.pages)",
                        method: .post,
                        headers: [
                            .authorization: "Bearer \(token)",
                            .contentType: "text/html",
                        ],
                        body: ByteBuffer(string: "<h1>hi</h1>")
                    ) { Rejection($0) }
                    collected.append(rejection)
                }
                return collected
            }

        #expect(rejections.count == tokens.count)
        for (token, rejection) in zip(tokens, rejections) {
            #expect(rejection.status == .unauthorized, "\(token)")
        }
        for index in rejections.indices.dropFirst() {
            #expect(
                rejections[index - 1] == rejections[index],
                "\(tokens[index - 1]) vs \(tokens[index])"
            )
        }
        let first = try #require(rejections.first)
        // Not three copies of some *other* uniform answer: a middleware that threw the same
        // 500 for all three would satisfy every comparison above.
        #expect(String(decoding: first.body, as: UTF8.self).contains("Invalid upload token"))
        // And the header half of the comparison is not vacuous. If these responses ever
        // carried no headers at all, "identical headers" would stay true for free — and
        // would go on being true after someone added a distinguishing one.
        #expect(!first.headers.isEmpty)
    }

    /// End to end on the route that matters: a stored credential publishes exactly as the
    /// shared token does, and gets stamped for it.
    @Test func aClientTokenCanPublish() async throws {
        let clients = InMemoryClientStore()
        let seeded = await clients.seed(token: "stele_pat_agent", name: "claude-code")

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            try await client.execute(
                uri: "/pages",
                method: .post,
                headers: [
                    .authorization: "Bearer stele_pat_agent",
                    .contentType: "text/html",
                ],
                body: ByteBuffer(string: "<h1>hi</h1>")
            ) { response in
                #expect(response.status == .created)
            }
        }
        #expect(await clients.recordedUses == [seeded.id])
    }
}

/// Everything a caller probing for valid credentials can observe about a refusal, reduced
/// to something `==` can compare in one go.
///
/// Deliberately the *whole* response rather than a chosen subset: the point of the type is
/// that a future header — a `WWW-Authenticate` that names the failure, a `Retry-After` on
/// one branch only — is included in the comparison without anyone remembering to add it.
/// Headers are canonicalised and sorted because their order is not part of the message and
/// nothing observable depends on it.
private struct Rejection: Equatable, Sendable {
    let status: HTTPResponse.Status
    let headers: [String]
    let body: [UInt8]

    init(_ response: TestResponse) {
        self.status = response.status
        self.headers = response.headers
            .map { "\($0.name.canonicalName): \($0.value)" }
            .sorted()
        self.body = Array(buffer: response.body)
    }
}

/// A store that authenticates fine and cannot record a use — the shape of a database that
/// is up for reads and refusing writes.
private struct UnwritableClientStore: ClientStoring {
    struct WriteRefused: Error {}

    func client(forTokenHash hash: [UInt8]) async throws -> Client? {
        guard hash == ClientCredential.hash("stele_pat_agent") else { return nil }
        return Client(
            id: 7,
            name: "unwritable",
            scopes: [ClientScope.publish.rawValue],
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func recordUse(clientID: Int64) async throws {
        throw WriteRefused()
    }

    /// Refused too, for the same reason: this store is standing in for a database that is
    /// up for reads and rejecting writes. Nothing in this suite reaches the admin routes,
    /// so a store that could mint here would only be pretending.
    func insert(
        name: String, tokenHash: [UInt8], scopes: [String], expiresAt: Date?
    ) async throws -> Client? {
        throw WriteRefused()
    }

    func allClients() async throws -> [Client] { [] }

    func revoke(name: String) async throws -> Client? {
        throw WriteRefused()
    }
}
