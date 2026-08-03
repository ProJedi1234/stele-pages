import Foundation
@testable import SteleCore

/// An in-memory `PageStoring` for router tests.
///
/// An actor rather than a lock-wrapped class: the protocol's methods are already `async`,
/// so an actor conforms directly, and `Mutex` would need macOS 15 while the manifest
/// declares macOS 14.
///
/// Only the seam's insert-if-free primitive is implemented here, so the
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
        contentType: String = PageContentType.default
    ) {
        pages[slug] = page(slug: slug, body: body, contentType: contentType)
    }

    func fetch(slug: Slug) async throws -> Page? {
        pages[slug]
    }

    func insert(slug: Slug, body: String, contentType: String) async throws -> Bool {
        guard !failInserts, pages[slug] == nil else { return false }
        pages[slug] = page(slug: slug, body: body, contentType: contentType)
        return true
    }

    private func page(slug: Slug, body: String, contentType: String) -> Page {
        Page(
            slug: slug,
            body: body,
            contentType: contentType,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
