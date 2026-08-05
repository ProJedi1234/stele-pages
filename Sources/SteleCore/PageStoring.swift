import Logging

/// The storage operations the router depends on.
///
/// Split out so `buildRouter` can be exercised against an in-memory fake without a
/// Postgres. `migrate()` is deliberately absent: only `buildApplication` calls it, and it
/// does so on the concrete `PageStore`, so schema bootstrap stays a database concern
/// rather than something every conformer has to pretend to implement.
///
/// The seam is storage primitives only — insert-if-free and update-if-present — with the
/// requested-vs-generated policy and the collision-retry loop living in the extension
/// below, shared by every conformer. That keeps the policy written (and tested) once:
/// a conformer that only implements the primitives cannot drift from the retry semantics.
public protocol PageStoring: Sendable {
    /// Fetches a page, or nil if no such slug exists.
    func fetch(slug: Slug) async throws -> Page?

    /// Stores a page if the slug is free, as one atomic step — the check and the write
    /// must not leave a window where two concurrent uploads both see the slug as free.
    ///
    /// - Parameter clientID: the credential that wrote the page, or nil when there is no
    ///   honest owner to record — see `Client.attributableID`. It is the caller's job to
    ///   have mapped the synthesised shared-token credential to nil already; a conformer
    ///   backed by a database has a foreign key here and cannot invent a row.
    /// - Returns: true if the page was stored, false if the slug was already taken.
    func insert(
        slug: Slug, body: String, contentType: String, clientID: Int64?
    ) async throws -> Bool

    /// Replaces the body — and, when `contentType` is non-nil, the content type — of an
    /// existing page, as one atomic step: the existence check and the write must not
    /// leave a window where a concurrent delete or insert changes what the update lands
    /// on. A nil `contentType` preserves the stored one. Never creates: a slug with no
    /// row stays absent.
    ///
    /// - Parameter clientID: as `insert`, and it is *written* rather than coalesced: the
    ///   column records who last wrote the page, not who first published it. A nil
    ///   therefore clears an existing attribution, which is the honest answer — the page's
    ///   current bytes came from a credential with no row behind it. (`createdAt` is what
    ///   stays fixed across a replacement; provenance follows the bytes.)
    /// - Returns: true if the page was replaced, false if no such slug exists.
    func update(
        slug: Slug, body: String, contentType: String?, clientID: Int64?
    ) async throws -> Bool
}

extension PageStoring {
    /// How many times to redraw a generated slug before giving up. Each attempt is a
    /// fresh random draw, so the odds compound: with a keyspace of ~11.8M, five
    /// attempts fail only if the table is very full.
    static var maxSlugAttempts: Int { 5 }

    /// Stores a page, either at `requestedSlug` or at a freshly generated one.
    ///
    /// The two cases fail differently on purpose: a caller who picked a name wants to
    /// hear that it's taken (`PageStoreError.slugTaken`), whereas a generated collision
    /// is the server's problem to retry silently — until `maxSlugAttempts` draws in a
    /// row collide and this gives up with `PageStoreError.couldNotAllocateSlug`.
    public func create(
        requestedSlug: Slug?,
        body: String,
        contentType: String,
        clientID: Int64?,
        generator: SlugGenerator,
        logger: Logger? = nil
    ) async throws -> Slug {
        if let requestedSlug {
            guard try await insert(
                slug: requestedSlug, body: body, contentType: contentType, clientID: clientID
            )
            else { throw PageStoreError.slugTaken(requestedSlug) }
            return requestedSlug
        }

        for attempt in 1...Self.maxSlugAttempts {
            let candidate = generator.generate()
            if try await insert(
                slug: candidate, body: body, contentType: contentType, clientID: clientID
            ) {
                return candidate
            }
            logger?.warning(
                "slug collision, retrying",
                metadata: ["slug": "\(candidate)", "attempt": "\(attempt)"]
            )
        }
        throw PageStoreError.couldNotAllocateSlug(attempts: Self.maxSlugAttempts)
    }
}
