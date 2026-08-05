import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import SteleCore

/// HTTP-level tests for the three credential-management routes.
///
/// They authenticate with the shared `STELE_UPLOAD_TOKEN`, which is the real bootstrap
/// path: minting the first per-client credential needs a credential you cannot otherwise
/// have yet, and that is the whole job the shared token has left.
///
/// The property most of these exist to protect is negative — that the plaintext token
/// appears in exactly one response and nowhere else, ever — so several assertions are about
/// what the bytes do *not* contain.
@Suite("Admin client management")
struct AdminClientsTests {
    static let collection = "/\(ServerRoute.admin)/\(ServerRoute.adminClients)"

    /// An application whose credential store starts empty, so a listing shows exactly what
    /// the test under it minted. `TestFixture`'s default store holds a publishing
    /// credential for the write suites, and it would otherwise turn up in every assertion
    /// here — first in the list, since it is the oldest.
    static func makeApp() throws -> Application<RouterResponder<SteleRequestContext>> {
        try TestFixture.makeApp(clients: InMemoryClientStore())
    }

    static var authorized: HTTPFields {
        [
            .authorization: "Bearer \(TestFixture.token)",
            .contentType: "application/json",
        ]
    }

    /// `POST /admin/clients` with `body`, returning the status and the decoded object.
    @discardableResult
    static func create(
        _ client: some TestClientProtocol,
        body: String
    ) async throws -> (status: HTTPResponse.Status, raw: String, json: [String: Any]) {
        try await client.execute(
            uri: collection,
            method: .post,
            headers: authorized,
            body: ByteBuffer(string: body)
        ) { response in
            let raw = String(buffer: response.body)
            let json = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                as? [String: Any] ?? [:]
            return (response.status, raw, json)
        }
    }

    static func list(
        _ client: some TestClientProtocol
    ) async throws -> (status: HTTPResponse.Status, raw: String, clients: [[String: Any]]) {
        try await client.execute(uri: collection, method: .get, headers: authorized) { response in
            let raw = String(buffer: response.body)
            let payload = (try? JSONSerialization.jsonObject(with: Data(buffer: response.body)))
                as? [String: Any]
            return (response.status, raw, payload?["clients"] as? [[String: Any]] ?? [])
        }
    }

    // MARK: - Creating

    /// The happy path, and the one response in the server that carries a secret. The token
    /// has to be there, has to be recognisable as a stele credential, and has to be the
    /// only place it ever appears — which the listing test below is the other half of.
    @Test func createReturnsTheTokenOnceAndTheCredentialAlongsideIt() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            #expect(created.status == .created)

            let token = try #require(created.json["token"] as? String)
            #expect(token.hasPrefix(ClientCredential.prefix))
            // The prefix plus base64url of 32 bytes: long enough that a truncated or
            // placeholder value cannot pass.
            #expect(token.count > ClientCredential.prefix.count + 40)

            let credential = try #require(created.json["client"] as? [String: Any])
            #expect(credential["name"] as? String == "claude-code")
            // The default, and the only scope an agent credential should get.
            #expect(credential["scopes"] as? [String] == [ClientScope.publish.rawValue])
            #expect(credential["createdAt"] is String)
            // Absent rather than present-and-null is not the point; what matters is that a
            // fresh credential is neither expired nor revoked.
            #expect(credential["expiresAt"] == nil || credential["expiresAt"] is NSNull)
            #expect(credential["revokedAt"] == nil || credential["revokedAt"] is NSNull)
            // The secret belongs to the response, not to the credential record — the CLI
            // decodes `client` with the same type it decodes a listing with.
            #expect(credential["token"] == nil)
        }
    }

    /// End to end, and the assertion that the minting actually works rather than merely
    /// returning a plausible string: the token that came out of `POST /admin/clients`
    /// publishes a page through the ordinary write route.
    @Test func aMintedCredentialCanImmediatelyPublish() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            let token = try #require(created.json["token"] as? String)

            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
                body: ByteBuffer(string: "<h1>minted</h1>")
            ) { response in
                #expect(response.status == .created)
            }
        }
    }

    /// Two mints of the same name produce two different tokens, which is what makes the
    /// digest column's uniqueness constraint a formality rather than a real risk — and what
    /// makes a lost token recoverable only by minting a replacement.
    @Test func everyMintProducesADifferentToken() async throws {
        try await Self.makeApp().test(.router) { client in
            let first = try await Self.create(client, body: #"{"name":"one"}"#)
            let second = try await Self.create(client, body: #"{"name":"two"}"#)
            #expect(first.json["token"] as? String != second.json["token"] as? String)
        }
    }

    @Test func explicitScopesAreStoredAndAnUnknownOneIs400() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.create(
                client,
                body: #"{"name":"operator","scopes":["publish","admin","publish"]}"#
            )
            #expect(created.status == .created)
            let credential = try #require(created.json["client"] as? [String: Any])
            // Deduped, and in the order asked for.
            #expect(
                credential["scopes"] as? [String]
                    == [ClientScope.publish.rawValue, ClientScope.admin.rawValue]
            )

            // A scope nothing grants would mint a credential that silently cannot do the
            // job, and the operator would not find out until the agent's first publish.
            let bogus = try await Self.create(
                client, body: #"{"name":"typo","scopes":["publsh"]}"#
            )
            #expect(bogus.status == .badRequest)
            #expect(bogus.raw.contains(ClientScope.publish.rawValue))
            #expect(bogus.raw.contains(ClientScope.admin.rawValue))

            // An explicitly empty array is a mistake, not a request for a useless
            // credential.
            let empty = try await Self.create(client, body: #"{"name":"nothing","scopes":[]}"#)
            #expect(empty.status == .badRequest)
        }
    }

    @Test func expiresInBecomesAnAbsoluteExpiryAndMustBePositive() async throws {
        try await Self.makeApp().test(.router) { client in
            let before = Date()
            let created = try await Self.create(
                client, body: #"{"name":"temporary","expiresIn":3600}"#
            )
            #expect(created.status == .created)

            let credential = try #require(created.json["client"] as? [String: Any])
            let raw = try #require(credential["expiresAt"] as? String)
            let expiresAt = try #require(ISO8601DateFormatter().date(from: raw))
            // An hour from now, give or take however long the request took — and give or
            // take a second in the other direction, because RFC 3339 without a fractional
            // part truncates the sub-second component the encoder started with.
            #expect(expiresAt.timeIntervalSince(before) > 3_598)
            #expect(expiresAt.timeIntervalSince(before) < 3_700)

            for bad in ["0", "-60"] {
                let response = try await Self.create(
                    client, body: #"{"name":"bad","expiresIn":\#(bad)}"#
                )
                #expect(response.status == .badRequest)
            }
        }
    }

    /// The other end of the range, which is not a taste question. A `timestamptz` is
    /// microseconds in an `Int64` and PostgresNIO converts to that with `Int64(_:)` over a
    /// `Double`, so a far enough expiry does not fail to bind — it traps, taking the process
    /// and every in-flight request with it. One JSON field reaches that, so the field is
    /// bounded and the answer is a 400.
    ///
    /// The in-memory store would happily hold any of these dates; what this pins is that
    /// `validatedExpiry` refuses them before a store is ever asked.
    @Test func anAbsurdlyDistantExpiryIs400RatherThanACrash() async throws {
        try await Self.makeApp().test(.router) { client in
            for bad in ["\(Int.max)", "\(maxExpiresInSeconds + 1)"] {
                let response = try await Self.create(
                    client, body: #"{"name":"distant","expiresIn":\#(bad)}"#
                )
                #expect(response.status == .badRequest, "\(bad)")
                #expect(response.json["token"] == nil)
            }

            // The boundary itself is allowed: the limit is a safety rail, and a century is
            // past anything an operator means but not a value to reject as nonsense.
            let allowed = try await Self.create(
                client, body: #"{"name":"long-lived","expiresIn":\#(maxExpiresInSeconds)}"#
            )
            #expect(allowed.status == .created)
        }
    }

    /// The name is the handle `DELETE` addresses, so anything that would not survive a URL
    /// path segment has to be refused at creation — a credential nobody can revoke is the
    /// one failure this whole feature exists to prevent.
    @Test("names that could not be revoked are refused", arguments: [
        "", "has space", "Upper", "slash/name", "under_score",
        String(repeating: "a", count: 65),
    ])
    func invalidNamesAre400(name: String) async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.create(client, body: #"{"name":"\#(name)"}"#)
            #expect(created.status == .badRequest)
            #expect(created.raw.contains("Invalid client name"))
        }
    }

    @Test func aMalformedBodyIs400AndNamesTheShapeExpected() async throws {
        try await Self.makeApp().test(.router) { client in
            for body in ["", "not json", #"{"scopes":["publish"]}"#] {
                let created = try await Self.create(client, body: body)
                #expect(created.status == .badRequest, "\(body)")
                #expect(created.raw.contains("name"), "\(body)")
            }
        }
    }

    /// Live names are unique because the name is the revocation handle: two *usable* rows
    /// sharing one would make `DELETE /admin/clients/:name` ambiguous at exactly the wrong
    /// moment. Revoked rows are the other case — see `aRevokedNameCanBeReissued`.
    @Test func aDuplicateNameIs409AndMintsNothing() async throws {
        try await Self.makeApp().test(.router) { client in
            #expect(try await Self.create(client, body: #"{"name":"twice"}"#).status == .created)

            let second = try await Self.create(client, body: #"{"name":"twice"}"#)
            #expect(second.status == .conflict)
            #expect(second.raw.contains("twice"))
            #expect(second.json["token"] == nil)

            #expect(try await Self.list(client).clients.count == 1)
        }
    }

    // MARK: - Listing

    /// The negative property, asserted on the bytes rather than on a decoded shape: the
    /// listing must not carry the token or its digest under any key, including one a future
    /// `Encodable` conformance might add by accident.
    @Test func theListingNeverCarriesATokenOrADigest() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            let token = try #require(created.json["token"] as? String)

            let listed = try await Self.list(client)
            #expect(listed.status == .ok)
            #expect(!listed.raw.contains(token))
            #expect(!listed.raw.lowercased().contains("token"))
            #expect(!listed.raw.lowercased().contains("hash"))

            let entry = try #require(listed.clients.first)
            #expect(entry["name"] as? String == "claude-code")
            #expect(entry["scopes"] as? [String] == [ClientScope.publish.rawValue])
            #expect(entry["createdAt"] is String)
            // `lastUsedAt` answers the operator's "is this still in service?". A credential
            // that has never been used has no value for it, and `JSONEncoder` omits a nil
            // `Optional` rather than writing null — so absence *is* the never-used case, and
            // the assertion worth making is that nothing has invented one.
            #expect(entry["lastUsedAt"] == nil)
        }
    }

    /// Oldest first, so a listing reads as a history rather than as whatever order a
    /// dictionary happened to iterate in.
    @Test func theListingIsOldestFirst() async throws {
        try await Self.makeApp().test(.router) { client in
            for name in ["first", "second", "third"] {
                #expect(
                    try await Self.create(client, body: #"{"name":"\#(name)"}"#).status == .created
                )
            }
            let names = try await Self.list(client).clients.compactMap { $0["name"] as? String }
            #expect(names == ["first", "second", "third"])
        }
    }

    /// An empty listing is an empty array under the same key, not a 404 and not a bare
    /// `[]` — the envelope is what lets this grow a cursor later without breaking the CLI.
    @Test func anEmptyListingIsStillAnEnvelope() async throws {
        try await Self.makeApp().test(.router) { client in
            let listed = try await Self.list(client)
            #expect(listed.status == .ok)
            #expect(listed.clients.isEmpty)
            #expect(listed.raw.contains("\"clients\""))
        }
    }

    // MARK: - Revoking

    /// Revocation is what the credential system is *for*, so this is the end-to-end shape
    /// that matters: mint, publish, revoke, and the same token stops working.
    @Test func revokingStopsTheCredentialFromAuthenticating() async throws {
        try await Self.makeApp().test(.router) { client in
            let created = try await Self.create(client, body: #"{"name":"leaked"}"#)
            let token = try #require(created.json["token"] as? String)

            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
                body: ByteBuffer(string: "<h1>before</h1>")
            ) { #expect($0.status == .created) }

            try await client.execute(
                uri: "\(Self.collection)/leaked",
                method: .delete,
                headers: Self.authorized
            ) { response in
                #expect(response.status == .ok)
                let payload = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: response.body))
                        as? [String: Any]
                )
                #expect(payload["revokedAt"] is String)
                #expect(payload["name"] as? String == "leaked")
                #expect(payload["token"] == nil)
            }

            // A revoked credential is indistinguishable from one that never existed — 401,
            // not 403: the caller is no longer behind the token, so "it used to work" is
            // not a fact to hand them.
            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
                body: ByteBuffer(string: "<h1>after</h1>")
            ) { #expect($0.status == .unauthorized) }
        }
    }

    /// Idempotent in the way that matters. A second `DELETE` succeeds, and it must not move
    /// `revokedAt` — that timestamp is the boundary an incident is reconstructed from, and
    /// a retried request that rewrote it would erase the only record of when trust ended.
    @Test func revokingTwiceSucceedsAndKeepsTheOriginalTimestamp() async throws {
        try await Self.makeApp().test(.router) { client in
            _ = try await Self.create(client, body: #"{"name":"leaked"}"#)

            func revoke() async throws -> (HTTPResponse.Status, String?) {
                try await client.execute(
                    uri: "\(Self.collection)/leaked", method: .delete, headers: Self.authorized
                ) { response in
                    let payload = (try? JSONSerialization.jsonObject(
                        with: Data(buffer: response.body)
                    )) as? [String: Any]
                    return (response.status, payload?["revokedAt"] as? String)
                }
            }

            let first = try await revoke()
            let second = try await revoke()
            #expect(first.0 == .ok)
            #expect(second.0 == .ok)
            #expect(first.1 != nil)
            #expect(first.1 == second.1)

            // And the row survives revocation: the history is the point.
            let names = try await Self.list(client).clients.compactMap { $0["name"] as? String }
            #expect(names == ["leaked"])
        }
    }

    /// Rotation, end to end and through the routes an operator actually types: mint, revoke,
    /// mint again under the same name. The name is the handle their tooling stores, so a
    /// scheme where revoking retired it would make every rotation a rename — and the only
    /// way out would be `claude-code-2`, then `-3`.
    ///
    /// The three assertions that matter are that the second mint is a `201` rather than the
    /// `409` this used to be, that the revoked token stays dead, and that the history keeps
    /// both rows.
    @Test func aRevokedNameCanBeReissued() async throws {
        try await Self.makeApp().test(.router) { client in
            let first = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            let firstToken = try #require(first.json["token"] as? String)

            try await client.execute(
                uri: "\(Self.collection)/claude-code",
                method: .delete,
                headers: Self.authorized
            ) { #expect($0.status == .ok) }

            let second = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            #expect(second.status == .created)
            let secondToken = try #require(second.json["token"] as? String)
            #expect(secondToken != firstToken)

            func publish(with token: String) async throws -> HTTPResponse.Status {
                try await client.execute(
                    uri: "/\(ServerRoute.pages)",
                    method: .post,
                    headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
                    body: ByteBuffer(string: "<h1>rotated</h1>")
                ) { $0.status }
            }
            #expect(try await publish(with: secondToken) == .created)
            #expect(try await publish(with: firstToken) == .unauthorized)

            // Two rows, one name: the retired credential is still the record of what was
            // revoked and when, which is the question the listing exists to answer.
            let listed = try await Self.list(client).clients
            #expect(listed.compactMap { $0["name"] as? String } == ["claude-code", "claude-code"])
            #expect(listed.first?["revokedAt"] is String)
            #expect(listed.last?["revokedAt"] == nil || listed.last?["revokedAt"] is NSNull)

            // A second *live* one is still refused, and the message says which half of the
            // rotation is missing.
            let third = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            #expect(third.status == .conflict)
            #expect(third.raw.contains("Revoke it first"))
        }
    }

    /// Which of several rows sharing a name a `DELETE` lands on. Reaching the already-retired
    /// one would answer `200` with a `revokedAt` the operator recognises while leaving the
    /// live token publishing.
    @Test func revokingAReissuedNameTakesTheLiveCredential() async throws {
        try await Self.makeApp().test(.router) { client in
            _ = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            try await client.execute(
                uri: "\(Self.collection)/claude-code", method: .delete, headers: Self.authorized
            ) { #expect($0.status == .ok) }

            let reissued = try await Self.create(client, body: #"{"name":"claude-code"}"#)
            let token = try #require(reissued.json["token"] as? String)

            try await client.execute(
                uri: "\(Self.collection)/claude-code", method: .delete, headers: Self.authorized
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/\(ServerRoute.pages)",
                method: .post,
                headers: [.authorization: "Bearer \(token)", .contentType: "text/html"],
                body: ByteBuffer(string: "<h1>after</h1>")
            ) { #expect($0.status == .unauthorized) }

            // Nothing live left, and the retry still answers rather than 404ing.
            try await client.execute(
                uri: "\(Self.collection)/claude-code", method: .delete, headers: Self.authorized
            ) { #expect($0.status == .ok) }

            let revocations = try await Self.list(client).clients.map { $0["revokedAt"] is String }
            #expect(revocations == [true, true])
        }
    }

    /// A 404 rather than a cheerful no-op, and the exception to this repo's uniform-404
    /// rule that the README already licenses: this caller is behind an admin credential, so
    /// there is nothing left to leak — and a typo the operator cannot see is exactly how a
    /// credential they believe is revoked stays live.
    @Test func revokingAnUnknownNameIs404() async throws {
        try await Self.makeApp().test(.router) { client in
            try await client.execute(
                uri: "\(Self.collection)/never-existed",
                method: .delete,
                headers: Self.authorized
            ) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body).contains("never-existed"))
            }
        }
    }

    /// The two routes have to agree on what a name is, or a name `POST` accepted would
    /// address nothing here. Both go through `Client.validated(name:)`.
    @Test func revokingAnUnaddressableNameIs400() async throws {
        try await Self.makeApp().test(.router) { client in
            try await client.execute(
                uri: "\(Self.collection)/Upper",
                method: .delete,
                headers: Self.authorized
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("Invalid client name"))
            }
        }
    }
}
