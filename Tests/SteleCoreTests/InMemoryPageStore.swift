import Foundation
@testable import SteleCore

/// An in-memory `PageStoring` for router tests.
///
/// An actor rather than a lock-wrapped class: the protocol's methods are already `async`,
/// so an actor conforms directly, and `Mutex` would need macOS 15 while the manifest
/// declares macOS 14.
///
/// Only the seam's primitives — insert-if-free, update-if-present, delete-if-live and
/// delete-what-has-expired — are implemented here, so the requested-vs-generated policy,
/// the collision-retry loop and the reclaim-before-insert ordering the router tests
/// exercise are the real shared ones from `PageStoring`'s extension, not a
/// reimplementation.
///
/// Where expiry is concerned this fake follows the SQL rather than doing whatever is
/// convenient, because the router tests are the only place several of those rules are
/// checked at all: a read hides an expired page, an update refuses one and never moves a
/// stored deadline, a single-slug delete refuses one too, and an insert still collides with
/// an expired row — it is a row until something deletes it. A fake that quietly filtered
/// expired rows out of `insert` would make the reclamation tests pass without any
/// reclamation happening.
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
    ///
    /// - Parameter expiresAt: nil — the default, and what every pre-expiry test wants — is a
    ///   permanent page. A date in the past is how a test arranges the one state no HTTP
    ///   request can produce: a page that is already dead but has not been reclaimed.
    func seed(
        slug: Slug,
        body: String,
        contentType: String = PageContentType.default,
        expiresAt: Date? = nil
    ) {
        pages[slug] = page(slug: slug, body: body, contentType: contentType, expiresAt: expiresAt)
    }

    /// Every slug physically present, expired or not.
    ///
    /// The only way a test can tell "hidden from reads" apart from "actually deleted" —
    /// every other observation this fake offers already filters expired pages out, which is
    /// exactly what would make a reclamation test pass vacuously.
    var storedSlugs: Set<Slug> {
        Set(pages.keys)
    }

    func fetch(slug: Slug) async throws -> Page? {
        guard let page = pages[slug], !hasExpired(page) else { return nil }
        return page
    }

    func insert(
        slug: Slug, body: String, contentType: String, expiresAt: Date?
    ) async throws -> Bool {
        // `pages[slug] == nil`, not "no *live* page at slug": an expired row holds its name
        // until it is deleted, exactly as it does in Postgres, which is what makes
        // reclaiming before the insert observable rather than decorative.
        guard !failInserts, pages[slug] == nil else { return false }
        pages[slug] = page(slug: slug, body: body, contentType: contentType, expiresAt: expiresAt)
        return true
    }

    func update(slug: Slug, body: String, contentType: String?) async throws -> PageUpdateOutcome {
        guard let existing = pages[slug], !hasExpired(existing) else { return .noSuchPage }
        // No `createdAt` theater: `page` stamps every entry with the same fixed date, so
        // "preserved" and "reset" are indistinguishable here — the real created_at
        // guarantee lives in `PageStore`'s SQL and only a Postgres test can check it.
        // `expiresAt` is different: it is carried across from the existing row on purpose,
        // and a test can see the difference, because the deadline a PUT reports is part of
        // the wire contract.
        pages[slug] = page(
            slug: slug,
            body: body,
            contentType: contentType ?? existing.contentType,
            expiresAt: existing.expiresAt
        )
        return .replaced(expiresAt: existing.expiresAt)
    }

    func delete(slug: Slug) async throws -> Bool {
        // Hard, like the store's DELETE: nothing is kept to mark the slug as spent, so a
        // test that deletes and then inserts at the same slug sees it free — which is the
        // behaviour the router relies on and the only part of the real thing worth
        // imitating here.
        //
        // Expired rows are refused rather than removed, mirroring the SQL's deadline
        // predicate. Getting this wrong in the convenient direction — `removeValue` on
        // anything present — is invisible in every test that never seeds an expired page,
        // and would let the router answer 204 for a page the fake's own `fetch` hides.
        guard let existing = pages[slug], !hasExpired(existing) else { return false }
        pages.removeValue(forKey: slug)
        return true
    }

    func deleteExpired() async throws -> Int {
        let dead = pages.filter { hasExpired($0.value) }
        for slug in dead.keys { pages.removeValue(forKey: slug) }
        return dead.count
    }

    /// `<=`, matching the SQL's `expires_at <= now()` — and the exact complement of the
    /// `expires_at > now()` the reads use, so no page is ever both visible and reclaimable.
    private func hasExpired(_ page: Page, at moment: Date = Date()) -> Bool {
        guard let expiresAt = page.expiresAt else { return false }
        return expiresAt <= moment
    }

    private func page(slug: Slug, body: String, contentType: String, expiresAt: Date?) -> Page {
        Page(
            slug: slug,
            body: body,
            contentType: contentType,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: expiresAt
        )
    }
}
