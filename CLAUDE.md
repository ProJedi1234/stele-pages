# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A Hummingbird 2 HTTP server that stores an uploaded HTML file in Postgres and serves it
back at a readable three-word slug (`quiet-cedar-otter`), for seven days unless the
uploader asked for something else. Swift 6, SwiftPM. The README covers the API, the slug
design, page lifetimes, and deployment; source files carry the reasoning for their own
decisions in doc comments.

## Commands

```sh
swift build
swift test
swift test --filter SlugValidationTests       # one suite
swift test --filter rejectsReservedNames      # one test
swift run stele                               # needs env vars; see below
```

Tests use **swift-testing** (`@Suite` / `@Test` / `#expect`), not XCTest. `--filter`
matches the suite's *type* name and the test function name — not the `@Suite("…")`
display string, which silently matches nothing and reports success.

No linter or formatter is configured.

## Running locally

Needs `DATABASE_URL` and `STELE_UPLOAD_TOKEN` in the environment. Prefer Postgres in
Docker with the app on the host — a Swift change is a ~10s rebuild versus rebuilding the
image:

```sh
docker compose up -d postgres
set -a && . ./.env && set +a
swift run stele
```

`docker compose up -d` runs the full local stack at `localhost:8080`. There is no migrate
step — `PageStore.migrate()` applies the versioned migration list on boot. Applied
versions live in `schema_migrations`, and the run is serialized by a Postgres advisory
lock, so it is safe to run repeatedly and concurrently.

## Testing

Router behavior — routing, auth, status codes, the content-type allowlist, `?ttl=`
parsing (including its refusal on `PUT`), expired reads, 404 uniformity, and the headers
pages are served with — is covered by HTTP-level tests. Note the shape of
`theReportedLifetimeIsTheStoredOne`: `POST` builds its `expires` from the same value it
hands to `create`, so reading that field back proves only the parse — it takes a follow-up
`PUT`, which reports what the *store* returned, to prove the expiry was written at all.
They
run `buildRouter` through `HummingbirdTesting`'s `.router` mode (no listening socket)
against an in-memory `PageStoring` fake, so no curl and no database are needed.

`PublishSkillTests` is the odd one out: alongside the usual route assertions it reads the
rendered SKILL.md as data and pins its prose to the constants it documents — the component,
tone and syntax-token vocabularies against `Stylesheet`, the accepted types against
`PageContentType.allowed`, the example slugs through `Slug(custom:)`, the lifetime table and
`?ttl=` grammar against `PageLifetime` — so changing the contract without changing the
document fails the build rather than shipping stale instructions.

The slug-retry policy, the requested-slug policy and the reclaim-before-insert ordering
are shared code in `PageStoring`'s extension, so the router tests exercise the real thing
(the 503 test runs the retry loop to genuine exhaustion, and the reclamation test proves a
just-expired slug is claimable by the very upload that freed it).

`PageStoreDatabaseTests` is the one suite that needs Postgres, gated on
`STELE_TEST_DATABASE_URL` so a plain `swift test` stays hermetic:

```sh
docker compose up -d postgres
STELE_TEST_DATABASE_URL=postgres://stele:stele_dev_password@localhost:5432/postgres swift test
```

It creates and drops a throwaway schema per test, and is `.serialized` because Postgres
advisory locks are scoped to the database, which per-test schemas do not divide. It
covers the migration runner: the schema version 1 produces, what version 2 adds (the
nullable `expires_at` and its *partial* index — assert the `indexdef`, not just the index
name, or a full index passes), the upgrade path from a database created by the
pre-migration bootstrap, skipping, ordering, exactly-once backfills, rollback of a failed
migration, and the advisory lock. A probe migration in that suite must use a version the
real list does not contain, or the runner skips it and the test asserting it fails passes
nothing — `theLockIsReleasedWhetherTheRunSucceedsOrFails` computes one past the end for
exactly that reason.

`upgradesADatabaseCreatedByTheOldBootstrap` is what proves version 2's backfill actually
ran on a live-shaped database: the page it inserts before migrating comes back with a
deadline seven days out rather than a NULL, and with `created_at` untouched. `Date?` from a
genuine NULL — the mistake that compiles, passes every in-memory test and 500s in
production — is decoded in `expiryPredicatesHideReclaimAndSpareTheRightRows` instead, on the
row it inserts with a nil expiry. Between them both branches of that decode are covered
against real Postgres; do not let a refactor collapse them into one.

`expiryPredicatesHideReclaimAndSpareTheRightRows` is the one test that runs the data path
against real Postgres, and it is there because the expiry predicates exist **only** as SQL:
`InMemoryPageStore.hasExpired` is independent hand-written Swift, so an inverted comparison
in `PageStore` is invisible to every other test. Inverting `fetch`'s makes every page 404
from the moment it is published; inverting `deleteExpired`'s makes every upload destroy
every live page that carries a deadline. Both are silent, and the second is data loss. It
seeds a past, a future and a NULL deadline and pins `insert`, `fetch`, `update` and
`deleteExpired` against all three.

`deleteReportsWhetherARowWasRemoved` covers the other single-slug write: the
`DELETE … RETURNING` existence check, that the `WHERE` clause removes the addressed row and
not the table (which is why it seeds a second page it never deletes — with one row, "matched
the right row" and "matched every row" are the same observation, and `removeValue(forKey:)`
cannot express that bug at all), that the freed slug can be claimed again, and that an
expired row is refused rather than removed.

What remains uncovered against real Postgres is narrower than it was: the
`ON CONFLICT DO NOTHING` *collision* branch of `insert` (the success branch is covered
above) is the standing gap, asserted today only against the in-memory fake.

## Conventions

- **`Slug` is the validation chokepoint.** Every slug reaches the database through
  `Slug(custom:)`; `Slug(unchecked:)` is internal and only for values read back out. If
  you hold a `Slug`, it is already safe in a URL path.
- **Adding a route means registering its first path segment in `ServerRoute`
  (Server.swift) and adding it to `Slug.reserved`.** `buildRouter` builds its paths from
  `ServerRoute`, and a test asserts the reserved set covers `ServerRoute.names`, so a
  route added any other way escapes the reservation check. A route whose first segment
  has only deeper children (`/assets/stele.css`) still needs its own bare-segment `GET`
  returning the uniform 404: the trie matches the literal `assets` node and does not
  backtrack to `/:slug`, so `GET /assets` would otherwise answer with the framework's own
  plain-text 404 — the one distinguishable response on the public read surface. That path
  belongs in `NotFoundTests.all404sAreIdentical`, which is what makes the regression loud.
  A first segment that *carries its own value* (`/skill`) is the other case: the trie
  resolves it, so it needs no stub and must stay **out** of `all404sAreIdentical` — that
  test asserts a 404, and a route that answers 200 there would either fail or, worse, be
  "fixed" by deleting the route's content. The distinction is whether the bare segment is
  a real endpoint, not whether it has children.
- **A generated document that quotes the code belongs in the same module as the code, and
  quotes it by interpolation.** `PublishSkill` renders the SKILL.md served at `GET /skill`
  from `Slug.reserved`, `PageContentType.allowed`, `Stylesheet.toneClasses`, the
  configured base URL, the byte limit and `PageLifetime`'s lifetime vocabulary
  (`queryParameter`, `neverKeyword`, `defaultDays`, `maxDays`). Never retype one of those
  values into the prose: interpolation removes the chance of drift, where a test can only
  notice it later. The deliberate exceptions are the component-class table and the
  syntax-token list — each row carries hand-written prose no constant could generate, so the
  class names are typed out and `PublishSkillTests.componentTableMatchesTheStylesheet` /
  `.documentsEverySyntaxTokenClass` hold them set-equal to `Stylesheet.componentClasses`
  / `.syntaxTokenClasses` in both directions. For the rest of the prose that has no
  constant behind it, `PublishSkillTests` pins what it can — extend those tests rather
  than adding a second source of truth, and change the document in the same commit that
  changes the contract it describes.
- **`PageStore` is the only file that touches the database.** Keep it that way.
- **`PageStore.migrations` is append-only.** Change the schema by adding the next
  version, never by editing a shipped one; `schema_migrations` is the record of what
  every live database has run, and an edited version diverges the databases that already
  applied it from the ones that haven't with nothing to detect the difference. Version 1
  is deliberately written to be a no-op on databases that predate the version table. A
  migration runs exactly once, so data backfills belong there too.
- **Routes take `some PageStoring`, not a concrete store.** That seam is what lets the
  HTTP tests run without Postgres. A conformer implements only `fetch` and the atomic
  storage primitives — insert-if-free, update-if-present, delete-if-live,
  delete-what-has-expired;
  `create`'s retry policy, requested-slug policy and reclaim-*before*-insert ordering live
  in the protocol extension and must stay there, shared. The ordering is load-bearing:
  reclaiming first is what frees an expired slug in time for the upload happening now, and
  a delete failure must propagate rather than be swallowed. `deleteExpired` deliberately
  has no default implementation — a default would be a no-op every conformer inherits in
  silence, and every reclamation test would pass against a store that reclaims nothing.
  The two deletes are separate primitives on purpose: `delete(slug:)` answers one caller
  about one name, `deleteExpired` is housekeeping addressed at no slug in particular, and
  one entry point for both would need a predicate that is sometimes the slug and sometimes
  the clock. `PageStore` is the only conformer that talks to a database; keep new
  persistence behind the protocol rather than reaching past it.

## Decisions that look like bugs

Don't "fix" these without a reason; the README argues them out in full.

- **Reads are unauthenticated.** Slugs are pretty, not secret — an 11.8M keyspace is
  scannable. Access control would need a real auth check, not a longer slug.
- **Every 404 on the public read surface is identical.** Malformed, reserved, absent and
  *expired* slugs return the same page so a scanner can't map the namespace faster than
  guessing — an expired page answering differently would reveal that a name used to be a
  page, handing over the namespace's publication history for free.
  This is deliberately *not* true behind the upload token: `PUT` and `DELETE /pages/:slug`
  return distinguishing `400`/`404` errors, because that caller has nothing left to leak
  to. `DELETE` is not idempotent for the same reason — a repeat delete is a `404`, not the
  `204` convention suggests, so a script that deleted a typo'd slug is told it removed
  nothing instead of being congratulated on work it never did.
- **`DELETE` refuses an expired page rather than sweeping it up.** `delete(slug:)` carries
  the same `expires_at > now()` predicate `fetch` and `update` do, so a DELETE aimed at an
  expired-but-unreclaimed row is a `404`, not a `204`. Removing the row would be tidier by
  one row and wrong by one answer: it would report "deleted that for you" about a page every
  reader already 404s, and about work the next upload's reclamation was going to do anyway.
  The write surface and the read surface agree on which pages exist.
- **Deleting is hard, and the slug goes back into the pool.** No tombstone, no
  `deleted_at`, nothing that keeps a retired name spent — so a link already shared may one
  day resolve to somebody else's page. Link stability would cost a growing table of names
  nobody may use again plus a `WHERE deleted_at IS NULL` on every read, to protect URLs
  this server already treats as guessable rather than secret. A page whose link must keep
  pointing somewhere sensible is replaced with `PUT`, which never releases the name.
- **`STELE_UPLOAD_TOKEN` has no default.** A default would be a published credential; an
  absent one would silently open the upload endpoint.
- **Pages expire by default, and permanence is the opt-out.** `?ttl=` is 7 days when
  absent, `never` for permanent, and a `400` for anything else — never a silent default.
  A `NULL` `expires_at` means "never expires" and nothing else — pages that predate the
  feature are **not** exempt, because migration 2 backfills them to seven days from the
  upgrade as it adds the column. That backfill belongs in that migration and nowhere else:
  one statement earlier the column did not exist, so every `NULL` it sees is provably a
  pre-expiry page, while the same `UPDATE` written later could not distinguish those from a
  deliberate `never`. It measures from `now()` rather than `created_at` so a page older than
  the default does not arrive already dead and get reclaimed by the next upload. Expired
  slugs return to the pool
  with no tombstone, so a name that expired can be drawn or claimed again. Reclamation
  happens on upload only; there is no cron, and an idle server holding invisible expired
  rows is fine because nothing can read them. `PUT` refuses `?ttl=` with a `400` rather
  than ignoring it — a replacement cannot move a deadline, and answering `200` to
  `?ttl=never` would leave the caller believing it had. All of these look like bugs and
  are not.
- **The shared stylesheet and the publish skill are Swift strings, not SwiftPM
  resources.** They live as raw literals in `Sources/SteleCore/Stylesheet.swift` and
  `Sources/SteleCore/PublishSkill.swift`. The Dockerfile's runtime stage copies
  only the built executable, and SwiftPM emits a resource bundle as a *sibling directory*
  of that executable which `--static-swift-stdlib` does not embed — so a `Bundle.module`
  lookup would pass `swift test` on a dev machine and 500 in production, the worst
  failure shape available. Moving either to a top-level `Resources/` would also drop it
  out of CI's `Sources/**` path filter. The skill is not a page in Postgres for a further
  reason: it changes by deploy, not by upload, so a stored copy would let a deployment
  serve one version's documentation while running another's API.

## Deployment

The app and its database are deployed to different hosts — see the README's "Deploying".
**Never point production data at the local `docker compose` database.** Development
machines commonly run with durability tradeoffs that are fine for rebuildable data and
not fine for the only copy of something.

Concrete host names, addresses, and the specific durability caveat for this environment
are in `docs/homelab.local.md`, which is gitignored — this repo is deliberately free of
them. Read that file before doing any deployment work.
