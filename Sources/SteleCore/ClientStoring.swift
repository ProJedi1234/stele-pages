import Foundation

/// Why a credential could not be stored.
///
/// One case, because there is only one way `insert` can refuse: the name was taken. The
/// token-hash collision the same constraint also guards is 256 bits of CSPRNG output
/// landing twice, which is not a failure worth a case a caller could branch on.
public enum ClientStoreError: Error, Equatable {
    /// A credential already holds this name.
    case nameTaken(String)
}

/// The credential operations authentication depends on.
///
/// Split out for the same reason `PageStoring` is: so the HTTP tests can exercise the
/// real code against an in-memory fake and a plain `swift test` needs no Postgres.
/// Authentication that could only run against a database would take the whole write
/// surface's tests with it.
///
/// The seam is primitives only — look a credential up by the digest of its token, and
/// stamp a use — with the policy that turns a row into a *decision* living in the
/// extension below, shared by every conformer. That keeps the rule written and tested
/// once, so a fake cannot drift from the store on what "valid" means.
public protocol ClientStoring: Sendable {
    /// The credential whose token hashes to `hash`, or nil if there is none.
    ///
    /// Returns revoked and expired credentials too. Filtering them here would move the
    /// policy into each conformer, and would also lose the distinction the operator's
    /// tooling needs — a revoked credential is a row worth listing, not an absence.
    func client(forTokenHash hash: [UInt8]) async throws -> Client?

    /// Records that `clientID` was just used, for the operator's "is this still in
    /// service?" question. Best effort: this runs after the request has been authorised
    /// and must not be what fails it.
    func recordUse(clientID: Int64) async throws

    /// Stores a credential if both `name` and `tokenHash` are free, as one atomic step —
    /// the uniqueness check and the write must not leave a window where two concurrent
    /// mints both see a name as available.
    ///
    /// A name is free when no *live* credential holds it. Revoked rows keep their names —
    /// the listing is the record of what was revoked and when — but do not reserve them,
    /// because rotating a credential means minting a replacement under the name the
    /// operator and their tooling already know.
    ///
    /// Takes the digest, never a token: the plaintext exists in exactly one function
    /// (`create(name:scopes:expiresAt:githubLogin:)` below) and does not cross this seam, so
    /// no conformer is ever in a position to store one by accident.
    ///
    /// `githubLogin` is the account that signed in to mint this credential, and nil for every
    /// credential minted any other way. It is carried on the primitive rather than defaulted
    /// away because a protocol requirement cannot have a default: a conformer that quietly
    /// dropped the argument would satisfy every reporting test in the suite while writing
    /// NULL to a column the exchange had a real answer for.
    ///
    /// - Returns: the stored row, or nil if the name — or, impossibly, the digest — was
    ///   already taken.
    func insert(
        name: String, tokenHash: [UInt8], scopes: [String], expiresAt: Date?,
        githubLogin: String?
    ) async throws -> Client?

    /// Every credential, oldest first, revoked and expired ones included.
    ///
    /// Revoked rows are the point rather than an oversight: "which credentials did I
    /// revoke, and when?" is the question the operator asks during an incident, and a list
    /// that hid them would answer it with silence.
    func allClients() async throws -> [Client]

    /// Marks the credential named `name` revoked, keeping an existing `revoked_at` rather
    /// than moving it. That is what makes `DELETE` idempotent in the way that matters: a
    /// second call must not rewrite the moment a credential stopped being trusted, because
    /// that moment is the boundary an incident is reconstructed from.
    ///
    /// Several rows can share a name once one has been rotated. This revokes the live one
    /// if there is one — there is at most one — and otherwise reports the most recently
    /// revoked, which is what keeps a repeated call idempotent rather than a 404.
    ///
    /// - Returns: the row as it now stands, or nil if there is no such credential.
    func revoke(name: String) async throws -> Client?
}

extension ClientStoring {
    /// Resolves a presented token to the credential it authenticates, or nil.
    ///
    /// The one collapsed nil is the point. Unknown, revoked and expired are three
    /// different facts about a credential and the caller gets none of them, because a
    /// caller probing for valid tokens is by definition *not* behind the token — the
    /// README's licence to return distinguishable errors to an authenticated caller does
    /// not reach this path. Telling an attacker "that token existed once" is telling them
    /// their guess was structurally right.
    ///
    /// - Parameter moment: injectable so the expiry boundary is testable without waiting
    ///   for a clock.
    public func authenticate(token: String, at moment: Date = Date()) async throws -> Client? {
        guard let client = try await client(forTokenHash: ClientCredential.hash(token)),
              client.isUsable(at: moment)
        else { return nil }
        return client
    }

    /// Mints a credential and stores it, returning the row and the one plaintext copy of
    /// its token that will ever exist.
    ///
    /// Generating and hashing live here rather than in a handler for the same reason the
    /// slug-retry loop does: it is policy, and a second implementation of it is a second
    /// chance to store something other than `ClientCredential.hash` of what was handed
    /// out. The caller's only job is to put `token` in the response and then forget it —
    /// nothing in this process or the database can produce it again.
    ///
    /// `githubLogin` is defaulted here and not on the primitive, which is the difference
    /// between an extension method and a protocol requirement: only one of the two minting
    /// routes has a GitHub identity to record, so the admin handler says nothing and means
    /// nothing by it, while the exchange passes the login GitHub reported. Every conformer
    /// still has to carry the parameter, so the default cannot become a place a store
    /// forgets the column.
    ///
    /// - Throws: `ClientStoreError.nameTaken` when the name is already in use.
    public func create(
        name: String,
        scopes: [ClientScope],
        expiresAt: Date?,
        githubLogin: String? = nil
    ) async throws -> (client: Client, token: String) {
        let token = ClientCredential.generate()
        guard let client = try await insert(
            name: name,
            tokenHash: ClientCredential.hash(token),
            scopes: scopes.map(\.rawValue),
            expiresAt: expiresAt,
            githubLogin: githubLogin
        ) else {
            throw ClientStoreError.nameTaken(name)
        }
        return (client, token)
    }
}
