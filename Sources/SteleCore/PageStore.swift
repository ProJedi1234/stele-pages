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
    /// How many times to redraw a generated slug before giving up. Each attempt is a
    /// fresh random draw, so the odds compound: with a keyspace of ~11.8M, five
    /// attempts fail only if the table is very full.
    static let maxSlugAttempts = 5

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

    /// Stores a page.
    ///
    /// - Parameter requestedSlug: pass a slug to claim it, or nil to have one generated.
    ///   The two cases fail differently on purpose: a caller who picked a name wants to
    ///   hear that it's taken, whereas a generated collision is the server's problem to
    ///   retry silently.
    public func create(
        requestedSlug: Slug?,
        body: String,
        contentType: String,
        generator: SlugGenerator
    ) async throws -> Slug {
        if let requestedSlug {
            guard try await insert(slug: requestedSlug, body: body, contentType: contentType)
            else { throw PageStoreError.slugTaken(requestedSlug) }
            return requestedSlug
        }

        for attempt in 1...Self.maxSlugAttempts {
            let candidate = generator.generate()
            if try await insert(slug: candidate, body: body, contentType: contentType) {
                return candidate
            }
            logger.warning(
                "slug collision, retrying",
                metadata: ["slug": "\(candidate)", "attempt": "\(attempt)"]
            )
        }
        throw PageStoreError.couldNotAllocateSlug(attempts: Self.maxSlugAttempts)
    }

    /// - Returns: true if the row was inserted, false if the slug was already taken.
    private func insert(slug: Slug, body: String, contentType: String) async throws -> Bool {
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
}
