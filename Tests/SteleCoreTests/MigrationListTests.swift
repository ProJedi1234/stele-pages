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

    /// Version 2's two halves. Either one alone compiles and boots: without the table the
    /// foreign key fails loudly, but without the `client_id` column every write simply
    /// records no owner and nothing ever says so.
    @Test func versionTwoAddsClientsAndAttributesPagesToThem() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 2 }).statements
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
    @Test func versionTwoDefaultsNewCredentialsToThePublishScope() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 2 }).statements
            .map(\.sql)
        #expect(sql.contains { $0.contains("DEFAULT '{\(ClientScope.publish.rawValue)}'") })
    }

    /// Version 3's two halves, which only mean anything together: the column constraint has
    /// to go or the partial index adds nothing, and the partial index has to arrive or two
    /// live credentials could share the revocation handle. An entry carrying only the `DROP`
    /// would migrate cleanly and leave the schema with no uniqueness on names at all.
    @Test func versionThreeMovesNameUniquenessOntoLiveRows() throws {
        let sql = try #require(PageStore.migrations.first { $0.version == 3 }).statements
            .map(\.sql)
        #expect(sql.contains { $0.contains("ALTER TABLE clients DROP CONSTRAINT clients_name_key") })
        let index = try #require(sql.first { $0.contains("CREATE UNIQUE INDEX clients_live_name_idx") })
        // The predicate is the whole migration. Without it this is version 2's constraint
        // again, wearing an index's name.
        #expect(index.contains("WHERE revoked_at IS NULL"))
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
