import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// `GET /admin/whoami` — the route that answers "which credential am I holding?".
///
/// The property this suite exists for is the placement, not the payload: the route sits
/// under `/admin` but outside the `admin`-scoped group, because the caller that runs it most
/// is a publish-only agent. `stele auth status` is the first command the skill tells an agent
/// to run and `stele auth login` checks a credential here before writing it to disk, so a
/// `403` from this path would break the bootstrap for every credential the server is built to
/// issue. `aPublishOnlyCredentialIsAnsweredHereAndStillRefusedOnTheAdminRoutes` is that
/// assertion, and it holds both halves in one test on purpose: the answer only means anything
/// alongside the refusal that proves the scope gate is still there.
@Suite("Whoami")
struct WhoamiTests {
    static let uri = "/\(ServerRoute.admin)/\(ServerRoute.adminWhoami)"
    static let clients = "/\(ServerRoute.admin)/\(ServerRoute.adminClients)"

    static func whoami(
        _ client: some TestClientProtocol,
        token: String?
    ) async throws -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        var headers: HTTPFields = [:]
        if let token { headers[.authorization] = "Bearer \(token)" }
        return try await client.execute(uri: uri, method: .get, headers: headers) { response in
            let raw = String(buffer: response.body)
            let json = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                as? [String: Any] ?? [:]
            return (response.status, raw, json)
        }
    }

    /// The whole reason the route is registered in its own group. A credential carrying
    /// `publish` and nothing else — which is every agent credential — is answered here and
    /// refused one path along, and both facts are asserted against the same running app so
    /// neither can be true only in isolation.
    @Test func aPublishOnlyCredentialIsAnsweredHereAndStillRefusedOnTheAdminRoutes() async throws {
        let clients = InMemoryClientStore()
        let credential = await clients.seed(
            token: TestFixture.publishToken, name: "claude-code", scopes: [.publish]
        )

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            let identified = try await Self.whoami(client, token: TestFixture.publishToken)
            #expect(identified.status == .ok)
            #expect(identified.json["name"] as? String == credential.name)
            #expect(identified.json["scopes"] as? [String] == [ClientScope.publish.rawValue])
            #expect(identified.json["createdAt"] is String)

            try await client.execute(
                uri: Self.clients,
                method: .get,
                headers: [.authorization: "Bearer \(TestFixture.publishToken)"]
            ) { response in
                #expect(response.status == .forbidden)
                let message = try TestFixture.errorMessage(response.body)
                #expect(message.contains(ClientScope.admin.rawValue))
            }
        }
    }

    /// The route reports a credential, so the one thing it must never report is the secret
    /// that addresses it. Asserted on the bytes rather than a decoded shape, exactly as
    /// `AdminClientsTests.theListingNeverCarriesATokenOrADigest` is: a key added by a future
    /// `Encodable` conformance would slip past a field-by-field check.
    @Test func theAnswerNeverCarriesATokenOrADigest() async throws {
        let clients = InMemoryClientStore()
        await clients.seed(token: TestFixture.publishToken, name: "claude-code")

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            let identified = try await Self.whoami(client, token: TestFixture.publishToken)
            #expect(identified.status == .ok)
            #expect(!identified.raw.contains(TestFixture.publishToken))
            #expect(!identified.raw.lowercased().contains("token"))
            #expect(!identified.raw.lowercased().contains("hash"))
        }
    }

    /// Expiry is half of what the caller came for: "this works" and "until when" are one
    /// answer, and a `stele auth status` that could not say the second would let a credential
    /// lapse silently.
    @Test func theAnswerReportsExpiryAndRevocation() async throws {
        let clients = InMemoryClientStore()
        let expiry = Date().addingTimeInterval(3_600)
        await clients.seed(token: TestFixture.publishToken, name: "temporary", expiresAt: expiry)

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            let identified = try await Self.whoami(client, token: TestFixture.publishToken)
            #expect(identified.status == .ok)
            let reported = try #require(identified.json["expiresAt"] as? String)
            let parsed = try #require(ISO8601DateFormatter().date(from: reported))
            #expect(abs(parsed.timeIntervalSince(expiry)) < 2)
            // A usable credential is not revoked, and nothing may invent a timestamp for it.
            #expect(identified.json["revokedAt"] == nil)
        }
    }

    /// The shared token authenticates like anything else and is reported as what it is — the
    /// synthesised `admin` credential — rather than special-cased into an error. It is the
    /// operator's own token, and "which credential is this shell holding?" is a question they
    /// ask too.
    @Test func theSharedTokenIsReportedAsTheSynthesisedCredential() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            let identified = try await Self.whoami(client, token: TestFixture.token)
            #expect(identified.status == .ok)
            #expect(identified.json["name"] as? String == Client.sharedToken.name)
            #expect(identified.json["scopes"] as? [String] == [ClientScope.admin.rawValue])
        }
    }

    /// A credential the server will not accept gets the same `401` here as anywhere else,
    /// including the one that used to work. This is the answer `stele auth login` depends on
    /// to refuse to store a dead credential, and `stele auth status` to report one.
    @Test func rejectedCredentialsAre401() async throws {
        let clients = InMemoryClientStore()
        await clients.seed(token: "stele_pat_revoked", name: "revoked", revokedAt: Date())
        await clients.seed(
            token: "stele_pat_expired",
            name: "expired",
            expiresAt: Date(timeIntervalSince1970: 1)
        )

        try await TestFixture.makeApp(clients: clients).test(.router) { client in
            for token in ["stele_pat_revoked", "stele_pat_expired", "stele_pat_never_issued"] {
                let identified = try await Self.whoami(client, token: token)
                #expect(identified.status == .unauthorized, "\(token)")
                // The four rejection reasons stay indistinguishable: this caller is not
                // behind the token, so "that credential existed once" is not theirs to learn.
                #expect(identified.raw.contains("Invalid upload token"), "\(token)")
            }

            let anonymous = try await Self.whoami(client, token: nil)
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.raw.contains("Missing Authorization header"))
        }
    }

    /// The route is a real endpoint under a segment whose bare form answers the uniform 404,
    /// so both have to keep behaving as themselves: `/admin` must not start advertising that
    /// something lives beneath it, and `/admin/whoami` must not be swallowed by the stub.
    /// `NotFoundTests.all404sAreIdentical` is the other half of this.
    @Test func theBareAdminSegmentIsUnaffected() async throws {
        try await TestFixture.makeApp().test(.router) { client in
            try await client.execute(uri: "/\(ServerRoute.admin)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body) == notFoundPage())
            }
        }
    }
}
