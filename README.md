# stele

Publish an HTML file, get a readable link back. It expires in a week unless you say
otherwise.

```
$ curl -X POST "localhost:8080/pages?ttl=never" \
    -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \
    -H "Content-Type: text/html" \
    --data-binary @index.html
{"slug":"radiant-surf-gecko","url":"http://localhost:8080/radiant-surf-gecko","expires":null}
```

Anyone can then load `/radiant-surf-gecko` and get the page, for as long as the page
lives — see "How long a page lives". Pages live in Postgres, so the server holds no state
and can be restarted or moved freely.

A *stele* is the stone slab you put up in public for people to read — which is the job.

## The identifier

Slugs are three words drawn from three curated pools, one per part of speech:

    adjective  -  nature noun  -  creature/object noun
      radiant       surf            gecko
      quiet         cedar           otter
      brisk         harbor          compass

Keeping each slot to its own pool is what makes every combination read as a phrase
instead of three adjacent words. Pools are 253 / 208 / 224 words, so:

| `STELE_SLUG_WORDS` | Shape                       | Combinations  |
| ------------------ | --------------------------- | ------------- |
| `3` (default)      | `quiet-cedar-otter`         | 11,787,776    |
| `4`                | `quiet-mossy-cedar-otter`   | 2,982,307,328 |

Slugs are drawn at random, not derived from a row counter, so one slug never reveals
another. On the rare collision the server simply redraws (five attempts, then 503). A slug
freed by an expiry goes back into the pool and can be drawn or claimed again — expired
pages leave no tombstone behind them.

### Slugs are pretty, not secret

**A three-word slug is guessable by an attacker who is willing to scan.** 11.8M is a
large number for a human and a small one for a script. Anyone who can reach the server
can eventually enumerate every page on it.

That's a fine trade for publishing pages meant to be shared. It is *not* a fine trade if
a page's contents should stay private — an unguessable URL would be doing access-control
work it can't do at this size. If you need that, set `STELE_SLUG_WORDS=4` (~3 billion,
meaningfully harder) and treat even that as obscurity rather than security. Real privacy
needs an auth check on reads, which this server deliberately does not have.

Expiry adds nothing to that risk. A page past its deadline answers with the byte-identical
404 that a malformed, reserved or never-published slug answers with, so a scanner cannot
learn that a name *used to* be a page — which would otherwise hand it the publication
history of the namespace for free.

## Running it locally

```sh
cp .env.example .env
openssl rand -hex 32          # put this in STELE_UPLOAD_TOKEN
docker compose up -d          # app + Postgres; working at localhost:8080
```

While actually writing code, run the database in Docker and the app on the host instead
— a Swift change is a ~10s rebuild, versus rebuilding the image on every edit:

```sh
docker compose up -d postgres
set -a && . ./.env && set +a
swift run stele
```

The schema is an ordered, append-only list of migrations in code. Whatever a database
hasn't applied yet runs on boot, under a Postgres advisory lock — so there's still no
separate migrate step, and two instances starting at once are safe. See "Changing the
schema" below.

Run the tests with `swift test`. That run is hermetic and needs no database. The suite
that exercises the migration runner against a real Postgres is gated on a separate
variable:

```sh
docker compose up -d postgres
STELE_TEST_DATABASE_URL=postgres://stele:stele_dev_password@localhost:5432/postgres swift test
```

It creates and drops a throwaway schema per test on whichever cluster you point it at.
The variable is deliberately not `DATABASE_URL`, so pointing the server at a database
never points a suite that drops things at it too.

### Changing the schema

`PageStore.migrations` is an ordered, append-only list. To change the schema, append a
`Migration` with the next version and its statements; never edit a version that has
shipped, because it has already run on databases you don't control and nothing would
detect the divergence. On boot the runner reads `schema_migrations`, applies whatever is
missing in version order, and commits each migration together with the row recording it —
so a step is either fully applied and recorded, or not applied at all.

One SQL command per array element, literal text only: an interpolation becomes a bind
parameter, and DDL can't take binds. Statements aren't limited to DDL — because a version
runs exactly once, a data backfill belongs in a migration too. `CREATE INDEX CONCURRENTLY`
doesn't, because each migration runs inside a transaction.

Version 1 is the original schema written with `IF NOT EXISTS`, so a database created
before there was a version table simply records version 1 and carries on. Nothing is
dumped or restored.

Version 2 is the page-expiry column, and it is what every later migration should look
like: a versioned step with no `IF NOT EXISTS`, rather than another idempotent `ALTER`
accumulating in a bootstrap function. Only version 1 needs the conditional forms, because
only version 1 describes a schema that already existed before the runner did. Version 2
adds `expires_at` as nullable with no default, backfills every row already in the table to
seven days out, then builds a *partial* index on it. It is also the example of why a
backfill belongs in a migration rather than in application code: the statement is only
accurate in the one moment it runs, when a `NULL` still provably means "published before
expiry existed" rather than "published with `?ttl=never`".

### The two compose files

| File                        | Contains        | For                                         |
| --------------------------- | --------------- | ------------------------------------------- |
| `docker-compose.yml`        | app + Postgres  | Local development. Throwaway database.      |
| `docker-compose.deploy.yml` | app only        | Deployment. Database lives elsewhere.       |

They're deliberately not the same file. The deployment stack has no Postgres service:
bundling one would put production data in a container volume on whichever machine
happens to run the app, which is rarely the machine you chose for durable storage. See
"Deploying" below.

## API

| Route              | Auth   | Behaviour                                              |
| ------------------ | ------ | ------------------------------------------------------ |
| `GET /`            | none   | Usage page                                             |
| `GET /healthz`     | none   | `ok`                                                   |
| `GET /:slug`       | none   | The stored page, or a 404 page if it's absent or expired |
| `GET /assets/stele.css` | none | The shared stylesheet (see "A shared look")         |
| `GET /skill`       | none   | The publish skill, as Markdown (see "Teaching an agent to publish") |
| `POST /pages`      | bearer | Stores the request body, takes `?slug=` and `?ttl=`, returns `{slug, url, expires}` as `201` |
| `PUT /pages/:slug` | bearer | Replaces a stored page's body and content type, returns `{slug, url, expires}` as `200` |
| `DELETE /pages/:slug` | bearer | Removes a stored page and frees the slug, returns `204` |

`POST /pages` takes the page as the raw request body, up to `STELE_MAX_PAGE_BYTES`
(default 1 MiB; larger is `413`). Add `?slug=my-page` to choose the name yourself — it's
validated by the same rules as a generated one, returning `400` if invalid and `409` if
taken. Add `?ttl=` to choose how long it lives, described below. Accepted content types
are `text/html` (default), `text/plain`, `text/css`, and `text/markdown`; anything else is
`415`. An empty body, a non-UTF-8 one, a NUL byte, an invalid slug and an invalid `ttl`
are each `400`, a missing or wrong bearer token is `401`, and if five random draws in a
row collide with existing slugs the server gives up with `503` rather than retrying
forever.

`PUT /pages/:slug` replaces an existing page's body and content type, and shares POST's
request semantics — the same size limit (`413`), content-type allowlist (`415`), empty or
non-UTF-8 body (`400`), and bearer token (`401`) — with one deliberate difference:
omitting `Content-Type` keeps the page's stored type instead of defaulting to HTML, so a
re-upload that forgets the header can't silently turn a stylesheet into a page browsers
refuse to apply. It reports the page's `expires` and never moves it, for the same reason it
never touches `created_at`, and a `?ttl=` on this verb is a `400` rather than a value
quietly dropped — accepting `?ttl=never` with a `200` and changing nothing would be the one
silent default the `POST` parser exists to prevent. The slug in the path obeys the
same grammar as a custom slug below; malformed or reserved is `400` rather than the
public `404`, because this side of the API is behind the upload token and has nothing to
hide from its caller. A well-formed slug with no *live* page at it is `404` — absent, or
expired and not yet cleaned up: `PUT` never creates, so publishing a new page is always
`POST`.

`DELETE /pages/:slug` removes the page and answers `204` with an empty body. There is no
`{slug, url}` to return — the URL that payload would carry now leads to the 404 page, and
handing back a dead link on a success response is worse than saying nothing. No request
body is read at all, so the size limit and the content-type allowlist have nothing to
apply to and neither `413` nor `415` can come back from this route; a `Content-Type` sent
anyway is ignored rather than rejected. Malformed or reserved is `400` and a well-formed
slug with no page at it is `404`, on the same reasoning as `PUT`: this side of the API is
behind the upload token and has nothing to hide from its caller, so a delete that removed
nothing says so instead of returning the idempotent `204` that would let a script delete a
typo and be told it worked.

An *expired* page is one of the slugs with no page at it. The delete carries the same
deadline predicate the reads and `PUT` do, so a `DELETE` aimed at a page that has passed its
`?ttl=` is a `404` even while the row is physically still there awaiting reclamation — the
write surface and the read surface agree on which pages exist, and answering `204` would
claim credit for removing something every reader already treats as gone. The row is left
for the next upload's reclamation rather than swept up here, so `delete` has exactly one
job. The practical consequence for a caller: you never need to delete a page to make it
expire, and a tidy-up pass over pages you published last week will earn a `404` each.

**The delete is hard, and the slug goes back into the pool.** The row is gone; nothing is
kept to mark the name as spent, so a later `POST ?slug=` can ask for it and the random
generator can draw it — which means a link that has already been shared may one day
resolve to somebody else's page. That is the trade, taken deliberately rather than
conceded: the alternative is a tombstone, which buys link stability by growing a table of
names nobody may ever use again and a `WHERE deleted_at IS NULL` on every read after it,
in exchange for protecting URLs that this server already treats as guessable rather than
secret. Deleting is the operation for giving a name up. A page whose link is out in the
world and must keep pointing somewhere sensible should be replaced with `PUT`, which never
lets go of the name.

Custom slugs are lowercase letters, digits and single interior hyphens, 3–64 characters.
Names the server uses for itself (`pages`, `healthz`, …) are rejected rather than
accepted-then-shadowed.

### How long a page lives

**Pages are ephemeral by default.** A `POST` with no `?ttl=` expires 7 days after it is
published; permanence is the deliberate opt-out, not the default.

| Query        | Lifetime                                   |
| ------------ | ------------------------------------------ |
| omitted      | 7 days                                     |
| `?ttl=30`    | 30 days; any whole number from 1 to 36500  |
| `?ttl=never` | Never expires                              |

Anything else — `0`, a negative, `7.5`, an empty value, a count past the maximum — is a
`400`. Nothing is silently rounded or defaulted: a rejected `ttl` means the page was not
published at all, because a caller who mistyped a lifetime and got a week-long page would
not find out until the link died. The upper bound exists because an unbounded day count is
`Date` arithmetic waiting to overflow, and because "effectively never" should be spelled
`never`.

Both writes report the result as an `expires` field: an RFC 3339 instant in UTC, or JSON
`null` for a page that never expires. It is always present — an absent key would read as
"the server has no opinion", and it always has one.

The default is the part worth arguing about, so: a page server whose links all last
forever accumulates every draft, preview and one-off anybody ever published, and nothing
about a link tells you afterwards which it was. Making the common case temporary costs one
query parameter on the pages that matter, and nothing at all on the ones that don't.

Expiry is enforced in two places, for two different reasons:

- **On read, for correctness.** The fetch query treats a page past its deadline as absent,
  so it stops being served at exactly the right moment regardless of cleanup — and it 404s
  with the same bytes every other miss does.
- **On write, to reclaim.** Each successful upload first deletes expired rows, which is
  what returns their slugs to the pool. A partial index (`WHERE expires_at IS NOT NULL`)
  keeps that cheap, since permanent pages never enter it. There is no cron and no
  scheduler: cleanup frequency scales with usage, and an idle server holding invisible
  expired rows is fine, because nothing can read them anyway.

A `NULL` expiry means "never expires", and that is the only thing it means: it is what
`?ttl=never` stores, and nothing else produces one.

**Pages published before this feature existed are not exempt.** Migration 2 backfills them
in the same breath as it adds the column, so they expire seven days after the upgrade runs.
That backfill has to live in that migration and nowhere else — one statement earlier the
column did not exist, so every `NULL` it sees is provably a pre-expiry page, whereas the
same `UPDATE` written any later could not tell those apart from a page whose author asked
for `never`. The interval is measured from the migration rather than from `created_at`,
because a page older than the default would otherwise arrive with a deadline already behind
it and be deleted by the very next upload — a feature meant to bound storage would open by
destroying the archive. Everything already published gets one full lifetime from the
upgrade, and anything worth keeping should be re-published with `?ttl=never` inside that
window.

Expired slugs return to the pool. Once the row is deleted the generator may draw the name
again, or a caller may claim it with `?slug=`. There are no tombstones: a name that expired
is a name that is free.

### A shared look

Pages published here can look like they belong together without anyone copying a
`<style>` block between them. One line in the `<head>` is the whole integration:

```html
<link rel="stylesheet" href="/assets/stele.css">
```

**Plain semantic HTML is styled with no classes at all** — headings, paragraphs, lists,
links, `code`, `pre`, tables, quotes, images. That is the important half: a page written
by someone who never read this section still comes out looking like the rest of the
server. The classes are opt-in extras for the handful of shapes HTML has no element for:

| Class                       | For                                                        |
| --------------------------- | ---------------------------------------------------------- |
| `.card`                     | A bordered surface panel around a title and a few lines     |
| `.grid`                     | A row of cards that rewraps itself; no breakpoints to pick  |
| `.scroll`                   | Wraps a too-wide table so it scrolls instead of squeezing    |
| `.callout`                  | A tinted aside with an accent left border                   |
| `.badge`                    | A small inline pill for a status, an HTTP method or a tag   |
| `.muted`                    | Secondary text — a subtitle, a caption, an aside            |
| `body.narrow` / `body.wide` | A short centred message page; or one carrying wide content  |

`.callout` and `.badge` share one tone vocabulary, added as a second class: `note` (the
default), `ok`, `warn`, `danger` — so `<div class="callout warn">` and
`<span class="badge ok">`. The two body modifiers go on the `<body>` element itself,
since what they change is the page's measure.

`.scroll` is the one class worth reaching for even on an otherwise plain page. A bare
`<table>` is styled — rounded frame, shaded head, alternating rows — but it can only
shrink to fit, so on a phone a table of any width degrades into columns broken across
three lines each. Wrapping it (`<div class="scroll"><table>…</table></div>`) lets it keep
its natural width and scroll inside the frame instead. Scrolling genuinely needs the
extra element: one box has to stay pinned to the page width while the other is free to be
wider than it, and a lone `<table>` cannot be both.

Code blocks get their colour the same opt-in way, and with no highlighter: the server
runs no parser and serves no JavaScript. The author wraps tokens in spans while writing
the snippet — `tok-kw`, `tok-str`, `tok-num`, `tok-fn`, `tok-type`, `tok-com` — which an
agent, the usual author here, does more reliably than a regex-based highlighter would
have. Anything left unwrapped keeps the default text colour, so a partially marked-up
snippet degrades to plain code rather than to anything broken.

Dark mode needs nothing from an author. Every colour comes from a `--stele-*` custom
property and a single `prefers-color-scheme` block reassigns those properties, so a page
that uses the classes is dark-mode-correct for free rather than carrying a second copy of
its own colours to keep in step. The same indirection is how you retheme without forking:
override the tokens in your own page — `:root { --stele-accent: #7c3aed; }` — instead of
restating the rules. The server's own landing and 404 pages link this sheet and carry no
CSS of their own, so it is the same stylesheet in use on every deploy, not a sample.

**There is no versioned path, and that is a real tradeoff.** `/assets/stele.css` mutates
in place: editing it restyles every page linking it, which is exactly the point — it is
how a fleet of already-published pages gets a fix — and it is also the risk. It is served
`no-cache` with an ETag, so a browser revalidates rather than pinning a stale copy, which
means a change lands on the next load whether the author wanted it or not. A page whose
appearance must never change should carry its own `<style>` and link nothing; so should
one that inlines overrides fitted to today's rules. That is the deal, accepted knowingly,
until it first bites.

Serving something at a fixed path costs nothing on the enumeration front: `/assets` is a
documented, server-owned prefix outside the single-segment slug namespace, and `GET /assets`
itself answers the same uniform 404 as every other miss, so a scanner that finds it learns
only what this README already told it. A deeper miss like `/assets/nope.css` gets the
framework's own 404 rather than the uniform page — a two-segment path can never be a slug,
so it has no namespace to leak.

### Teaching an agent to publish

`GET /skill` returns a SKILL.md — `text/markdown; charset=utf-8` — that teaches an agent
the whole publish contract: how to write the one self-contained HTML file, the component
classes above, the `curl` that publishes it, and what each failure status means. There is
no MCP server and no CLI to install; the skill wraps `curl`, which every agent already
has. Bootstrapping one anywhere is a single instruction:

```sh
curl https://stele.example.com/skill
```

The document is served by the deployment it documents, and is rendered from that
deployment's configuration rather than being a compile-time constant. Every value with exactly one constant behind
it — the base URL, `STELE_MAX_PAGE_BYTES`, the stylesheet path, the slug length bounds,
the reserved names, the accepted content types, and the whole `ttl` vocabulary (the
parameter's name, the `never` keyword, the default lifetime and its maximum) — is
interpolated from that constant, so
the `curl` an agent copies out is already pointed at the right host with the right limits.
That removes the opportunity for drift rather than detecting it afterwards: there is no
second copy of those values to fall out of step. What is left is prose, and the prose is
pinned by tests to the code it describes — the component table against the stylesheet's
own class list, the content types against the allowlist, the example slugs against
`Slug(custom:)` itself, and the lifetime table against `PageLifetime`.

This README is the one document that *cannot* interpolate any of that — it is a static
file, so every route, limit, keyword and lifetime in it is typed by hand. Changing the
contract therefore means changing this file in the same commit that changes the code.

Like the stylesheet, it ships with the app rather than living in Postgres: it changes by
deploy, not by upload, and a database copy could serve one version's documentation from a
deployment running another. It is Markdown, not a styled page, because the reader is an
agent.

**There is no versioned skill path, and it is the same tradeoff as the stylesheet.**
`/skill` mutates with the deployment, so an agent that cached the document yesterday may
publish against a contract that has since moved — and, symmetrically, a fix to the
instructions reaches every agent on its next fetch, which is the point. It is served
`no-cache` with a strong ETag, so a client revalidates rather than pinning a stale copy;
that makes the window small, not zero. Fetch the skill at the start of a publishing task,
not once at setup.

Serving it publicly leaks nothing: the document describes the routes this README already
describes, `skill` is a reserved name that no page can claim, and writes still need the
bearer token — an agent that reads the skill without one learns how to publish and cannot.
Unlike `/pages` and `/assets`, `/skill` needs no bare-segment 404 stub, because it is a
terminal node that carries its own value; a deeper miss like `/skill/nope` gets the
framework's own 404, which no single-segment slug could ever have reached.

## Configuration

Everything is environment variables, read once at startup — see `.env.example` for the
annotated list. A bad value stops the process immediately with a message naming the
variable, rather than surfacing later as a connection error.

`DATABASE_URL` is a standard libpq URL, including `?sslmode=` with libpq's semantics:
`require` encrypts without verifying the certificate (so a self-signed or IP-addressed
Postgres works, exactly as it does with psql), and only `verify-ca` / `verify-full`
check the chain and hostname. Switching databases is a one-line change.

## Deploying

Create the role and database on your Postgres host first:

```sql
CREATE ROLE stele LOGIN PASSWORD 'pick-something-strong';
CREATE DATABASE stele OWNER stele;
```

Then, on the host that will run the app:

```sh
cat > .env <<'EOF'
DATABASE_URL=postgres://stele:pick-something-strong@DB_HOST:5432/stele
STELE_UPLOAD_TOKEN=<openssl rand -hex 32>
STELE_BASE_URL=https://stele.example.com
EOF

docker compose -f docker-compose.deploy.yml up -d --build
```

All three of those variables are required and the stack refuses to start without them,
rather than defaulting to something that would quietly be wrong.

Nothing else changes — any unapplied migrations run on boot, exactly as they do locally.
An existing deployment needs no dump and restore: version 1 describes the schema it
already has, so the first boot after a version table exists records version 1 without
running anything, then applies whatever versions come after it.

Today that means version 2, and **it is not a schema-only migration: it puts a deadline on
every page you have already published.** Alongside the nullable `expires_at` and its
partial index, version 2 backfills every existing row to expire seven days after the
upgrade runs. When that week is up, the next upload reclaims them, and expired slugs leave
no tombstone — the pages and their names are gone. Re-publish anything worth keeping with
`?ttl=never` inside that window; "Page lifetimes" above argues out why the backfill belongs
in that migration and measures from the upgrade rather than from `created_at`. Budget for
it on a large table, too: the `ALTER` and the index are catalog-only, but the backfill
`UPDATE` rewrites every row before the server starts serving.

**Point `DATABASE_URL` at a host whose storage you trust.** Development machines often
run with durability tradeoffs that are fine for rebuildable data and not fine for the
only copy of something — writes the database reports as committed can be lost on a power
cut. The local `docker compose` database is for development only.

## Before this faces the internet

The current shape is built for a trusted LAN. Three things need attention first:

- **Stored pages are same-origin.** An uploaded page's JavaScript runs on the server's
  own domain. There's nothing to steal today — no cookies, no session, no authenticated
  reads — but it stops being harmless the moment this server grows any of those. Serving
  pages from a separate domain to the API is the durable fix.
- **One shared upload token.** No per-user attribution and no revocation short of
  rotating it for everyone.
- **No rate limiting.** Reads are unauthenticated and unmetered, which is what makes the
  enumeration note above practical rather than theoretical.
