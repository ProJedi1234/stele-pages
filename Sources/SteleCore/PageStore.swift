import Crypto
import Foundation
import Logging
import PostgresNIO

/// The `pages.kind` column, which says which half of a row is populated.
///
/// A column rather than a rule inferred from `body IS NULL`, even though migration 6's
/// CHECK constraint makes the two equivalent today. The equivalence is what a third kind
/// would break, and the failure mode of inferring is silent: every existing read would
/// classify the new kind as whichever side of the NULL it happened to land on. Asking a
/// column that was deliberately written is a question with an answer.
enum PageKind: String {
    case text
    case blob
}

/// What a page holds, as read back — never the bytes of an attachment.
///
/// The asymmetry with `PageBody`, which is the same distinction on the way *in*, is the
/// point of having two types. A write has to carry an attachment's bytes; a read of a
/// page's metadata must not, because the callers of `fetch` are the viewer and the router,
/// and neither has any use for a 32 MB video it would have to buffer to ignore. Bytes come
/// out through `fetchBlob` alone, which is the only method in the seam that can return
/// them and the only one that takes a range to bound what it returns.
public enum PageContent: Sendable, Equatable {
    case text(String)
    /// An attachment: everything about the bytes except the bytes.
    ///
    /// `byteSize` and `digest` are read from `page_blobs` rather than recomputed, which is
    /// what lets the viewer render a size and the raw route emit an `ETag` without the
    /// column that holds the bytes ever being named in the query — Postgres does not
    /// detoast what it is not asked for.
    case attachment(byteSize: Int, digest: String, filename: String?)
}

/// A stored page, as read back from the database.
public struct Page: Sendable, Equatable {
    public var slug: Slug
    public var content: PageContent
    public var contentType: String
    public var createdAt: Date
    /// When the page stops being served, or nil if it never does.
    ///
    /// Nil means one thing only: somebody asked for `PageLifetime.neverKeyword`. Pages that
    /// predate expiry are not a second meaning — migration 2 gave them a real deadline as it
    /// added the column, which is why that backfill had to happen in the same migration.
    /// Once the column exists, a NULL is a decision rather than an absence of one.
    public var expiresAt: Date?
    /// The credential that last wrote this page, or nil for one written by the shared token
    /// or published before migration 3 added the column.
    ///
    /// Read back rather than write-only so attribution is *observable* — a column nothing
    /// ever selects is one whose writes no test can check, which is how it came to be
    /// unwritten in the first place. It is deliberately not served anywhere: `GET /:slug`
    /// answers with the body and its type, and who published a page is the operator's
    /// question, not the reader's.
    public var clientID: Int64?
}

/// One page as the index reports it: everything the landing page shows about a page, and
/// nothing else.
///
/// A type of its own rather than a `Page` carrying an empty body, and the omission is the
/// entire reason it exists. `Page` holds up to `maxPageBytes` — a megabyte by default — and
/// the index reads twenty rows at once, so a shape that *could* hold a body is one that a
/// later `SELECT *` would quietly fill twenty times over. There is nothing here to fill.
///
/// `clientID` is absent for a second reason, and it is not an oversight either: who
/// published a page is the operator's question, answered by the admin routes, and this
/// struct is rendered into a page anyone can load.
public struct PageSummary: Sendable, Equatable {
    public var slug: Slug
    public var contentType: String
    public var createdAt: Date
    /// When the page stops being served, or nil if it never does — the same vocabulary
    /// `Page.expiresAt` uses, because it is read out of the same column.
    public var expiresAt: Date?

    public init(slug: Slug, contentType: String, createdAt: Date, expiresAt: Date?) {
        self.slug = slug
        self.contentType = contentType
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public enum PageStoreError: Error, Equatable {
    /// The caller asked for a specific slug that is already taken.
    case slugTaken(Slug)
    /// The generator lost the collision race repeatedly. Effectively impossible unless
    /// the table has grown to a meaningful fraction of the keyspace.
    case couldNotAllocateSlug(attempts: Int)
    /// A `pages` row says it is an attachment and `page_blobs` has nothing under its slug.
    ///
    /// Unreachable through this store: the two rows are written in one transaction and the
    /// foreign key cascades, so nothing short of a hand-edited database produces it. It is
    /// an error rather than a nil because the alternative is a 404 for a page that provably
    /// exists — the row is right there — and a reader cannot tell that apart from an expiry
    /// they missed. Failing loudly is what puts it in the log instead of in a bug report
    /// six weeks later.
    case blobMissing(Slug)
}

/// All database access, and the schema's history along with it. Every statement here is
/// parameterised via PostgresNIO's interpolation, which binds values rather than splicing
/// them into SQL text.
public struct PageStore: Sendable {
    private let client: PostgresClient
    private let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    /// Fetches a page, or nil if no such slug exists — or if it has expired.
    public func fetch(slug: Slug) async throws -> Page? {
        // The deadline is tested in the query rather than by the caller, and that is the
        // whole correctness half of expiry. Reclamation only runs on upload, so a row can
        // outlive its `expires_at` by any amount of time; filtering here means a page stops
        // being served at exactly its deadline no matter when — or whether — anything gets
        // around to deleting it.
        // A LEFT JOIN rather than a second query, and `b.bytes` is deliberately not among
        // the columns: Postgres does not detoast a value the query never names, so this
        // reads an attachment's size and digest without touching the megabytes sitting
        // beside them. That property is the whole reason the bytes live in their own table,
        // and it is one an incautious `SELECT b.*` would silently give back.
        let rows = try await client.query(
            """
            SELECT p.kind, p.body, p.content_type, p.filename, p.created_at,
                   p.expires_at, p.client_id, b.byte_size, b.digest
            FROM pages p LEFT JOIN page_blobs b ON b.slug = p.slug
            WHERE p.slug = \(slug.value)
              AND (p.expires_at IS NULL OR p.expires_at > now())
            """,
            logger: logger
        )

        // `Date?`, not `Date`. Every page published with `?ttl=never` holds NULL here, so
        // decoding this as non-optional would compile, pass any test written against a page
        // with a deadline, and throw at runtime on precisely the pages someone chose to keep
        // forever. Version 2's backfill removed the *other* source of NULLs — pages older
        // than the column — but not this one, and this one is permanent by design.
        //
        // `client_id` is optional for a different reason and permanently so: the shared
        // token has no row to point at, and pages written before migration 3 have no owner
        // to name.
        // `body` is `String?` now and `byte_size`/`digest` are optional for the mirror-image
        // reason: exactly one side of that pair is populated in any row, and which one is
        // what `kind` says. Decoding either as non-optional would compile and then throw on
        // precisely the rows the other kind produces.
        for try await (kind, body, contentType, filename, createdAt, expiresAt, clientID,
                       byteSize, digest) in rows.decode(
            (String, String?, String, String?, Date, Date?, Int64?, Int64?, String?).self,
            context: .default
        ) {
            return Page(
                slug: slug,
                content: try Self.content(
                    kind: kind, slug: slug, body: body,
                    filename: filename, byteSize: byteSize, digest: digest
                ),
                contentType: contentType,
                createdAt: createdAt,
                expiresAt: expiresAt,
                clientID: clientID
            )
        }
        return nil
    }

    /// Resolves the two half-populated column sets a row can carry into the one that
    /// `kind` says is real.
    ///
    /// `kind` is the authority rather than "body is NULL, so it must be an attachment",
    /// which is the same reading the CHECK constraint in migration 6 enforces. Inferring
    /// from the NULL would work today and would quietly pick a side the day a third kind
    /// exists; asking the column that was written to answer this question does not.
    private static func content(
        kind: String, slug: Slug, body: String?,
        filename: String?, byteSize: Int64?, digest: String?
    ) throws -> PageContent {
        switch kind {
        case PageKind.blob.rawValue:
            // The CHECK constraint guarantees the `pages` half; the foreign key guarantees
            // the `page_blobs` half. Both still get asserted here, because a decode that
            // trusts a schema it cannot see is how a hand-edited database becomes a crash
            // in a request handler.
            guard let byteSize, let digest else { throw PageStoreError.blobMissing(slug) }
            return .attachment(byteSize: Int(byteSize), digest: digest, filename: filename)
        default:
            // A row whose `kind` this build does not recognise reads as text, which is what
            // the column defaults to and what every row written before migration 6 is. The
            // alternative — throwing — would make an older binary booted against a newer
            // database fail the *read* path rather than only declining to write the new
            // kind, and a rollback is exactly when that matters.
            return .text(body ?? "")
        }
    }

    /// The most recently published live pages, newest first.
    public func recent(limit: Int) async throws -> [PageSummary] {
        // The deadline predicate is the one `fetch` carries, and this is the route where
        // getting it wrong stops being a bug and becomes a disclosure. An index that listed
        // expired rows would tell a reader which names *used to* be pages — the publication
        // history of the namespace, which is the exact thing the byte-identical 404 exists to
        // withhold. Every surface in this file agrees on which pages exist; this one has to.
        //
        // `body` is deliberately not selected. Twenty rows of up to `maxPageBytes` each is a
        // megabyte-scale read to render a list of links, and none of those bytes reach the
        // page. `PageSummary` has nowhere to put them, which is what keeps it that way.
        //
        // `ORDER BY created_at DESC` rides `pages_created_at_idx`, created by version 1 with
        // exactly that ordering — so this is a limited index scan and not a sort of the whole
        // table, and the landing page needs no migration of its own.
        //
        // The `slug` tie-break is not decoration. `created_at` defaults to `now()`, which in
        // Postgres is *transaction* start time: pages inserted by one transaction share it to
        // the microsecond, and without a second key the planner may return them in either
        // order on successive loads. A list of links that reshuffles itself between refreshes
        // reads as a bug in the server rather than as a tie.
        let rows = try await client.query(
            """
            SELECT slug, content_type, created_at, expires_at
            FROM pages
            WHERE expires_at IS NULL OR expires_at > now()
            ORDER BY created_at DESC, slug ASC
            LIMIT \(limit)
            """,
            logger: logger
        )

        var summaries: [PageSummary] = []
        for try await (slug, contentType, createdAt, expiresAt) in rows.decode(
            (String, String, Date, Date?).self, context: .default
        ) {
            summaries.append(
                PageSummary(
                    // `Slug(unchecked:)`, which is what it is for: every one of these passed
                    // `Slug(custom:)` on the way into the table.
                    slug: Slug(unchecked: slug),
                    contentType: contentType,
                    createdAt: createdAt,
                    // `Date?` for the same permanent reason `fetch` decodes it that way: a
                    // page published with `?ttl=never` holds NULL here forever.
                    expiresAt: expiresAt
                )
            )
        }
        return summaries
    }

    /// - Returns: true if the row was inserted, false if the slug was already taken.
    public func insert(
        slug: Slug, body: PageBody, contentType: String, expiresAt: Date?, clientID: Int64?
    ) async throws -> Bool {
        switch body {
        case .text(let text):
            return try await insertText(
                slug: slug, text: text, contentType: contentType,
                expiresAt: expiresAt, clientID: clientID
            )
        case .blob(let bytes, let filename):
            return try await insertBlob(
                slug: slug, bytes: bytes, filename: filename, contentType: contentType,
                expiresAt: expiresAt, clientID: clientID
            )
        }
    }

    /// The `pages`-only half of `insert`, for a page whose body is text.
    private func insertText(
        slug: Slug, text: String, contentType: String, expiresAt: Date?, clientID: Int64?
    ) async throws -> Bool {
        // ON CONFLICT DO NOTHING makes the uniqueness check and the insert one atomic
        // step. Checking first and then inserting would leave a window where two
        // concurrent uploads both see the slug as free. Note that an *expired* row still
        // conflicts — it is a row — which is why `create` reclaims before it gets here.
        //
        // `client_id` is a foreign key into `clients`, so a nil here is the only way to
        // record a page whose writer has no row — the shared token's. `Client.attributableID`
        // is what turns that credential into the nil, upstream of this call.
        let rows = try await client.query(
            """
            INSERT INTO pages (slug, kind, body, content_type, expires_at, client_id)
            VALUES (\(slug.value), \(PageKind.text.rawValue), \(text), \(contentType),
                    \(expiresAt), \(clientID))
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

    /// The two-table half of `insert`, for a page whose body is bytes.
    ///
    /// One transaction, because a `pages` row claiming to be an attachment with no
    /// `page_blobs` row under it is the one state the schema cannot express and every read
    /// would then have to defend against — `PageStoreError.blobMissing` exists for a
    /// database somebody edited by hand, not for a window this store leaves open.
    ///
    /// A leased connection rather than two `client.query` calls: the pool hands out a
    /// different connection per call, so a BEGIN issued that way would open a transaction on
    /// one connection and the INSERT would run outside it on another.
    private func insertBlob(
        slug: Slug, bytes: [UInt8], filename: String?, contentType: String,
        expiresAt: Date?, clientID: Int64?
    ) async throws -> Bool {
        try await client.withConnection { connection in
            try await connection.withTransaction(logger: logger) { transaction in
                // The same untargeted `ON CONFLICT DO NOTHING` the text path uses, and it
                // still decides the whole outcome: if this claims no row the slug was taken,
                // and the blob insert below must not run. Returning early inside the
                // transaction commits an empty one, which is the cheapest correct thing.
                let claimed = try await transaction.query(
                    """
                    INSERT INTO pages
                        (slug, kind, body, content_type, filename, expires_at, client_id)
                    VALUES (\(slug.value), \(PageKind.blob.rawValue), NULL, \(contentType),
                            \(filename), \(expiresAt), \(clientID))
                    ON CONFLICT (slug) DO NOTHING
                    RETURNING slug
                    """,
                    logger: logger
                )

                var inserted = false
                for try await _ in claimed.decode(String.self, context: .default) {
                    inserted = true
                }
                guard inserted else { return false }

                // `Data`, not `[UInt8]`: PostgresNIO encodes an array as a Postgres *array*
                // — here `char[]` — rather than as `bytea`, which is the same trap
                // `ClientStore` documents for `token_hash` and fails at bind time with a
                // type mismatch that names neither this column nor that reason.
                try await transaction.query(
                    """
                    INSERT INTO page_blobs (slug, bytes, byte_size, digest)
                    VALUES (\(slug.value), \(Data(bytes)), \(Int64(bytes.count)),
                            \(Self.digest(of: bytes)))
                    """,
                    logger: logger
                )
                return true
            }
        }
    }

    /// - Returns: `.replaced` with the page's unchanged expiry, or `.noSuchPage` if no live
    ///   row exists at that slug.
    public func update(
        slug: Slug, body: PageBody, contentType: String?, clientID: Int64?
    ) async throws -> PageUpdateOutcome {
        // Both kinds run in one transaction, including text-replacing-text, which needs no
        // second statement. That uniformity is the point: a replacement may change a page's
        // *kind*, so the `page_blobs` row has to be created or removed in step with the
        // `pages` row it belongs to, and a text path that skipped the transaction would be
        // one branch out of four where it does not.
        try await client.withConnection { connection in
            try await connection.withTransaction(logger: logger) { transaction in
                try await Self.applyUpdate(
                    slug: slug, body: body, contentType: contentType, clientID: clientID,
                    on: transaction, logger: logger
                )
            }
        }
    }

    /// The body of `update`, inside the caller's transaction.
    private static func applyUpdate(
        slug: Slug, body: PageBody, contentType: String?, clientID: Int64?,
        on transaction: PostgresConnection, logger: Logger
    ) async throws -> PageUpdateOutcome {
        // A single UPDATE is its own existence check: the WHERE clause and the write are
        // one statement, and RETURNING tells us whether a row matched. `created_at` is
        // left alone, so a replaced page keeps the moment it was first published, and a
        // nil content type COALESCEs to the stored value rather than overwriting it.
        //
        // `expires_at` is left alone for exactly the reason `created_at` is: a replacement
        // is a new body at an old address, not a new page. If editing extended the deadline,
        // a link's lifetime would depend on how often somebody happened to touch it.
        //
        // `client_id` gets the opposite treatment to both, and deliberately: it is
        // *assigned* rather than left or COALESCEd. An absent content type means "the caller
        // expressed no opinion", whereas the writer is never absent — it is whoever's
        // credential just replaced these bytes. Coalescing it would leave a page attributed
        // to a credential that wrote none of what it now serves.
        //
        // The same expired-row exclusion the fetch uses appears here so that a PUT to an
        // expired-but-unreclaimed page is a 404 exactly as a GET of it is — the write
        // surface and the read surface agree on which pages exist.
        //
        // `kind`, `body` and `filename` are assigned rather than coalesced, because a
        // replacement decides all three: a PUT of a PNG over an HTML page makes it an
        // attachment, and a PUT of HTML over a PNG makes it text again. `content_type` keeps
        // its COALESCE — that one really can be "no opinion", which is what an absent
        // request header means and what preserves a stylesheet's type across a re-upload.
        //
        // But only while the kind holds still. `kind` inside the CASE is the row's *old*
        // value, so "no opinion" preserves the stored type for a replacement of like with
        // like and falls back to the default when the page changes kind — because the
        // stored type describes bytes that are being thrown away, and keeping it would
        // serve HTML as `image/png` behind a `200`. `nosniff` stops that being dangerous
        // and nothing stops it being wrong.
        //
        // The ELSE arm is only ever reached by a text body: an attachment write names its
        // type or is refused before it reaches the store, so a nil `contentType` here is
        // provably a text one. That is the router's guarantee rather than this statement's,
        // which is why the fallback is spelled out instead of being derived from `kind`.
        let kind: PageKind
        let text: String?
        let filename: String?
        switch body {
        case .text(let value):
            kind = .text
            text = value
            filename = nil
        case .blob(_, let name):
            kind = .blob
            text = nil
            filename = name
        }

        let rows = try await transaction.query(
            """
            UPDATE pages
            SET kind = \(kind.rawValue),
                body = \(text),
                filename = \(filename),
                content_type = COALESCE(
                    \(contentType),
                    CASE WHEN kind = \(kind.rawValue) THEN content_type
                         ELSE \(PageContentType.default) END
                ),
                client_id = \(clientID)
            WHERE slug = \(slug.value)
              AND (expires_at IS NULL OR expires_at > now())
            RETURNING expires_at
            """,
            logger: logger
        )

        var expiry: Date??
        for try await expiresAt in rows.decode(Date?.self, context: .default) {
            expiry = expiresAt
        }
        guard let expiresAt = expiry else { return .noSuchPage }

        // Unconditional, and that is what makes the four kind transitions three statements
        // instead of a truth table. The row for the *old* bytes goes whatever the new body
        // is — replacing an attachment means its previous bytes are dead either way — and
        // the insert below only runs when the new body has bytes of its own.
        try await transaction.query(
            "DELETE FROM page_blobs WHERE slug = \(slug.value)", logger: logger
        )

        if case .blob(let bytes, _) = body {
            try await transaction.query(
                """
                INSERT INTO page_blobs (slug, bytes, byte_size, digest)
                VALUES (\(slug.value), \(Data(bytes)), \(Int64(bytes.count)),
                        \(digest(of: bytes)))
                """,
                logger: logger
            )
        }

        return .replaced(expiresAt: expiresAt)
    }

    /// - Returns: the requested slice of an attachment's bytes, or nil if no live
    ///   attachment exists at that slug.
    public func fetchBlob(slug: Slug, range: Range<Int>?) async throws -> PageBlobSlice? {
        // The range is applied by Postgres rather than by slicing a fetched value, which is
        // the entire reason `page_blobs.bytes` is `STORAGE EXTERNAL`: an uncompressed TOAST
        // value supports a genuine partial read, so a seek into the middle of a video reads
        // the pages it lands on instead of the whole file. With the default EXTENDED
        // storage this same statement would be correct and would decompress from the start
        // every time.
        //
        // `substring` is 1-indexed, hence the `+ 1`. `Int32` and not `Int64`, because the
        // overload Postgres offers for `bytea` takes `integer` — binding a `bigint` fails
        // to resolve the function at all rather than widening to it, which is a `42883` at
        // runtime and compiles perfectly. `clamping:` because the caller's range comes from
        // a `Range:` header eventually, and saturating is the honest answer for an offset
        // past anything this column can hold.
        // Clamped *before* the `+ 1`, not after, and that order is the whole point. The
        // offset originates in a `Range:` header, so `Int.max` is a value a caller can
        // simply send; `Int32(clamping: lowerBound + 1)` would overflow on the addition
        // before the clamp ever ran, and an overflow in Swift is a trap — which makes it an
        // unauthenticated way to take the process down. Clamping first bounds the operand,
        // and the saturated case skips the increment rather than repeating the problem one
        // width down. Every value that did not trap keeps the result it had.
        let offset = Int32(clamping: range?.lowerBound ?? 0)
        let start = offset == .max ? offset : offset + 1

        // An upper bound past what an `Int32` can express *is* "to the end", and is read
        // that way rather than clamped to a large number. That spelling is what lets a
        // caller who does not know the size — every `bytes=N-` request, which is what a
        // video player sends after its first probe — ask for the rest of a file in one
        // read. Clamping to `Int32.max` instead would work today only because the
        // configured ceiling is far below it, which is a correctness argument resting on a
        // number in another file.
        let length: Int32?
        if let range, range.upperBound < Int(Int32.max) {
            length = Int32(clamping: range.count)
        } else {
            length = nil
        }

        // The deadline predicate again, on `pages`, because the bytes have no expiry of
        // their own and this route is a read like any other. Without it an expired
        // attachment would keep serving through `/static` after `GET /:slug` had started
        // 404ing it — the write surface and the read surface disagreeing about which pages
        // exist, in the one place where the disagreement is invisible from a browser.
        // Two statements rather than one with a nullable length. A nil bind reaches
        // Postgres as `unknown`, which `substring` cannot resolve an overload against, and
        // the alternatives are worse than a branch: casting the NULL puts a type name in
        // the SQL to keep in step with the bind, and passing a huge length instead of NULL
        // is a magic number defending against nothing. "To the end" has its own spelling in
        // SQL, so this uses it.
        let query: PostgresQuery = if let length {
            """
            SELECT p.content_type, p.filename, b.byte_size, b.digest,
                   substring(b.bytes FROM \(start) FOR \(length))
            FROM page_blobs b JOIN pages p ON p.slug = b.slug
            WHERE b.slug = \(slug.value)
              AND (p.expires_at IS NULL OR p.expires_at > now())
            """
        } else {
            """
            SELECT p.content_type, p.filename, b.byte_size, b.digest,
                   substring(b.bytes FROM \(start))
            FROM page_blobs b JOIN pages p ON p.slug = b.slug
            WHERE b.slug = \(slug.value)
              AND (p.expires_at IS NULL OR p.expires_at > now())
            """
        }

        let rows = try await client.query(query, logger: logger)

        for try await (contentType, filename, byteSize, digest, bytes) in rows.decode(
            (String, String?, Int64, String, Data).self, context: .default
        ) {
            return PageBlobSlice(
                bytes: Array(bytes),
                contentType: contentType,
                filename: filename,
                // The size of the *whole* attachment, not of the slice — a `206` has to
                // report both, and only one of them is `bytes.count`.
                totalSize: Int(byteSize),
                digest: digest
            )
        }
        return nil
    }

    /// - Returns: `.amended` with the resulting slug and deadline, `.noSuchPage` if no live
    ///   row exists at `slug`, or `.slugTaken` if the target name is held by another row.
    public func applyAmendment(
        slug: Slug, newSlug: Slug?, newExpiry: PageExpiry?
    ) async throws -> PageAmendOutcome {
        // Two binds for one optional instruction, because the column already uses NULL to
        // mean "permanent" and so cannot also use it to mean "unchanged". `COALESCE` handles
        // the slug — nil there is unambiguous, since no row has a NULL name — but the expiry
        // needs the boolean to distinguish `?ttl=never` from an absent `?ttl=`. Collapsing
        // these into one nullable bind would make every `never` a no-op.
        let changesExpiry = newExpiry != nil
        let expiryValue = newExpiry?.date ?? nil

        do {
            // One UPDATE, so the existence check, the deadline predicate and the write are a
            // single statement — the same reasoning as `update` and `delete` above. The
            // collision check is *not* a clause here, deliberately: any `NOT EXISTS`
            // sub-select is evaluated against the statement's snapshot, so a concurrent
            // insert of the target name committing in between would pass the check and then
            // violate the index anyway. The primary key is the only authority that cannot be
            // raced, so the conflict is caught below from the error it raises rather than
            // predicted here.
            //
            // Renaming a page to the name it already holds updates the row to its own value,
            // which no unique index objects to, so the no-op case falls out rather than
            // needing a branch.
            let rows = try await client.query(
                """
                UPDATE pages
                SET slug = COALESCE(\(newSlug?.value), slug),
                    expires_at = CASE WHEN \(changesExpiry) THEN \(expiryValue)
                                      ELSE expires_at END
                WHERE slug = \(slug.value)
                  AND (expires_at IS NULL OR expires_at > now())
                RETURNING slug, expires_at
                """,
                logger: logger
            )

            // `Date?` for the same permanent reason `fetch` decodes one: a page amended to
            // `never` — or one that was already permanent and only moved — returns NULL here,
            // and this is the statement that produces that row.
            for try await (resulting, expiresAt) in rows.decode(
                (String, Date?).self, context: .default
            ) {
                // `unchecked:` because the value came back out of the column. Either it is
                // the `newSlug` this call validated, or it is the row's existing name, which
                // passed `Slug(custom:)` on its way in.
                return .amended(slug: Slug(unchecked: resulting), expiresAt: expiresAt)
            }
            return .noSuchPage
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == Self.uniqueViolation {
            // Only a slug change can collide, so a unique violation with no rename requested
            // is some other constraint failing and must not be reported as a taken name.
            guard let newSlug else { throw error }
            return .slugTaken(newSlug)
        }
    }

    /// SHA-256 of an attachment's bytes, lowercase hex, stored in `page_blobs.digest`.
    ///
    /// Deliberately not `strongETag(over:)`, which every other validator in this server
    /// comes from. That helper hashes bytes the caller is already holding, and the entire
    /// point of this column is that the reader is *not* holding them: the viewer and the
    /// `304` path need a validator without detoasting a 32 MB video to compute one. So the
    /// digest is taken once, at write time, and read back as a column. The HTTP layer
    /// quotes it into an entity-tag; what is stored is a fact about the bytes rather than
    /// an HTTP artefact.
    ///
    /// SHA-256 rather than FNV-1a because this one is written down and outlives the
    /// request that made it — a stored digest is the thing you compare against when asking
    /// whether two uploads are the same bytes, and 64 bits is not enough to answer that.
    static func digest(of bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// SQLSTATE `unique_violation`. Named rather than typed at the catch site so the one
    /// place that turns a database error into a `409` says which error it means.
    static let uniqueViolation = "23505"

    /// Deletes every row whose deadline has passed, returning their slugs to the pool.
    ///
    /// - Returns: how many rows were removed.
    public func deleteExpired() async throws -> Int {
        // `expires_at <= now()` is the exact complement of the `expires_at > now()` the
        // reads use, so nothing this deletes was still visible and nothing visible is
        // deleted. The partial index on `expires_at` — `WHERE expires_at IS NOT NULL` —
        // is what keeps this cheap on a table that is mostly permanent pages.
        //
        // Counted by iterating `RETURNING slug` rather than read off a command tag:
        // `PostgresRowSequence` exposes no affected-row count, and the returned rows are
        // pages that no longer exist, so the sequence is only ever as long as the work was.
        let rows = try await client.query(
            """
            DELETE FROM pages
            WHERE expires_at IS NOT NULL AND expires_at <= now()
            RETURNING slug
            """,
            logger: logger
        )

        var deleted = 0
        for try await _ in rows.decode(String.self, context: .default) {
            deleted += 1
        }
        return deleted
    }

    /// - Returns: true if a live row was removed, false if no live page exists at that slug.
    public func delete(slug: Slug) async throws -> Bool {
        // Like the UPDATE above, the statement is its own existence check: the WHERE
        // clause and the removal are one command, and RETURNING says whether a row
        // matched. Reading first and then deleting would leave a window in which a
        // concurrent PUT rewrites the row — or a POST claims the slug again after a
        // parallel delete — and this would answer for a page other than the one it
        // removed. The row is gone outright: no tombstone column to filter out of every
        // later read, and the slug is free the moment this commits.
        //
        // The deadline predicate is the same one `fetch` and `update` carry, and it is here
        // for the reason it is there: the write surface and the read surface have to agree
        // on which pages exist. Without it a DELETE aimed at an expired-but-unreclaimed row
        // would remove it and answer `204` — "I deleted that for you" about a page every
        // reader already 404s, and about work the next upload's reclamation was going to do
        // anyway. The row stays; `deleteExpired` owns it.
        let rows = try await client.query(
            """
            DELETE FROM pages WHERE slug = \(slug.value)
              AND (expires_at IS NULL OR expires_at > now())
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

// MARK: - Schema migrations

extension PageStore {
    /// One versioned step in the schema's history.
    ///
    /// `statements` run in order, each as its own query: PostgresNIO speaks the extended
    /// query protocol, which refuses more than one command per message, so a migration is
    /// a list of statements rather than one semicolon-separated script. They are
    /// `PostgresQuery` literals with no interpolation on purpose — DDL cannot take bind
    /// parameters, and a `\(…)` inside one of these would become a *bind* rather than SQL
    /// text, failing loudly instead of doing what it looks like it does.
    ///
    /// Every migration runs inside a transaction, so the statements Postgres refuses to
    /// run in one — `CREATE INDEX CONCURRENTLY`, `VACUUM`, `ALTER SYSTEM` — cannot be
    /// expressed today. The per-migration transaction boundary is the seam where a
    /// `transactional: Bool = true` flag would go if one is ever needed; building it
    /// before there is a migration that wants it is ceremony.
    struct Migration: Sendable {
        let version: Int32
        let statements: [PostgresQuery]
    }

    /// The schema's entire history, in version order.
    ///
    /// **Append only.** An applied version is a fact recorded in every database that has
    /// ever booted this code; editing an entry diverges the databases that already ran it
    /// from the ones that haven't, with nothing to detect the difference. Change the
    /// schema by adding the next version — version 2 is what that looks like, and it is
    /// deliberately not another idempotent `ALTER` bolted onto version 1.
    ///
    /// The number is claimed by whatever merges first, and that is not a formality: two
    /// branches that both append a "version 3" produce databases where version 3 means two
    /// different things and `schema_migrations` cannot tell them apart. Rebasing onto a list
    /// that has grown means renumbering, not keeping the number the branch was written with.
    ///
    /// Statements are not limited to DDL. Because a version runs exactly once and commits
    /// with the row recording it, a data backfill belongs in a migration too and will run
    /// once, ever.
    static let migrations: [Migration] = [
        Migration(
            version: 1,
            statements: [
                // `IF NOT EXISTS` because version 1 is a retroactive description of a
                // schema that already exists in production, created by the idempotent
                // bootstrap this runner replaces. There, v1 must do nothing but record
                // itself; on a virgin database it must build the schema. That is what
                // makes the upgrade a deploy rather than a dump and restore.
                """
                CREATE TABLE IF NOT EXISTS pages (
                    slug         text PRIMARY KEY,
                    body         text NOT NULL,
                    content_type text NOT NULL,
                    created_at   timestamptz NOT NULL DEFAULT now()
                )
                """,
                "CREATE INDEX IF NOT EXISTS pages_created_at_idx ON pages (created_at DESC)",
            ]
        ),
        Migration(
            version: 2,
            statements: [
                // No `IF NOT EXISTS` here, unlike version 1. Version 1 needed it because it
                // retroactively described a schema that already existed in production;
                // version 2 has never run anywhere, so `schema_migrations` alone decides
                // whether it runs. A conditional form would hide a divergence rather than
                // fail on it.
                //
                // Nullable with no default. The nullability is the vocabulary — NULL means
                // "never expires" — and no default is what makes this a catalog-only change:
                // Postgres rewrites no rows for a nullable column with no default, so the
                // `ALTER` is instant on a table of any size.
                "ALTER TABLE pages ADD COLUMN expires_at timestamptz",
                // Existing pages become ephemeral too, and this statement is the only moment
                // in the schema's whole history when that can be said accurately. One
                // statement ago the column did not exist, so *every* NULL here is a page that
                // predates expiry. A backfill written any later could not tell those apart
                // from a page whose author asked for `never` — the two are the same value —
                // and would quietly put a deadline on pages someone had deliberately made
                // permanent.
                //
                // `now()`, not `created_at`: a page older than the default would otherwise
                // land with a deadline already in the past and be deleted by the next upload,
                // so a feature meant to bound storage would begin by destroying the archive
                // it was pointed at. Everything already published instead gets one full
                // default lifetime measured from the upgrade, which is also the only reading
                // under which nobody's link dies before they could have heard about it.
                //
                // The interval is written out rather than interpolated from
                // `PageLifetime.defaultDays`, and must stay that way. A migration is a record
                // of what was done once; if the default later becomes fourteen days, this
                // statement must still say seven, because seven days is what the databases
                // that already ran it actually wrote. Interpolating a constant here would
                // silently rewrite history every time the constant moved.
                "UPDATE pages SET expires_at = now() + interval '7 days' WHERE expires_at IS NULL",
                // Built last, after the backfill, so the `UPDATE` above has no index to
                // maintain while it runs.
                //
                // Partial, on exactly the predicate the reclaiming DELETE uses. Permanent
                // pages never enter the index at all, so a table that is mostly permanent
                // pages pays almost nothing to keep it — which is what makes running the
                // cleanup on every single upload affordable.
                """
                CREATE INDEX pages_expires_at_idx ON pages (expires_at)
                WHERE expires_at IS NOT NULL
                """,
            ]
        ),
        Migration(
            version: 3,
            statements: [
                // Per-client credentials. No `IF NOT EXISTS`: unlike version 1 this
                // describes a table that has never existed anywhere, so a name collision
                // is a mistake worth failing the boot over rather than a state to
                // tolerate.
                //
                // `token_hash` is the digest, never the token — see `ClientCredential`.
                // Its UNIQUE constraint is also the index the authentication lookup rides
                // on, which is what keeps that a hash comparison rather than a scan.
                //
                // The `'{publish}'` default is `ClientScope.publish` retyped, the one
                // place in the repo where that is unavoidable: these statements are
                // literal SQL by design — a `\(…)` here becomes a *bind* parameter, and
                // DDL cannot take binds. `MigrationListTests` pins the two together
                // instead.
                """
                CREATE TABLE clients (
                    id           bigserial PRIMARY KEY,
                    name         text NOT NULL UNIQUE,
                    token_hash   bytea NOT NULL UNIQUE,
                    scopes       text[] NOT NULL DEFAULT '{publish}',
                    created_at   timestamptz NOT NULL DEFAULT now(),
                    last_used_at timestamptz,
                    expires_at   timestamptz,
                    revoked_at   timestamptz
                )
                """,
                // Nullable, and left null for every page that already exists. Those were
                // written with the shared token and there is no honest owner to invent
                // for them. The column cannot be backfilled here either: `migrate()` runs
                // in the store layer and has no access to configuration, so it could not
                // hash `STELE_UPLOAD_TOKEN` into a `clients` row even if that were the
                // right answer — and keeping that separation is worth more than a tidier
                // backfill.
                "ALTER TABLE pages ADD COLUMN client_id bigint REFERENCES clients (id)",
            ]
        ),
        Migration(
            version: 4,
            statements: [
                // Version 3 made `name` unique across the whole table, and rows are never
                // deleted — so revoking `claude-code` retired that name permanently and the
                // replacement had to be called `claude-code-2`. Rotation is the ordinary
                // reason to revoke, and a name that survives it is the whole point of having
                // one: it is the handle `DELETE /admin/clients/:name` addresses and the
                // string an operator recognises in a listing.
                //
                // Uniqueness moves to the live rows rather than being dropped. Two *usable*
                // credentials sharing a name would make revocation ambiguous at exactly the
                // wrong moment, which is the thing version 3 was right about; the history
                // beside them is what an incident is reconstructed from and does not need to
                // be unique to be read. `ClientStore.revoke` is what resolves the resulting
                // several-rows-one-name to a single row — live first, newest revocation
                // otherwise.
                //
                // The constraint is dropped by the name Postgres generates for a column-level
                // UNIQUE (`<table>_<column>_key`), not by one version 3 chose. No
                // `IF EXISTS`: on any database that ran version 3 it is there, and on one
                // where it is not, something has edited the schema by hand and the boot
                // should say so.
                "ALTER TABLE clients DROP CONSTRAINT clients_name_key",
                """
                CREATE UNIQUE INDEX clients_live_name_idx
                ON clients (name) WHERE revoked_at IS NULL
                """,
            ]
        ),
        Migration(
            version: 5,
            statements: [
                // Which GitHub account signed in to mint this credential. Nullable, and
                // that is the honest shape rather than the convenient one: a credential
                // minted through `POST /admin/clients` was nobody's GitHub identity, and a
                // NOT NULL column would demand a value that does not exist — which in
                // practice means an empty string or an invented login, and both are
                // indistinguishable from a real answer once they are in the table. The
                // column is an audit record, so a fabricated entry is worse than no entry.
                //
                // No backfill, and unlike version 2's there is nothing this one could
                // honestly write. Every row that predates this column was minted through
                // the admin route, so NULL already says the true thing about all of them.
                // Version 2 had to backfill because its NULL became ambiguous the instant
                // the column existed — it could mean "predates expiry" or "deliberately
                // permanent" — and this one's does not: nothing but the GitHub exchange
                // writes this column, so NULL means "not signed in for" rather than
                // "unknown". A second identity provider would need its own answer here,
                // because its credentials would arrive carrying a NULL that means something
                // else again — which is a migration to write then, not a hedge to leave now.
                //
                // No default and no index. The default is left off for the reason above
                // rather than for speed: Postgres keeps a constant default in the catalog
                // and rewrites no rows for it, so one would cost nothing in time and would
                // stamp a login no account ever chose onto every credential minted after
                // it. And nothing looks a credential up by this column — a repeat sign-in
                // resolves by *name*, the login folded into the alphabet a credential is
                // addressed by — so this is the answer to "which account minted this?" that
                // an operator reads out of a listing, not a key anything joins on.
                "ALTER TABLE clients ADD COLUMN github_login text",
            ]
        ),
        Migration(
            version: 6,
            statements: [
                // Attachments: a page whose body is bytes. The bytes go in their own table
                // and everything else about them stays in `pages`, which is what keeps one
                // slug namespace, one expiry column and one reclamation path for both kinds
                // — every route that already deletes, renames, expires or lists a page does
                // so for an attachment with no new code.
                //
                // `body` becomes nullable because an attachment has none. That is the one
                // constraint this migration relaxes, and the CHECK below is what stops the
                // relaxation reaching text pages, where a NULL body would be a page serving
                // nothing behind a 200.
                "ALTER TABLE pages ALTER COLUMN body DROP NOT NULL",
                // `NOT NULL DEFAULT 'text'` is the backfill: every row that predates this
                // column is a text page, and Postgres stores a constant default in the
                // catalog rather than rewriting the table for it. Unlike version 2's
                // deadline there is nothing ambiguous to resolve later — a row written
                // before attachments existed cannot have been one.
                "ALTER TABLE pages ADD COLUMN kind text NOT NULL DEFAULT 'text'",
                // The original filename, for the one thing a slug cannot carry: what a
                // browser should call the file when it saves it. Nullable because a text
                // page was never a file.
                "ALTER TABLE pages ADD COLUMN filename text",
                """
                ALTER TABLE pages ADD CONSTRAINT pages_kind_ck
                    CHECK (kind IN ('text', 'blob'))
                """,
                // The invariant `PageStore.content(kind:…)` reads back. Written as an
                // equality between two booleans rather than as two ORed implications
                // because it has to close both directions: a text page with no body and an
                // attachment carrying one are both rows this code would misread, and only
                // one of them is the obvious mistake.
                """
                ALTER TABLE pages ADD CONSTRAINT pages_kind_body_ck
                    CHECK ((kind = 'text') = (body IS NOT NULL))
                """,
                // `ON DELETE CASCADE` is what makes `deleteExpired`, `delete(slug:)` and
                // every expiry sweep reclaim an attachment's bytes without knowing
                // attachments exist. `ON UPDATE CASCADE` does the same for `applyAmendment`,
                // whose rename is an UPDATE of the primary key this references.
                //
                // Both are properties of storing the bytes in Postgres. A future object
                // store would have to do this work in the application, with no transaction
                // spanning the two — which is the sweeper this server currently does not
                // need, and the real cost of that swap.
                """
                CREATE TABLE page_blobs (
                    slug      text PRIMARY KEY
                              REFERENCES pages (slug) ON UPDATE CASCADE ON DELETE CASCADE,
                    bytes     bytea  NOT NULL,
                    byte_size bigint NOT NULL,
                    digest    text   NOT NULL
                )
                """,
                // EXTERNAL, not the default EXTENDED, and this is load-bearing rather than
                // a tuning knob: TOAST only supports a genuine partial read of an
                // *uncompressed* value, so `fetchBlob`'s `substring` is a seek with this
                // line and a decompress-from-the-start without it. Video and images arrive
                // compressed anyway, so what EXTENDED would buy on this column is nothing.
                "ALTER TABLE page_blobs ALTER COLUMN bytes SET STORAGE EXTERNAL",
            ]
        ),
    ]

    /// Advisory locks are scoped to a database, so this constant only ever collides with
    /// another stele booting against the same database — which is exactly what it's for.
    /// Typed `Int64` to select `pg_advisory_lock(bigint)` rather than the `(int4, int4)`
    /// overload.
    ///
    /// Internal rather than private so the Postgres test suite can assert from a second
    /// session that the lock was released.
    static let migrationLockKey: Int64 = 0x5354_454C_4501  // "STELE" + 01

    /// Brings the database up to the newest schema version, applying only what it has not
    /// already applied.
    ///
    /// Still runs on every boot; there is still no separate migrate step. Two things make
    /// that safe. Each migration and the row recording it commit in one transaction, so
    /// "applied but unrecorded" is not a state the database can be left in. And the whole
    /// run holds a session-level advisory lock, so two instances starting at once
    /// serialise and the loser finds the work already done.
    public func migrate() async throws {
        try await migrate(Self.migrations)
    }

    /// The runner proper. Takes its list as a parameter so tests can drive it with
    /// migrations that aren't the real schema.
    func migrate(_ migrations: [Migration]) async throws {
        // One leased connection for the whole run: `pg_advisory_lock` is session-scoped,
        // and `client.query` leases a different connection per call, so a lock taken that
        // way would be held by an arbitrary pooled connection and released whenever that
        // connection happened to close.
        let newestVersion = try await client.withConnection { connection in
            // `pg_advisory_lock` waits indefinitely. That is the wanted behaviour during a
            // rolling restart — the second instance should wait for the first, not fail
            // its boot — but it means a wedged holder hangs this one before it ever binds
            // its port. This line is what makes that diagnosable in one grep.
            logger.info("acquiring the migration lock")
            try await connection.query(
                "SELECT pg_advisory_lock(\(Self.migrationLockKey))", logger: logger
            )
            let newestVersion: Int32?
            do {
                newestVersion = try await apply(migrations, on: connection)
            } catch {
                // The pool hands a connection back without resetting its session state, so
                // a lock left held would outlive this boot and block the next one. `defer`
                // cannot `await`, so the unlock lives on both exits explicitly. If this one
                // also fails the connection is already broken, and the backend's disconnect
                // releases the lock server-side.
                _ = try? await connection.query(
                    "SELECT pg_advisory_unlock(\(Self.migrationLockKey))", logger: logger
                )
                throw error
            }
            try await connection.query(
                "SELECT pg_advisory_unlock(\(Self.migrationLockKey))", logger: logger
            )
            return newestVersion
        }
        // Which schema version a running instance believes it is on, stated once per boot.
        // During an incident that is the first thing worth knowing and the last thing
        // anyone wants to derive by reading the deployed tag.
        logger.info(
            "schema migrations up to date",
            metadata: ["version": "\(newestVersion.map(String.init) ?? "none")"]
        )
    }

    /// - Returns: the newest version recorded in `schema_migrations` once the run is done,
    ///   or nil if the list was empty and the database has never had a migration applied.
    private func apply(
        _ migrations: [Migration], on connection: PostgresConnection
    ) async throws -> Int32? {
        // Inside the lock, not before it. `CREATE TABLE IF NOT EXISTS` is not atomic —
        // two sessions can both pass the existence check and one then fails on the
        // catalog's unique index — and reading the applied versions before the lock would
        // let a waiting boot act on a snapshot the winner has since changed. (The
        // bootstrap this replaces had that first race on `pages`; the lock closes it.)
        try await connection.query(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version    integer PRIMARY KEY,
                applied_at timestamptz NOT NULL DEFAULT now()
            )
            """,
            logger: logger
        )

        var applied = Set<Int32>()
        let rows = try await connection.query(
            "SELECT version FROM schema_migrations", logger: logger
        )
        for try await version in rows.decode(Int32.self, context: .default) {
            applied.insert(version)
        }

        // An older binary booting against a newer database does nothing — it only
        // iterates its own list — which is right, but silent. Say it out loud: this is
        // exactly the situation an operator wants named during a rollback.
        let newestInBuild = migrations.last?.version ?? 0
        if let newestApplied = applied.max(), newestApplied > newestInBuild {
            logger.warning(
                "database schema is newer than this build",
                metadata: ["database": "\(newestApplied)", "build": "\(newestInBuild)"]
            )
        }

        for migration in migrations where !applied.contains(migration.version) {
            // Logged before the transaction because `withTransaction` wraps failures in
            // `PostgresTransactionError`; without this line a failed boot's log has a
            // wrapped error and no indication of which version failed.
            logger.info("applying migration", metadata: ["version": "\(migration.version)"])
            // Statements and version row commit or roll back together. That is the whole
            // exactly-once guarantee: a half-applied migration leaves no version row and
            // is retried; a recorded version means every statement landed, including a
            // one-shot data backfill.
            try await connection.withTransaction(logger: logger) { transaction in
                for statement in migration.statements {
                    try await transaction.query(statement, logger: logger)
                }
                try await transaction.query(
                    "INSERT INTO schema_migrations (version) VALUES (\(migration.version))",
                    logger: logger
                )
            }
            applied.insert(migration.version)
        }

        return applied.max()
    }
}

/// `PageStore` is the database-backed conformer of the seam the router talks to. Only
/// the storage primitives — insert-if-free, update-if-present, delete-if-live and
/// delete-what-has-expired — live here; the retry policy, the requested-slug policy and the
/// order reclamation runs in come from `PageStoring`'s extension, shared with every other
/// conformer.
extension PageStore: PageStoring {}
