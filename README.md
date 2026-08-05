# stele

Publish an HTML file, get a readable link back.

```
$ stele publish index.html
http://localhost:8080/radiant-surf-gecko
```

The `stele` CLI ([stele-cli](https://github.com/ProJedi1234/stele-cli)) holds the
credential so that whoever runs it — usually an agent — never has to. Underneath it is an
ordinary HTTP request, and curl still works if you are holding a token yourself:

```
$ curl -X POST localhost:8080/pages \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: text/html" \
    --data-binary @index.html
{"url":"http://localhost:8080/radiant-surf-gecko","slug":"radiant-surf-gecko"}
```

Anyone can then load `/radiant-surf-gecko` and get the page. Pages live in Postgres, so
the server holds no state and can be restarted or moved freely.

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
another. On the rare collision the server simply redraws (five attempts, then 503).

### Slugs are pretty, not secret

**A three-word slug is guessable by an attacker who is willing to scan.** 11.8M is a
large number for a human and a small one for a script. Anyone who can reach the server
can eventually enumerate every page on it.

That's a fine trade for publishing pages meant to be shared. It is *not* a fine trade if
a page's contents should stay private — an unguessable URL would be doing access-control
work it can't do at this size. If you need that, set `STELE_SLUG_WORDS=4` (~3 billion,
meaningfully harder) and treat even that as obscurity rather than security. Real privacy
needs an auth check on reads, which this server deliberately does not have.

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

The TTL column (issue #6) would ship as:

```swift
Migration(version: 2, statements: [
    "ALTER TABLE pages ADD COLUMN expires_at timestamptz",
    "CREATE INDEX pages_expires_at_idx ON pages (expires_at) WHERE expires_at IS NOT NULL",
])
```

— a versioned step, not another idempotent `ALTER` accumulating in a bootstrap function.
Nullable with no default, so it's a catalog-only change with no table rewrite.

Version 1 is the original schema written with `IF NOT EXISTS`, so a database created
before there was a version table simply records version 1 and carries on. Nothing is
dumped or restored.

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
| `GET /:slug`       | none   | The stored page, or a 404 page                         |
| `GET /assets/stele.css` | none | The shared stylesheet (see "A shared look")         |
| `GET /skill`       | none   | The publish skill, as Markdown (see "Teaching an agent to publish") |
| `POST /pages`      | `publish` | Stores the request body, returns `{slug, url}` as `201` |
| `PUT /pages/:slug` | `publish` | Replaces a stored page's body and content type, returns `{slug, url}` as `200` |
| `GET /admin/whoami` | any credential | Reports the credential presented — name, scopes, expiry, last use — and never a token |
| `POST /admin/clients` | `admin` | Mints a credential, returns `{token, client}` as `201`. The token is shown once and never again |
| `GET /admin/clients` | `admin` | Lists credentials — names, scopes, last use, revocation — and never a token |
| `DELETE /admin/clients/:name` | `admin` | Revokes one, returns the credential as `200`. The row stays |

The auth column names the *scope* a bearer token has to carry; see "Credentials" below.
`GET /admin` itself answers the same uniform 404 as any other miss, so nothing on the
public read surface advertises that the credential routes are there.

`GET /admin/whoami` is the one route under `/admin` that requires no scope, only a valid
credential. It is what `stele auth status` asks and what `stele auth login` checks before
writing a credential to disk — both of which a publish-only agent runs — so gating it on
`admin` would refuse the one question a working agent credential most needs answered. It
returns the same credential record the listing does, and like the listing it carries
neither the token nor its digest.

`POST /pages` takes the page as the raw request body, up to `STELE_MAX_PAGE_BYTES`
(default 1 MiB; larger is `413`). Add `?slug=my-page` to choose the name yourself — it's
validated by the same rules as a generated one, returning `400` if invalid and `409` if
taken. Accepted content types are `text/html` (default), `text/plain`, `text/css`, and
`text/markdown`; anything else is `415`. An empty or non-UTF-8 body is `400`, a missing
or wrong bearer token is `401`, and if five random draws in a row collide with existing
slugs the server gives up with `503` rather than retrying forever.

`PUT /pages/:slug` replaces an existing page's body and content type, and shares POST's
request semantics — the same size limit (`413`), content-type allowlist (`415`), empty or
non-UTF-8 body (`400`), and bearer token (`401`) — with one deliberate difference:
omitting `Content-Type` keeps the page's stored type instead of defaulting to HTML, so a
re-upload that forgets the header can't silently turn a stylesheet into a page browsers
refuse to apply. The slug in the path obeys the
same grammar as a custom slug below; malformed or reserved is `400` rather than the
public `404`, because this side of the API is behind the upload token and has nothing to
hide from its caller. A well-formed slug with no page at it is `404`: `PUT` never
creates, so publishing a new page is always `POST`.

Custom slugs are lowercase letters, digits and single interior hyphens, 3–64 characters.
Names the server uses for itself (`pages`, `healthz`, …) are rejected rather than
accepted-then-shadowed.

### Credentials

Every writer gets its own token. A credential is a row in `clients` — a name, a SHA-256
of the token, an array of scopes, and optional expiry and revocation timestamps — and the
token itself exists in plaintext exactly once, in the `201` that minted it. The server
stores only the digest and cannot produce it again, so a caller that loses it mints a
replacement rather than looking it up.

Scopes are what make revocation work. An agent's credential carries `publish` and nothing
else, so a leaked one can deface pages — bad, bounded, recoverable from a re-publish — but
it cannot reach `POST /admin/clients` to mint itself a second credential and revoke yours.
`admin` is the operator's scope and no agent holds it. A valid credential used outside its
scopes is `403`, not `401`: it is working exactly as issued, and answering `401` would send
someone to rotate a token whose only problem is that it was never allowed to do this.

Every *rejected* credential, on the other hand, gets one byte-identical `401`. Unknown,
revoked and expired are three facts a caller probing for a valid token learns none of —
the README's licence to return distinguishing errors applies to callers already behind the
token, and this one is not. A missing `Authorization` header keeps its own message, because
a caller who presented nothing has learned nothing.

**`STELE_UPLOAD_TOKEN` is now the admin credential, and it can no longer publish.** It
resolves to a synthesised client carrying `admin` alone, which is the bootstrap: minting
the first per-client credential otherwise needs a credential you cannot yet have. It stays
required and defaultless, and it moves out of every agent's environment into one
operator's:

```sh
curl -X POST "$STELE/admin/clients" \
    -H "Authorization: Bearer $STELE_UPLOAD_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"claude-code","scopes":["publish"],"expiresIn":7776000}'
```

`scopes` defaults to `["publish"]` and `expiresIn` is seconds from now, absent meaning no
expiry and anything past a century being a `400` — a `timestamptz` is microseconds in an
`Int64`, and a date far enough out is not a value the driver refuses but one it traps on.
Revoking is `DELETE /admin/clients/:name`; it keeps the first `revoked_at` rather than
moving it on a retry, and the row is never deleted — "which did I revoke, and when?" is the
question the listing exists to answer.

Rotating a credential is revoke, then mint again under the same name. Names are unique
among *live* credentials only: a revoked row keeps its name in the listing without
reserving it, so `claude-code` stays `claude-code` across a rotation instead of becoming
`claude-code-2`. Uniqueness still holds where it matters — there is at most one live
credential per name, which is what keeps `DELETE /admin/clients/:name` unambiguous, and it
always takes the live one.

Every write records the credential that made it in `pages.client_id`, on `POST` and on
`PUT` alike — the column says who wrote the bytes currently being served, so replacing a
page re-attributes it rather than leaving the original publisher credited for content they
did not write. Attribution is never served: `GET /:slug` answers with the page, and who
published it is the operator's question.

Pages published before any of this, or by the shared token, carry `client_id IS NULL`.
There was no honest owner to invent for them — the shared token is synthesised rather than
stored, so it has no row for a foreign key to point at.

### Clients, and the version gate

Writes are expected to come from [stele-cli](https://github.com/ProJedi1234/stele-cli),
which stores the credential in a `0600` file and never prints it. That is the whole point
of the split: the agent runs `stele publish page.html`, and the secret never enters its
context.

The CLI sends `User-Agent: stele-cli/<version>` on every write, and a build older than the
server's `minimumCLIVersion` gets `426 Upgrade Required` with the required version and the
reinstall command in the body — a contract mismatch that announces itself and names its own
fix, instead of surfacing later as a field nobody could decode. **A request with no such
`User-Agent` is never gated**, so curl keeps working; the header is a compatibility signal,
not a security control, and nothing behind it assumes a minimum client. `minimumCLIVersion`
lives in `Sources/SteleCore/SteleCLI.swift` alongside the clone URL and the install
commands, which are the only facts this repository hardcodes about that one — and the
publish skill interpolates all of them rather than restating any.

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
the whole publish contract: how to install the CLI, how to write the one self-contained
HTML file, the component classes above, the commands that publish and replace a page, and
what each failure status means. It assumes a machine with nothing on it, because on a fresh
machine that is the situation. Bootstrapping an agent anywhere is a single instruction:

```sh
curl https://stele.example.com/skill
```

The document is served by the deployment it documents, and is rendered from that
deployment's configuration rather than being a compile-time constant. Every value with exactly one constant behind
it — the base URL, `STELE_MAX_PAGE_BYTES`, the stylesheet path, the slug length bounds,
the reserved names, the accepted content types, and now the CLI's clone URL, install
commands and minimum version — is interpolated from that constant, so the
`stele auth login --host …` an agent copies out is already pointed at the right host with
the right limits. That removes the opportunity for drift rather than detecting it
afterwards: there is no second copy of those values to fall out of step, not even across
the two repositories. What is left is prose, and the prose is pinned by tests to the code
it describes — the component table against the stylesheet's own class list, the content
types against the allowlist, the example slugs against `Slug(custom:)` itself, and the only
version string in the document against `minimumCLIVersion`.

**The skill does not hand the agent a credential, and that is the load-bearing part.** It
tells the agent to check `stele auth status`, to install the tool if it is missing, and to
*ask the user* to run `stele auth login` — never to obtain, store or pass a token. An
earlier version of this document told the agent to hold `STELE_UPLOAD_TOKEN` and warned it
not to publish the secret it was holding; the CLI removes the secret from the model's reach
instead of asking it to be careful. A test asserts the document contains no
`Authorization`, no `Bearer` and no token-shaped instruction, because a well-meant edit
restoring any of them would work perfectly and quietly undo the whole arrangement.

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
describes, `skill` is a reserved name that no page can claim, and writes still need a
credential — an agent that reads the skill without one learns how to publish and cannot.
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

Nothing else changes — any unapplied migrations run on boot, exactly as they do locally.
An existing deployment needs no dump and restore: version 1 describes the schema it
already has, so the first boot after a version table exists records version 1 and does
nothing else. All three of those variables are required and the stack refuses to start without them,
rather than defaulting to something that would quietly be wrong.

**Point `DATABASE_URL` at a host whose storage you trust.** Development machines often
run with durability tradeoffs that are fine for rebuildable data and not fine for the
only copy of something — writes the database reports as committed can be lost on a power
cut. The local `docker compose` database is for development only.

## Before this faces the internet

The current shape is built for a trusted LAN. Two things need attention first:

- **Stored pages are same-origin.** An uploaded page's JavaScript runs on the server's
  own domain. There's nothing to steal today — no cookies, no session, no authenticated
  reads — but it stops being harmless the moment this server grows any of those. Serving
  pages from a separate domain to the API is the durable fix.
- **No rate limiting.** Reads are unauthenticated and unmetered, which is what makes the
  enumeration note above practical rather than theoretical.

Per-writer credentials used to be the third item on this list. They are done: each client
has its own scoped, expirable, revocable token, and the shared token has been demoted to
the operator's bootstrap credential — see "Credentials". The `pages.client_id` column that
records *which* credential published a page exists and is still unwritten, so attribution
is the remaining half of that item.
