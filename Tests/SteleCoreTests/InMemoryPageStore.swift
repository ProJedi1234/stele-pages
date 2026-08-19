import Foundation
@testable import SteleCore

/// An in-memory `PageStoring` for router tests.
///
/// An actor rather than a lock-wrapped class: the protocol's methods are already `async`,
/// so an actor conforms directly, and `Mutex` would need macOS 15 while the manifest
/// declares macOS 14.
///
/// Only the seam's primitives — insert-if-free, update-if-present, amend-if-live,
/// delete-if-live and delete-what-has-expired — are implemented here, so the
/// requested-vs-generated policy, the collision-retry loop and the reclaim-before-insert
/// ordering the router tests exercise are the real shared ones from `PageStoring`'s
/// extension, not a reimplementation.
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

    /// The bytes, kept beside the pages rather than on `Page`, mirroring the two tables.
    ///
    /// Not a convenience: `Page` carries `PageContent`, which has nowhere to put bytes, and
    /// that is exactly the property the read seam is built around. A fake that hung the
    /// bytes off the page would let a router test read them through `fetch` and pass —
    /// against a store where that column is never selected.
    private var blobs: [Slug: [UInt8]] = [:]

    /// When true, every insert reports the slug as taken, so the shared retry loop runs
    /// to genuine exhaustion — this is how the 503 path is driven.
    private let failInserts: Bool

    /// When true, `recent` throws, which is the only way to reach the landing page's
    /// degraded index — the branch where the store is unreachable and the page has to render
    /// anyway.
    private let failRecent: Bool

    /// Hands out a distinct, increasing `created_at` to each stored page.
    ///
    /// A counter rather than `Date()`: two pages seeded in the same test can land in the same
    /// millisecond, and the thing under test is an *order*. Postgres has the same hazard for
    /// real — `now()` is transaction time — which is why `PageStore.recent` breaks ties on
    /// slug; here the counter removes ties entirely, so a router test that asserts newest-first
    /// is asserting the ordering and not the tie-break.
    private var clock = 0

    init(failInserts: Bool = false, failRecent: Bool = false) {
        self.failInserts = failInserts
        self.failRecent = failRecent
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
        expiresAt: Date? = nil,
        clientID: Int64? = nil
    ) {
        seed(
            slug: slug,
            body: .text(body),
            contentType: contentType,
            expiresAt: expiresAt,
            clientID: clientID
        )
    }

    /// The same, for a page of either kind. The `String` overload above stays because
    /// almost every test seeds text and `body: "<h1>hi</h1>"` is what those tests are about.
    func seed(
        slug: Slug,
        body: PageBody,
        contentType: String = PageContentType.default,
        expiresAt: Date? = nil,
        clientID: Int64? = nil
    ) {
        pages[slug] = page(
            slug: slug,
            body: body,
            contentType: contentType,
            expiresAt: expiresAt,
            clientID: clientID
        )
        store(body, at: slug)
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

    /// Mirrors `PageStore.fetchBlob`, expiry predicate included — an expired attachment is
    /// nil here exactly as it is there, which is what keeps `/static` and `GET /:slug`
    /// agreeing about when a page stops existing.
    ///
    /// The out-of-range case is the one worth copying carefully: a range starting past the
    /// end yields empty bytes and the real `totalSize`, because that is what the caller
    /// needs to answer `416`. A fake that clamped it, or returned nil, would let the route
    /// answer a request nobody made and pass.
    func fetchBlob(slug: Slug, range: Range<Int>?) async throws -> PageBlobSlice? {
        guard let page = pages[slug], !hasExpired(page),
              case .attachment(_, let digest, let filename) = page.content,
              let bytes = blobs[slug]
        else { return nil }

        // Clamped at both ends, mirroring what `substring` does with a range that overruns
        // the value — including an upper bound of `Int.max`, which is how a caller spells
        // "to the end" when it does not know where the end is.
        let slice: [UInt8]
        if let range {
            let start = min(range.lowerBound, bytes.count)
            let end = min(range.upperBound, bytes.count)
            slice = Array(bytes[start..<max(start, end)])
        } else {
            slice = bytes
        }

        return PageBlobSlice(
            bytes: slice,
            contentType: page.contentType,
            filename: filename,
            totalSize: bytes.count,
            digest: digest
        )
    }

    func insert(
        slug: Slug, body: PageBody, contentType: String, expiresAt: Date?, clientID: Int64?
    ) async throws -> Bool {
        // `pages[slug] == nil`, not "no *live* page at slug": an expired row holds its name
        // until it is deleted, exactly as it does in Postgres, which is what makes
        // reclaiming before the insert observable rather than decorative.
        guard !failInserts, pages[slug] == nil else { return false }
        pages[slug] = page(
            slug: slug,
            body: body,
            contentType: contentType,
            expiresAt: expiresAt,
            clientID: clientID
        )
        store(body, at: slug)
        return true
    }

    func update(
        slug: Slug, body: PageBody, contentType: String?, clientID: Int64?
    ) async throws -> PageUpdateOutcome {
        guard let existing = pages[slug], !hasExpired(existing) else { return .noSuchPage }
        // `createdAt` and `expiresAt` are both carried across from the existing row, matching
        // the store's `UPDATE`, which sets neither column. Both are observable now that the
        // index exists: the deadline a PUT reports has always been part of the wire contract,
        // and `created_at` decides where a replaced page sits in the landing page's list — a
        // fake that restamped it would let a replacement jump to the top here and stay put
        // against real Postgres.
        //
        // `clientID` goes the other way — assigned, not carried, mirroring the store's
        // `client_id = …`: the column is who last wrote the page. A fake that preserved it
        // would let `AttributionTests.updatingReattributesThePage` pass against the store and
        // fail against reality, or the reverse.
        // The store's `COALESCE(…, CASE WHEN kind = … THEN content_type ELSE default END)`,
        // in Swift. An absent content type preserves the stored one only while the kind
        // holds still; across a kind change the stored type describes bytes that are being
        // discarded, and a fake that kept it would let `image/png` ride onto an HTML page
        // here and be caught only by the Postgres suite.
        let resolvedContentType: String
        if let contentType {
            resolvedContentType = contentType
        } else if content(of: body).isSameKind(as: existing.content) {
            resolvedContentType = existing.contentType
        } else {
            resolvedContentType = PageContentType.default
        }

        pages[slug] = Page(
            slug: slug,
            content: content(of: body),
            contentType: resolvedContentType,
            createdAt: existing.createdAt,
            expiresAt: existing.expiresAt,
            clientID: clientID
        )
        // The unconditional delete the store's UPDATE path does, for the same reason: a
        // replacement decides the page's kind, so bytes left behind by the previous one
        // would outlive the row that referenced them. In Postgres the row is removed by an
        // explicit DELETE inside the same transaction; here it is a dictionary.
        blobs.removeValue(forKey: slug)
        store(body, at: slug)
        return .replaced(expiresAt: existing.expiresAt)
    }

    /// Mirrors `PageStore.recent`: live rows only, newest first, capped at `limit`, and no
    /// body — the summary type has nowhere to put one.
    ///
    /// The expiry filter is the part worth writing by hand rather than reusing `fetch`: it is
    /// the same predicate, and the reason it has to be the same one is that an index listing
    /// expired pages would disclose the namespace's history. A fake that skipped the filter
    /// would make the test asserting that pass against nothing.
    func recent(limit: Int) async throws -> [PageSummary] {
        if failRecent { throw InMemoryStoreUnavailable() }
        return pages.values
            .filter { !hasExpired($0) }
            // Descending by `createdAt`, which the counter above makes a total order, so the
            // tie-break `PageStore.recent` needs is not simulated here — see `clock`.
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map {
                PageSummary(
                    slug: $0.slug,
                    contentType: $0.contentType,
                    createdAt: $0.createdAt,
                    expiresAt: $0.expiresAt
                )
            }
    }

    func applyAmendment(
        slug: Slug, newSlug: Slug?, newExpiry: PageExpiry?
    ) async throws -> PageAmendOutcome {
        guard let existing = pages[slug], !hasExpired(existing) else { return .noSuchPage }

        let target = newSlug ?? slug
        // `pages[target] != nil`, not "a *live* page at target": an expired row holds its
        // name here exactly as it does in Postgres, which is what makes `amend`'s
        // reclaim-first ordering observable instead of decorative. Renaming to the name the
        // page already has is excluded, mirroring an UPDATE that sets a row's key to its own
        // value — a fake that reported that as taken would turn a harmless no-op into a 409.
        if target != slug, pages[target] != nil { return .slugTaken(target) }

        // Spelled out rather than written as `newExpiry.map(\.date) ?? existing.expiresAt`:
        // that expression is a `Date??` collapsing correctly by accident, and the accident is
        // exactly the nil-means-two-things confusion `PageExpiry` exists to prevent.
        let expiresAt: Date?
        if let newExpiry {
            expiresAt = newExpiry.date
        } else {
            expiresAt = existing.expiresAt
        }

        // Built directly rather than through `page(…)`, for the reason `update` is: that
        // helper stamps the next tick of `clock`, and an amendment must not restamp
        // `createdAt`. Renaming a page is not republishing it, so a rename must not move the
        // page to the top of the landing page's list — a fake that used the helper here would
        // let that reordering pass while real Postgres, whose UPDATE never touches the
        // column, kept the page where it was.
        //
        // Body, content type and `clientID` are carried across too. That last one is worth
        // stating: `update` above deliberately *assigns* it, and a fake that copied that
        // behaviour here would let the router quietly re-attribute a page to whoever renamed
        // it.
        pages.removeValue(forKey: slug)
        // The bytes move with the row. In Postgres this is the foreign key's
        // `ON UPDATE CASCADE` and costs no code at all; here it has to be written, and
        // getting it wrong would leave a renamed attachment serving nothing from `/static`
        // while `fetch` still described it.
        if let bytes = blobs.removeValue(forKey: slug) { blobs[target] = bytes }
        pages[target] = Page(
            slug: target,
            content: existing.content,
            contentType: existing.contentType,
            createdAt: existing.createdAt,
            expiresAt: expiresAt,
            clientID: existing.clientID
        )
        return .amended(slug: target, expiresAt: expiresAt)
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
        // `ON DELETE CASCADE` in the schema; a second line here.
        blobs.removeValue(forKey: slug)
        return true
    }

    func deleteExpired() async throws -> Int {
        let dead = pages.filter { hasExpired($0.value) }
        for slug in dead.keys {
            pages.removeValue(forKey: slug)
            blobs.removeValue(forKey: slug)
        }
        return dead.count
    }

    /// `<=`, matching the SQL's `expires_at <= now()` — and the exact complement of the
    /// `expires_at > now()` the reads use, so no page is ever both visible and reclaimable.
    private func hasExpired(_ page: Page, at moment: Date = Date()) -> Bool {
        guard let expiresAt = page.expiresAt else { return false }
        return expiresAt <= moment
    }

    /// Builds a freshly-published page, stamping it with the next tick of `clock`.
    ///
    /// Only `seed` and `insert` go through here — the two ways a page comes into existence.
    /// `update` builds its own `Page` precisely so it cannot pick up a new `createdAt`.
    private func page(
        slug: Slug, body: PageBody, contentType: String, expiresAt: Date?, clientID: Int64?
    ) -> Page {
        clock += 1
        return Page(
            slug: slug,
            content: content(of: body),
            contentType: contentType,
            // Epoch-relative and one second apart: far enough in the past that every page in
            // these tests reads as years old, which is a stable label — a stamp near `now`
            // would render as "just now" or "1m ago" depending on how long the suite took.
            createdAt: Date(timeIntervalSince1970: TimeInterval(clock)),
            expiresAt: expiresAt,
            clientID: clientID
        )
    }

    /// Files the bytes of a blob body, and nothing for a text one.
    private func store(_ body: PageBody, at slug: Slug) {
        guard case .blob(let bytes, _) = body else { return }
        blobs[slug] = bytes
    }

    /// The write-side body as the read side describes it — the fake's stand-in for the
    /// column list `PageStore.content(kind:…)` reassembles a row from.
    ///
    /// The digest goes through `PageStore.digest(of:)` rather than being invented, so a
    /// router test asserting an `ETag` is asserting the same string real Postgres stored.
    private func content(of body: PageBody) -> PageContent {
        switch body {
        case .text(let text):
            return .text(text)
        case .blob(let bytes, let filename):
            return .attachment(
                byteSize: bytes.count,
                digest: PageStore.digest(of: bytes),
                filename: filename
            )
        }
    }
}

/// What the fake throws when it is asked to fail — the landing page's degraded-index branch
/// is reachable no other way.
struct InMemoryStoreUnavailable: Error {}
