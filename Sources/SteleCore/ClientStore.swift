import Foundation
import Logging
import PostgresNIO

/// What a credential is allowed to do.
///
/// A scope is checked separately from whether the credential is valid. Without one every
/// token is a root token, and a leaked publishing credential could mint itself a second
/// credential and revoke yours — which is what would make revocation useless. Scopes are
/// what make revocation actually work.
///
/// Adding a value here is free: `scopes` is a Postgres array, so a new scope needs no
/// migration. `delete` joins these two when `DELETE` arrives.
public enum ClientScope: String, Sendable, CaseIterable {
    /// Publishing and updating pages. Every agent credential gets this, and only this.
    case publish
    /// Client management. The operator credential's, and no agent's.
    case admin
}

/// Why a credential name was rejected. Shaped like `SlugError` — each case says what to
/// change rather than a bare "invalid" — because the operator reads it at a terminal.
public enum ClientNameError: Error, Equatable, CustomStringConvertible {
    case empty
    case tooLong(max: Int)
    case invalidCharacter(Character)

    public var description: String {
        switch self {
        case .empty:
            "must not be empty"
        case .tooLong(let max):
            "must be at most \(max) characters"
        case .invalidCharacter(let character):
            "contains '\(character)'; only lowercase letters, digits and hyphens are allowed"
        }
    }
}

/// A credential holder, as read back from the database.
///
/// The token itself is not here and never will be: only `ClientCredential.hash` of it is
/// stored, so there is nothing on this type that could leak into a log line or a
/// response body.
///
/// `scopes` is `[String]` rather than `[ClientScope]` on purpose. It is a `text[]` in
/// Postgres, and a row written by a newer build — or by hand — can hold a value this
/// build has never heard of. Decoding into an enum would fail the whole lookup, turning
/// an unknown scope into an outage; keeping the raw strings makes it a scope that simply
/// grants nothing. Ask with `has(_:)`.
public struct Client: Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var scopes: [String]
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var expiresAt: Date?
    public var revokedAt: Date?

    /// The GitHub login that signed in to mint this credential, or nil when no GitHub
    /// account did.
    ///
    /// Kept in GitHub's canonical casing rather than the folded spelling the credential is
    /// *named* after. The matching already happened, case-insensitively, at exchange time;
    /// what is worth keeping afterwards is the casing the owner would recognise on their own
    /// profile. The name is the handle a URL path segment addresses, and this is the identity
    /// that bought it — two different jobs, which is why they are two fields and not one.
    ///
    /// Nil is not a gap waiting to be filled. A credential minted through
    /// `POST /admin/clients` has no GitHub identity at all, and so does every row that
    /// predates the column; NOT NULL would have forced an invented login onto all of them.
    ///
    /// It records who minted, and is **not** an authorization input. Nothing reads it to
    /// decide anything, deliberately: the allowlist is consulted once, at the moment a
    /// credential is issued, and cutting one off afterwards is `DELETE /admin/clients/:name`.
    /// A later check that re-derived permission from this field would turn an audit record
    /// into a second, stale copy of `STELE_GITHUB_OWNERS` — one that no longer matches the
    /// configuration and that nothing updates.
    public var githubLogin: String?

    public init(
        id: Int64,
        name: String,
        scopes: [String],
        createdAt: Date,
        lastUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        revokedAt: Date? = nil,
        githubLogin: String? = nil
    ) {
        self.id = id
        self.name = name
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.githubLogin = githubLogin
    }

    /// Whether this credential carries `scope`.
    public func has(_ scope: ClientScope) -> Bool {
        scopes.contains(scope.rawValue)
    }

    /// Whether the credential may be used at `moment` — not revoked, and not past its
    /// expiry. A null `expires_at` means it does not expire.
    ///
    /// Takes the moment as a parameter rather than reading the clock so the boundary is
    /// testable. Callers should not use this to *report* why a credential was refused:
    /// see `ClientStoring.authenticate(token:at:)`.
    public func isUsable(at moment: Date) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > moment } ?? true)
    }

    /// Long enough for `claude-code-on-argos`, short enough that the column stays readable
    /// in a terminal listing.
    public static let maxNameLength = 64

    /// Validates an operator-supplied credential name.
    ///
    /// The name is the handle `DELETE /admin/clients/:name` addresses, so it has to
    /// survive a URL path segment intact: a credential named `agent/one`, or one with a
    /// space in it, is a credential nobody can revoke — and an unrevokable credential is
    /// the one failure this whole feature exists to prevent. Hence the same alphabet
    /// `Slug` accepts.
    ///
    /// Deliberately *not* `Slug` itself, even though the rules nearly coincide. A
    /// credential is not a page, and borrowing that type would inherit its reserved-word
    /// list — there is nothing wrong with a client called `admin`, and a three-character
    /// minimum on a name is arbitrary here.
    public static func validated(name raw: String) throws(ClientNameError) -> String {
        guard !raw.isEmpty else { throw .empty }
        guard raw.count <= maxNameLength else { throw .tooLong(max: maxNameLength) }
        for character in raw {
            let isAllowed = character.isASCII
                && (character.isLowercase || character.isNumber || character == "-")
            guard isAllowed else { throw .invalidCharacter(character) }
        }
        return raw
    }
}

/// The credentials half of the store layer. Sits beside `PageStore` and follows the same
/// rules: every statement is parameterised via PostgresNIO's interpolation, which binds
/// values rather than splicing them into SQL text.
///
/// The schema it reads is created by `PageStore.migrations`, not here. The migration list
/// is the history of the whole database and there is exactly one of it; splitting it per
/// table would give two version sequences with no defined order between them.
public struct ClientStore: Sendable {
    /// Named `postgres` rather than `client`, which in this file means a credential
    /// holder and nothing else.
    private let postgres: PostgresClient
    private let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.postgres = client
        self.logger = logger
    }

    /// Looks a credential up by the digest of the token presented with it, or nil if no
    /// such credential exists.
    ///
    /// Returns revoked and expired rows too — validity is `ClientStoring`'s policy, and
    /// keeping it out of the SQL means the one place that decides what "usable" means is
    /// shared with the in-memory fake rather than reimplemented in it.
    public func client(forTokenHash hash: [UInt8]) async throws -> Client? {
        // `Data`, not the `[UInt8]` the seam speaks. PostgresNIO binds `[UInt8]` as a
        // Postgres *array* of `char` — `UInt8` conforms to `PostgresArrayEncodable` — so
        // a bare `\(hash)` would compare a `char[]` against a `bytea` column and fail at
        // runtime with a type error rather than at compile time. `Data` is the bytea
        // conformance.
        let rows = try await postgres.query(
            """
            SELECT id, name, scopes, created_at, last_used_at, expires_at, revoked_at,
                   github_login
            FROM clients WHERE token_hash = \(Data(hash))
            """,
            logger: logger
        )
        return try await Self.decode(rows).first
    }

    /// Stores a credential if the name and the digest are both free.
    ///
    /// `ON CONFLICT DO NOTHING` with no conflict target, so *either* unique index —
    /// `token_hash`'s constraint or `clients_live_name_idx` — turns into an empty result
    /// rather than a thrown error. Untargeted is also what lets the name index be a
    /// *partial* one: a conflict target would have to restate its `WHERE revoked_at IS
    /// NULL` predicate here, in a second place, to be inferred at all. As with
    /// `PageStore.insert`, the check and the write are one statement: reading the names
    /// first and inserting after would leave a window where two concurrent mints both see a
    /// name as free.
    ///
    /// "Free" means no *live* credential holds it — a revoked row keeps its name in the
    /// history without reserving it, so rotating a credential can reuse the name the
    /// operator already knows.
    ///
    /// - Returns: the stored row, or nil if the name was taken.
    public func insert(
        name: String, tokenHash: [UInt8], scopes: [String], expiresAt: Date?,
        githubLogin: String?
    ) async throws -> Client? {
        // `Data(tokenHash)` for the same reason the lookup uses it: PostgresNIO binds a
        // bare `[UInt8]` as a `char[]`, which would not match a `bytea` column.
        // `githubLogin` needs none of that ceremony — it is a `text` column and `String?`
        // is exactly what PostgresNIO binds to one, nil included.
        let rows = try await postgres.query(
            """
            INSERT INTO clients (name, token_hash, scopes, expires_at, github_login)
            VALUES (\(name), \(Data(tokenHash)), \(scopes), \(expiresAt), \(githubLogin))
            ON CONFLICT DO NOTHING
            RETURNING id, name, scopes, created_at, last_used_at, expires_at, revoked_at,
                      github_login
            """,
            logger: logger
        )
        return try await Self.decode(rows).first
    }

    /// Every credential, oldest first. `id` breaks ties on `created_at`, which two rows
    /// minted inside one clock tick can share.
    public func allClients() async throws -> [Client] {
        let rows = try await postgres.query(
            """
            SELECT id, name, scopes, created_at, last_used_at, expires_at, revoked_at,
                   github_login
            FROM clients ORDER BY created_at, id
            """,
            logger: logger
        )
        return try await Self.decode(rows)
    }

    /// Revokes the credential named `name`.
    ///
    /// `COALESCE(revoked_at, now())` is the idempotency: a second revoke returns the same
    /// row it returned the first time rather than resetting the moment the credential
    /// stopped being trusted. One statement again, so the existence check cannot land on a
    /// row a concurrent write has since changed, and `RETURNING` reports the miss.
    ///
    /// Since version 3 a name can be held by several rows — one live credential and the
    /// retired ones it replaced — so the subselect picks which. `revoked_at DESC NULLS
    /// FIRST` reads as "the live one, or else the most recently retired one", and the
    /// partial unique index is what guarantees the first branch matches at most one row.
    /// The second branch is what keeps a repeated `DELETE` a `200` rather than a `404`
    /// after the last live credential of that name is gone, and it returns the same row —
    /// and so the same `revoked_at` — every time.
    ///
    /// Updating *every* row with the name would be harmless under `COALESCE` and is still
    /// wrong: it would return whichever row the planner reached first, so a retry could
    /// answer with a different credential than the call it is retrying.
    public func revoke(name: String) async throws -> Client? {
        let rows = try await postgres.query(
            """
            UPDATE clients SET revoked_at = COALESCE(revoked_at, now())
            WHERE id = (
                SELECT id FROM clients WHERE name = \(name)
                ORDER BY revoked_at DESC NULLS FIRST, id DESC
                LIMIT 1
            )
            RETURNING id, name, scopes, created_at, last_used_at, expires_at, revoked_at,
                      github_login
            """,
            logger: logger
        )
        return try await Self.decode(rows).first
    }

    /// The one place the eight-column projection above is turned back into `Client`s.
    ///
    /// Shared rather than repeated per query because the *column list* cannot be: these are
    /// `PostgresQuery` literals, and a `\(Self.columns)` would become a bind parameter
    /// rather than SQL text. Four hand-written SELECT lists is the cost; four hand-written
    /// decoders — where a reordered tuple compiles and silently swaps two timestamps — is
    /// not a cost worth paying on top.
    private static func decode(_ rows: PostgresRowSequence) async throws -> [Client] {
        var clients: [Client] = []
        for try await (id, name, scopes, createdAt, lastUsedAt, expiresAt, revokedAt, githubLogin)
            in rows.decode(
                (Int64, String, [String], Date, Date?, Date?, Date?, String?).self,
                context: .default
            )
        {
            clients.append(
                Client(
                    id: id,
                    name: name,
                    scopes: scopes,
                    createdAt: createdAt,
                    lastUsedAt: lastUsedAt,
                    expiresAt: expiresAt,
                    revokedAt: revokedAt,
                    githubLogin: githubLogin
                )
            )
        }
        return clients
    }

    /// Stamps a credential as used, for the operator's "is this thing still in service?"
    /// question.
    ///
    /// `now()` is the database's clock rather than the process's, so the answer does not
    /// depend on which instance served the request. A no-op if the row is gone: this is
    /// bookkeeping on a request that has already been authorised, and failing the request
    /// because the audit stamp missed would be the wrong trade.
    public func recordUse(clientID: Int64) async throws {
        try await postgres.query(
            "UPDATE clients SET last_used_at = now() WHERE id = \(clientID)",
            logger: logger
        )
    }
}

/// `ClientStore` is the database-backed conformer of the credentials seam, exactly as
/// `PageStore` is of the pages one. Only the primitives — look up by hash, stamp a use,
/// insert-if-free, list, revoke — live here; the validity policy and the minting of a
/// token come from `ClientStoring`'s extension, shared with every other conformer.
extension ClientStore: ClientStoring {}
