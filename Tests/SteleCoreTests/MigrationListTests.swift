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
