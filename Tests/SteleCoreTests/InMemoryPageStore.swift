import Foundation
@testable import SteleCore

/// An in-memory `PageStoring` for router tests.
///
/// An actor rather than a lock-wrapped class: the protocol's methods are already `async`,
/// so an actor conforms directly, and `Mutex` would need macOS 15 while the manifest
/// declares macOS 14.
///
/// Only the seam's primitives — insert-if-free and update-if-present — are implemented
/// here, so the
/// requested-vs-generated policy and the collision-retry loop the router tests exercise
/// are the real shared ones from `PageStoring`'s extension, not a reimplementation.
///
/// Every test should build its own instance — swift-testing runs suites in parallel and
/// nothing here is meant to be shared.
actor InMemoryPageStore: PageStoring {
    private var pages: [Slug: Page] = [:]

    /// When true, every insert reports the slug as taken, so the shared retry loop runs
    /// to genuine exhaustion — this is how the 503 path is driven.
    private let failInserts: Bool

    init(failInserts: Bool = false) {
        self.failInserts = failInserts
    }

    /// Arranges a page for fetch/conflict tests, with a synthesised `createdAt`.
    func seed(
        slug: Slug,
        body: String,
        contentType: String = PageContentType.default,
        clientID: Int64? = nil
    ) {
        pages[slug] = page(slug: slug, body: body, contentType: contentType, clientID: clientID)
    }

    func fetch(slug: Slug) async throws -> Page? {
        pages[slug]
    }

    func insert(
        slug: Slug, body: String, contentType: String, clientID: Int64?
    ) async throws -> Bool {
        guard !failInserts, pages[slug] == nil else { return false }
        pages[slug] = page(slug: slug, body: body, contentType: contentType, clientID: clientID)
        return true
    }

    func update(
        slug: Slug, body: String, contentType: String?, clientID: Int64?
    ) async throws -> Bool {
        guard let existing = pages[slug] else { return false }
        // No `createdAt` theater: `page` stamps every entry with the same fixed date, so
        // "preserved" and "reset" are indistinguishable here — the real created_at
        // guarantee lives in `PageStore`'s SQL and only a Postgres test can check it.
        //
        // `clientID` is assigned, not coalesced, mirroring the store's `client_id = …`:
        // the column is who last wrote the page. A fake that preserved it instead would let
        // `AttributionTests.updatingReattributesThePage` pass against the store and fail
        // against reality, or the reverse.
        pages[slug] = page(
            slug: slug,
            body: body,
            contentType: contentType ?? existing.contentType,
            clientID: clientID
        )
        return true
    }

    private func page(
        slug: Slug, body: String, contentType: String, clientID: Int64?
    ) -> Page {
        Page(
            slug: slug,
            body: body,
            contentType: contentType,
            createdAt: Date(timeIntervalSince1970: 0),
            clientID: clientID
        )
    }
}
