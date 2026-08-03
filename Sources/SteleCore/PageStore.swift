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

/// All database access. Every statement here is parameterised via PostgresNIO's
/// interpolation, which binds values rather than splicing them into SQL text.
public struct PageStore: Sendable {
    private let client: PostgresClient
    private let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    /// Creates the schema if it isn't there yet.
    ///
    /// Idempotent and safe to run on every boot. This is deliberately not a migration
    /// framework — there is one table, and pulling in a migration runner for it would
    /// be more moving parts than the thing it manages.
    public func migrate() async throws {
        try await client.query(
            """
            CREATE TABLE IF NOT EXISTS pages (
                slug         text PRIMARY KEY,
                body         text NOT NULL,
                content_type text NOT NULL,
                created_at   timestamptz NOT NULL DEFAULT now()
            )
            """,
            logger: logger
        )
        try await client.query(
            "CREATE INDEX IF NOT EXISTS pages_created_at_idx ON pages (created_at DESC)",
            logger: logger
        )
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

/// `PageStore` is the database-backed conformer of the seam the router talks to. Only
/// the storage primitives — insert-if-free and update-if-present — live here; the retry
/// and requested-slug policy come from `PageStoring`'s extension, shared with every
/// other conformer.
extension PageStore: PageStoring {}
