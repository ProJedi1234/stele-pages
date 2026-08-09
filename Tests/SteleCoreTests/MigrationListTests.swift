import Testing

@testable import SteleCore

/// The invariants of `PageStore.migrations` that a reviewer would otherwise have to hold
/// in their head, checked with no database at all.
///
/// These are the three edits that would break a deployment without failing to compile: an
/// out-of-order or duplicate version, dropping version 1's `IF NOT EXISTS` forms, and an
/// accidental interpolation or semicolon-separated script.
@Suite("Migration list")
struct MigrationListTests {
    /// The runner applies the list in array order and records versions as it goes, so an
    /// out-of-order or duplicate entry would apply a schema change before its
    /// prerequisite, or silently skip one. There is deliberately no runtime `sorted()` —
    /// a defensive sort would paper over exactly the authoring mistake this test exists
    /// to catch.
    @Test func versionsAreUniqueIncreasingAndStartAtOne() {
        let versions = PageStore.migrations.map(\.version)
        #expect(versions.first == 1)
        #expect(versions == versions.sorted())
        #expect(Set(versions).count == versions.count)
    }

    /// Version 1 is a retroactive description of a schema that already exists in
    /// production. Without `IF NOT EXISTS` the first boot after this change fails on every
    /// database that predates the version table — which is all of them.
    @Test func versionOneStillTargetsAnExistingSchema() {
        let sql = PageStore.migrations[0].statements.map(\.sql)
        #expect(sql.contains { $0.contains("CREATE TABLE IF NOT EXISTS pages") })
        #expect(sql.contains { $0.contains("CREATE INDEX IF NOT EXISTS pages_created_at_idx") })
    }

    /// Version 2 adds the column *and* backfills it, and the backfill is the half with no
    /// compiler behind it: delete that one statement and everything still builds, every
    /// hermetic test still passes, and the only symptom is that pages published before the
    /// upgrade quietly keep an unbounded lifetime on every deployment that has already run
    /// the migration — where it can never be corrected, because by then a NULL is
    /// indistinguishable from a deliberate `never`.
    ///
    /// Pinned here rather than only in `PageStoreDatabaseTests`, which needs Postgres and so
    /// does not run in CI's default path. The literal `7 days` is matched deliberately
    /// against the text and not against `PageLifetime.defaultDays`: a shipped migration
    /// records what was written once, so this assertion must keep failing if someone
    /// "helpfully" re-derives the interval from a constant that is free to move.
    @Test func versionTwoBackfillsTheColumnItAdds() {
        let sql = PageStore.migrations[1].statements.map(\.sql)
        #expect(sql.contains { $0.contains("ADD COLUMN expires_at") })
        #expect(
            sql.contains {
                $0.contains("UPDATE pages SET expires_at = now() + interval '7 days'")
                    && $0.contains("WHERE expires_at IS NULL")
            }
        )
    }

    /// Version 3's two halves. Either one alone compiles and boots: without the table the
    /// foreign key fails loudly, but without the `client_id` column every write simply
    /// records no owner and nothing ever says so.
    @Test func versionThreeAddsClientsAndAttributesPagesToThem() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 3 }).statements
            .map(\.sql)
        #expect(sql.contains { $0.contains("CREATE TABLE clients") })
        #expect(sql.contains { $0.contains("token_hash   bytea NOT NULL UNIQUE") })
        #expect(
            sql.contains {
                $0.contains("ALTER TABLE pages ADD COLUMN client_id bigint REFERENCES clients (id)")
            }
        )
    }

    /// The one value in the schema that had to be retyped rather than interpolated — DDL
    /// cannot take bind parameters, so a `\(…)` in a migration becomes a bind and fails.
    /// This is the pin that stands in for the interpolation: renaming the scope without
    /// touching the default fails here instead of silently minting credentials with a
    /// scope nothing grants.
    @Test func versionThreeDefaultsNewCredentialsToThePublishScope() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 3 }).statements
            .map(\.sql)
        #expect(sql.contains { $0.contains("DEFAULT '{\(ClientScope.publish.rawValue)}'") })
    }

    /// Version 4's two halves, which only mean anything together: the column constraint has
    /// to go or the partial index adds nothing, and the partial index has to arrive or two
    /// live credentials could share the revocation handle. An entry carrying only the `DROP`
    /// would migrate cleanly and leave the schema with no uniqueness on names at all.
    @Test func versionFourMovesNameUniquenessOntoLiveRows() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 4 }).statements
            .map(\.sql)
        #expect(sql.contains { $0.contains("ALTER TABLE clients DROP CONSTRAINT clients_name_key") })
        let index = try #require(sql.first { $0.contains("CREATE UNIQUE INDEX clients_live_name_idx") })
        // The predicate is the whole migration. Without it this is version 3's constraint
        // again, wearing an index's name.
        #expect(index.contains("WHERE revoked_at IS NULL"))
    }

    /// Version 5's one statement, and the two words it must not contain. Nullable is the design
    /// rather than an oversight: a `NOT NULL` here would fail the migration outright on any
    /// database that already holds credentials, and a `NOT NULL DEFAULT ''` — the shape
    /// someone reaches for next — would succeed and quietly assert that every credential ever
    /// minted was signed in for by an account with no name.
    ///
    /// A bare `DEFAULT` is refused on its own too, and for the same reason rather than a
    /// performance one: Postgres 11 and later keep a constant default in the catalog and
    /// rewrite no rows for it, so one would cost nothing in time and everything in honesty.
    /// Every credential minted afterwards would carry a login no account ever chose, and the
    /// column's NULL would stop meaning "nobody signed in for this" the moment it did.
    @Test func versionFiveAddsANullableGitHubLogin() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 5 }).statements
            .map(\.sql)
        let alter = try #require(
            sql.first { $0.contains("ALTER TABLE clients ADD COLUMN github_login") }
        )
        #expect(alter.contains("github_login text"))
        #expect(!alter.contains("NOT NULL"))
        #expect(!alter.contains("DEFAULT"))
    }

    /// Two properties of the statement text, both of which fail confusingly at runtime.
    /// A `\(…)` in a `PostgresQuery` literal becomes a bind parameter rather than SQL
    /// text, and DDL cannot take binds; and PostgresNIO's extended query protocol refuses
    /// more than one command per message, so a semicolon-separated script never runs.
    @Test func statementsAreLiteralSqlWithNoBindsAndOneCommandEach() {
        for migration in PageStore.migrations {
            #expect(!migration.statements.isEmpty)
            for statement in migration.statements {
                #expect(statement.binds.count == 0)
                // Only an *interior* semicolon is a second command; a trailing one is
                // legal, so the last character is excluded.
                #expect(!statement.sql.dropLast().contains(";"))
            }
        }
    }
}
