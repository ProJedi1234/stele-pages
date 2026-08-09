import Foundation
import Testing

@testable import SteleCore

/// The policy in `ClientStoring`'s extension — the part every conformer shares and the
/// part the authentication middleware will lean on entirely.
///
/// The four cases below are the whole contract: exactly one of them resolves to a
/// credential, and the other three are indistinguishable from each other by design.
@Suite("Client authentication policy")
struct ClientStoringTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aValidTokenResolvesToItsClient() async throws {
        let store = InMemoryClientStore()
        let seeded = await store.seed(token: "stele_pat_valid", name: "claude-code")

        let client = try await store.authenticate(token: "stele_pat_valid", at: now)
        #expect(client == seeded)
        #expect(client?.has(.publish) == true)
        #expect(client?.has(.admin) == false)
    }

    /// Three failures, one answer. A caller probing for valid tokens is not behind the
    /// token, so "revoked" and "never existed" must be the same fact from outside — the
    /// alternative confirms that a guess was structurally right.
    @Test func unknownRevokedAndExpiredAreAllTheSameNil() async throws {
        let store = InMemoryClientStore()
        await store.seed(token: "stele_pat_revoked", name: "revoked", revokedAt: now)
        await store.seed(
            token: "stele_pat_expired",
            name: "expired",
            expiresAt: now.addingTimeInterval(-1)
        )

        let unknown = try await store.authenticate(token: "stele_pat_unknown", at: now)
        let revoked = try await store.authenticate(token: "stele_pat_revoked", at: now)
        let expired = try await store.authenticate(token: "stele_pat_expired", at: now)
        #expect(unknown == nil)
        #expect(revoked == nil)
        #expect(expired == nil)
    }

    /// The lookup is by digest, so the seam never sees the plaintext token and a store
    /// cannot accidentally be asked to compare one.
    @Test func lookupGoesThroughTheHashAndNotThePlaintext() async throws {
        let store = InMemoryClientStore()
        let seeded = await store.seed(token: "stele_pat_valid")

        let byHash = try await store.client(
            forTokenHash: ClientCredential.hash("stele_pat_valid")
        )
        #expect(byHash == seeded)
        let byPlaintext = try await store.client(forTokenHash: Array("stele_pat_valid".utf8))
        #expect(byPlaintext == nil)
    }

    /// The expiry boundary, which only a test that injects the clock can pin. Expiry is
    /// exclusive: a credential is dead *at* the instant it expires, not one tick after.
    @Test func expiryIsExclusiveAndAbsentExpiryNeverExpires() {
        let expiring = Client(
            id: 1, name: "expiring", scopes: [], createdAt: now, expiresAt: now
        )
        #expect(expiring.isUsable(at: now.addingTimeInterval(-1)))
        #expect(!expiring.isUsable(at: now))
        #expect(!expiring.isUsable(at: now.addingTimeInterval(1)))

        let perpetual = Client(id: 2, name: "perpetual", scopes: [], createdAt: now)
        #expect(perpetual.isUsable(at: .distantFuture))
    }

    /// Revocation outranks a valid expiry. A credential revoked before its natural end is
    /// the case that actually happens, and the one where getting the precedence backwards
    /// would leave a known-compromised token working.
    @Test func revocationBeatsAnUnexpiredExpiry() {
        let revoked = Client(
            id: 1,
            name: "revoked",
            scopes: [],
            createdAt: now,
            expiresAt: .distantFuture,
            revokedAt: now
        )
        #expect(!revoked.isUsable(at: now))
    }

    /// A scope this build has never heard of must not fail the lookup or grant anything —
    /// it is a `text[]` in Postgres and a newer build (or a `psql` session) can write one.
    @Test func anUnknownScopeGrantsNothingAndBreaksNothing() {
        let client = Client(id: 1, name: "future", scopes: ["telepathy"], createdAt: now)
        #expect(client.isUsable(at: now))
        #expect(!client.has(.publish))
        #expect(!client.has(.admin))
    }

    @Test func recordingAUseIsObservable() async throws {
        let store = InMemoryClientStore()
        let client = await store.seed(token: "stele_pat_valid")

        try await store.recordUse(clientID: client.id)
        try await store.recordUse(clientID: client.id)

        let uses = await store.recordedUses
        #expect(uses == [client.id, client.id])
    }

    // MARK: - Minting

    /// The round trip the whole scheme rests on: `create` hands back a token, stores only
    /// its digest, and that token then authenticates. If minting and checking ever disagree
    /// about what gets hashed, this is where it shows.
    @Test func aMintedTokenAuthenticatesAndOnlyItsDigestIsStored() async throws {
        let store = InMemoryClientStore()

        let (client, token) = try await store.create(
            name: "claude-code", scopes: [.publish], expiresAt: nil
        )
        #expect(client.name == "claude-code")
        #expect(client.scopes == [ClientScope.publish.rawValue])
        #expect(token.hasPrefix(ClientCredential.prefix))

        #expect(try await store.authenticate(token: token, at: now) == client)
        // Stored by digest, so the plaintext is not a key anything could be looked up by.
        #expect(try await store.client(forTokenHash: Array(token.utf8)) == nil)
        #expect(try await store.client(forTokenHash: ClientCredential.hash(token)) == client)
    }

    @Test func mintingTheSameNameTwiceThrowsAndStoresNothing() async throws {
        let store = InMemoryClientStore()
        _ = try await store.create(name: "twice", scopes: [.publish], expiresAt: nil)

        await #expect(throws: ClientStoreError.nameTaken("twice")) {
            try await store.create(name: "twice", scopes: [.admin], expiresAt: nil)
        }
        #expect(try await store.allClients().count == 1)
    }

    /// An expiry set at mint time is honoured by the same policy an expiry set any other way
    /// is — `create` stores an instant, and `authenticate` compares against it.
    @Test func aMintedCredentialRespectsItsExpiry() async throws {
        let store = InMemoryClientStore()
        let (_, token) = try await store.create(
            name: "temporary", scopes: [.publish], expiresAt: now.addingTimeInterval(60)
        )

        #expect(try await store.authenticate(token: token, at: now) != nil)
        #expect(try await store.authenticate(token: token, at: now.addingTimeInterval(61)) == nil)
    }

    /// The field travels with the credential rather than with the request that minted it: it
    /// is written once by `create` and read back by every route that reports a credential at
    /// all. Both origins are exercised in one test, because "carries the login" only means
    /// something alongside "and the hand-minted one does not" — a store that recorded a
    /// constant would satisfy either half alone.
    ///
    /// It survives revocation deliberately. A revoked row is what an incident is
    /// reconstructed from, and "whose credential was that?" is the question being asked at
    /// exactly that moment.
    @Test func aMintedCredentialCarriesTheGitHubLoginThatMintedIt() async throws {
        let store = InMemoryClientStore()

        let (signedIn, signedInToken) = try await store.create(
            name: "projedi1234", scopes: [.publish], expiresAt: nil, githubLogin: "ProJedi1234"
        )
        #expect(signedIn.githubLogin == "ProJedi1234")
        let resolved = try await store.authenticate(token: signedInToken, at: now)
        #expect(resolved?.githubLogin == "ProJedi1234")

        // The default is the admin route's answer, and it is an absence rather than a blank.
        let (handMinted, handMintedToken) = try await store.create(
            name: "claude-code", scopes: [.publish], expiresAt: nil
        )
        #expect(handMinted.githubLogin == nil)
        #expect(try await store.authenticate(token: handMintedToken, at: now)?.githubLogin == nil)

        #expect(try await store.revoke(name: "projedi1234")?.githubLogin == "ProJedi1234")
        let listed = try await store.allClients()
        #expect(listed.first { $0.name == "projedi1234" }?.githubLogin == "ProJedi1234")
        #expect(listed.first { $0.name == "claude-code" }?.githubLogin == nil)
    }

    // MARK: - Listing and revoking

    /// Revoked credentials stay in the listing. "Which credentials did I revoke, and when?"
    /// is the question asked during an incident, and a list that hid them would answer it
    /// with silence.
    @Test func revokingKeepsTheRowAndTheOriginalTimestamp() async throws {
        let store = InMemoryClientStore()
        _ = try await store.create(name: "leaked", scopes: [.publish], expiresAt: nil)

        let first = try await store.revoke(name: "leaked")
        let second = try await store.revoke(name: "leaked")
        #expect(first?.revokedAt != nil)
        // Not merely "still revoked": the moment trust ended must not move under a retry.
        #expect(first?.revokedAt == second?.revokedAt)

        let all = try await store.allClients()
        #expect(all.map(\.name) == ["leaked"])
        #expect(all.first?.revokedAt == first?.revokedAt)
    }

    @Test func revokingAnUnknownNameReportsTheMiss() async throws {
        let store = InMemoryClientStore()
        #expect(try await store.revoke(name: "never-existed") == nil)
    }

    /// Rotation, which is the ordinary reason to revoke anything: the name is the handle the
    /// operator and their tooling know, so retiring it along with the credential would make
    /// every rotation rename the agent. Uniqueness holds over live rows only — the revoked
    /// row stays in the listing and stops authenticating, which is the part that matters.
    @Test func aRevokedNameCanBeReissued() async throws {
        let store = InMemoryClientStore()
        let (_, firstToken) = try await store.create(
            name: "claude-code", scopes: [.publish], expiresAt: nil
        )
        _ = try await store.revoke(name: "claude-code")

        let (reissued, secondToken) = try await store.create(
            name: "claude-code", scopes: [.publish], expiresAt: nil
        )
        #expect(reissued.revokedAt == nil)
        #expect(try await store.authenticate(token: secondToken, at: now) == reissued)
        // The old token does not come back to life with the name.
        #expect(try await store.authenticate(token: firstToken, at: now) == nil)
        #expect(try await store.allClients().map(\.name) == ["claude-code", "claude-code"])

        // And a second live one is still refused, which is what keeps `DELETE
        // /admin/clients/:name` unambiguous.
        await #expect(throws: ClientStoreError.nameTaken("claude-code")) {
            try await store.create(name: "claude-code", scopes: [.publish], expiresAt: nil)
        }
    }

    /// Which row a `DELETE` lands on once a name has history behind it. The live credential
    /// is the only one revoking can mean; reaching the retired row instead would report a
    /// success while leaving the working token working.
    @Test func revokingANameWithHistoryTakesTheLiveCredential() async throws {
        let store = InMemoryClientStore()
        _ = try await store.create(name: "claude-code", scopes: [.publish], expiresAt: nil)
        let firstRevoke = try #require(try await store.revoke(name: "claude-code"))
        let (reissued, token) = try await store.create(
            name: "claude-code", scopes: [.publish], expiresAt: nil
        )

        let secondRevoke = try #require(try await store.revoke(name: "claude-code"))
        #expect(secondRevoke.id == reissued.id)
        #expect(try await store.authenticate(token: token, at: now) == nil)

        // With nothing live left, a retry still answers rather than 404ing — and answers
        // with the row it just revoked, at the timestamp it already had.
        let retry = try #require(try await store.revoke(name: "claude-code"))
        #expect(retry.id == secondRevoke.id)
        #expect(retry.revokedAt == secondRevoke.revokedAt)
        // The older row is untouched: its own moment of revocation is still its own.
        let stored = try await store.allClients()
        #expect(stored.first { $0.id == firstRevoke.id }?.revokedAt == firstRevoke.revokedAt)
    }

    @Test func theListingIsOldestFirst() async throws {
        let store = InMemoryClientStore()
        for name in ["first", "second", "third"] {
            _ = try await store.create(name: name, scopes: [.publish], expiresAt: nil)
        }
        #expect(try await store.allClients().map(\.name) == ["first", "second", "third"])
    }
}

/// A credential's name is the handle `DELETE /admin/clients/:name` addresses, so the
/// alphabet is a correctness rule rather than a style one: a name that cannot survive a URL
/// path segment names a credential nobody can revoke.
@Suite("Client names")
struct ClientNameTests {
    @Test("accepts names an operator would actually pick", arguments: [
        "claude-code", "agent1", "a", "claude-code-on-argos",
        String(repeating: "a", count: 64),
    ])
    func acceptsValid(_ candidate: String) throws {
        #expect(try Client.validated(name: candidate) == candidate)
    }

    @Test func rejectsEmpty() {
        #expect(throws: ClientNameError.empty) { try Client.validated(name: "") }
    }

    @Test func rejectsTooLong() {
        #expect(throws: ClientNameError.tooLong(max: Client.maxNameLength)) {
            try Client.validated(name: String(repeating: "a", count: Client.maxNameLength + 1))
        }
    }

    @Test("rejects anything a URL path segment would mangle", arguments: [
        "has space", "Upper", "slash/name", "under_score", "question?", "caf\u{e9}", "a%20b",
    ])
    func rejectsUnaddressable(_ candidate: String) {
        #expect(throws: ClientNameError.self) { try Client.validated(name: candidate) }
    }

    /// Deliberately *not* `Slug`: a client called `admin` is fine, and a three-character
    /// minimum is a page rule with no meaning here. If this ever starts throwing, someone
    /// has routed credential names through the slug chokepoint.
    @Test func doesNotInheritTheSlugReservedList() throws {
        for reserved in ["admin", "pages", "healthz"] {
            #expect(try Client.validated(name: reserved) == reserved)
        }
    }
}
