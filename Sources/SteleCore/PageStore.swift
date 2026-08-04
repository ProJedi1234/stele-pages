import Foundation
import Logging
import PostgresNIO

/// A stored page, as read back from the database.
public struct Page: Sendable, Equatable {
    public var slug: Slug
    public var body: String
    public var contentType: String
    public var createdAt: Date
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

    /// Fetches a page, or nil if no such slug exists.
    public func fetch(slug: Slug) async throws -> Page? {
        let rows = try await client.query(
            """
            SELECT body, content_type, created_at
            FROM pages WHERE slug = \(slug.value)
            """,
            logger: logger
        )

        for try await (body, contentType, createdAt) in rows.decode(
            (String, String, Date).self, context: .default
        ) {
            return Page(slug: slug, body: body, contentType: contentType, createdAt: createdAt)
        }
        return nil
    }

    /// - Returns: true if the row was inserted, false if the slug was already taken.
    public func insert(slug: Slug, body: String, contentType: String) async throws -> Bool {
        // ON CONFLICT DO NOTHING makes the uniqueness check and the insert one atomic
        // step. Checking first and then inserting would leave a window where two
        // concurrent uploads both see the slug as free.
        let rows = try await client.query(
            """
            INSERT INTO pages (slug, body, content_type)
            VALUES (\(slug.value), \(body), \(contentType))
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

    /// - Returns: true if the row was replaced, false if no such slug exists.
    public func update(slug: Slug, body: String, contentType: String?) async throws -> Bool {
        // A single UPDATE is its own existence check: the WHERE clause and the write are
        // one statement, and RETURNING tells us whether a row matched. `created_at` is
        // left alone, so a replaced page keeps the moment it was first published, and a
        // nil content type COALESCEs to the stored value rather than overwriting it.
        let rows = try await client.query(
            """
            UPDATE pages SET body = \(body), content_type = COALESCE(\(contentType), content_type)
            WHERE slug = \(slug.value)
            RETURNING slug
            """,
            logger: logger
        )

        for try await _ in rows.decode(String.self, context: .default) {
            return true
        }
        return false
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
    /// schema by adding the next version. Issue #6's TTL column ships as
    /// `Migration(version: 2, statements: ["ALTER TABLE pages ADD COLUMN expires_at
    /// timestamptz"])`, not as another idempotent `ALTER` bolted onto version 1.
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
        )
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
/// the storage primitives — insert-if-free and update-if-present — live here; the retry
/// and requested-slug policy come from `PageStoring`'s extension, shared with every
/// other conformer.
extension PageStore: PageStoring {}
