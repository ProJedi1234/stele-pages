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
parsing (including its refusal on `PUT` and its "leave it alone" reading on `PATCH`),
expired reads, 404 uniformity, and the headers
pages are served with — is covered by HTTP-level tests. `AmendPageTests` covers the rename
and retime verb; its sharpest assertions are the ones about what an amendment must *not*
disturb — `renamingAloneDoesNotTouchTheDeadline` is the guard against the router reaching
`PageLifetime(raw: nil)` and quietly putting seven days on a permanent page, and
`amendingDoesNotReattributeThePage` pins the deliberate inversion of `PUT`'s behaviour. Note the shape of
`theReportedLifetimeIsTheStoredOne`: `POST` builds its `expires` from the same value it
hands to `create`, so reading that field back proves only the parse — it takes a follow-up
`PUT`, which reports what the *store* returned, to prove the expiry was written at all.
They
run `buildRouter` through `HummingbirdTesting`'s `.router` mode (no listening socket)
against an in-memory `PageStoring` fake, so no curl and no database are needed.

`PublishSkillTests` is the odd one out: alongside the usual route assertions it reads the
rendered SKILL.md as data and pins its prose to the constants it documents — the component,
tone and syntax-token vocabularies against `Stylesheet`, the accepted types against `PageContentType.allowed`,
the example slugs through `Slug(custom:)`, the lifetime table and `?ttl=` grammar against
`PageLifetime`, the install sequence, the flag set and the exit-code table against
`SteleCLI`, and
every dotted-numeric token in the whole document against `minimumCLIVersion` — so changing
the contract without changing the document fails the build rather than shipping stale
instructions.

The client-facing half of that is newer and exists because it failed once. `--ttl` shipped
in `stele-cli` while the document still read "`stele publish` does not expose this yet", so
an agent asked for a permanent page refused a request it could have satisfied — and the
refusal read as policy rather than staleness, which is why nobody noticed. No test in this
package can see the other repository, so `documentsEveryFlagTheAgentCanUse` and
`theExitTableMatchesTheClientsExitCodes` do the only thing that is available: hold the
document to `SteleCLI.flags` and `SteleCLI.exits`, so the document and this package cannot
disagree and there is exactly one place left to update when the client moves. The exit table
is order-sensitive on purpose — an agent reads it top to bottom, and a code out of sequence
reads as a severity ranking that is not there. Two of its assertions are *negative* and are the ones to leave alone:
`neverPutsTheCredentialInTheAgentsHands` fails if the document ever again mentions
`STELE_UPLOAD_TOKEN`, an `Authorization` header or a `curl -X`, and `handsAuthenticationToTheUser`
pins the sentence that says whose step `stele auth login` is. The skill's job is to keep
the credential out of the model's reach; prose that hands it back would pass every other
test in the suite.

`PATCH /pages/:slug` was in that trap and is now out of it, which is the more instructive
half. `documentsTheAmendRoute` used to pin the sentence saying no `stele` command ran the
verb, plus the sentence attributing that absence to the *tool* rather than the server —
honest wording, and both became lies the day `stele amend` shipped. It now pins the command
and the two things an agent gets wrong by carrying over what it knows from `publish`: that
omitting `--ttl` here leaves the deadline alone rather than applying the default, and that
dropping `--slug` is not the escape from a `409` that it is on a publish.

Its negative counterpart `doesNotClaimALifetimeIsUnchangeable` is the one to keep, and it has
now grown twice for the same reason. The document first stated four times that a lifetime
could never change; each of those became a claim about the client ("no command you can run"),
which was true until it wasn't. **The client-scoped hedge is not a safer way to say it** — it
is the same claim with a shorter shelf life, so both spellings are in the sieve. A future edit
drifting back to either would read fine, pass everything else here, and teach an agent to
refuse something it could do.

One mechanical constraint that suite learned the hard way: the markdown is a wrapped raw
string, so an assertion phrase that straddles a line break cannot be pinned at all. Prose
carrying an assertion gets reflowed to keep the claim on one line — not the reverse.

`documentsTheDeleteRoute` is where those two jobs pull against each other, and the shape it
settled on is deliberate, and it is now the third of these tests to be turned over by the
client catching up. `DELETE /pages/:slug` used to be a verb the route table had to name (a
verb missing from that table is one the agent will not use, because the document tells it not
to invent sub-paths) while the prose said in the same breath that nothing ran it — because
the only way to act on that row was to go find a credential, which is the one thing the
rewrite exists to prevent. `stele delete` shipped, so both halves of that sentence are false
and the assertions invert: the phrase **"no delete command"**, in the absolute and in the
client-scoped spelling both, joins the sieve for the reason
`doesNotClaimALifetimeIsUnchangeable` gives. `204` inverts with it — it was asserted *absent*
because that table is what a command tells you and none could earn one, and it is now
required, because an agent told a delete succeeds but not what success looks like goes
hunting for a URL that was never printed. That last part is the third assertion: `stele
delete` writes nothing to stdout, deliberately, and the document teaches
`url=$(stele publish page.html)` a few sections earlier.

The slug-retry policy, the requested-slug policy and the reclaim-before-insert ordering
are shared code in `PageStoring`'s extension, so the router tests exercise the real thing
(the 503 test runs the retry loop to genuine exhaustion, and the reclamation test proves a
just-expired slug is claimable by the very upload that freed it).
`ClientStoring` is the same arrangement for credentials: the primitives are
lookup-by-hash, record-a-use, insert-if-free, list and revoke, while the two pieces of
policy live in the extension — `authenticate(token:at:)`, which collapses the hash, the
revocation check and the expiry check into one nil, and `create(name:scopes:expiresAt:)`,
which generates a token and stores only its digest. `InMemoryClientStore` therefore cannot
disagree with `ClientStore` about what "valid" means, or about what gets hashed.

`AdminClientsTests` covers the three credential routes, and most of what it asserts is
negative: that the plaintext token appears in the `201` body and in no other response, on
the raw bytes rather than on a decoded shape, so a field a future `Encodable` conformance
adds by accident is caught. `ScopeEnforcementTests` covers the other half — which valid
credentials are refused, and with which status code.

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
name, or a full index passes), what version 3 adds, what version 4 replaces, the upgrade
path from a database created by the pre-migration bootstrap, skipping, ordering,
exactly-once backfills, rollback of a failed migration, and the advisory lock. Tests that
pin one version's shape drive `migrate(_:)` with a prefix of the list rather than
`migrate()`, so they keep meaning what they say as versions are appended — version 3's test
in particular, since version 4 deliberately drops the `name` constraint it asserts. The ones
that are about the *runner* rather than a version compare against
`PageStore.migrations.map(\.version)` rather than a literal, for the same reason. A probe
migration in that suite must use a version the real list does not contain, or the runner
skips it and the test asserting it fails passes nothing —
`theLockIsReleasedWhetherTheRunSucceedsOrFails` computes one past the end for exactly that
reason.

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
every live page that carries a deadline; inverting `recent`'s turns the landing page into a
list of exactly the pages that no longer exist. All three are silent, the second is data
loss and the third is a disclosure. It seeds a past, a future and a NULL deadline and pins
`insert`, `fetch`, `update`, `recent` and `deleteExpired` against all three — `recent`
before the reclaiming delete runs, so the expired row is still physically present and the
assertion is about the query rather than about cleanup.

`InMemoryPageStore` stamps each stored page with a monotonic counter rather than one fixed
date, because the landing page's index is an *order* and two pages seeded in one test would
otherwise tie. `update` builds its `Page` by hand precisely so it cannot pick up a new
stamp: `created_at` survives a replacement in the SQL, so a page that is re-uploaded must
not jump to the top of the index. Only `seed` and `insert` go through the stamping helper.

It also covers `ClientStore` against real Postgres, which is where its type claims can
actually be checked: that `token_hash` binds as `Data` — PostgresNIO encodes a `[UInt8]`
as a `char[]`, not as `bytea` — and that `scopes` binds and decodes as `text[]` in both
directions. The write half is there too: that an untargeted `ON CONFLICT DO NOTHING`
catches the `name` *and* `token_hash` constraints rather than throwing on one, and that
`COALESCE(revoked_at, now())` really does leave a second revoke's timestamp alone.
`PageStore`'s own `insert` / `fetch` / `update` are covered too, which they had to be once
writes started recording `pages.client_id`: that column is a foreign key, so the value the
write path chooses is checked by the database and by nothing else — the in-memory fake
stores whatever it is handed, and an id with no row behind it (the synthesised shared
token's `0`) would pass every HTTP test in the repo and fail every publish in production.
`pagesAreStoredFetchedAndReattributedAgainstTheRealSchema` pins that refusal, the
`created_at` a replacement preserves, and the two outcomes the router turns into a `409`
and a `404`.

`deleteReportsWhetherARowWasRemoved` covers the other single-slug write: the
`DELETE … RETURNING` existence check, that the `WHERE` clause removes the addressed row and
not the table (which is why it seeds a second page it never deletes — with one row, "matched
the right row" and "matched every row" are the same observation, and `removeValue(forKey:)`
cannot express that bug at all), that the freed slug can be claimed again, and that an
expired row is refused rather than removed.

`amendmentsMoveAndRetimeAPageWithoutDisturbingIt` is the third, and it exists mainly for one
branch. `applyAmendment` is the only statement in the store whose outcome comes from an
*error* rather than a row count: it carries no `NOT EXISTS` guard on the target name —
deliberately, since any such sub-select reads the statement's snapshot and can be overtaken
by a concurrent insert committing before the index is touched — so a taken name arrives as
SQLSTATE `23505` off the primary key and `.slugTaken` is that error caught and translated.
`InMemoryPageStore` reaches the same verdict from a dictionary, so it agrees by construction
and proves nothing; if the catch clause ever stops matching, every rename onto a taken name
becomes a `500` and only this suite would notice. It also pins the two expiry binds in both
directions (a bind that can clear a deadline but not set one passes every test that only
amends toward `never`) and the `CASE … ELSE expires_at` arm that a single nullable bind would
turn into "make it permanent", plus the `created_at` and `client_id` an amendment must leave
alone. `amendmentsRefuseAnExpiredPageRatherThanRevivingIt` is split out because its
interesting half is what does *not* happen, and it proves refusal rather than a silent sweep
the way the delete test does — by watching `deleteExpired` still find the row.

What remains uncovered against real Postgres is narrower than it was: the
`ON CONFLICT DO NOTHING` *collision* branch of `PageStore.insert` (its success branch is
covered above, and `ClientStore`'s collision branch is covered separately) is the standing
gap, asserted today only against the in-memory fake.

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
  a real endpoint, not whether it has children. `/admin` is the second instance of the stub
  case, and the one where getting it wrong costs most: registered *inside* the
  authenticated group it would answer `401`, which advertises exactly where the
  credential-minting routes live. Register the stub outside the group.
- **A write route belongs in a group whose middleware carries the scope it needs.**
  `RequireScopeMiddleware(.publish)` gates `/pages`; `RequireScopeMiddleware(.admin)` gates
  `/admin`. Both sit *after* `BearerTokenMiddleware` in the group and read the `Client` it
  put on the context — a scope check that re-parsed the header would be a second opinion
  about what a token means. Do not write the check as a `guard` at the top of a handler:
  the failure mode of that version is a route someone forgets to guard, which compiles,
  passes its own tests, and is simply open. Insufficient scope is `403`, not `401` — see
  "Decisions that look like bugs". **`GET /admin/whoami` is the deliberate exception and
  must stay one:** it sits under `/admin` in its own group, behind `BearerTokenMiddleware`
  and *no* scope check, because the caller that runs it most is a publish-only agent —
  `stele auth status` is the first command the skill tells one to run, and `stele auth
  login` checks a credential there before writing it to disk. Tidying it into the
  `admin`-scoped group answers both with a `403` from a credential that works perfectly.
  `WhoamiTests.aPublishOnlyCredentialIsAnsweredHereAndStillRefusedOnTheAdminRoutes` holds
  the two halves together.
- **`PATCH /pages/:slug` changes a page's address and deadline; it is not a small `PUT`.**
  It reads no body and rewrites none — contents, content type, `created_at` and `client_id`
  all survive, the last deliberately (see "A write records who wrote it"). Keep it a
  separate verb: `PUT`'s `400` on `?ttl=` is still correct, because *a replacement* still
  cannot retime a page. The trap is `PageLifetime(raw:)`, whose nil resolves to
  `defaultDays` — right for a publish, catastrophic here, where an absent `?ttl=` must mean
  "leave it alone" or a rename would put a week's deadline on a permanent page. That is what
  `PageExpiry` is for: nil is the absence of an instruction and `.never` is the instruction
  to be permanent, which a `Date?` cannot say and a `Date??` can only say by accident. A
  rename is a *hard move* — old name freed, no redirect, no tombstone — on the same
  reasoning as `delete`.
- **A write records who wrote it.** Both write routes pass
  `context.client?.attributableID` down through `PageStoring`'s primitives into
  `pages.client_id`, and `update` *assigns* it rather than coalescing — the column is who
  wrote the bytes currently being served, not who first published the slug. The one nil is
  `Client.sharedToken`: it is synthesised with `id` 0 and has no row, and the column is a
  foreign key, so `attributableID` maps it to NULL. Do not add a second place that decides
  what to write there.
- **A generated document that quotes the code belongs in the same module as the code, and
  quotes it by interpolation.** `PublishSkill` renders the SKILL.md served at `GET /skill`
  from `Slug.reserved`, `PageContentType.allowed`, `Stylesheet.toneClasses`,
  `ClientScope`, `ServerRoute`, `SteleCLI`, `minimumCLIVersion`, `PageLifetime`'s lifetime
  vocabulary (`queryParameter`, `neverKeyword`, `defaultDays`, `maxDays`), the configured
  base URL and the byte limit. Never retype one of
  those values into the prose: interpolation removes the chance of drift, where a test can
  only notice it later. **This now reaches across repositories.** The skill documents a
  tool built in `stele-cli`, and nothing in a build of *this* package would notice a clone
  URL that had moved or a make target that had been renamed — so those facts live in
  `Sources/SteleCore/SteleCLI.swift` and the document quotes them: the clone URL and
  `minimumCLIVersion` are hardcoded, the install and completions commands are derived from
  the checkout path, and `flags` and `exits` are transcriptions of the client's own
  `ArgumentParser` options and `Exit` table. A transcription is the most this package can
  offer — it cannot verify the other repo, only refuse to hold two copies of its own answer
  — and it is what `--ttl` needed and did not have. **Anything the skill says about the
  client goes here first and is interpolated from here.** The deliberate exceptions are the component-class table and the syntax-token
  list — each row carries hand-written prose no constant could generate, so the class
  names are typed out and `PublishSkillTests.componentTableMatchesTheStylesheet` /
  `.documentsEverySyntaxTokenClass` hold them set-equal to `Stylesheet.componentClasses`
  / `.syntaxTokenClasses` in both directions. The scope names are *not* an exception —
  they are interpolated from `ClientScope`, and
  `PublishSkillTests.theRouteTableNamesExactlyTheScopesThatExist` holds the route table's
  auth column set-equal to `ClientScope.allCases`. For the rest of the prose that has no
  constant behind it, `PublishSkillTests` pins what it can — extend those tests rather
  than adding a second source of truth, and change the document in the same commit that
  changes the contract it describes.
- **The store layer is the only code that touches the database.** That is
  `Sources/SteleCore/PageStore.swift` and `Sources/SteleCore/ClientStore.swift` — pages and
  client credentials — and a new table gets a new store beside them rather than a query
  somewhere convenient. Keep it that way.
- **The migration list stays in `PageStore`, whatever it creates.** `PageStore.migrations`
  is the history of the whole schema, `clients` included, because there is one database
  and one version sequence; splitting it per store would give two sequences with no
  defined order between them. `ClientStore` reads a table it does not create, and that is
  correct.
- **`PageStore.migrations` is append-only.** Change the schema by adding the next
  version, never by editing a shipped one; `schema_migrations` is the record of what
  every live database has run, and an edited version diverges the databases that already
  applied it from the ones that haven't with nothing to detect the difference. Version 1
  is deliberately written to be a no-op on databases that predate the version table. A
  migration runs exactly once, so data backfills belong there too.
- **Routes take `some PageStoring`, not a concrete store.** That seam is what lets the
  HTTP tests run without Postgres. A conformer implements only `fetch` and the atomic
  storage primitives — insert-if-free, update-if-present, amend-if-live, delete-if-live,
  delete-what-has-expired;
  `create`'s retry policy, requested-slug policy and reclaim-*before*-insert ordering live
  in the protocol extension and must stay there, shared. The ordering is load-bearing:
  reclaiming first is what frees an expired slug in time for the upload happening now, and
  a delete failure must propagate rather than be swallowed. `amend` is the second policy
  method and exists only to run that same reclamation ahead of `applyAmendment`, so a rename
  onto a just-expired name succeeds instead of `409`ing against a page no verb admits
  exists. The policy and the primitive carry **different names on purpose**: a defaulted
  `logger` argument letting them share one would make the un-logged call site resolve
  silently to the primitive, skipping reclamation with nothing to notice. `deleteExpired` deliberately
  has no default implementation — a default would be a no-op every conformer inherits in
  silence, and every reclamation test would pass against a store that reclaims nothing.
  The two deletes are separate primitives on purpose: `delete(slug:)` answers one caller
  about one name, `deleteExpired` is housekeeping addressed at no slug in particular, and
  one entry point for both would need a predicate that is sometimes the slug and sometimes
  the clock. `PageStore` is the only conformer that talks to a database; keep new
  persistence behind the protocol rather than reaching past it. `ClientStoring` is the same
  seam for credentials — `ClientStore` on Postgres, `InMemoryClientStore` in the tests — so
  authentication stays exercisable without one.
- **Per-request state lives on `SteleRequestContext`, and only the middleware that earned
  it writes it.** Hummingbird makes the context a type parameter, so `buildRouter` returns
  `Router<SteleRequestContext>` and anything a handler needs beyond the URL is a field on
  that struct. `client` is set in exactly one place — `BearerTokenMiddleware`, after the
  credential has been checked — so a handler behind that middleware can read it as "this
  request is authorised". Re-deriving a credential from the header anywhere else would be a
  second opinion about what a token means.

## Decisions that look like bugs

Don't "fix" these without a reason; the README argues them out in full.

- **Reads are unauthenticated.** Slugs are pretty, not secret — an 11.8M keyspace is
  scannable. Access control would need a real auth check, not a longer slug.
- **The landing page publishes the live namespace, and that is the point of it.** `GET /`
  lists the twenty most recently published live pages by name, unauthenticated. It reverses
  the "guessable only to someone willing to scan" framing the slug design rests on, and the
  README argues out what that does and does not cost. Two things must stay true. `recent`
  carries the same `expires_at > now()` predicate every other read does — an index listing
  expired rows would hand over the publication history that the uniform 404 exists to
  withhold, which is the one leak this feature must not introduce. And `PageSummary` must
  keep having nowhere to put a body: twenty rows of up to `maxPageBytes` is a megabyte-scale
  read to render a list of links, and none of those bytes reach the page.
- **The landing page degrades rather than 500s.** A store that cannot be read renders "the
  index is unavailable" and keeps the rest of the document, which is publishing
  documentation that is still true while Postgres is down. It is not swallowed — the handler
  logs at error level, because this is the one branch where the page looks fine and the
  server is not. "Nothing published yet" is a *different* string on purpose: an empty index
  is a fact about the server, and a server that cannot see its own table does not have it.
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
  absent one would silently open the upload endpoint. It still authenticates alongside
  per-client tokens, resolving to the synthesised `Client.sharedToken` — `admin`-scoped,
  `id` 0, no row in `clients`. That is the bootstrap: minting the first per-client
  credential needs a credential you cannot otherwise have yet. Its `id` is never a
  foreign key; a page it publishes has no owner to record.
- **Every rejected credential gets one byte-identical 401.** Unknown, revoked, expired and
  a mistyped shared token are four facts the caller learns none of.
  `ClientStoring.authenticate` collapses the first three to nil before the middleware sees
  them, so there is no shape left to branch on. The README's licence to return
  distinguishing errors applies to callers *behind* the token; someone probing for a valid
  one is not behind it. A *missing* `Authorization` header keeps its own message — a caller
  who presented nothing has learned nothing.
- **`STELE_UPLOAD_TOKEN` can no longer publish.** It resolves to `Client.sharedToken`,
  which carries `admin` and nothing else, so `POST /pages` and `PUT /pages/:slug` answer it
  with a `403`. That is the demotion, not a bug: it became the credential that *mints*
  publishing credentials, and a root token that could also write pages would be one an
  agent had a reason to hold. The fixture that publishes in the tests is
  `TestFixture.publishToken`, not `TestFixture.token`.
- **The `426` version gate only fires on a client that names itself.** A write carrying
  `User-Agent: stele-cli/<version>` older than `minimumCLIVersion` gets `426 Upgrade
  Required`; a request with no such header — curl, a script, anything predating the CLI —
  is waved straight through. That asymmetry is the whole design: gating unversioned
  clients would be a far larger outage than the drift it prevents, and it also means the
  gate is *advisory*. Anyone can omit the header, so nothing behind it may assume a
  minimum client, and it must never be reached for as a security control. A `stele-cli/`
  token with an unreadable version is rejected rather than waved through, because a client
  that sends the header is asking to be version-checked.
  `MinimumCLIVersionMiddleware` is registered **last** in its group, after
  authentication and the scope check: reinstalling the CLI does not fix a bad credential,
  and a `426` would spend an agent's one retry on the wrong thing.
- **Insufficient scope is `403`, and that is deliberately distinguishable from `401`.** The
  credential is valid; it simply is not permitted, and the caller is already behind the
  token so there is nothing left to leak to them. Collapsing the two would be actively
  harmful rather than merely cautious: a `401` sends an operator to rotate a credential
  that is working exactly as issued, instead of to widen its scopes. The error names both
  the required scope and the ones the credential carries — the caller already knows both,
  because it is their credential.
- **Revoking is idempotent by keeping the first `revoked_at`, not by tolerating a second
  write.** `ClientStore.revoke` is `COALESCE(revoked_at, now())`, and `InMemoryClientStore`
  mirrors it. That timestamp is the boundary an incident is reconstructed from; a retried
  `DELETE` that moved it would erase the only record of when trust ended. The row itself is
  never deleted, and revoked credentials stay in `GET /admin/clients` — "which did I revoke,
  and when?" is the question that list exists to answer.
- **A credential name is unique among *live* rows, not across the table.** Migration 3
  replaced version 2's `name UNIQUE` with `clients_live_name_idx`, a partial index over
  `WHERE revoked_at IS NULL`. Rows are never deleted, so table-wide uniqueness meant
  revoking `claude-code` retired the name permanently and rotation — revoke, then mint the
  replacement — answered `409` forever, with `claude-code-2` as the only way out. Two
  consequences to keep straight. `ClientStore.insert` must stay an *untargeted*
  `ON CONFLICT DO NOTHING`: a conflict target would have to restate the index's predicate to
  infer it at all. And `revoke` resolves several-rows-one-name to a single row with
  `ORDER BY revoked_at DESC NULLS FIRST` — the live one, or else the most recently retired
  one, which is what keeps a repeated `DELETE` a `200` rather than a `404`. Updating every
  row with that name is harmless under `COALESCE` and still wrong: it would return whichever
  row the planner reached first, so a retry could answer with a different credential than the
  call it retries.
- **`expiresIn` is bounded above, and that bound is not a policy.** `validatedExpiry` caps it
  at `maxExpiresInSeconds` (a century). PostgresNIO encodes a `Date` as microseconds in an
  `Int64` via a plain `Int64(_:)` over a `Double`, which **traps** past roughly the year
  294000 — a trap in a handler takes the process and every in-flight request with it, and one
  JSON field reaches it. "No expiry" is already spelled by omitting the field, so nothing
  legitimate lives above the cap. The in-memory store holds any `Date` it is handed, so this
  is one of the cases where only the Postgres path can fail: pin new arithmetic on that column
  in `validatedExpiry`, not downstream.
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
  happens on `POST` and on `PATCH` and nowhere else — the two verbs that need a name freed
  in time for the request in hand, one to claim it and one to move onto it, which is why
  both go through a `PageStoring` policy method (`create`, `amend`) rather than straight to
  a primitive. There is no cron, and an idle server holding invisible expired
  rows is fine because nothing can read them. `PUT` refuses `?ttl=` with a `400` rather
  than ignoring it — a replacement cannot move a deadline, and answering `200` to
  `?ttl=never` would leave the caller believing it had. `PATCH` is where a deadline moves,
  and it measures from the request rather than from `created_at`, so `?ttl=30` grants thirty
  days rather than whatever is left of them. It cannot revive an expired page: the same
  live-row predicate applies, so `?ttl=never` on a dead page is a `404`. All of these look
  like bugs and are not.
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
