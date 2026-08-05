import Foundation
import Logging
import PostgresNIO
import Testing

@testable import SteleCore

// The only suite in this repo that needs a real Postgres. Everything the migration runner
// claims — that `CREATE TABLE IF NOT EXISTS` makes version 1 a no-op on a database that
// predates the version table, that a failed migration leaves no version row, that an
// advisory lock serialises two instances booting at once — is a statement about Postgres
// behaviour, and there is no way to assert it against a fake.
//
// **This suite creates and drops schemas on whatever cluster `STELE_TEST_DATABASE_URL`
// points at.** That is a deliberately different variable from `DATABASE_URL`: the local
// compose project name is pinned and its volume is shared across worktrees, so a suite
// that drops objects must not be one exported variable away from the developer's own
// pages. Point it at the maintenance database:
//
//     docker compose up -d postgres
//     STELE_TEST_DATABASE_URL=postgres://stele:stele_dev_password@localhost:5432/postgres swift test
//
// Without the variable the suite is disabled and a plain `swift test` stays hermetic.

/// Everything the Postgres suite needs to build clients and throwaway schemas.
enum PostgresFixture {
    static let databaseURL = ProcessInfo.processInfo.environment["STELE_TEST_DATABASE_URL"]
    static var isConfigured: Bool { databaseURL != nil }

    /// Quiet on purpose. A passing run of this suite would otherwise print a few hundred
    /// lines of connection-pool chatter around the assertions that matter.
    static let logger: Logger = {
        var logger = Logger(label: "stele.tests.postgres")
        logger.logLevel = .critical
        return logger
    }()

    /// The state one test runs against: its own schema, clients pinned to it, and a
    /// client that is not.
    struct Database {
        /// Pinned to `schema` via the connection startup packet, so `pages` and
        /// `schema_migrations` are this test's alone.
        let clients: [PostgresClient]
        /// Default `search_path`, and therefore the second session an assertion about
        /// session state — a held advisory lock — has to be made from.
        let bootstrap: PostgresClient
        let schema: String

        var client: PostgresClient { clients[0] }
        var store: PageStore { PageStore(client: client, logger: PostgresFixture.logger) }
    }

    /// Runs `body` against a freshly created, empty schema, and drops it afterwards.
    ///
    /// Isolation is a schema rather than a database because `CREATE SCHEMA` is cheap and
    /// `additionalStartupParameters` can pin `search_path` for every connection a client
    /// opens, which makes the store's unqualified `pages` land in the right place with no
    /// change to `PageStore`. A per-test database would isolate more and cost a template
    /// copy per test; the one thing it would additionally isolate — the advisory lock,
    /// which is scoped to the database and not the schema — is handled by running this
    /// suite serialised instead.
    ///
    /// - Parameter clients: how many independent clients the body gets. Only the
    ///   concurrency test needs two; a second client is what makes two `migrate` calls
    ///   genuinely contend rather than share a pool.
    static func withThrowawaySchema(
        clients count: Int = 1,
        _ body: (Database) async throws -> Void
    ) async throws {
        let url = try #require(databaseURL)
        let (configuration, _) = try Configuration.parseDatabaseURL(url)
        // Generated here and never taken from input, but quoted at every use anyway — a
        // schema name cannot be a bind parameter, so this is the one place in the repo
        // where an identifier is spliced into SQL text.
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        let schema = "stele_test_\(suffix)"

        var bootstrapConfiguration = configuration
        bootstrapConfiguration.options.maximumConnections = 2
        var pinnedConfiguration = configuration
        pinnedConfiguration.options.maximumConnections = 4
        pinnedConfiguration.options.additionalStartupParameters = [("search_path", schema)]

        let bootstrap = PostgresClient(
            configuration: bootstrapConfiguration, backgroundLogger: logger
        )
        let clients = (0..<count).map { _ in
            PostgresClient(configuration: pinnedConfiguration, backgroundLogger: logger)
        }

        // Unstructured tasks rather than a task group: `run()` has to be live for the
        // whole helper, and `cancel()` is synchronous, so `defer` can shut them down on
        // every exit path — which a task group's `cancelAll` cannot do around a throwing
        // body without re-plumbing the result by hand.
        let runners = ([bootstrap] + clients).map { client in Task { await client.run() } }
        defer { runners.forEach { $0.cancel() } }

        try await bootstrap.query(
            PostgresQuery(unsafeSQL: #"CREATE SCHEMA "\#(schema)""#), logger: logger
        )
        let result: Result<Void, any Error>
        do {
            try await body(Database(clients: clients, bootstrap: bootstrap, schema: schema))
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // Runs before the failure is rethrown, so a failing assertion still leaves the
        // cluster as it found it.
        _ = try? await bootstrap.query(
            PostgresQuery(unsafeSQL: #"DROP SCHEMA "\#(schema)" CASCADE"#), logger: logger
        )
        try result.get()
    }

    /// First column of the first row, or nil if the query returned none.
    static func scalar<Value: PostgresDecodable & Sendable>(
        _ query: PostgresQuery, as type: Value.Type = Value.self, on client: PostgresClient
    ) async throws -> Value? {
        for try await value in try await client.query(query, logger: logger)
            .decode(Value.self, context: .default)
        {
            return value
        }
        return nil
    }

    /// First column of every row, in the order the query returned them.
    static func column<Value: PostgresDecodable & Sendable>(
        _ query: PostgresQuery, as type: Value.Type = Value.self, on client: PostgresClient
    ) async throws -> [Value] {
        var values: [Value] = []
        for try await value in try await client.query(query, logger: logger)
            .decode(Value.self, context: .default)
        {
            values.append(value)
        }
        return values
    }

    static func appliedVersions(on client: PostgresClient) async throws -> [Int32] {
        try await column("SELECT version FROM schema_migrations ORDER BY version", on: client)
    }

    /// Whether the migration lock is free, asked from a session that is not the store's.
    ///
    /// `pg_try_advisory_lock` is the only way to observe this: the lock is session state,
    /// and PostgresNIO's pool does not reset a connection when it is released, so a lock
    /// the runner forgot to drop would ride back into the pool and block the next boot.
    static func migrationLockIsFree(on client: PostgresClient) async throws -> Bool {
        try await client.withConnection { connection in
            let rows = try await connection.query(
                "SELECT pg_try_advisory_lock(\(PageStore.migrationLockKey))", logger: logger
            )
            var acquired = false
            for try await value in rows.decode(Bool.self, context: .default) { acquired = value }
            if acquired {
                try await connection.query(
                    "SELECT pg_advisory_unlock(\(PageStore.migrationLockKey))", logger: logger
                )
            }
            return acquired
        }
    }
}

/// Serialised, not parallel like every other suite here. Postgres advisory locks are
/// scoped to the *database*, which per-test schemas do not divide, so two migration runs
/// overlapping across tests would contend on the real lock key — harmless for the runner,
/// fatal for the test that asserts the lock is free.
@Suite(
    "PageStore against Postgres",
    .enabled(if: PostgresFixture.isConfigured),
    .serialized
)
struct PageStoreDatabaseTests {
    /// What version 1 produces when there was nothing there before. The runner's own
    /// `IF NOT EXISTS` forms mean a wrong shape would never announce itself — this is the
    /// only place the schema's actual columns, constraints and index are pinned.
    @Test func virginDatabaseGetsTheVersionOneSchema() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate()

            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [1])

            var columns: [String: (type: String, nullable: String)] = [:]
            let rows = try await database.client.query(
                """
                SELECT column_name, data_type, is_nullable FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'pages'
                """,
                logger: PostgresFixture.logger
            )
            for try await (name, type, nullable) in rows.decode(
                (String, String, String).self, context: .default
            ) {
                columns[name] = (type, nullable)
            }
            #expect(Set(columns.keys) == ["slug", "body", "content_type", "created_at"])
            #expect(columns["slug"]?.type == "text")
            #expect(columns["body"]?.type == "text")
            #expect(columns["content_type"]?.type == "text")
            #expect(columns["created_at"]?.type == "timestamp with time zone")
            #expect(columns.values.allSatisfy { $0.nullable == "NO" })

            // The primary key, asked for separately because nothing above implies it:
            // `is_nullable = NO` is equally true of a bare `NOT NULL`, so a version 1 that
            // lost `PRIMARY KEY` would satisfy every assertion so far. `insert`'s
            // `ON CONFLICT (slug)` hard-depends on a unique index over exactly that
            // column; without one every upload fails at runtime with 42P10 on a database
            // built from this migration, and only on a *virgin* one — the `IF NOT EXISTS`
            // hides it everywhere else, which is the reason this test exists.
            let primaryKeyColumns: [String] = try await PostgresFixture.column(
                """
                SELECT attribute.attname
                FROM pg_constraint AS constraint_
                JOIN pg_attribute AS attribute
                  ON attribute.attrelid = constraint_.conrelid
                 AND attribute.attnum = ANY (constraint_.conkey)
                WHERE constraint_.conrelid = 'pages'::regclass
                  AND constraint_.contype = 'p'
                ORDER BY attribute.attname
                """,
                on: database.client
            )
            #expect(primaryKeyColumns == ["slug"])

            let createdAtDefault = try await PostgresFixture.scalar(
                """
                SELECT column_default FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'pages'
                  AND column_name = 'created_at'
                """,
                as: String.self, on: database.client
            )
            #expect(createdAtDefault?.contains("now()") == true)

            let indexDefinition = try await PostgresFixture.scalar(
                """
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = \(database.schema) AND indexname = 'pages_created_at_idx'
                """,
                as: String.self, on: database.client
            )
            #expect(indexDefinition?.contains("created_at DESC") == true)
        }
    }

    /// The production upgrade, proved without a dump and restore.
    ///
    /// The DDL below is a verbatim snapshot of the bootstrap `migrate()` this runner
    /// replaced, so the fixture is a database in exactly the state every live deployment
    /// is in today: the right tables, and no `schema_migrations` at all. Booting the new
    /// code must record version 1, run nothing, and leave the existing rows — including
    /// `created_at`, the one column an accidental table rewrite would disturb — untouched.
    @Test func upgradesADatabaseCreatedByTheOldBootstrap() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.client.query(
                """
                CREATE TABLE IF NOT EXISTS pages (
                    slug         text PRIMARY KEY,
                    body         text NOT NULL,
                    content_type text NOT NULL,
                    created_at   timestamptz NOT NULL DEFAULT now()
                )
                """,
                logger: PostgresFixture.logger
            )
            try await database.client.query(
                "CREATE INDEX IF NOT EXISTS pages_created_at_idx ON pages (created_at DESC)",
                logger: PostgresFixture.logger
            )
            try await database.client.query(
                """
                INSERT INTO pages (slug, body, content_type)
                VALUES ('quiet-cedar-otter', '<h1>before</h1>', 'text/html')
                """,
                logger: PostgresFixture.logger
            )
            let createdAtBefore = try await PostgresFixture.scalar(
                "SELECT created_at FROM pages WHERE slug = 'quiet-cedar-otter'",
                as: Date.self, on: database.client
            )

            try await database.store.migrate()

            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [1])
            let page = try await database.store.fetch(slug: Slug(unchecked: "quiet-cedar-otter"))
            #expect(page?.body == "<h1>before</h1>")
            #expect(page?.contentType == "text/html")
            #expect(page?.createdAt == createdAtBefore)
        }
    }

    /// Genuine skipping, not "a re-insert that happened to bounce off the primary key":
    /// `applied_at` is written by the row that records a migration, so an unchanged
    /// timestamp is proof the second run never entered the transaction.
    @Test func reRunAppliesNothingAndLeavesAppliedAtAlone() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate()
            let appliedAt = try await PostgresFixture.scalar(
                "SELECT applied_at FROM schema_migrations WHERE version = 1",
                as: Date.self, on: database.client
            )

            try await database.store.migrate()

            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [1])
            let appliedAtAfter = try await PostgresFixture.scalar(
                "SELECT applied_at FROM schema_migrations WHERE version = 1",
                as: Date.self, on: database.client
            )
            #expect(appliedAtAfter == appliedAt)
        }
    }

    /// Order and skip together, through the `migrate(_:)` seam so the assertions can be
    /// about migrations rather than about the real schema.
    ///
    /// Version 2 only succeeds if version 1 ran first, which is the order claim. The
    /// second run then appends a version and must leave the earlier ones alone — if it
    /// re-ran version 2 the probe table would hold two rows.
    @Test func appliesInOrderAndSkipsWhatIsAlreadyApplied() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let store = database.store
            let first = PageStore.Migration(
                version: 1, statements: ["CREATE TABLE probe (id integer)"]
            )
            let second = PageStore.Migration(
                version: 2, statements: ["INSERT INTO probe (id) VALUES (1)"]
            )
            let third = PageStore.Migration(
                version: 3, statements: ["CREATE TABLE probe_two (id integer)"]
            )

            try await store.migrate([first, second])
            let afterFirstRun = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(afterFirstRun == [1, 2])
            let probeRows = try await PostgresFixture.scalar(
                "SELECT count(*) FROM probe", as: Int.self, on: database.client
            )
            #expect(probeRows == 1)

            try await store.migrate([first, second, third])
            let afterSecondRun = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(afterSecondRun == [1, 2, 3])
            let probeRowsAgain = try await PostgresFixture.scalar(
                "SELECT count(*) FROM probe", as: Int.self, on: database.client
            )
            #expect(probeRowsAgain == 1)
            let probeTwoExists = try await PostgresFixture.scalar(
                "SELECT to_regclass('probe_two') IS NOT NULL",
                as: Bool.self, on: database.client
            )
            #expect(probeTwoExists == true)
        }
    }

    /// A migration whose only statement is DML runs exactly once, ever. This is the
    /// property that makes a data backfill a legitimate migration rather than something
    /// that needs a one-off script and a note in the runbook.
    @Test func aDataBackfillRunsExactlyOnce() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.client.query(
                "CREATE TABLE counters (name text PRIMARY KEY, n integer NOT NULL)",
                logger: PostgresFixture.logger
            )
            try await database.client.query(
                "INSERT INTO counters (name, n) VALUES ('backfill', 0)",
                logger: PostgresFixture.logger
            )

            let backfill = PageStore.Migration(
                version: 1, statements: ["UPDATE counters SET n = n + 1 WHERE name = 'backfill'"]
            )
            try await database.store.migrate([backfill])
            try await database.store.migrate([backfill])

            let counter = try await PostgresFixture.scalar(
                "SELECT n FROM counters WHERE name = 'backfill'",
                as: Int32.self, on: database.client
            )
            #expect(counter == 1)
        }
    }

    /// A failing statement rolls back everything the migration did *and* the row that
    /// would have recorded it, so the next boot retries the whole thing. "Applied but
    /// unrecorded" is the state this test exists to rule out.
    ///
    /// It asserts *that* it throws rather than what: the error arrives wrapped in
    /// `PostgresTransactionError`, and pinning the wrapper's shape would be a test of
    /// PostgresNIO.
    @Test func aFailedMigrationLeavesNoTraceOfItself() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let broken = PageStore.Migration(
                version: 1,
                statements: [
                    "CREATE TABLE ok (id integer)",
                    "THIS IS NOT SQL",
                ]
            )

            await #expect(throws: (any Error).self) {
                try await database.store.migrate([broken])
            }

            let tableIsAbsent = try await PostgresFixture.scalar(
                "SELECT to_regclass('ok') IS NULL", as: Bool.self, on: database.client
            )
            #expect(tableIsAbsent == true)
            // `schema_migrations` itself survives — it is created outside the migration's
            // transaction — but must be empty.
            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [])
        }
    }

    /// Two instances booting at once, which is what a rolling restart looks like.
    ///
    /// The DDL deliberately has no `IF NOT EXISTS` and is preceded by a slow statement, so
    /// an unserialised second run would read an empty `schema_migrations`, re-run the
    /// migration, and die on `42P07 duplicate table`. Both returning, with one version row
    /// between them, is the whole claim. This also fails loudly if anyone ever moves the
    /// applied-versions read outside the lock.
    @Test func concurrentRunsSerialiseOnTheAdvisoryLock() async throws {
        try await PostgresFixture.withThrowawaySchema(clients: 2) { database in
            let migration = PageStore.Migration(
                version: 1,
                statements: [
                    "SELECT pg_sleep(0.5)",
                    "CREATE TABLE probe (id integer)",
                ]
            )
            let first = PageStore(client: database.clients[0], logger: PostgresFixture.logger)
            let second = PageStore(client: database.clients[1], logger: PostgresFixture.logger)

            async let firstRun: Void = first.migrate([migration])
            async let secondRun: Void = second.migrate([migration])
            try await firstRun
            try await secondRun

            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [1])
        }
    }

    /// The lock is released on the success path and on the failure path.
    ///
    /// Both matter equally: the pool does not reset session state, so a lock left held
    /// rides the connection back into the pool and the *next* boot hangs on it forever
    /// with no error anywhere to explain why.
    @Test func theLockIsReleasedWhetherTheRunSucceedsOrFails() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate()
            let freeAfterSuccess = try await PostgresFixture.migrationLockIsFree(
                on: database.bootstrap
            )
            #expect(freeAfterSuccess)

            let broken = PageStore.Migration(version: 2, statements: ["THIS IS NOT SQL"])
            await #expect(throws: (any Error).self) {
                try await database.store.migrate([broken])
            }
            let freeAfterFailure = try await PostgresFixture.migrationLockIsFree(
                on: database.bootstrap
            )
            #expect(freeAfterFailure)
        }
    }

    /// The one storage primitive here that is not about the migration runner, because
    /// everything it promises is a claim about a SQL statement and not about Swift.
    ///
    /// `delete`'s `Bool` is the router's entire 204-versus-404 decision, and it comes from
    /// `DELETE … RETURNING slug` yielding a row or not. The in-memory fake gets that for
    /// free from `removeValue`, which means every HTTP test in the suite is asserting the
    /// dictionary's honesty rather than the statement's: a `RETURNING` clause that reported
    /// on a slug it had not removed, or reported nothing on one it had, would pass all of
    /// them. The re-delete is the half worth the round trip — "no row matched" has to be
    /// distinguishable from "a row matched", not merely absent.
    ///
    /// Two rows, not one, and that is the point of the bystander. With a single row in the
    /// schema, "the addressed row matched" and "every row matched" are the same
    /// observation: `DELETE FROM pages` with the `WHERE` clause dropped, or widened to a
    /// `LIKE` prefix, would satisfy every other assertion here — and `removeValue(forKey:)`
    /// cannot express that bug at all, so nothing else in the repo would see it either. The
    /// surviving page is what makes the predicate load-bearing, and one deployed `DELETE`
    /// that emptied the table is the failure nobody can undo.
    ///
    /// The re-claim at the end is the other property the hard delete rests on, asserted
    /// where it is not tautological: the fake frees the key by construction, whereas here a
    /// `deleted_at` column and an `UPDATE` in place of the `DELETE` would still read back
    /// as absent while `ON CONFLICT DO NOTHING` bounced off the tombstone — a 409 on
    /// republish, in production, with the whole suite green.
    ///
    /// `insert`, `fetch` and `update` are otherwise still the standing gap; this closes it
    /// for `delete` alone, and leans on them only as far as the delete's own claims need.
    @Test func deleteReportsWhetherARowWasRemoved() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let store = database.store
            try await store.migrate()
            let slug = try Slug(custom: "quiet-cedar-otter")
            let bystander = try Slug(custom: "amber-willow-heron")

            let inserted = try await store.insert(
                slug: slug, body: "<h1>here</h1>", contentType: PageContentType.default
            )
            #expect(inserted)
            let insertedBystander = try await store.insert(
                slug: bystander, body: "<h1>elsewhere</h1>", contentType: PageContentType.default
            )
            #expect(insertedBystander)

            let removed = try await store.delete(slug: slug)
            #expect(removed)
            // Hard, as advertised: the row is not filtered out of a read, it is gone.
            let afterDelete = try await store.fetch(slug: slug)
            #expect(afterDelete == nil)
            // And the statement removed the row it was addressed at, not the table.
            let survivor = try await store.fetch(slug: bystander)
            #expect(survivor?.body == "<h1>elsewhere</h1>")

            let removedAgain = try await store.delete(slug: slug)
            #expect(removedAgain == false)

            // The freed slug, claimed again against a real primary key.
            let reclaimed = try await store.insert(
                slug: slug, body: "<h1>second tenant</h1>", contentType: PageContentType.default
            )
            #expect(reclaimed)
            let republished = try await store.fetch(slug: slug)
            #expect(republished?.body == "<h1>second tenant</h1>")
        }
    }
}
