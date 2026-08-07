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

/// A deadline a caller has asked a page to take, as opposed to one a page already holds.
///
/// An enum rather than the `Date?` the column stores, because an amendment needs *three*
/// answers where the column has two: set a deadline, remove the deadline, or leave whatever
/// is there alone. Spelling the third one as a further layer of Optional would give
/// `Date??`, where the two nils mean opposite things and the compiler is no help telling
/// them apart — `expiresAt: nil` reads as "no deadline" at every call site, and would
/// silently mean "no change" at this one. `PageExpiry?` puts the distinction in the type:
/// nil is the absence of an instruction, and `.never` is the instruction to be permanent.
public enum PageExpiry: Sendable, Equatable {
    case at(Date)
    /// Permanent — SQL `NULL`, and the same thing `PageLifetime.neverKeyword` asks for.
    case never

    /// The value the column takes.
    public var date: Date? {
        switch self {
        case .at(let date): date
        case .never: nil
        }
    }

    /// Rebuilds the instruction from a parsed lifetime, whose own nil already means
    /// "never". The conversion lives here rather than at the router so there is one place
    /// that decides which nil is which.
    public init(_ lifetime: PageLifetime) {
        self = lifetime.expiresAt.map(Self.at) ?? .never
    }
}

/// What an amendment found at the address it was aimed at.
///
/// Three cases rather than `PageUpdateOutcome`'s two, because an amendment can fail in a way
/// a replacement cannot: the address it wants may already belong to somebody else. Carrying
/// the resulting slug rather than assuming the requested one is what lets the caller answer
/// with the page's *current* URL without deciding for itself whether the rename took.
public enum PageAmendOutcome: Sendable, Equatable {
    case amended(slug: Slug, expiresAt: Date?)
    /// No *live* row at the addressed slug — absent, or expired and not yet reclaimed, the
    /// same conflation `PageUpdateOutcome.noSuchPage` makes and for the same reason.
    case noSuchPage
    /// The requested new slug is held by another row. Carries the name so the caller does
    /// not have to remember which of the two slugs it asked about.
    case slugTaken(Slug)
}

/// The storage operations the router depends on.
///
/// Split out so `buildRouter` can be exercised against an in-memory fake without a
/// Postgres. `migrate()` is deliberately absent: only `buildApplication` calls it, and it
/// does so on the concrete `PageStore`, so schema bootstrap stays a database concern
/// rather than something every conformer has to pretend to implement.
///
/// The seam is storage primitives only — insert-if-free, update-if-present,
/// delete-if-live, delete-what-has-expired, and list-the-live-ones — with the
/// requested-vs-generated policy,
/// the collision-retry loop, and the order reclamation runs in living in the extension
/// below, shared by every conformer. That keeps the policy written (and tested) once: a
/// conformer that only implements the primitives cannot drift from the retry semantics.
///
/// The two deletes are not variations on each other. `delete(slug:)` is a caller giving one
/// name up and is answerable to that caller; `deleteExpired()` is housekeeping nobody asked
/// for, addressed at no slug in particular, and reports a count rather than a fate. Folding
/// them into one entry point would mean a predicate that is sometimes the slug and sometimes
/// the clock.
public protocol PageStoring: Sendable {
    /// Fetches a page, or nil if no such slug exists.
    ///
    /// An expired page is nil, not a `Page` with a passed deadline for the caller to check.
    /// Reclamation only happens on upload, so a row can outlive its deadline by any amount
    /// of time; a conformer that returned it and left the filtering to the router would
    /// serve expired pages for as long as nobody happened to publish.
    func fetch(slug: Slug) async throws -> Page?

    /// The most recently published live pages, newest first, at most `limit` of them.
    ///
    /// "Live" means what it means everywhere else in this protocol, and here the cost of
    /// disagreeing is not a wrong answer but a leak: an index that listed expired rows would
    /// hand a reader the names of pages that no longer exist, which is the publication
    /// history the uniform 404 is written to withhold. The index and the read surface have to
    /// name the same set of pages.
    ///
    /// Ordered by publication, not by last write. `created_at` survives a `PUT` — a
    /// replacement is a new body at an old address — so re-uploading a page does not push it
    /// back to the top of the list. That is the honest reading of "recent" for a list of
    /// links, and it also means the order cannot be churned by whoever edits most often.
    ///
    /// Returns summaries rather than `Page`s because the body is the one thing a list must
    /// not read: see `PageSummary`.
    ///
    /// Given no default implementation, for the reason `deleteExpired` is given none. A
    /// default returning `[]` is a no-op that every conformer inherits in silence, and the
    /// symptom — a landing page that renders an empty index against a table full of pages —
    /// looks exactly like a server nobody has published to yet.
    func recent(limit: Int) async throws -> [PageSummary]

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

    /// Moves a *live* page to a new slug, changes its deadline, or both, as one atomic step:
    /// the existence check, the collision check and the write must not leave a window where a
    /// concurrent upload claims the target name between them.
    ///
    /// Touches nothing else. The body, the content type, `created_at` and `client_id` all
    /// survive — an amendment changes where a page lives and how long it lives, not what it
    /// is. `client_id` in particular is *not* reassigned, which is the opposite of what
    /// `update` does and follows from the same rule: that column records who wrote the bytes
    /// currently being served, and an amendment writes no bytes.
    ///
    /// "Live" carries the meaning it does everywhere else — an expired-but-unreclaimed row is
    /// `.noSuchPage`, so this verb agrees with `fetch`, `update` and `delete` about which
    /// pages exist. The *target* name is a different question: it is taken if any row holds
    /// it, expired or not, exactly as `insert` sees it, which is why `amend` reclaims first.
    ///
    /// The move is hard. The old slug is released the moment this commits, with no tombstone
    /// and no redirect, so a link already handed out goes to the uniform 404 and the name can
    /// be claimed — or drawn by the generator — by somebody else's page. That is the same
    /// bargain `delete(slug:)` strikes, and it is deliberate: the alternative is a permanent
    /// table of retired names plus a lookup on every read, to protect URLs this server
    /// already treats as guessable rather than stable.
    ///
    /// - Parameters:
    ///   - slug: the address to amend, which is where the page lives *now*.
    ///   - newSlug: the address to move it to, or nil to leave it where it is. Renaming a
    ///     page to the slug it already has is a no-op that succeeds, not a collision with
    ///     itself.
    ///   - newExpiry: the deadline to impose, or nil to leave the stored one alone. See
    ///     `PageExpiry` for why this is not a `Date?`.
    /// - Returns: `.amended` with the page's resulting slug and deadline, `.noSuchPage` if no
    ///   live row exists at `slug`, or `.slugTaken` if `newSlug` is held by another row.
    func applyAmendment(
        slug: Slug, newSlug: Slug?, newExpiry: PageExpiry?
    ) async throws -> PageAmendOutcome

    /// Removes the *live* page at `slug`, as one atomic step: the existence check and the
    /// removal must not leave a window where a concurrent write changes what the removal
    /// lands on, or this reports on a page it did not delete.
    ///
    /// "Live" carries the same meaning it does in `fetch` and `update`, and for the same
    /// reason: an expired-but-unreclaimed row must read as absent here too, or DELETE would
    /// answer `204` for a page that GET and PUT both call gone. Such a row is left where it
    /// is rather than swept up opportunistically — reclamation is `deleteExpired`'s job, and
    /// a delete that removed rows it then reported as absent would be doing two things under
    /// one return value.
    ///
    /// The removal is hard — no tombstone, no reservation. The slug goes straight back
    /// into the pool, so a later POST can ask for it and the generator can draw it. That
    /// is the intended reading of a delete: the caller is giving the name up, not holding
    /// it. Anyone still following the old link sees whatever gets published there next.
    ///
    /// - Returns: true if a live row was removed, false if no live page existed there.
    func delete(slug: Slug) async throws -> Bool

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

    /// Amends a page's address, its deadline, or both, reclaiming expired rows first.
    ///
    /// The policy half of `applyAmendment`, and it is one line: the same reclaim-*before*-write
    /// ordering `create` uses, for the same reason. A rename onto a name whose page died
    /// yesterday should succeed — the row is invisible to every reader, and the only thing
    /// still holding the name is disk nobody has got around to freeing. Without this the
    /// caller gets a `409` naming a page they cannot fetch, look at, or delete, with no action
    /// available that would clear it.
    ///
    /// It lives in the extension rather than in each conformer so the in-memory fake and the
    /// Postgres store cannot disagree about it, which is the same reason `create`'s retry loop
    /// is here. A failure to reclaim propagates rather than being swallowed: a database that
    /// cannot DELETE will not UPDATE either.
    ///
    /// Distinct in name from the primitive on purpose. Defaulting a `logger` argument to make
    /// the two overloads share one name would leave `amend(slug:newSlug:newExpiry:)` resolving
    /// to the *primitive* — silently skipping reclamation at whichever call site forgot the
    /// argument, which is precisely the bug this arrangement exists to make unwritable.
    public func amend(
        slug: Slug,
        newSlug: Slug?,
        newExpiry: PageExpiry?,
        logger: Logger? = nil
    ) async throws -> PageAmendOutcome {
        let reclaimed = try await deleteExpired()
        if reclaimed > 0 {
            logger?.info("reclaimed expired pages", metadata: ["count": "\(reclaimed)"])
        }
        return try await applyAmendment(slug: slug, newSlug: newSlug, newExpiry: newExpiry)
    }
}
