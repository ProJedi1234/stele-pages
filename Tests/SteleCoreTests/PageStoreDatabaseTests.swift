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
        var clientStore: ClientStore {
            ClientStore(client: client, logger: PostgresFixture.logger)
        }
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
    ///
    /// Runs version 1 *alone*, through the `migrate(_:)` seam, so the assertions stay
    /// about what version 1 produces as the list grows past it. Every later version is
    /// pinned by its own test, and the full-list boot is covered by
    /// `migrationFourMovesNameUniquenessOntoLiveRows` and by
    /// `upgradesADatabaseCreatedByTheOldBootstrap`.
    @Test func virginDatabaseGetsTheVersionOneSchema() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate(Array(PageStore.migrations.prefix(1)))

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

    /// What version 2 adds, driven with a two-version prefix so the assertions stay about
    /// version 2 as the list grows past it — the same treatment version 1's test gets, and for
    /// the same reason. That the shipped list actually *reaches* current is pinned by
    /// `upgradesADatabaseCreatedByTheOldBootstrap`, against the list rather than a literal.
    ///
    /// Three things, each of which fails silently on its own. The column has to exist, or
    /// every query in `PageStore` errors on boot. It has to be **nullable**, because NULL is
    /// how a permanent page is stored and a `NOT NULL` column would force every page to
    /// carry a deadline. And the index has to be **partial** — asserting only its name would
    /// pass on a full index over `expires_at`, which is the same index over a table's worth
    /// of NULLs for permanent pages, quietly paying for what the `WHERE` clause was added to
    /// avoid.
    @Test func virginDatabaseGetsTheVersionTwoExpiryColumnAndPartialIndex() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate(Array(PageStore.migrations.prefix(2)))

            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [1, 2])

            let expiresAt = try await PostgresFixture.scalar(
                """
                SELECT data_type || ' ' || is_nullable FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'pages'
                  AND column_name = 'expires_at'
                """,
                as: String.self, on: database.client
            )
            #expect(expiresAt == "timestamp with time zone YES")

            // No default either: a default would give every future row a deadline the caller
            // never chose, and `ttl=never` would have nothing to store.
            let expiresAtDefault = try await PostgresFixture.scalar(
                """
                SELECT column_default IS NULL FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'pages'
                  AND column_name = 'expires_at'
                """,
                as: Bool.self, on: database.client
            )
            #expect(expiresAtDefault == true)

            let indexDefinition = try await PostgresFixture.scalar(
                """
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = \(database.schema) AND indexname = 'pages_expires_at_idx'
                """,
                as: String.self, on: database.client
            )
            #expect(indexDefinition?.contains("(expires_at)") == true)
            #expect(indexDefinition?.contains("WHERE (expires_at IS NOT NULL)") == true)
        }
    }

    /// The production upgrade, proved without a dump and restore.
    ///
    /// The DDL below is a verbatim snapshot of the bootstrap `migrate()` this runner
    /// replaced, so the fixture is a database in exactly the state every live deployment
    /// is in today: the right tables, and no `schema_migrations` at all. Booting the new
    /// code must record version 1, run nothing for it, apply version 2, and leave the
    /// existing rows — including `created_at`, the one column an accidental table rewrite
    /// would disturb — untouched.
    ///
    /// This is also where version 2's backfill is proved, and it is the only place it can be:
    /// the statement only does anything to rows that were already there when the column
    /// appeared, which is a state no other test can construct. The page inserted before
    /// migrating must come back with a deadline about a week out — not NULL, which would mean
    /// the backfill never ran and every existing deployment kept an unbounded archive, and not
    /// a date in the past, which would mean the interval was measured from `created_at` and
    /// the next upload would delete pages the upgrade was supposed to preserve.
    ///
    /// "Still served" is the other load-bearing half. The fetch now filters on the deadline,
    /// so a backfill that wrote a bad instant would make every page on a live deployment
    /// vanish on the first boot after this deploy, and the assertion on the body is what
    /// notices.
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

            // The whole list, named by the list rather than by a literal: this test is about
            // an old database catching up to *current*, so appending a version must extend
            // what it expects rather than fail it.
            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == PageStore.migrations.map(\.version))
            let page = try await database.store.fetch(slug: Slug(unchecked: "quiet-cedar-otter"))
            #expect(page?.body == "<h1>before</h1>")
            #expect(page?.contentType == "text/html")
            #expect(page?.createdAt == createdAtBefore)
            // Expiring in a week, not permanent. The window is generous because the assertion
            // is about *which* instant the backfill chose, and the two wrong choices are far
            // outside it: a NULL fails the unwrap, and `created_at + 7 days` on a row inserted
            // moments ago would land a whole week earlier than this range starts.
            let deadline = try #require(page?.expiresAt)
            let expected = Date().addingTimeInterval(
                Double(PageLifetime.defaultDays) * PageLifetime.secondsPerDay
            )
            #expect(abs(deadline.timeIntervalSince(expected)) < 60)
            // And it is a real deadline rather than a formality: the same row read back
            // through the deadline-filtering fetch is still served today.
            #expect(deadline > Date())
        }
    }

    /// What version 3 adds, asserted on a database that already had pages in it — which
    /// is the only interesting case, since a page written before credentials existed has
    /// no owner to attribute it to and must survive the migration saying so.
    ///
    /// `token_hash`'s UNIQUE constraint is the one checked by name: it is both the
    /// integrity rule that stops two credentials sharing a digest *and* the index the
    /// authentication lookup rides on, so losing it degrades every authenticated request
    /// to a sequential scan without failing anything.
    ///
    /// Driven with a three-version prefix rather than the whole list, because version 4
    /// deliberately replaces the `name` constraint asserted below — running to current here
    /// would make this test fail for the one reason that is not a regression.
    @Test func migrationThreeAddsCredentialsAndLeavesExistingPagesUnowned() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate(Array(PageStore.migrations.prefix(1)))
            try await database.client.query(
                """
                INSERT INTO pages (slug, body, content_type)
                VALUES ('quiet-cedar-otter', '<h1>before</h1>', 'text/html')
                """,
                logger: PostgresFixture.logger
            )

            try await database.store.migrate(Array(PageStore.migrations.prefix(3)))

            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == [1, 2, 3])

            var columns: [String: (type: String, nullable: String)] = [:]
            let rows = try await database.client.query(
                """
                SELECT column_name, data_type, is_nullable FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'clients'
                """,
                logger: PostgresFixture.logger
            )
            for try await (name, type, nullable) in rows.decode(
                (String, String, String).self, context: .default
            ) {
                columns[name] = (type, nullable)
            }
            #expect(
                Set(columns.keys) == [
                    "id", "name", "token_hash", "scopes",
                    "created_at", "last_used_at", "expires_at", "revoked_at",
                ]
            )
            #expect(columns["id"]?.type == "bigint")
            #expect(columns["name"]?.type == "text")
            #expect(columns["token_hash"]?.type == "bytea")
            // information_schema reports every array as "ARRAY"; the element type lives in
            // `udt_name`, which is `_text` for a `text[]`.
            #expect(columns["scopes"]?.type == "ARRAY")
            #expect(columns["name"]?.nullable == "NO")
            #expect(columns["token_hash"]?.nullable == "NO")
            #expect(columns["scopes"]?.nullable == "NO")
            #expect(columns["created_at"]?.nullable == "NO")
            // The three that record something that may not have happened yet. A NOT NULL
            // here would force a sentinel date and make "never used" unrepresentable.
            #expect(columns["last_used_at"]?.nullable == "YES")
            #expect(columns["expires_at"]?.nullable == "YES")
            #expect(columns["revoked_at"]?.nullable == "YES")

            // A credential minted with no scopes named gets `publish` and nothing more —
            // the difference between an agent token and a root token.
            let scopesDefault = try await PostgresFixture.scalar(
                """
                SELECT column_default FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'clients'
                  AND column_name = 'scopes'
                """,
                as: String.self, on: database.client
            )
            #expect(scopesDefault?.contains("{\(ClientScope.publish.rawValue)}") == true)

            let uniqueConstraints: [String] = try await PostgresFixture.column(
                """
                SELECT attribute.attname
                FROM pg_constraint AS constraint_
                JOIN pg_attribute AS attribute
                  ON attribute.attrelid = constraint_.conrelid
                 AND attribute.attnum = ANY (constraint_.conkey)
                WHERE constraint_.conrelid = 'clients'::regclass
                  AND constraint_.contype = 'u'
                ORDER BY attribute.attname
                """,
                on: database.client
            )
            #expect(uniqueConstraints == ["name", "token_hash"])

            // Declared *and* enforced. `ClientStore.insert` turns this refusal into a nil
            // through `ON CONFLICT DO NOTHING`, so a raw statement is the only place the
            // database's own answer is visible — and the constraint is what stops two
            // credentials resolving to one row, which would make `authenticate` return
            // whichever the planner reached first.
            let digest = Data(ClientCredential.hash(ClientCredential.generate()))
            try await database.client.query(
                "INSERT INTO clients (name, token_hash) VALUES ('first', \(digest))",
                logger: PostgresFixture.logger
            )
            await #expect(throws: (any Error).self) {
                _ = try await database.client.query(
                    "INSERT INTO clients (name, token_hash) VALUES ('second', \(digest))",
                    logger: PostgresFixture.logger
                )
            }
            // The digest is unique, not the pair: a *different* digest under a different
            // name is fine, so the failure above was the constraint rather than the table
            // refusing a second row for some unrelated reason.
            try await database.client.query(
                """
                INSERT INTO clients (name, token_hash)
                VALUES ('second', \(Data(ClientCredential.hash(ClientCredential.generate()))))
                """,
                logger: PostgresFixture.logger
            )

            // The attribution column, and the foreign key that makes it mean something.
            #expect(columns["client_id"] == nil)  // it belongs to `pages`, not `clients`
            let clientIDColumn = try await PostgresFixture.scalar(
                """
                SELECT data_type || ' ' || is_nullable FROM information_schema.columns
                WHERE table_schema = \(database.schema) AND table_name = 'pages'
                  AND column_name = 'client_id'
                """,
                as: String.self, on: database.client
            )
            #expect(clientIDColumn == "bigint YES")
            let foreignKeyTarget = try await PostgresFixture.scalar(
                """
                SELECT confrelid::regclass::text FROM pg_constraint
                WHERE conrelid = 'pages'::regclass AND contype = 'f'
                """,
                as: String.self, on: database.client
            )
            #expect(foreignKeyTarget == "clients")

            // The page written before the migration keeps its body and gains no owner.
            let unowned = try await PostgresFixture.scalar(
                "SELECT client_id IS NULL FROM pages WHERE slug = 'quiet-cedar-otter'",
                as: Bool.self, on: database.client
            )
            #expect(unowned == true)
        }
    }

    /// What version 4 replaces, and the behaviour that replacement exists for. Runs the whole
    /// list, so it is also the full-list boot: version 4 is an `ALTER` against a table version
    /// 3 built, and an ordering mistake between them fails here.
    ///
    /// Two halves, and both need the database. The schema half is that `clients_name_key` is
    /// gone and a partial unique index has taken its place — an index whose predicate cannot
    /// be checked anywhere but in `pg_indexes`. The behavioural half is that `ON CONFLICT DO
    /// NOTHING` still catches a *partial* index without a conflict target, which is not
    /// obvious from the SQL and is the one thing that would turn a duplicate name from a
    /// clean nil into a thrown error reaching the operator as a 500.
    @Test func migrationFourMovesNameUniquenessOntoLiveRows() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            // A credential minted under version 3's rules, so this is an upgrade of a
            // database with data in it rather than a fresh build.
            try await database.store.migrate(Array(PageStore.migrations.prefix(3)))
            try await database.client.query(
                """
                INSERT INTO clients (name, token_hash)
                VALUES ('claude-code', \(Data(ClientCredential.hash(ClientCredential.generate()))))
                """,
                logger: PostgresFixture.logger
            )

            try await database.store.migrate()
            #expect(
                try await PostgresFixture.appliedVersions(on: database.client)
                    == PageStore.migrations.map(\.version)
            )

            let nameConstraints: [String] = try await PostgresFixture.column(
                """
                SELECT conname::text FROM pg_constraint
                WHERE conrelid = 'clients'::regclass AND contype = 'u'
                ORDER BY conname
                """,
                on: database.client
            )
            #expect(nameConstraints == ["clients_token_hash_key"])

            let indexDefinition = try await PostgresFixture.scalar(
                """
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = \(database.schema) AND indexname = 'clients_live_name_idx'
                """,
                as: String.self, on: database.client
            )
            #expect(indexDefinition?.contains("UNIQUE") == true)
            #expect(indexDefinition?.contains("(name)") == true)
            #expect(indexDefinition?.contains("WHERE (revoked_at IS NULL)") == true)

            // The rotation the whole migration is for, through the store rather than through
            // raw SQL: revoke, then mint the same name again.
            let store = database.clientStore
            #expect(try await store.revoke(name: "claude-code") != nil)
            let (reissued, token) = try await store.create(
                name: "claude-code", scopes: [.publish], expiresAt: nil
            )
            #expect(reissued.revokedAt == nil)
            #expect(try await store.authenticate(token: token) == reissued)
            #expect(try await store.allClients().map(\.name) == ["claude-code", "claude-code"])

            // And a *second* live one is still refused — as a nil from the untargeted
            // `ON CONFLICT DO NOTHING`, which is the part a partial index could have broken.
            #expect(
                try await store.insert(
                    name: "claude-code",
                    tokenHash: ClientCredential.hash(ClientCredential.generate()),
                    scopes: [ClientScope.publish.rawValue],
                    expiresAt: nil
                ) == nil
            )

            // `revoke` resolves the two rows to one: the live credential, not the retired
            // row with the same name. Reaching the wrong one would report success and leave
            // the working token working.
            let revoked = try #require(try await store.revoke(name: "claude-code"))
            #expect(revoked.id == reissued.id)
            #expect(try await store.authenticate(token: token) == nil)
            // With nothing live left the retry still answers, and answers with the same row
            // at the same instant rather than 404ing or moving the boundary.
            let retry = try #require(try await store.revoke(name: "claude-code"))
            #expect(retry.id == reissued.id)
            #expect(retry.revokedAt == revoked.revokedAt)
        }
    }

    /// `ClientStore` against the real schema, which is the only place two of its claims
    /// can be checked: that `bytea` is bound as `Data` rather than as the `char[]`
    /// PostgresNIO would make of a `[UInt8]`, and that `text[]` decodes back into
    /// `[String]`. Both fail at runtime and neither is visible to the in-memory fake.
    @Test func clientStoreReadsBackWhatTheSchemaHolds() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate()

            let token = ClientCredential.generate()
            try await database.client.query(
                """
                INSERT INTO clients (name, token_hash, scopes)
                VALUES ('claude-code', \(Data(ClientCredential.hash(token))), '{publish}')
                """,
                logger: PostgresFixture.logger
            )

            let store = database.clientStore
            let client = try #require(try await store.authenticate(token: token))
            #expect(client.name == "claude-code")
            #expect(client.scopes == [ClientScope.publish.rawValue])
            #expect(client.has(.publish))
            #expect(client.lastUsedAt == nil)
            #expect(client.expiresAt == nil)
            #expect(client.revokedAt == nil)

            // A token that was never issued resolves to nothing, rather than to the one
            // row in the table.
            let unknown = try await store.authenticate(token: ClientCredential.generate())
            #expect(unknown == nil)

            try await store.recordUse(clientID: client.id)
            let used = try #require(try await store.authenticate(token: token))
            #expect(used.lastUsedAt != nil)
            #expect(used.createdAt == client.createdAt)
        }
    }

    /// `ClientStore`'s write half, which has two more claims only Postgres can settle:
    /// that `scopes` *binds* as `text[]` on the way in (the read side proved only the way
    /// out), and that `ON CONFLICT DO NOTHING` with no conflict target catches both unique
    /// constraints rather than throwing on one of them.
    ///
    /// The whole mint-to-authenticate round trip runs through `ClientStoring.create`, so
    /// the shared policy — generate, hash, store the digest — is exercised against the real
    /// column types rather than only against the fake's dictionary.
    @Test func clientStoreMintsListsAndRevokesAgainstTheRealSchema() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate()
            let store = database.clientStore

            let expiry = Date().addingTimeInterval(3_600)
            let (agent, agentToken) = try await store.create(
                name: "claude-code", scopes: [.publish], expiresAt: expiry
            )
            let (operator_, operatorToken) = try await store.create(
                name: "operator", scopes: [.publish, .admin], expiresAt: nil
            )

            #expect(agent.scopes == [ClientScope.publish.rawValue])
            #expect(operator_.scopes == [ClientScope.publish.rawValue, ClientScope.admin.rawValue])
            #expect(operator_.expiresAt == nil)
            // `timestamptz` is microsecond-resolution, so this is "the instant we asked
            // for", not "roughly".
            let storedExpiry = try #require(agent.expiresAt)
            #expect(abs(storedExpiry.timeIntervalSince(expiry)) < 0.001)
            // The digest went in, so the plaintext round-trips through the unique index.
            #expect(try await store.authenticate(token: agentToken) == agent)

            // Both unique constraints, via one untargeted `ON CONFLICT DO NOTHING`: the
            // name, and the digest. Neither may throw, and neither may insert.
            #expect(
                try await store.insert(
                    name: "claude-code",
                    tokenHash: ClientCredential.hash(ClientCredential.generate()),
                    scopes: [ClientScope.publish.rawValue],
                    expiresAt: nil
                ) == nil
            )
            #expect(
                try await store.insert(
                    name: "a-different-name",
                    tokenHash: ClientCredential.hash(agentToken),
                    scopes: [ClientScope.publish.rawValue],
                    expiresAt: nil
                ) == nil
            )
            #expect(try await store.allClients().map(\.name) == ["claude-code", "operator"])

            // `COALESCE(revoked_at, now())`: the second call must return the first call's
            // timestamp rather than stamping a new one.
            let firstRevoke = try #require(try await store.revoke(name: "claude-code"))
            let secondRevoke = try #require(try await store.revoke(name: "claude-code"))
            #expect(firstRevoke.revokedAt != nil)
            #expect(firstRevoke.revokedAt == secondRevoke.revokedAt)
            #expect(try await store.revoke(name: "never-existed") == nil)

            // The row survives revocation and still lists; only the credential's ability to
            // authenticate is gone.
            #expect(try await store.allClients().map(\.name) == ["claude-code", "operator"])
            #expect(try await store.authenticate(token: agentToken) == nil)
            #expect(try await store.authenticate(token: operatorToken) != nil)
        }
    }

    /// `PageStore`'s own three statements against the real table, which until attribution
    /// landed were the standing gap in this suite.
    ///
    /// `client_id` is why the gap had to close. It is a foreign key, so the value the write
    /// path chooses is checked by the database and by nothing else: the in-memory fake stores
    /// whatever it is handed, so an `id` with no row behind it — the synthesised shared
    /// token's `0` — passes every HTTP test in the repo and fails every publish in
    /// production. The last assertion here is that refusal, which is what makes
    /// `Client.attributableID`'s nil load-bearing rather than decorative.
    ///
    /// The two boolean returns come along for the ride, because they are the same three
    /// statements: `ON CONFLICT DO NOTHING` reporting a taken slug as false rather than
    /// throwing, and `UPDATE … RETURNING` reporting an absent one — both of which the router
    /// turns into a `409` and a `404`.
    @Test func pagesAreStoredFetchedAndReattributedAgainstTheRealSchema() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            try await database.store.migrate()
            let store = database.store

            let (first, _) = try await database.clientStore.create(
                name: "first", scopes: [.publish], expiresAt: nil
            )
            let (second, _) = try await database.clientStore.create(
                name: "second", scopes: [.publish], expiresAt: nil
            )

            let slug = try Slug(custom: "quiet-cedar-otter")
            #expect(
                try await store.insert(
                    slug: slug,
                    body: "<h1>one</h1>",
                    contentType: PageContentType.default,
                    expiresAt: nil,
                    clientID: first.id
                )
            )
            let published = try #require(try await store.fetch(slug: slug))
            #expect(published.body == "<h1>one</h1>")
            #expect(published.clientID == first.id)

            // A second writer takes the attribution with the bytes, and the nil content type
            // keeps the stored one — the two halves of the UPDATE that are treated
            // deliberately differently.
            #expect(
                try await store.update(
                    slug: slug, body: "<h1>two</h1>", contentType: nil, clientID: second.id
                ) == .replaced(expiresAt: nil)
            )
            let replaced = try #require(try await store.fetch(slug: slug))
            #expect(replaced.body == "<h1>two</h1>")
            #expect(replaced.contentType == PageContentType.default)
            #expect(replaced.clientID == second.id)
            // And the page is still the same page: `created_at` is the moment it was first
            // published, which only this suite can check.
            #expect(replaced.createdAt == published.createdAt)

            // No honest owner is a null, not a zero. This is the shared token's row in the
            // table, and the row every page predating migration 3 already has.
            let orphan = try Slug(custom: "amber-willow-heron")
            #expect(
                try await store.insert(
                    slug: orphan,
                    body: "<h1>unowned</h1>",
                    contentType: PageContentType.default,
                    expiresAt: nil,
                    clientID: Client.sharedToken.attributableID
                )
            )
            #expect(try await store.fetch(slug: orphan)?.clientID == nil)

            // The two refusals the router reports as 409 and 404.
            #expect(
                try await store.insert(
                    slug: slug,
                    body: "<h1>mine now</h1>",
                    contentType: PageContentType.default,
                    expiresAt: nil,
                    clientID: first.id
                ) == false
            )
            #expect(try await store.fetch(slug: slug)?.body == "<h1>two</h1>")
            #expect(
                try await store.update(
                    slug: try Slug(custom: "never-published"),
                    body: "<h1>nowhere</h1>",
                    contentType: nil,
                    clientID: first.id
                ) == .noSuchPage
            )

            // The foreign key, enforced. `Client.sharedToken.id` refers to no row, so writing
            // it — rather than the nil above — is the failure that would greet every publish
            // if `attributableID` ever stopped mapping it.
            await #expect(throws: (any Error).self) {
                _ = try await store.insert(
                    slug: try Slug(custom: "dangling-foreign-key"),
                    body: "<h1>no</h1>",
                    contentType: PageContentType.default,
                    expiresAt: nil,
                    clientID: Client.sharedToken.id
                )
            }
        }
    }

    /// The expiry predicates, executed as SQL — the only place they ever are.
    ///
    /// Everything else that exercises expiry runs against `InMemoryPageStore`, whose
    /// `hasExpired` is hand-written Swift sharing nothing with `PageStore`'s `WHERE` clauses,
    /// so it cannot notice a comparison pointing the wrong way. Invert any one of them and the
    /// rest of the suite still passes: `expires_at < now()` in the fetch makes every page
    /// published under the default lifetime 404 from the instant it is created,
    /// `expires_at > now()` in the delete makes every upload destroy every *live* page that
    /// carries a deadline, and the same inversion in `recent` turns the landing page into a
    /// list of exactly the pages that no longer exist. None of the three raises an error
    /// anywhere; the second is silent data loss and the third is a silent disclosure.
    ///
    /// Three rows — a past deadline, a future one, and NULL — are the smallest fixture that
    /// pins the direction of every comparison and the NULL branch at once. This is also the
    /// only Postgres coverage `insert`, `update`, `recent` and `deleteExpired` have.
    @Test func expiryPredicatesHideReclaimAndSpareTheRightRows() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let store = database.store
            try await store.migrate()

            let dead = Slug(unchecked: "quiet-cedar-otter")
            let live = Slug(unchecked: "amber-willow-heron")
            let permanent = Slug(unchecked: "brisk-maple-compass")
            let deadline = Date().addingTimeInterval(3600)

            for (slug, body, expiresAt) in [
                (dead, "<h1>dead</h1>", Date().addingTimeInterval(-3600)),
                (live, "<h1>live</h1>", deadline),
                (permanent, "<h1>permanent</h1>", nil),
            ] as [(Slug, String, Date?)] {
                let inserted = try await store.insert(
                    slug: slug,
                    body: body,
                    contentType: PageContentType.default,
                    expiresAt: expiresAt,
                    clientID: nil
                )
                #expect(inserted, "\(slug.value)")
            }

            // The read predicate. The expired row is still physically present — nothing has
            // reclaimed anything yet — so this is a statement about the query rather than
            // about cleanup that happened to have run.
            #expect(try await store.fetch(slug: dead) == nil)
            let livePage = try await store.fetch(slug: live)
            #expect(livePage?.body == "<h1>live</h1>")
            // `timestamptz` keeps microseconds and `Date` keeps a `Double` of seconds, so the
            // instant comes back near-identical rather than identical.
            #expect(Self.isNear(livePage?.expiresAt, deadline))
            let permanentPage = try await store.fetch(slug: permanent)
            #expect(permanentPage?.body == "<h1>permanent</h1>")
            #expect(permanentPage?.expiresAt == nil)

            // The index carries the same predicate, and this is the assertion it exists for.
            // Inverting it here does not produce a 404 or a 500 — it produces a landing page
            // that lists precisely the pages no reader can fetch, which is the namespace's
            // publication history rendered as a table. The expired row is still physically
            // present at this point, so this is a statement about the query.
            //
            // Order is newest-first by `created_at`, and the three inserts above ran as three
            // separate statements, so their transaction timestamps genuinely differ: the
            // permanent page was inserted last and must come first.
            let index = try await store.recent(limit: recentPageCount)
            #expect(index.map(\.slug) == [permanent, live])
            #expect(index.first?.expiresAt == nil)
            #expect(Self.isNear(index.last?.expiresAt, deadline))
            #expect(index.first?.contentType == PageContentType.default)
            // `limit` reaches the SQL rather than being applied after the fact — a `LIMIT`
            // bound as a parameter is the one part of that query a type mismatch could break.
            #expect(try await store.recent(limit: 1).map(\.slug) == [permanent])
            #expect(try await store.recent(limit: 0).isEmpty)

            // The same predicate on the write side, so `PUT` and `GET` agree about which
            // pages exist — and the expired row is not resurrected with a new body.
            let deadOutcome = try await store.update(
                slug: dead, body: "<h1>zombie</h1>", contentType: nil, clientID: nil
            )
            #expect(deadOutcome == .noSuchPage)
            let deadBody = try await PostgresFixture.scalar(
                "SELECT body FROM pages WHERE slug = 'quiet-cedar-otter'",
                as: String.self, on: database.client
            )
            #expect(deadBody == "<h1>dead</h1>")

            switch try await store.update(
                slug: live, body: "<h1>replaced</h1>", contentType: nil, clientID: nil
            ) {
            case .replaced(let stored):
                // Reported and unmoved: a replacement is a new body at an old address.
                #expect(Self.isNear(stored, deadline))
            case .noSuchPage:
                Issue.record("the live page should have been replaced")
            }

            // And the reclaiming DELETE takes exactly the row the reads were already hiding.
            let reclaimed = try await store.deleteExpired()
            #expect(reclaimed == 1)
            let remaining: [String] = try await PostgresFixture.column(
                "SELECT slug FROM pages ORDER BY slug", on: database.client
            )
            #expect(remaining == [live.value, permanent.value].sorted())

            // A second sweep with nothing left to take reports nothing, rather than counting
            // rows it did not delete.
            #expect(try await store.deleteExpired() == 0)
        }
    }

    /// Equality for an instant that has been through `timestamptz`, whose microsecond
    /// resolution is coarser than `Date`'s.
    static func isNear(_ actual: Date?, _ expected: Date) -> Bool {
        guard let actual else { return false }
        return abs(actual.timeIntervalSince(expected)) < 0.001
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

            // Named by the list: this test is about a re-run applying *nothing*, whatever
            // "everything" currently is.
            let versions = try await PostgresFixture.appliedVersions(on: database.client)
            #expect(versions == PageStore.migrations.map(\.version))
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

            // One past the end of the shipped list, computed rather than typed. A version the
            // real list already contains would be recorded as applied by the `migrate()`
            // above, so the runner would *skip* this migration, never execute the nonsense,
            // and the expectation below would fail on a perfectly working runner — a
            // trap that springs the day somebody appends a version.
            let unusedVersion = (PageStore.migrations.last?.version ?? 0) + 1
            let broken = PageStore.Migration(
                version: unusedVersion, statements: ["THIS IS NOT SQL"]
            )
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
    /// The expired case is the third claim, and the one only this suite can settle honestly:
    /// `delete` carries the same `expires_at > now()` predicate the reads do, so a dead row
    /// is refused rather than removed. Proved by refusing it and *then* watching
    /// `deleteExpired` still find it — a delete that had quietly swept the row up would
    /// return false either way, and only the reclaim count tells the two apart.
    ///
    /// `insert`, `fetch` and `update` are otherwise still the standing gap; this closes it
    /// for `delete` alone, and leans on them only as far as the delete's own claims need.
    @Test func deleteReportsWhetherARowWasRemoved() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let store = database.store
            try await store.migrate()
            let slug = try Slug(custom: "quiet-cedar-otter")
            let bystander = try Slug(custom: "amber-willow-heron")
            let dead = try Slug(custom: "brisk-maple-compass")

            // `clientID: nil` throughout — attribution is not what this test is about, and
            // the foreign key it has to satisfy is pinned by
            // `pagesAreStoredFetchedAndReattributedAgainstTheRealSchema` instead.
            let inserted = try await store.insert(
                slug: slug, body: "<h1>here</h1>",
                contentType: PageContentType.default, expiresAt: nil, clientID: nil
            )
            #expect(inserted)
            let insertedBystander = try await store.insert(
                slug: bystander, body: "<h1>elsewhere</h1>",
                contentType: PageContentType.default, expiresAt: nil, clientID: nil
            )
            #expect(insertedBystander)
            let insertedDead = try await store.insert(
                slug: dead, body: "<h1>expired</h1>",
                contentType: PageContentType.default,
                expiresAt: Date().addingTimeInterval(-60), clientID: nil
            )
            #expect(insertedDead)

            let removed = try await store.delete(slug: slug)
            #expect(removed)
            // Hard, as advertised: the row is not filtered out of a read, it is gone.
            let afterDelete = try await store.fetch(slug: slug)
            #expect(afterDelete == nil)
            // And the statement removed the row it was addressed at, not the table.
            let survivor = try await store.fetch(slug: bystander)
            #expect(survivor?.body == "<h1>elsewhere</h1>")

            // An expired page is already gone as far as every reader is concerned, so there
            // is nothing here to delete and nothing to report having deleted.
            let removedDead = try await store.delete(slug: dead)
            #expect(removedDead == false)
            // …and it was refused, not silently swept: the row is still there for
            // reclamation to find. Without this, `delete` removing it would look identical.
            let reclaimed = try await store.deleteExpired()
            #expect(reclaimed == 1)

            let removedAgain = try await store.delete(slug: slug)
            #expect(removedAgain == false)

            // The freed slug, claimed again against a real primary key.
            let reinserted = try await store.insert(
                slug: slug, body: "<h1>second tenant</h1>",
                contentType: PageContentType.default, expiresAt: nil, clientID: nil
            )
            #expect(reinserted)
            let republished = try await store.fetch(slug: slug)
            #expect(republished?.body == "<h1>second tenant</h1>")
        }
    }

    /// `applyAmendment` against the real schema, which is the only place three of its claims
    /// can be checked at all.
    ///
    /// **The conflict branch is the reason this test exists.** It is the one outcome in the
    /// whole store that is produced by an *error* rather than by a row count: the statement
    /// carries no `NOT EXISTS` guard, deliberately — any such sub-select reads the
    /// statement's snapshot and could be overtaken by a concurrent insert committing before
    /// the index is touched — so a taken name arrives as SQLSTATE `23505` off the primary
    /// key, and `.slugTaken` is that error caught and translated. `InMemoryPageStore` reaches
    /// the same verdict by looking in a dictionary, so it agrees with this by construction
    /// and proves nothing about it. If the catch clause stops matching — a PostgresNIO error
    /// shape that changes, a `serverInfo` that arrives empty — every rename onto a taken name
    /// becomes a `500`, and this suite is the only thing that would notice.
    ///
    /// **The expiry binds are the second.** The column already spends NULL on "permanent", so
    /// the statement needs a separate boolean to say "leave it alone", and both directions
    /// have to survive a real round trip: a bind that clears a deadline but cannot set one
    /// would pass every test that only ever amends toward `never`. The two are asserted in
    /// sequence on one row, then a rename with *no* expiry instruction is asserted to leave
    /// the result standing — which is the `CASE … ELSE expires_at` arm, and the one that a
    /// single nullable bind would silently turn into "make it permanent".
    ///
    /// **And `created_at` and `client_id` are the third.** The in-memory fake stamps a fixed
    /// `createdAt` on every row, so "preserved" and "reset" are indistinguishable there;
    /// `client_id` is a foreign key, so a statement that reassigned it — or nulled it — is
    /// checked by the database and by nothing else.
    @Test func amendmentsMoveAndRetimeAPageWithoutDisturbingIt() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let store = database.store
            try await store.migrate()

            let (owner, _) = try await database.clientStore.create(
                name: "owner", scopes: [.publish], expiresAt: nil
            )

            let original = try Slug(custom: "quiet-cedar-otter")
            let renamed = try Slug(custom: "amber-willow-heron")
            let occupied = try Slug(custom: "brisk-maple-compass")

            #expect(
                try await store.insert(
                    slug: original, body: "<h1>here</h1>",
                    contentType: "text/css; charset=utf-8",
                    expiresAt: nil, clientID: owner.id
                )
            )
            #expect(
                try await store.insert(
                    slug: occupied, body: "<h1>theirs</h1>",
                    contentType: PageContentType.default, expiresAt: nil, clientID: nil
                )
            )
            let published = try #require(try await store.fetch(slug: original))

            // A permanent page given a deadline: the `CASE … THEN` arm carrying a real
            // timestamptz, which is the direction a clear-only bind would drop.
            let deadline = Date().addingTimeInterval(3 * PageLifetime.secondsPerDay)
            guard case .amended(let stillThere, let dated) = try await store.applyAmendment(
                slug: original, newSlug: nil, newExpiry: .at(deadline)
            ) else {
                Issue.record("retiming a live page must succeed")
                return
            }
            #expect(stillThere == original)
            #expect(abs(try #require(dated).timeIntervalSince(deadline)) < 1)

            // And back to permanent: the same arm carrying NULL. Distinguishable from the
            // "leave it alone" case only because the row currently holds a date.
            guard case .amended(_, let cleared) = try await store.applyAmendment(
                slug: original, newSlug: nil, newExpiry: .never
            ) else {
                Issue.record("clearing a deadline must succeed")
                return
            }
            #expect(cleared == nil)

            // A taken name, caught from the primary key's own complaint.
            #expect(
                try await store.applyAmendment(
                    slug: original, newSlug: occupied, newExpiry: nil
                ) == .slugTaken(occupied)
            )
            // The collision left both pages exactly as they were — the failure mode worth
            // ruling out is a half-applied move that destroys the page it landed on.
            #expect(try await store.fetch(slug: original)?.body == "<h1>here</h1>")
            #expect(try await store.fetch(slug: occupied)?.body == "<h1>theirs</h1>")

            // The move itself, with no expiry instruction: the `ELSE expires_at` arm has to
            // leave the NULL alone rather than treating an absent instruction as a deadline.
            guard case .amended(let moved, let untouched) = try await store.applyAmendment(
                slug: original, newSlug: renamed, newExpiry: nil
            ) else {
                Issue.record("renaming a live page must succeed")
                return
            }
            #expect(moved == renamed)
            #expect(untouched == nil)

            let atNewName = try #require(try await store.fetch(slug: renamed))
            #expect(atNewName.body == "<h1>here</h1>")
            #expect(atNewName.contentType == "text/css; charset=utf-8")
            // Still the same page, first published at the same instant, by the same
            // credential. `client_id` is *not* reassigned here — that is the difference
            // between this verb and `update`, and the foreign key means only Postgres can
            // confirm the value written is a real one.
            #expect(atNewName.createdAt == published.createdAt)
            #expect(atNewName.clientID == owner.id)

            // Hard move: the old name is not merely hidden, it is gone and claimable.
            #expect(try await store.fetch(slug: original) == nil)
            #expect(
                try await store.insert(
                    slug: original, body: "<h1>second tenant</h1>",
                    contentType: PageContentType.default, expiresAt: nil, clientID: nil
                )
            )

            // Renaming a page to the name it already holds updates a row to its own key,
            // which no unique index objects to. Asserted here rather than only against the
            // fake because "the index tolerates this" is a claim about Postgres.
            #expect(
                try await store.applyAmendment(
                    slug: renamed, newSlug: renamed, newExpiry: nil
                ) == .amended(slug: renamed, expiresAt: nil)
            )
        }
    }

    /// The deadline predicate on the amendment, which is the same `expires_at > now()` every
    /// other single-slug statement carries and is here for the same reason: this verb has to
    /// agree with `fetch`, `update` and `delete` about which pages exist.
    ///
    /// Split from the test above because the interesting half is what *doesn't* happen. An
    /// expired row must be refused rather than amended, and — like `delete` — refused rather
    /// than swept up, which is provable only by watching `deleteExpired` still find it
    /// afterwards. `?ttl=never` against a dead page is the specific temptation: an
    /// amendment that ignored the predicate would resurrect a page every reader already 404s,
    /// silently and permanently.
    @Test func amendmentsRefuseAnExpiredPageRatherThanRevivingIt() async throws {
        try await PostgresFixture.withThrowawaySchema { database in
            let store = database.store
            try await store.migrate()

            let dead = try Slug(custom: "quiet-cedar-otter")
            let target = try Slug(custom: "amber-willow-heron")
            #expect(
                try await store.insert(
                    slug: dead, body: "<h1>expired</h1>",
                    contentType: PageContentType.default,
                    expiresAt: Date().addingTimeInterval(-60), clientID: nil
                )
            )

            #expect(
                try await store.applyAmendment(
                    slug: dead, newSlug: nil, newExpiry: .never
                ) == .noSuchPage
            )
            #expect(
                try await store.applyAmendment(
                    slug: dead, newSlug: target, newExpiry: nil
                ) == .noSuchPage
            )

            // Refused, not swept: the row is still there for reclamation to find, and the
            // rename did not quietly happen anyway.
            #expect(try await store.fetch(slug: target) == nil)
            #expect(try await store.deleteExpired() == 1)
        }
    }
}
