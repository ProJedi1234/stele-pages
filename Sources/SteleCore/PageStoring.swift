import Foundation
import Logging

/// What a replacement found at the address it was aimed at.
///
/// An enum rather than the `Bool` this used to be, because "replaced" now carries something
/// the caller cannot obtain any other way: the page's stored expiry. A PUT reports that
/// deadline without changing it, and a caller handed only `true` could not tell a permanent
/// page apart from one whose expiry the server had simply declined to mention.
public enum PageUpdateOutcome: Sendable, Equatable {
    case replaced(expiresAt: Date?)
    /// No *live* row at that slug — absent, or expired and not yet reclaimed. The two are
    /// deliberately one case: an expired page is gone as far as every reader is concerned,
    /// and when the row is physically removed is a detail of reclamation, not of identity.
    case noSuchPage
}

/// The storage operations the router depends on.
///
/// Split out so `buildRouter` can be exercised against an in-memory fake without a
/// Postgres. `migrate()` is deliberately absent: only `buildApplication` calls it, and it
/// does so on the concrete `PageStore`, so schema bootstrap stays a database concern
/// rather than something every conformer has to pretend to implement.
///
/// The seam is storage primitives only — insert-if-free, update-if-present, and
/// delete-what-has-expired — with the requested-vs-generated policy, the collision-retry
/// loop, and the order reclamation runs in living in the extension below, shared by every
/// conformer. That keeps the policy written (and tested) once: a conformer that only
/// implements the primitives cannot drift from the retry semantics.
public protocol PageStoring: Sendable {
    /// Fetches a page, or nil if no such slug exists.
    ///
    /// An expired page is nil, not a `Page` with a passed deadline for the caller to check.
    /// Reclamation only happens on upload, so a row can outlive its deadline by any amount
    /// of time; a conformer that returned it and left the filtering to the router would
    /// serve expired pages for as long as nobody happened to publish.
    func fetch(slug: Slug) async throws -> Page?

    /// Stores a page if the slug is free, as one atomic step — the check and the write
    /// must not leave a window where two concurrent uploads both see the slug as free.
    ///
    /// "Free" means no row at all, not "no live row": an expired row still holds its slug
    /// until something deletes it, which is why `create` reclaims first.
    ///
    /// - Parameter expiresAt: when the page stops being served, or nil for a page that
    ///   never expires.
    /// - Parameter clientID: the credential that wrote the page, or nil when there is no
    ///   honest owner to record — see `Client.attributableID`. It is the caller's job to
    ///   have mapped the synthesised shared-token credential to nil already; a conformer
    ///   backed by a database has a foreign key here and cannot invent a row.
    /// - Returns: true if the page was stored, false if the slug was already taken.
    func insert(
        slug: Slug, body: String, contentType: String, expiresAt: Date?, clientID: Int64?
    ) async throws -> Bool

    /// Replaces the body — and, when `contentType` is non-nil, the content type — of an
    /// existing page, as one atomic step: the existence check and the write must not
    /// leave a window where a concurrent delete or insert changes what the update lands
    /// on. A nil `contentType` preserves the stored one. Never creates: a slug with no
    /// row stays absent.
    ///
    /// Never changes the expiry either, and reports it back instead. A replacement is a new
    /// body at an old address, not a new page.
    ///
    /// - Parameter clientID: as `insert`, and it is *written* rather than coalesced: the
    ///   column records who last wrote the page, not who first published it. A nil
    ///   therefore clears an existing attribution, which is the honest answer — the page's
    ///   current bytes came from a credential with no row behind it. `createdAt` and the
    ///   expiry are what stay fixed across a replacement; provenance follows the bytes.
    func update(
        slug: Slug, body: String, contentType: String?, clientID: Int64?
    ) async throws -> PageUpdateOutcome

    /// Removes every row whose expiry has passed, returning them to the slug pool.
    ///
    /// A primitive rather than something the extension could assemble, and deliberately
    /// given *no* default implementation: a default would be a no-op that every conformer
    /// inherited in silence, and every test that thinks it proves reclamation would pass
    /// against a store that reclaims nothing.
    ///
    /// - Returns: how many rows were removed.
    func deleteExpired() async throws -> Int
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
    ///
    /// - Parameter expiresAt: when the new page stops being served, or nil for one that
    ///   never expires. Undefaulted on purpose — a default here would let a caller that
    ///   parsed a lifetime and then forgot to pass it compile and quietly publish something
    ///   permanent.
    public func create(
        requestedSlug: Slug?,
        body: String,
        contentType: String,
        expiresAt: Date?,
        clientID: Int64?,
        generator: SlugGenerator,
        logger: Logger? = nil
    ) async throws -> Slug {
        // Before the insert, not after it, and not on a timer. Reclaiming first is what puts
        // a dead page's slug back in the pool in time for *this* upload — both for a
        // `?slug=` claim on a name that has just expired and for a generated draw that would
        // otherwise collide with a row no reader can see. Deleting afterwards would make
        // every reclamation exactly one upload late.
        //
        // Cleanup frequency therefore scales with traffic, and an idle server keeps
        // invisible expired rows indefinitely. That is the accepted trade: the reads are
        // already correct without this, so reclamation is only ever about disk and about
        // returning names to the pool.
        //
        // The failure propagates rather than being swallowed. A database that cannot DELETE
        // will not INSERT either, so hiding this would trade a truthful error for a
        // confusing one — and a silently skipped reclamation is the kind of failure that
        // never announces itself at all.
        let reclaimed = try await deleteExpired()
        if reclaimed > 0 {
            logger?.info("reclaimed expired pages", metadata: ["count": "\(reclaimed)"])
        }

        if let requestedSlug {
            guard try await insert(
                slug: requestedSlug,
                body: body,
                contentType: contentType,
                expiresAt: expiresAt,
                clientID: clientID
            )
            else { throw PageStoreError.slugTaken(requestedSlug) }
            return requestedSlug
        }

        for attempt in 1...Self.maxSlugAttempts {
            let candidate = generator.generate()
            if try await insert(
                slug: candidate,
                body: body,
                contentType: contentType,
                expiresAt: expiresAt,
                clientID: clientID
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
