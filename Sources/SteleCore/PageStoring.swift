/// The storage operations the router depends on.
///
/// Split out so `buildRouter` can be exercised against an in-memory fake without a
/// Postgres. `migrate()` is deliberately absent: only `buildApplication` calls it, and it
/// does so on the concrete `PageStore`, so schema bootstrap stays a database concern
/// rather than something every conformer has to pretend to implement.
public protocol PageStoring: Sendable {
    /// Fetches a page, or nil if no such slug exists.
    func fetch(slug: Slug) async throws -> Page?

    /// Stores a page, either at `requestedSlug` or at a freshly generated one.
    ///
    /// Throws `PageStoreError.slugTaken` when a requested slug is already in use, and
    /// `PageStoreError.couldNotAllocateSlug` when generation keeps colliding.
    func create(
        requestedSlug: Slug?,
        body: String,
        contentType: String,
        generator: SlugGenerator
    ) async throws -> Slug
}
