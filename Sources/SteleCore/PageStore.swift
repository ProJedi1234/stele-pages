import Foundation
import Logging
import PostgresNIO

/// A stored page, as read back from the database.
public struct Page: Sendable, Equatable {
    public var slug: Slug
    public var body: String
    public var contentType: String
    public var createdAt: Date
    /// When the page stops being served, or nil if it never does.
    ///
    /// Nil means one thing only: somebody asked for `PageLifetime.neverKeyword`. Pages that
    /// predate expiry are not a second meaning — migration 2 gave them a real deadline as it
    /// added the column, which is why that backfill had to happen in the same migration.
    /// Once the column exists, a NULL is a decision rather than an absence of one.
    public var expiresAt: Date?
    /// The credential that last wrote this page, or nil for one written by the shared token
    /// or published before migration 3 added the column.
    ///
    /// Read back rather than write-only so attribution is *observable* — a column nothing
    /// ever selects is one whose writes no test can check, which is how it came to be
    /// unwritten in the first place. It is deliberately not served anywhere: `GET /:slug`
    /// answers with the body and its type, and who published a page is the operator's
    /// question, not the reader's.
    public var clientID: Int64?
}

public enum PageStoreError: Error, Equatable {
    /// The caller asked for a specific slug that is already taken.
    case slugTaken(Slug)
    /// The generator lost the collision race repeatedly. Effectively impossible unless
    /// the table has grown to a meaningful fraction of the keyspace.
    case couldNotAllocateSlug(attempts: Int)
}

/// All database access, and the schema's history along with it. Every statement here is
/// parameterised via PostgresNIO's interpolation, which binds values rather than splicing
/// them into SQL text.
public struct PageStore: Sendable {
    private let client: PostgresClient
    private let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    /// Fetches a page, or nil if no such slug exists — or if it has expired.
    public func fetch(slug: Slug) async throws -> Page? {
        // The deadline is tested in the query rather than by the caller, and that is the
        // whole correctness half of expiry. Reclamation only runs on upload, so a row can
        // outlive its `expires_at` by any amount of time; filtering here means a page stops
        // being served at exactly its deadline no matter when — or whether — anything gets
        // around to deleting it.
        let rows = try await client.query(
            """
            SELECT body, content_type, created_at, expires_at, client_id
            FROM pages WHERE slug = \(slug.value)
              AND (expires_at IS NULL OR expires_at > now())
            """,
            logger: logger
        )

        // `Date?`, not `Date`. Every page published with `?ttl=never` holds NULL here, so
        // decoding this as non-optional would compile, pass any test written against a page
        // with a deadline, and throw at runtime on precisely the pages someone chose to keep
        // forever. Version 2's backfill removed the *other* source of NULLs — pages older
        // than the column — but not this one, and this one is permanent by design.
        //
        // `client_id` is optional for a different reason and permanently so: the shared
        // token has no row to point at, and pages written before migration 3 have no owner
        // to name.
        for try await (body, contentType, createdAt, expiresAt, clientID) in rows.decode(
            (String, String, Date, Date?, Int64?).self, context: .default
        ) {
            return Page(
                slug: slug,
                body: body,
                contentType: contentType,
                createdAt: createdAt,
                expiresAt: expiresAt,
                clientID: clientID
            )
        }
        return nil
    }

    /// - Returns: true if the row was inserted, false if the slug was already taken.
    public func insert(
        slug: Slug, body: String, contentType: String, expiresAt: Date?, clientID: Int64?
    ) async throws -> Bool {
        // ON CONFLICT DO NOTHING makes the uniqueness check and the insert one atomic
        // step. Checking first and then inserting would leave a window where two
        // concurrent uploads both see the slug as free. Note that an *expired* row still
        // conflicts — it is a row — which is why `create` reclaims before it gets here.
        //
        // `client_id` is a foreign key into `clients`, so a nil here is the only way to
        // record a page whose writer has no row — the shared token's. `Client.attributableID`
        // is what turns that credential into the nil, upstream of this call.
        let rows = try await client.query(
            """
            INSERT INTO pages (slug, body, content_type, expires_at, client_id)
            VALUES (\(slug.value), \(body), \(contentType), \(expiresAt), \(clientID))
            ON CONFLICT (slug) DO NOTHING
            RETURNING slug
            """,
            logger: logger
        )

        for try await _ in rows.decode(String.self, context: .default) {
            return true
        }
        return false
    }

    /// - Returns: `.replaced` with the page's unchanged expiry, or `.noSuchPage` if no live
    ///   row exists at that slug.
    public func update(
        slug: Slug, body: String, contentType: String?, clientID: Int64?
    ) async throws -> PageUpdateOutcome {
        // A single UPDATE is its own existence check: the WHERE clause and the write are
        // one statement, and RETURNING tells us whether a row matched. `created_at` is
        // left alone, so a replaced page keeps the moment it was first published, and a
        // nil content type COALESCEs to the stored value rather than overwriting it.
        //
        // `expires_at` is left alone for exactly the reason `created_at` is: a replacement
        // is a new body at an old address, not a new page. If editing extended the deadline,
        // a link's lifetime would depend on how often somebody happened to touch it.
        //
        // `client_id` gets the opposite treatment to both, and deliberately: it is
        // *assigned* rather than left or COALESCEd. An absent content type means "the caller
        // expressed no opinion", whereas the writer is never absent — it is whoever's
        // credential just replaced these bytes. Coalescing it would leave a page attributed
        // to a credential that wrote none of what it now serves.
        //
        // The same expired-row exclusion the fetch uses appears here so that a PUT to an
        // expired-but-unreclaimed page is a 404 exactly as a GET of it is — the write
        // surface and the read surface agree on which pages exist.
        let rows = try await client.query(
            """
            UPDATE pages
            SET body = \(body),
                content_type = COALESCE(\(contentType), content_type),
                client_id = \(clientID)
            WHERE slug = \(slug.value)
              AND (expires_at IS NULL OR expires_at > now())
            RETURNING expires_at
            """,
            logger: logger
        )

        for try await expiresAt in rows.decode(Date?.self, context: .default) {
            return .replaced(expiresAt: expiresAt)
        }
        return .noSuchPage
    }

    /// Deletes every row whose deadline has passed, returning their slugs to the pool.
    ///
    /// - Returns: how many rows were removed.
    public func deleteExpired() async throws -> Int {
        // `expires_at <= now()` is the exact complement of the `expires_at > now()` the
        // reads use, so nothing this deletes was still visible and nothing visible is
        // deleted. The partial index on `expires_at` — `WHERE expires_at IS NOT NULL` —
        // is what keeps this cheap on a table that is mostly permanent pages.
        //
        // Counted by iterating `RETURNING slug` rather than read off a command tag:
        // `PostgresRowSequence` exposes no affected-row count, and the returned rows are
        // pages that no longer exist, so the sequence is only ever as long as the work was.
        let rows = try await client.query(
            """
            DELETE FROM pages
            WHERE expires_at IS NOT NULL AND expires_at <= now()
            RETURNING slug
            """,
            logger: logger
        )

        var deleted = 0
        for try await _ in rows.decode(String.self, context: .default) {
            deleted += 1
        }
        return deleted
    }
}

// MARK: - Schema migrations

extension PageStore {
    /// One versioned step in the schema's history.
    ///
    /// `statements` run in order, each as its own query: PostgresNIO speaks the extended
    /// query protocol, which refuses more than one command per message, so a migration is
    /// a list of statements rather than one semicolon-separated script. They are
    /// `PostgresQuery` literals with no interpolation on purpose — DDL cannot take bind
    /// parameters, and a `\(…)` inside one of these would become a *bind* rather than SQL
    /// text, failing loudly instead of doing what it looks like it does.
    ///
    /// Every migration runs inside a transaction, so the statements Postgres refuses to
    /// run in one — `CREATE INDEX CONCURRENTLY`, `VACUUM`, `ALTER SYSTEM` — cannot be
    /// expressed today. The per-migration transaction boundary is the seam where a
    /// `transactional: Bool = true` flag would go if one is ever needed; building it
    /// before there is a migration that wants it is ceremony.
    struct Migration: Sendable {
        let version: Int32
        let statements: [PostgresQuery]
    }

    /// The schema's entire history, in version order.
    ///
    /// **Append only.** An applied version is a fact recorded in every database that has
    /// ever booted this code; editing an entry diverges the databases that already ran it
    /// from the ones that haven't, with nothing to detect the difference. Change the
    /// schema by adding the next version — version 2 is what that looks like, and it is
    /// deliberately not another idempotent `ALTER` bolted onto version 1.
    ///
    /// The number is claimed by whatever merges first, and that is not a formality: two
    /// branches that both append a "version 3" produce databases where version 3 means two
    /// different things and `schema_migrations` cannot tell them apart. Rebasing onto a list
    /// that has grown means renumbering, not keeping the number the branch was written with.
    ///
    /// Statements are not limited to DDL. Because a version runs exactly once and commits
    /// with the row recording it, a data backfill belongs in a migration too and will run
    /// once, ever.
    static let migrations: [Migration] = [
        Migration(
            version: 1,
            statements: [
                // `IF NOT EXISTS` because version 1 is a retroactive description of a
                // schema that already exists in production, created by the idempotent
                // bootstrap this runner replaces. There, v1 must do nothing but record
                // itself; on a virgin database it must build the schema. That is what
                // makes the upgrade a deploy rather than a dump and restore.
                """
                CREATE TABLE IF NOT EXISTS pages (
                    slug         text PRIMARY KEY,
                    body         text NOT NULL,
                    content_type text NOT NULL,
                    created_at   timestamptz NOT NULL DEFAULT now()
                )
                """,
                "CREATE INDEX IF NOT EXISTS pages_created_at_idx ON pages (created_at DESC)",
            ]
        ),
        Migration(
            version: 2,
            statements: [
                // No `IF NOT EXISTS` here, unlike version 1. Version 1 needed it because it
                // retroactively described a schema that already existed in production;
                // version 2 has never run anywhere, so `schema_migrations` alone decides
                // whether it runs. A conditional form would hide a divergence rather than
                // fail on it.
                //
                // Nullable with no default. The nullability is the vocabulary — NULL means
                // "never expires" — and no default is what makes this a catalog-only change:
                // Postgres rewrites no rows for a nullable column with no default, so the
                // `ALTER` is instant on a table of any size.
                "ALTER TABLE pages ADD COLUMN expires_at timestamptz",
                // Existing pages become ephemeral too, and this statement is the only moment
                // in the schema's whole history when that can be said accurately. One
                // statement ago the column did not exist, so *every* NULL here is a page that
                // predates expiry. A backfill written any later could not tell those apart
                // from a page whose author asked for `never` — the two are the same value —
                // and would quietly put a deadline on pages someone had deliberately made
                // permanent.
                //
                // `now()`, not `created_at`: a page older than the default would otherwise
                // land with a deadline already in the past and be deleted by the next upload,
                // so a feature meant to bound storage would begin by destroying the archive
                // it was pointed at. Everything already published instead gets one full
                // default lifetime measured from the upgrade, which is also the only reading
                // under which nobody's link dies before they could have heard about it.
                //
                // The interval is written out rather than interpolated from
                // `PageLifetime.defaultDays`, and must stay that way. A migration is a record
                // of what was done once; if the default later becomes fourteen days, this
                // statement must still say seven, because seven days is what the databases
                // that already ran it actually wrote. Interpolating a constant here would
                // silently rewrite history every time the constant moved.
                "UPDATE pages SET expires_at = now() + interval '7 days' WHERE expires_at IS NULL",
                // Built last, after the backfill, so the `UPDATE` above has no index to
                // maintain while it runs.
                //
                // Partial, on exactly the predicate the reclaiming DELETE uses. Permanent
                // pages never enter the index at all, so a table that is mostly permanent
                // pages pays almost nothing to keep it — which is what makes running the
                // cleanup on every single upload affordable.
                """
                CREATE INDEX pages_expires_at_idx ON pages (expires_at)
                WHERE expires_at IS NOT NULL
                """,
            ]
        ),
        Migration(
            version: 3,
            statements: [
                // Per-client credentials. No `IF NOT EXISTS`: unlike version 1 this
                // describes a table that has never existed anywhere, so a name collision
                // is a mistake worth failing the boot over rather than a state to
                // tolerate.
                //
                // `token_hash` is the digest, never the token — see `ClientCredential`.
                // Its UNIQUE constraint is also the index the authentication lookup rides
                // on, which is what keeps that a hash comparison rather than a scan.
                //
                // The `'{publish}'` default is `ClientScope.publish` retyped, the one
                // place in the repo where that is unavoidable: these statements are
                // literal SQL by design — a `\(…)` here becomes a *bind* parameter, and
                // DDL cannot take binds. `MigrationListTests` pins the two together
                // instead.
                """
                CREATE TABLE clients (
                    id           bigserial PRIMARY KEY,
                    name         text NOT NULL UNIQUE,
                    token_hash   bytea NOT NULL UNIQUE,
                    scopes       text[] NOT NULL DEFAULT '{publish}',
                    created_at   timestamptz NOT NULL DEFAULT now(),
                    last_used_at timestamptz,
                    expires_at   timestamptz,
                    revoked_at   timestamptz
                )
                """,
                // Nullable, and left null for every page that already exists. Those were
                // written with the shared token and there is no honest owner to invent
                // for them. The column cannot be backfilled here either: `migrate()` runs
                // in the store layer and has no access to configuration, so it could not
                // hash `STELE_UPLOAD_TOKEN` into a `clients` row even if that were the
                // right answer — and keeping that separation is worth more than a tidier
                // backfill.
                "ALTER TABLE pages ADD COLUMN client_id bigint REFERENCES clients (id)",
            ]
        ),
        Migration(
            version: 4,
            statements: [
                // Version 3 made `name` unique across the whole table, and rows are never
                // deleted — so revoking `claude-code` retired that name permanently and the
                // replacement had to be called `claude-code-2`. Rotation is the ordinary
                // reason to revoke, and a name that survives it is the whole point of having
                // one: it is the handle `DELETE /admin/clients/:name` addresses and the
                // string an operator recognises in a listing.
                //
                // Uniqueness moves to the live rows rather than being dropped. Two *usable*
                // credentials sharing a name would make revocation ambiguous at exactly the
                // wrong moment, which is the thing version 3 was right about; the history
                // beside them is what an incident is reconstructed from and does not need to
                // be unique to be read. `ClientStore.revoke` is what resolves the resulting
                // several-rows-one-name to a single row — live first, newest revocation
                // otherwise.
                //
                // The constraint is dropped by the name Postgres generates for a column-level
                // UNIQUE (`<table>_<column>_key`), not by one version 3 chose. No
                // `IF EXISTS`: on any database that ran version 3 it is there, and on one
                // where it is not, something has edited the schema by hand and the boot
                // should say so.
                "ALTER TABLE clients DROP CONSTRAINT clients_name_key",
                """
                CREATE UNIQUE INDEX clients_live_name_idx
                ON clients (name) WHERE revoked_at IS NULL
                """,
            ]
        ),
    ]

    /// Advisory locks are scoped to a database, so this constant only ever collides with
    /// another stele booting against the same database — which is exactly what it's for.
    /// Typed `Int64` to select `pg_advisory_lock(bigint)` rather than the `(int4, int4)`
    /// overload.
    ///
    /// Internal rather than private so the Postgres test suite can assert from a second
    /// session that the lock was released.
    static let migrationLockKey: Int64 = 0x5354_454C_4501  // "STELE" + 01

    /// Brings the database up to the newest schema version, applying only what it has not
    /// already applied.
    ///
    /// Still runs on every boot; there is still no separate migrate step. Two things make
    /// that safe. Each migration and the row recording it commit in one transaction, so
    /// "applied but unrecorded" is not a state the database can be left in. And the whole
    /// run holds a session-level advisory lock, so two instances starting at once
    /// serialise and the loser finds the work already done.
    public func migrate() async throws {
        try await migrate(Self.migrations)
    }

    /// The runner proper. Takes its list as a parameter so tests can drive it with
    /// migrations that aren't the real schema.
    func migrate(_ migrations: [Migration]) async throws {
        // One leased connection for the whole run: `pg_advisory_lock` is session-scoped,
        // and `client.query` leases a different connection per call, so a lock taken that
        // way would be held by an arbitrary pooled connection and released whenever that
        // connection happened to close.
        let newestVersion = try await client.withConnection { connection in
            // `pg_advisory_lock` waits indefinitely. That is the wanted behaviour during a
            // rolling restart — the second instance should wait for the first, not fail
            // its boot — but it means a wedged holder hangs this one before it ever binds
            // its port. This line is what makes that diagnosable in one grep.
            logger.info("acquiring the migration lock")
            try await connection.query(
                "SELECT pg_advisory_lock(\(Self.migrationLockKey))", logger: logger
            )
            let newestVersion: Int32?
            do {
                newestVersion = try await apply(migrations, on: connection)
            } catch {
                // The pool hands a connection back without resetting its session state, so
                // a lock left held would outlive this boot and block the next one. `defer`
                // cannot `await`, so the unlock lives on both exits explicitly. If this one
                // also fails the connection is already broken, and the backend's disconnect
                // releases the lock server-side.
                _ = try? await connection.query(
                    "SELECT pg_advisory_unlock(\(Self.migrationLockKey))", logger: logger
                )
                throw error
            }
            try await connection.query(
                "SELECT pg_advisory_unlock(\(Self.migrationLockKey))", logger: logger
            )
            return newestVersion
        }
        // Which schema version a running instance believes it is on, stated once per boot.
        // During an incident that is the first thing worth knowing and the last thing
        // anyone wants to derive by reading the deployed tag.
        logger.info(
            "schema migrations up to date",
            metadata: ["version": "\(newestVersion.map(String.init) ?? "none")"]
        )
    }

    /// - Returns: the newest version recorded in `schema_migrations` once the run is done,
    ///   or nil if the list was empty and the database has never had a migration applied.
    private func apply(
        _ migrations: [Migration], on connection: PostgresConnection
    ) async throws -> Int32? {
        // Inside the lock, not before it. `CREATE TABLE IF NOT EXISTS` is not atomic —
        // two sessions can both pass the existence check and one then fails on the
        // catalog's unique index — and reading the applied versions before the lock would
        // let a waiting boot act on a snapshot the winner has since changed. (The
        // bootstrap this replaces had that first race on `pages`; the lock closes it.)
        try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version    integer PRIMARY KEY,
                applied_at timestamptz NOT NULL DEFAULT now()
            )
            """,
            logger: logger
        )

        var applied = Set<Int32>()
        let rows = try await connection.query(
            "SELECT version FROM schema_migrations", logger: logger
        )
        for try await version in rows.decode(Int32.self, context: .default) {
            applied.insert(version)
        }

        // An older binary booting against a newer database does nothing — it only
        // iterates its own list — which is right, but silent. Say it out loud: this is
        // exactly the situation an operator wants named during a rollback.
        let newestInBuild = migrations.last?.version ?? 0
        if let newestApplied = applied.max(), newestApplied > newestInBuild {
            logger.warning(
                "database schema is newer than this build",
                metadata: ["database": "\(newestApplied)", "build": "\(newestInBuild)"]
            )
        }

        for migration in migrations where !applied.contains(migration.version) {
            // Logged before the transaction because `withTransaction` wraps failures in
            // `PostgresTransactionError`; without this line a failed boot's log has a
            // wrapped error and no indication of which version failed.
            logger.info("applying migration", metadata: ["version": "\(migration.version)"])
            // Statements and version row commit or roll back together. That is the whole
            // exactly-once guarantee: a half-applied migration leaves no version row and
            // is retried; a recorded version means every statement landed, including a
            // one-shot data backfill.
            try await connection.withTransaction(logger: logger) { transaction in
                for statement in migration.statements {
                    try await transaction.query(statement, logger: logger)
                }
                try await transaction.query(
                    "INSERT INTO schema_migrations (version) VALUES (\(migration.version))",
                    logger: logger
                )
            }
            applied.insert(migration.version)
        }

        return applied.max()
    }
}

/// `PageStore` is the database-backed conformer of the seam the router talks to. Only
/// the storage primitives — insert-if-free, update-if-present, delete-what-has-expired —
/// live here; the retry policy, the requested-slug policy and the order reclamation runs
/// in come from `PageStoring`'s extension, shared with every other conformer.
extension PageStore: PageStoring {}
