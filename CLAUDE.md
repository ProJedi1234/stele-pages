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
step — `PageStore.migrate()` runs on boot and is idempotent.

## Testing gap

Every test is pure logic: slug validation and generation, wordlist invariants,
`DATABASE_URL` parsing. There is **no HTTP-level test coverage** — routing, auth, status
codes, and the content-type allowlist have only been checked by hand with curl.
`buildRouter` is split out from `buildApplication` so it can be tested without a
listening socket, but nothing does that yet. Closing this needs the `HummingbirdTesting`
product (available, not yet a dependency) and a Postgres for `PageStore`.

## Conventions

- **`Slug` is the validation chokepoint.** Every slug reaches the database through
  `Slug(custom:)`; `Slug(unchecked:)` is internal and only for values read back out. If
  you hold a `Slug`, it is already safe in a URL path.
- **Adding a route means adding its name to `Slug.reserved`** — a test asserts the
  reserved set covers the real routes, and it will fail if you forget.
- **`PageStore` is the only file that touches the database.** Keep it that way.

## Decisions that look like bugs

Don't "fix" these without a reason; the README argues them out in full.

- **Reads are unauthenticated.** Slugs are pretty, not secret — an 11.8M keyspace is
  scannable. Access control would need a real auth check, not a longer slug.
- **Every 404 is identical.** Malformed, reserved, and absent slugs return the same page
  so a scanner can't map the namespace faster than guessing.
- **`STELE_UPLOAD_TOKEN` has no default.** A default would be a published credential; an
  absent one would silently open the upload endpoint.

## Deployment

The app and its database are deployed to different hosts — see the README's "Deploying".
**Never point production data at the local `docker compose` database.** Development
machines commonly run with durability tradeoffs that are fine for rebuildable data and
not fine for the only copy of something.

Concrete host names, addresses, and the specific durability caveat for this environment
are in `docs/homelab.local.md`, which is gitignored — this repo is deliberately free of
them. Read that file before doing any deployment work.
