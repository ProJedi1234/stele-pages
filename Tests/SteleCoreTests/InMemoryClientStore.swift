import Foundation

@testable import SteleCore

/// An in-memory `ClientStoring` for authentication tests, mirroring `InMemoryPageStore`.
///
/// An actor for the same reason that one is: the protocol's methods are already `async`,
/// and `Mutex` would need macOS 15 while the manifest declares macOS 14.
///
/// Only the seam's primitives are implemented, so the validity policy the tests exercise
/// — the collapsed nil for unknown, revoked and expired — is the real shared one from
/// `ClientStoring`'s extension rather than a reimplementation that could quietly disagree
/// with the store.
///
/// Every test should build its own instance; swift-testing runs suites in parallel and
/// nothing here is meant to be shared.
actor InMemoryClientStore: ClientStoring {
    /// Keyed by the digest, not by the token, so seeding goes through the real
    /// `ClientCredential.hash` and a change to the hashing would be felt here.
    private var clientsByTokenHash: [[UInt8]: Client] = [:]

    /// Every `recordUse` call, in order — the only way to assert on a fire-and-forget
    /// write.
    private(set) var recordedUses: [Int64] = []

    private var nextID: Int64 = 1

    /// A store already holding one credential, seeded without an `await`.
    ///
    /// `TestFixture.makeApp` is not async and has no business becoming so just to arrange a
    /// token, and every write suite now needs a `publish`-scoped one — the shared token is
    /// `admin`-only and no longer passes the scope check on `/pages`. An actor's
    /// synchronous `init` may touch its own stored properties, which is all this does; it
    /// cannot call `seed` below, because that one is isolated.
    init(
        holding token: String? = nil,
        named name: String = "test-client",
        scopes: [ClientScope] = [.publish]
    ) {
        guard let token else { return }
        clientsByTokenHash[ClientCredential.hash(token)] = Client(
            id: nextID,
            name: name,
            scopes: scopes.map(\.rawValue),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        nextID += 1
    }

    /// Arranges a credential and returns it, along with the plaintext token that resolves
    /// to it.
    @discardableResult
    func seed(
        token: String,
        name: String = "test-client",
        scopes: [ClientScope] = [.publish],
        expiresAt: Date? = nil,
        revokedAt: Date? = nil
    ) -> Client {
        let client = Client(
            id: nextID,
            name: name,
            scopes: scopes.map(\.rawValue),
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: nil,
            expiresAt: expiresAt,
            revokedAt: revokedAt
        )
        nextID += 1
        clientsByTokenHash[ClientCredential.hash(token)] = client
        return client
    }

    func client(forTokenHash hash: [UInt8]) async throws -> Client? {
        clientsByTokenHash[hash]
    }

    func recordUse(clientID: Int64) async throws {
        recordedUses.append(clientID)
        // `last_used_at` is stamped by the database's clock in the real store, so there
        // is no honest value to write here — `recordedUses` is what tests assert on.
    }

    /// Both unique constraints, in the order Postgres would hit them: the digest first
    /// (which is what the dictionary is keyed by) and then the name.
    func insert(
        name: String, tokenHash: [UInt8], scopes: [String], expiresAt: Date?
    ) async throws -> Client? {
        guard clientsByTokenHash[tokenHash] == nil,
              !clientsByTokenHash.values.contains(where: { $0.name == name })
        else { return nil }

        // A real `Date()`, unlike `seed`'s fixed epoch: the store's `now()` is what makes
        // revoking twice observable as "the timestamp did not move", and a frozen clock
        // would make that assertion pass vacuously.
        let client = Client(
            id: nextID,
            name: name,
            scopes: scopes,
            createdAt: Date(),
            expiresAt: expiresAt
        )
        nextID += 1
        clientsByTokenHash[tokenHash] = client
        return client
    }

    /// Sorted by `id`, which is monotonic here, so it stands in for the store's
    /// `ORDER BY created_at, id` without depending on the clock's resolution.
    func allClients() async throws -> [Client] {
        clientsByTokenHash.values.sorted { $0.id < $1.id }
    }

    func revoke(name: String) async throws -> Client? {
        guard let key = clientsByTokenHash.first(where: { $0.value.name == name })?.key
        else { return nil }
        // The fake's copy of `COALESCE(revoked_at, now())`. Written as a policy the store
        // also implements rather than inherited from the seam, because it is one SQL
        // expression there and cannot be shared — `ClientStoringTests` pins both.
        if clientsByTokenHash[key]?.revokedAt == nil {
            clientsByTokenHash[key]?.revokedAt = Date()
        }
        return clientsByTokenHash[key]
    }
}
