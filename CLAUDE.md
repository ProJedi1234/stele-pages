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

Router behavior — routing, auth, status codes, the content-type allowlist, 404
uniformity, and the headers pages are served with — is covered by HTTP-level tests. They
run `buildRouter` through `HummingbirdTesting`'s `.router` mode (no listening socket)
against an in-memory `PageStoring` fake, so no curl and no database are needed.

The slug-retry and requested-slug policy is shared code in `PageStoring`'s extension, so
the router tests exercise the real thing (the 503 test runs the retry loop to genuine
exhaustion). The remaining gap is **`PageStore` itself** — the interpolated SQL, the
atomicity of the `ON CONFLICT` insert, and the `UPDATE … RETURNING` existence check are
never exercised against Postgres. Closing that
needs a real database; if such a suite is added, gate it on an env var so a plain
`swift test` stays hermetic.

## Conventions

- **`Slug` is the validation chokepoint.** Every slug reaches the database through
  `Slug(custom:)`; `Slug(unchecked:)` is internal and only for values read back out. If
  you hold a `Slug`, it is already safe in a URL path.
- **Adding a route means registering its first path segment in `ServerRoute`
  (Server.swift) and adding it to `Slug.reserved`.** `buildRouter` builds its paths from
  `ServerRoute`, and a test asserts the reserved set covers `ServerRoute.names`, so a
  route added any other way escapes the reservation check.
- **`PageStore` is the only file that touches the database.** Keep it that way.
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

## Deployment

The app and its database are deployed to different hosts — see the README's "Deploying".
**Never point production data at the local `docker compose` database.** Development
machines commonly run with durability tradeoffs that are fine for rebuildable data and
not fine for the only copy of something.

Concrete host names, addresses, and the specific durability caveat for this environment
are in `docs/homelab.local.md`, which is gitignored — this repo is deliberately free of
them. Read that file before doing any deployment work.
