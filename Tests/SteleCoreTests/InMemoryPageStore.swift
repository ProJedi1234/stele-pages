import Foundation
@testable import SteleCore

/// An in-memory `PageStoring` for router tests.
///
/// An actor rather than a lock-wrapped class: the protocol's methods are already `async`,
/// so an actor conforms directly, and `Mutex` would need macOS 15 while the manifest
/// declares macOS 14.
///
/// Every test should build its own instance — swift-testing runs suites in parallel and
/// nothing here is meant to be shared.
actor InMemoryPageStore: PageStoring {
    /// How many generated candidates to try before giving up — `PageStore`'s own limit,
    /// referenced rather than re-declared so the fake can't drift from the store it mirrors.
    static let maxSlugAttempts = PageStore.maxSlugAttempts

    private var pages: [Slug: Page] = [:]

    /// When true, `create(requestedSlug: nil, …)` always fails allocation — the 503 path.
    private let failAllocation: Bool

    init(failAllocation: Bool = false) {
        self.failAllocation = failAllocation
    }

    /// Arranges a page for fetch/conflict tests, with a synthesised `createdAt`.
    @discardableResult
    func seed(
        slug: Slug,
        body: String,
        contentType: String = PageContentType.default,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) -> Page {
        let page = Page(slug: slug, body: body, contentType: contentType, createdAt: createdAt)
        pages[slug] = page
        return page
    }

    func fetch(slug: Slug) async throws -> Page? {
        pages[slug]
    }

    func create(
        requestedSlug: Slug?,
        body: String,
        contentType: String,
        generator: SlugGenerator
    ) async throws -> Slug {
        if let requestedSlug {
            guard pages[requestedSlug] == nil else {
                throw PageStoreError.slugTaken(requestedSlug)
            }
            insert(slug: requestedSlug, body: body, contentType: contentType)
            return requestedSlug
        }

        guard !failAllocation else {
            throw PageStoreError.couldNotAllocateSlug(attempts: Self.maxSlugAttempts)
        }

        for _ in 1...Self.maxSlugAttempts {
            let candidate = generator.generate()
            if pages[candidate] == nil {
                insert(slug: candidate, body: body, contentType: contentType)
                return candidate
            }
        }
        throw PageStoreError.couldNotAllocateSlug(attempts: Self.maxSlugAttempts)
    }

    private func insert(slug: Slug, body: String, contentType: String) {
        pages[slug] = Page(
            slug: slug,
            body: body,
            contentType: contentType,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
