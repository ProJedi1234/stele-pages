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
