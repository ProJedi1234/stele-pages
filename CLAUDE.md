# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A Hummingbird 2 HTTP server that stores an uploaded HTML file in Postgres and serves it
back at a readable three-word slug (`quiet-cedar-otter`). Swift 6, SwiftPM. The README
covers the API, the slug design, and deployment; source files carry the reasoning for
their own decisions in doc comments.

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

Router behavior — routing, auth, status codes, the content-type allowlist, 404
uniformity, and the headers pages are served with — is covered by HTTP-level tests. They
run `buildRouter` through `HummingbirdTesting`'s `.router` mode (no listening socket)
against an in-memory `PageStoring` fake, so no curl and no database are needed.

`PublishSkillTests` is the odd one out: alongside the usual route assertions it reads the
rendered SKILL.md as data and pins its prose to the constants it documents — the component
and tone tables against `Stylesheet`, the accepted types against `PageContentType.allowed`,
the example slugs through `Slug(custom:)` — so changing the contract without changing the
document fails the build rather than shipping stale instructions.

The slug-retry and requested-slug policy is shared code in `PageStoring`'s extension, so
the router tests exercise the real thing (the 503 test runs the retry loop to genuine
exhaustion).

`PageStoreDatabaseTests` is the one suite that needs Postgres, gated on
`STELE_TEST_DATABASE_URL` so a plain `swift test` stays hermetic:

```sh
docker compose up -d postgres
STELE_TEST_DATABASE_URL=postgres://stele:stele_dev_password@localhost:5432/postgres swift test
```

It creates and drops a throwaway schema per test, and is `.serialized` because Postgres
advisory locks are scoped to the database, which per-test schemas do not divide. It
covers the migration runner: the schema version 1 produces, the upgrade path from a
database created by the pre-migration bootstrap, skipping, ordering, exactly-once
backfills, rollback of a failed migration, and the advisory lock. It deliberately does
**not** cover `insert` / `fetch` / `update` against real Postgres — the `ON CONFLICT DO
NOTHING` insert and the `UPDATE … RETURNING` existence check remain the standing gap,
asserted today only against the in-memory fake.

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
  configured base URL and the byte limit. Never retype one of those values into the
  prose: interpolation removes the chance of drift, where a test can only notice it
  later. The one deliberate exception is the component-class table — each row carries
  hand-written prose no constant could generate, so its class names are typed out and
  `PublishSkillTests.componentTableMatchesTheStylesheet` holds them set-equal to
  `Stylesheet.componentClasses` in both directions. For the rest of the prose that has no
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
  storage primitives — insert-if-free and update-if-present; `create`'s retry and
  requested-slug policy lives in the
  protocol extension and must stay there, shared. `PageStore` is the only conformer that
  talks to a database; keep new persistence behind the protocol rather than reaching
  past it.

## Decisions that look like bugs

Don't "fix" these without a reason; the README argues them out in full.

- **Reads are unauthenticated.** Slugs are pretty, not secret — an 11.8M keyspace is
  scannable. Access control would need a real auth check, not a longer slug.
- **Every 404 on the public read surface is identical.** Malformed, reserved, and absent
  slugs return the same page so a scanner can't map the namespace faster than guessing.
  This is deliberately *not* true behind the upload token: `PUT /pages/:slug` returns
  distinguishing `400`/`404` errors, because that caller has nothing left to leak to.
- **`STELE_UPLOAD_TOKEN` has no default.** A default would be a published credential; an
  absent one would silently open the upload endpoint.
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
